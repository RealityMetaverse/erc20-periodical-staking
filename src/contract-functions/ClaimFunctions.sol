// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";

abstract contract ClaimFunctions is ReadFunctions, WriteFunctions {
    function _claimDeposit(uint256 depositNumber, bool isBatchClaim) private {
        DepositStatus depositStatus = checkDepositStatus(msg.sender, depositNumber);
        TokenDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];

        uint256 depositAmount = 0;
        uint256 depositReward = 0;

        if (depositStatus != DepositStatus.READY_TO_CLAIM && depositStatus != DepositStatus.INDEFINITE) {
            if (!isBatchClaim) revert NotClaimable(depositNumber);
            return;
        }

        if (depositStatus == DepositStatus.READY_TO_CLAIM) {
            depositAmount = targetDeposit.amount;
            depositReward = targetDeposit.rewardGenerated;
        } else {
            depositReward = _calculateIndefiniteDepositReward(targetDeposit);

            if (depositReward == 0) {
                if (!isBatchClaim) revert NoRewardToClaim(depositNumber);
                return;
            }
        }

        if (!_checkIfEnoughFundsInRewardPool(depositReward, false)) {
            if (!isBatchClaim) revert NotEnoughFundsInRewardPool(depositReward, rewardPool);
            return;
        }

        if (depositStatus == DepositStatus.READY_TO_CLAIM) {
            targetDeposit.withdrawalDate = block.timestamp;
            userDataList[DataType.REWARD_EXPECTED][msg.sender] -= depositReward;
            totalDataList[DataType.REWARD_EXPECTED] -= depositReward;
        } else {
            targetDeposit.rewardGenerated += depositReward;
        }

        rewardPool -= depositReward;
        uint256 amountToSend = depositAmount + depositReward;

        _updateAllDataAfterAction(
            DataType.CLAIM, targetDeposit.stakingPhase, targetDeposit.stakingPeriod, depositAmount, depositReward
        );
        _updateActiveDepositStartIndex(msg.sender);

        _sendToken(msg.sender, amountToSend);
    }

    function claimDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifAvailable(DataType.CLAIM)
        ifDepositExists(depositNumber)
    {
        _claimDeposit(depositNumber, false);
    }

    function claimAll() external nonReentrant ifAvailable(DataType.CLAIM) {
        uint256 userDepositCount = stakerDepositList[msg.sender].length;

        for (
            uint256 depositNumber = stakerActiveDepositStartIndex[msg.sender];
            depositNumber < userDepositCount;
            depositNumber++
        ) {
            _claimDeposit(depositNumber, true);
        }
    }
}
