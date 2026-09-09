// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";
import "../../../common/Types.sol";

abstract contract WriteFunctions is ComplianceCheck {
    function _updateActiveDepositStartIndex(address userAddress) internal {
        uint256 userDepositCount = stakerDepositList[userAddress].length;

        if (userDepositCount == 0) return;

        uint256 currentIndex = stakerActiveDepositStartIndex[userAddress];
        uint256 newStartIndex = userDepositCount - 1;

        for (uint256 i = currentIndex; i < userDepositCount; i++) {
            DepositStatus status = checkDepositStatus(userAddress, i);
            if (
                status == DepositStatus.TIME_LEFT || status == DepositStatus.READY_TO_CLAIM
                    || status == DepositStatus.INDEFINITE
            ) {
                newStartIndex = i;
                break;
            }
        }

        if (newStartIndex != currentIndex) {
            stakerActiveDepositStartIndex[userAddress] = newStartIndex;
        }
    }

    function _updateAllDataAfterAction(
        Types.DataType action,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 depositAmount,
        uint256 rewardAmount
    ) internal {
        if (action == Types.DataType.STAKING) {
            userDataList[Types.DataType.STAKING][msg.sender] += depositAmount;
            totalDataList[Types.DataType.STAKING] += depositAmount;
            phasePeriodDataList[Types.PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod] += depositAmount;
            userPhasePeriodDataList[Types.DataType.STAKING][stakingPhase][stakingPeriod][msg.sender] += depositAmount;
        } else {
            if (depositAmount != 0) {
                userDataList[Types.DataType.STAKING][msg.sender] -= depositAmount;
                totalDataList[Types.DataType.STAKING] -= depositAmount;
                phasePeriodDataList[Types.PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod] -= depositAmount;
                userPhasePeriodDataList[Types.DataType.STAKING][stakingPhase][stakingPeriod][msg.sender] -=
                    depositAmount;

                userDataList[Types.DataType.WITHDRAWAL][msg.sender] += depositAmount;
                totalDataList[Types.DataType.WITHDRAWAL] += depositAmount;
                userPhasePeriodDataList[Types.DataType.WITHDRAWAL][stakingPhase][stakingPeriod][msg.sender] +=
                    depositAmount;
            }

            if (rewardAmount != 0) {
                userDataList[Types.DataType.CLAIM][msg.sender] += rewardAmount;
                totalDataList[Types.DataType.CLAIM] += rewardAmount;
                userPhasePeriodDataList[Types.DataType.CLAIM][stakingPhase][stakingPeriod][msg.sender] += rewardAmount;
            }
        }
    }
}
