// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.5.17;

import "./Node.sol";
import "./RollupLib.sol";
import "./Inbox.sol";
import "./Outbox.sol";

import "../challenge/ChallengeLib.sol";
import "../challenge/IChallengeFactory.sol";

contract Rollup is Inbox, Outbox {
    event SentLogs(bytes32 logsAccHash);

    struct Staker {
        uint256 latestStakedNode;
        uint256 amountStaked;
        // currentChallenge is 0 if staker is not in a challenge
        address currentChallenge;
        bool isZombie;
        bool isStaked;
    }

    struct ChallengeState {
        bytes32 inboxConsistencyHash;
        bytes32 inboxDeltaHash;
        bytes32 executionHash;
        uint256 executionCheckTime;
    }

    uint256 latestConfirmed;
    uint256 firstUnresolvedNode;
    uint256 latestNodeCreated;
    Node[] nodes;
    uint256 lastStakeBlock;
    uint256 stakerCount;
    mapping(address => Staker) stakers;

    uint256 baseStake;
    uint256 challengePeriod;

    uint256 arbGasSpeedLimitPerBlock;

    IChallengeFactory public challengeFactory;

    constructor(bytes32 _machineHash, address _challengeFactory) public {
        challengeFactory = IChallengeFactory(_challengeFactory);
        bytes32 state = RollupLib.nodeStateHash(
            block.number, // block proposed
            0,
            _machineHash,
            0, // inbox top
            0, // inbox count
            0, // send count
            0, // log count
            0 // inbox max couny
        );
        Node node = new Node(
            state,
            0, // challenge hash (not challengeable)
            0, // confirm data
            latestConfirmed,
            0 // deadline block (not challengeable)
        );
        nodes[0] = node;
    }

    function rejectNextNode(uint256 successorWithStake, address stakerAddress) external {
        // No stake has been placed during the last challengePeriod blocks
        require(block.number - lastStakeBlock >= challengePeriod);

        require(!stakers[stakerAddress].isZombie);

        // Confirm that someone is staked on some sibling node
        Node stakedSiblingNode = nodes[successorWithStake];
        // stakedSiblingNode is a child of latestConfirmed
        require(stakedSiblingNode.prev() == latestConfirmed);
        // staker is actually staked on stakedSiblingNode
        require(stakedSiblingNode.stakers(stakerAddress));

        Node node = nodes[firstUnresolvedNode];
        node.checkConfirmInvalid();
        discardUnresolvedNode();
        node.destroy();
    }

    // If the node previous to this one is not the latest confirmed, we can reject immediately
    function rejectNextNodeOutOfOrder() external {
        Node node = nodes[firstUnresolvedNode];
        node.checkConfirmOutOfOrder(latestConfirmed);
        discardUnresolvedNode();
        node.destroy();
    }

    function confirmNextNode(
        bytes32 logAcc,
        bytes calldata messageData,
        uint256[] calldata messageLengths
    ) external {
        // No stake has been placed during the last challengePeriod blocks
        require(block.number - lastStakeBlock >= challengePeriod);
        Node node = nodes[firstUnresolvedNode];
        node.checkConfirmValid(stakerCount, latestConfirmed);

        bytes32 sendAcc = RollupLib.generateLastMessageHash(messageData, messageLengths);
        require(node.confirmData() == RollupLib.confirmHash(sendAcc, logAcc));

        processOutgoingMessages(messageData, messageLengths);

        emit SentLogs(logAcc);

        latestConfirmed = firstUnresolvedNode;
        discardUnresolvedNode();
        node.destroy();
    }

    function newStakeOnExistingNode(
        bytes32 blockHash,
        uint256 blockNumber,
        uint256 nodeNum
    ) external payable {
        require(blockhash(blockNumber) == blockHash, "invalid known block");
        verifyCanStake();
        // Must stake on valid node
        checkValidNodeNumForStake(nodeNum);
        Node node = nodes[nodeNum];
        require(node.prev() == latestConfirmed);
        addNewStaker(nodeNum, node);
    }

    function addStakeOnExistingNode(
        bytes32 blockHash,
        uint256 blockNumber,
        uint256 nodeNum
    ) external {
        require(blockhash(blockNumber) == blockHash, "invalid known block");
        checkValidNodeNumForStake(nodeNum);
        Staker storage staker = stakers[msg.sender];
        require(!staker.isZombie);
        Node node = nodes[nodeNum];
        require(staker.latestStakedNode == node.prev());
        node.addStaker(msg.sender);
        staker.latestStakedNode = nodeNum;
    }

    function newStakeOnNewNode(
        bytes32 blockHash,
        uint256 blockNumber,
        uint256 nodeNum,
        uint256 prev,
        bytes32[7] calldata assertionBytes32Fields,
        uint256[11] calldata assertionIntFields
    ) external payable {
        require(blockhash(blockNumber) == blockHash, "invalid known block");
        verifyCanStake();
        require(nodeNum == latestNodeCreated + 1);
        require(prev == latestConfirmed);

        RollupLib.Assertion memory assertion = RollupLib.decodeAssertion(
            assertionBytes32Fields,
            assertionIntFields
        );

        Node node = createNewNode(assertion, prev);

        addNewStaker(nodeNum, node);
        nodes[nodeNum] = node;
        latestNodeCreated++;
    }

    function addStakeOnNewNode(
        bytes32 blockHash,
        uint256 blockNumber,
        uint256 nodeNum,
        bytes32[7] calldata assertionBytes32Fields,
        uint256[11] calldata assertionIntFields
    ) external {
        require(blockhash(blockNumber) == blockHash, "invalid known block");
        require(nodeNum == latestNodeCreated + 1);
        Staker storage staker = stakers[msg.sender];
        require(!staker.isZombie);

        RollupLib.Assertion memory assertion = RollupLib.decodeAssertion(
            assertionBytes32Fields,
            assertionIntFields
        );

        Node node = createNewNode(assertion, staker.latestStakedNode);

        node.addStaker(msg.sender);
        nodes[nodeNum] = node;
        staker.latestStakedNode = nodeNum;
        latestNodeCreated++;
    }

    function returnOldDeposit(address payable stakerAddress) external {
        Staker storage staker = stakers[stakerAddress];
        checkUnchallengedStaker(staker);
        require(staker.latestStakedNode <= latestConfirmed);

        delete stakers[stakerAddress];
        // TODO: Staker could force transfer to revert. We may want to allow funds to be withdrawn separately
        stakerAddress.transfer(staker.amountStaked);
    }

    function addToDeposit() external payable {
        Staker storage staker = stakers[msg.sender];
        checkUnchallengedStaker(staker);
        staker.amountStaked += msg.value;
    }

    function reduceDeposit(uint256 maxReduction) external {
        Staker storage staker = stakers[msg.sender];
        checkUnchallengedStaker(staker);
        uint256 currentRequired = currentRequiredStake();
        require(staker.amountStaked > currentRequired);
        uint256 withdrawAmount = staker.amountStaked - currentRequired;
        // Cap withdrawAmount at maxReduction
        if (withdrawAmount > maxReduction) {
            withdrawAmount = maxReduction;
        }
        msg.sender.transfer(withdrawAmount);
    }

    function removeZombieStaker(uint256 nodeNum, address stakerAddress) external {
        require(stakers[stakerAddress].isZombie);
        nodes[nodeNum].removeStaker(stakerAddress);
    }

    function createChallenge(
        address payable staker1Address,
        uint256 nodeNum1,
        address payable staker2Address,
        uint256 nodeNum2,
        bytes32 inboxConsistencyHash,
        bytes32 inboxDeltaHash,
        bytes32 executionHash,
        uint256 executionCheckTime
    ) external {
        createChallenge(
            staker1Address,
            nodeNum1,
            staker2Address,
            nodeNum2,
            ChallengeState(inboxConsistencyHash, inboxDeltaHash, executionHash, executionCheckTime)
        );
    }

    function completeChallenge(address winningStaker, address payable losingStaker) external {
        Staker storage winner = stakers[winningStaker];
        Staker storage loser = stakers[losingStaker];

        // Only the challenge contract can declare winners and losers
        require(winner.currentChallenge == msg.sender);
        require(loser.currentChallenge == msg.sender);

        if (loser.amountStaked > winner.amountStaked) {
            uint256 extraLoserStake = loser.amountStaked - winner.amountStaked;
            // TODO: unsafe to transfer to the loser directly
            losingStaker.transfer(extraLoserStake);
            loser.amountStaked -= extraLoserStake;
        }

        winner.amountStaked += loser.amountStaked / 2;

        // TODO: deposit extra loser stake into ArbOS

        loser.amountStaked = 0;
        loser.isZombie = true;
        winner.currentChallenge = address(0);
        loser.currentChallenge = address(0);
    }

    function currentRequiredStake() public view returns (uint256) {
        uint256 MAX_INT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        if (block.number < nodes[latestConfirmed].deadlineBlock()) {
            return baseStake;
        }
        uint256 latestConfirmedAge = block.number - nodes[latestConfirmed].deadlineBlock();
        uint256 challengePeriodsPassed = latestConfirmedAge / challengePeriod;
        if (challengePeriodsPassed > 255) {
            challengePeriodsPassed = 255;
        }
        uint256 multiplier = 2**challengePeriodsPassed - 1;
        if (multiplier == 0) {
            multiplier = 1;
        }

        if (multiplier > MAX_INT / baseStake) {
            return MAX_INT;
        }

        return baseStake * multiplier;
    }

    function createNewNode(RollupLib.Assertion memory assertion, uint256 prev)
        private
        returns (Node)
    {
        Node prevNode = nodes[prev];
        // Make sure the previous state is correct against the node being built on
        require(RollupLib.beforeNodeStateHash(assertion) == prevNode.stateHash());

        // inboxMaxCount must be greater than beforeInboxCount since we can't have read past the end of the inbox
        require(assertion.inboxMessagesRead <= inboxMaxCount - assertion.beforeInboxCount);

        uint256 prevDeadlineBlock = prevNode.deadlineBlock();

        // Verify that assertion meets the minimum Delta time requirement
        uint256 minimumAssertionPeriod = challengePeriod / 10;
        uint256 timeSinceLastNode = block.number - assertion.beforeProposedBlock;
        require(timeSinceLastNode > minimumAssertionPeriod);

        // Minimum size requirements: each assertion must satisfy either
        require(
            // Consumes at least all inbox messages put into L1 inbox before your prev node’s L1 blocknum
            assertion.inboxMessagesRead >=
                assertion.beforeInboxMaxCount - assertion.beforeInboxCount ||
                // Consumes ArbGas >=100% of speed limit for time since your prev node (based on difference in L1 blocknum)
                assertion.gasUsed >= timeSinceLastNode * arbGasSpeedLimitPerBlock
        );

        // Don't allow an assertion to use above a maximum amount of gas representing 4 assertion periods worth of computation
        require(assertion.gasUsed <= minimumAssertionPeriod * 4 * arbGasSpeedLimitPerBlock);

        uint256 deadlineBlock = block.number + challengePeriod;
        if (deadlineBlock < prevDeadlineBlock) {
            deadlineBlock = prevDeadlineBlock;
        }
        uint256 executionCheckTimeBlocks = assertion.gasUsed / arbGasSpeedLimitPerBlock;
        deadlineBlock += executionCheckTimeBlocks;

        return
            new Node(
                RollupLib.nodeStateHash(assertion, inboxMaxCount),
                RollupLib.challengeRoot(
                    assertion,
                    inboxMaxCount,
                    inboxMaxValue,
                    executionCheckTimeBlocks
                ),
                RollupLib.confirmHash(assertion),
                prev,
                deadlineBlock
            );
    }

    function createChallenge(
        address payable staker1Address,
        uint256 nodeNum1,
        address payable staker2Address,
        uint256 nodeNum2,
        ChallengeState memory state
    ) private {
        Staker storage staker1 = stakers[staker1Address];
        Staker storage staker2 = stakers[staker2Address];
        Node node1 = nodes[nodeNum1];
        Node node2 = nodes[nodeNum2];

        checkUnchallengedStaker(staker1);
        require(node1.stakers(staker1Address));

        checkUnchallengedStaker(staker2);
        require(node2.stakers(staker2Address));

        require(node1.prev() == node2.prev());
        require(latestConfirmed < nodeNum1);
        require(nodeNum1 < nodeNum2);
        require(nodeNum2 <= latestNodeCreated);

        require(
            node1.challengeHash() ==
                ChallengeLib.challengeRootHash(
                    state.inboxConsistencyHash,
                    state.inboxDeltaHash,
                    state.executionHash,
                    state.executionCheckTime
                )
        );

        // Start a challenge between staker1 and staker2. Staker1 will defend the correctness of node1, and staker2 will challenge it.
        address challengeAddress = challengeFactory.createChallenge(
            state.inboxConsistencyHash,
            state.inboxDeltaHash,
            state.executionHash,
            state.executionCheckTime,
            staker1Address,
            staker2Address,
            challengePeriod
        );

        staker1.currentChallenge = challengeAddress;
        staker2.currentChallenge = challengeAddress;
    }

    function discardUnresolvedNode() private {
        // node can be discarded
        nodes[firstUnresolvedNode] = Node(0);
        firstUnresolvedNode++;
    }

    function verifyCanStake() private {
        // Verify that sender is not already a staker
        require(!stakers[msg.sender].isStaked);
        require(msg.value >= currentRequiredStake());
    }

    function addNewStaker(uint256 nodeNum, Node node) private {
        require(!stakers[msg.sender].isStaked, "ALREADY_STAKED");
        stakers[msg.sender] = Staker(nodeNum, msg.value, address(0), false, true);
        node.addStaker(msg.sender);
    }

    function checkValidNodeNumForStake(uint256 nodeNum) private view {
        require(nodeNum >= firstUnresolvedNode && nodeNum <= latestNodeCreated);
    }

    function checkUnchallengedStaker(Staker storage staker) private view {
        require(!staker.isZombie);
        require(staker.currentChallenge == address(0));
    }
}