// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

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
            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] -= depositReward;
            totalDataList[Types.DataType.REWARD_EXPECTED] -= depositReward;
            userPhasePeriodDataList[Types.DataType.REWARD_EXPECTED][targetDeposit.stakingPhase][targetDeposit
                .stakingPeriod][msg.sender] -= depositReward;
        } else {
            targetDeposit.rewardGenerated += depositReward;
        }

        rewardPool -= depositReward;
        uint256 amountToSend = depositAmount + depositReward;

        _updateAllDataAfterAction(
            Types.DataType.CLAIM, targetDeposit.stakingPhase, targetDeposit.stakingPeriod, depositAmount, depositReward
        );
        _updateActiveDepositStartIndex(msg.sender);

        emit Claim(msg.sender, depositNumber, depositAmount, depositReward);
        _sendToken(msg.sender, amountToSend);
    }

    function claimDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifAvailable(Types.DataType.CLAIM)
        ifDepositExists(depositNumber)
    {
        _claimDeposit(depositNumber, false);
    }

    function claimAll() external nonReentrant ifAvailable(Types.DataType.CLAIM) {
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
