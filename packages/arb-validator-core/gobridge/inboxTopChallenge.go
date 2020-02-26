/*
 * Copyright 2020, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package gobridge

import (
	"context"
	"errors"
	"github.com/offchainlabs/arbitrum/packages/arb-validator-core/arbbridge"
	"github.com/offchainlabs/arbitrum/packages/arb-validator-core/valprotocol"
	"math/big"

	"github.com/offchainlabs/arbitrum/packages/arb-util/common"
)

type inboxTopChallenge struct {
	*bisectionChallenge
}

func newInboxTopChallenge(address common.Address, client *GoArbAuthClient) (*inboxTopChallenge, error) {
	bisectionChallenge, err := newBisectionChallenge(address, client)
	if err != nil {
		return nil, err
	}
	return &inboxTopChallenge{bisectionChallenge: bisectionChallenge}, nil
}

func (c *inboxTopChallenge) Bisect(
	ctx context.Context,
	chainHashes []common.Hash,
	chainLength *big.Int,
) error {

	bisectionCount := len(chainHashes) - 1

	if !c.client.GoEthClient.challenges[c.contractAddress].challengerDataHash.Equals(valprotocol.InboxTopChallengeDataHash(chainHashes[0], chainHashes[bisectionCount], chainLength)) {
		return errors.New("Bisect Incorrect previous state")
	}

	if chainLength.Cmp(big.NewInt(1)) < 1 {
		return errors.New("Can't bisect chain of less than 2")
	}

	hashes := make([][32]byte, 0, bisectionCount)
	hashes = append(hashes, valprotocol.InboxTopChallengeDataHash(
		chainHashes[0],
		chainHashes[1],
		new(big.Int).Add(new(big.Int).Div(chainLength, big.NewInt(int64(bisectionCount))), new(big.Int).Mod(chainLength, big.NewInt(int64(bisectionCount)))),
	))
	for i := 1; i < bisectionCount; i++ {
		hashes = append(hashes, valprotocol.InboxTopChallengeDataHash(
			chainHashes[i],
			chainHashes[i+1],
			new(big.Int).Div(chainLength, big.NewInt(int64(bisectionCount)))))
	}

	c.commitToSegment(hashes)
	c.asserterResponded()

	c.client.GoEthClient.pubMsg(c.challengeData, arbbridge.MaybeEvent{
		Event: arbbridge.InboxTopBisectionEvent{
			ChainInfo: arbbridge.ChainInfo{
				BlockId: c.client.GoEthClient.getCurrentBlock(),
			},
			ChainHashes: chainHashes,
			TotalLength: chainLength,
			Deadline:    c.client.GoEthClient.challenges[c.contractAddress].deadline,
		},
	})
	return nil
}

func (c *inboxTopChallenge) OneStepProof(
	ctx context.Context,
	lowerHashA common.Hash,
	value common.Hash,
) error {
	matchHash := valprotocol.InboxTopChallengeDataHash(lowerHashA, valprotocol.AddMessageToPending(lowerHashA, value), big.NewInt(1))
	if !c.client.GoEthClient.challenges[c.contractAddress].challengerDataHash.Equals(matchHash) {
		return errors.New("OneStepProof Incorrect previous state")
	}

	c.client.GoEthClient.pubMsg(c.challengeData, arbbridge.MaybeEvent{
		Event: arbbridge.OneStepProofEvent{
			ChainInfo: arbbridge.ChainInfo{
				BlockId: c.client.GoEthClient.getCurrentBlock(),
			},
		},
	})
	//_asserterWin()

	return nil
}

func (c *inboxTopChallenge) ChooseSegment(
	ctx context.Context,
	assertionToChallenge uint16,
	chainHashes []common.Hash,
	chainLength uint64,
) error {
	bisectionCount := uint64(len(chainHashes) - 1)
	bisectionHashes := make([]common.Hash, 0, bisectionCount)
	for i := uint64(0); i < bisectionCount; i++ {
		stepCount := valprotocol.CalculateBisectionStepCount(i, bisectionCount, chainLength)

		bisectionHashes = append(
			bisectionHashes,
			valprotocol.InboxTopChallengeDataHash(
				chainHashes[i],
				chainHashes[i+1],
				new(big.Int).SetUint64(uint64(stepCount)),
			),
		)
	}
	return c.bisectionChallenge.chooseSegment(
		ctx,
		assertionToChallenge,
		bisectionHashes,
	)
}