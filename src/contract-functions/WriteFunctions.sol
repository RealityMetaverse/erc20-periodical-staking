// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";

abstract contract WriteFunctions is ComplianceCheck {
    function _updateActiveDepositStartIndex(address userAddress) internal {
        uint256 userDepositCount = stakerDepositList[userAddress].length;
        uint256 currentIndex = stakerActiveDepositStartIndex[userAddress];

        for (uint256 i = currentIndex; i < userDepositCount; i++) {
            DepositStatus status = checkDepositStatus(userAddress, i);
            if (
                status == DepositStatus.TIME_LEFT || status == DepositStatus.READY_TO_CLAIM
                    || status == DepositStatus.INDEFINITE
            ) {
                stakerActiveDepositStartIndex[userAddress] = i;
                return;
            }
        }
    }

    function _updateAllDataAfterAction(
        DataType action,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 depositAmount,
        uint256 rewardAmount
    ) internal {
        if (action == DataType.STAKING) {
            userDataList[DataType.STAKING][msg.sender] += depositAmount;
            totalDataList[DataType.STAKING] += depositAmount;
            phasePeriodDataList[PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod] += depositAmount;
        } else {
            if (depositAmount != 0) {
                userDataList[DataType.STAKING][msg.sender] -= depositAmount;
                totalDataList[DataType.STAKING] -= depositAmount;
                phasePeriodDataList[PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod] -= depositAmount;

                userDataList[DataType.WITHDRAWAL][msg.sender] += depositAmount;
                totalDataList[DataType.WITHDRAWAL] += depositAmount;
            }

            if (rewardAmount != 0) {
                userDataList[DataType.CLAIM][msg.sender] += rewardAmount;
                totalDataList[DataType.CLAIM] += rewardAmount;
            }
        }
    }
}
