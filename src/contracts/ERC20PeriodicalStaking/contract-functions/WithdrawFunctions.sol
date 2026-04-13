// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract WithdrawFunctions is ReadFunctions, WriteFunctions {
    function withdrawDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifAvailable(Types.DataType.WITHDRAWAL)
        ifDepositExists(depositNumber)
    {
        DepositStatus depositStatus = checkDepositStatus(msg.sender, depositNumber);
        if (depositStatus != DepositStatus.TIME_LEFT && depositStatus != DepositStatus.INDEFINITE) {
            revert NotWithdrawable(depositNumber);
        }

        TokenDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];

        targetDeposit.withdrawalDate = block.timestamp;
        uint256 amountToSend = targetDeposit.amount;
        uint256 depositReward = 0;

        if (depositStatus == DepositStatus.TIME_LEFT) {
            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] -= targetDeposit.rewardGenerated;
            totalDataList[Types.DataType.REWARD_EXPECTED] -= targetDeposit.rewardGenerated;
            userPhasePeriodDataList[Types.DataType.REWARD_EXPECTED][targetDeposit.stakingPhase][targetDeposit
                .stakingPeriod][msg.sender] -= targetDeposit.rewardGenerated;
            targetDeposit.rewardGenerated = 0;
        } else {
            // DepositStatus.INDEFINITE
            targetDeposit.stakingEndDate = block.timestamp + 1;

            depositReward = _calculateIndefiniteDepositReward(targetDeposit);
            _checkIfEnoughFundsInRewardPool(depositReward, true);

            targetDeposit.rewardGenerated += depositReward;
            rewardPool -= depositReward;
            amountToSend += depositReward;
        }

        _updateAllDataAfterAction(
            Types.DataType.WITHDRAWAL,
            targetDeposit.stakingPhase,
            targetDeposit.stakingPeriod,
            targetDeposit.amount,
            depositReward
        );
        _updateActiveDepositStartIndex(msg.sender);

        emit Withdraw(msg.sender, depositNumber, targetDeposit.amount, depositReward);
        _sendToken(msg.sender, amountToSend);
    }
}
