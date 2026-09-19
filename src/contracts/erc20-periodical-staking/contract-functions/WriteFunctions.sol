// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";
import "../../../common/Types.sol";

abstract contract WriteFunctions is ComplianceCheck {
    /// @dev Advance the user's active-deposit cursor past every closed (WITHDRAWN/CLAIMED/SEIZED) deposit.
    ///      When every deposit is closed the cursor equals the deposit count, so later loops are empty.
    function _updateActiveDepositStartIndex(address userAddress) internal {
        PackedDeposit[] storage deposits = stakerDepositList[userAddress];
        uint256 userDepositCount = deposits.length;

        if (userDepositCount == 0) return;

        uint256 currentIndex = stakerActiveDepositStartIndex[userAddress];
        uint256 newStartIndex = userDepositCount;

        for (uint256 i = currentIndex; i < userDepositCount;) {
            DepositStatus status = _status(deposits[i]);
            if (
                status == DepositStatus.TIME_LEFT || status == DepositStatus.READY_TO_CLAIM
                    || status == DepositStatus.INDEFINITE
            ) {
                newStartIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (newStartIndex != currentIndex) {
            stakerActiveDepositStartIndex[userAddress] = newStartIndex;
        }
    }

    /// @dev Return the voucher bonus a deposit consumed to the wallet's budget. Must be called from exactly the
    ///      places where the principal actually leaves the staking counters (full withdrawal, READY_TO_CLAIM
    ///      claim, seize) and nowhere else -- releasing while the position is still open is a double-spend of the
    ///      budget. Always pass the DEPOSIT's own phase AND period, never the current ones: the cell meter is
    ///      keyed on both, and a wrong phase there silently leaves base room suppressed in the cell the deposit
    ///      really sat in, while freeing a cell it never touched.
    /// @dev Saturating on both counters: a release can never strand budget, and the per-deposit entry is
    ///      deleted so a second call is a no-op.
    function _releaseBonus(address wallet, uint256 depositNumber, uint256 phase, uint256 period) internal {
        uint256 b = depositBonusUsed[wallet][depositNumber];
        if (b == 0) return;

        uint256 t = walletBonusUsed[wallet];
        walletBonusUsed[wallet] = t > b ? t - b : 0;

        uint256 c = walletBonusUsedInCell[phase][period][wallet];
        walletBonusUsedInCell[phase][period][wallet] = c > b ? c - b : 0;

        delete depositBonusUsed[wallet][depositNumber];

        emit BonusReleased(wallet, phase, period, depositNumber, b);
    }

    /// @dev STAKING adds the principal to every staking counter. Any other action is a close: the principal
    ///      leaves the staking counters (freeing the controller limit) and is recorded as WITHDRAWAL, and the
    ///      reward is recorded as CLAIM.
    function _updateAllDataAfterAction(
        Types.DataType action,
        address user,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 depositAmount,
        uint256 rewardAmount
    ) internal {
        if (action == Types.DataType.STAKING) {
            userDataList[Types.DataType.STAKING][user] += depositAmount;
            totalDataList[Types.DataType.STAKING] += depositAmount;
            phasePeriodDataList[Types.PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod] += depositAmount;
            userPhasePeriodStaked[stakingPhase][stakingPeriod][user] += depositAmount;
        } else {
            if (depositAmount != 0) {
                userDataList[Types.DataType.STAKING][user] -= depositAmount;
                totalDataList[Types.DataType.STAKING] -= depositAmount;
                phasePeriodDataList[Types.PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod] -= depositAmount;
                userPhasePeriodStaked[stakingPhase][stakingPeriod][user] -= depositAmount;

                userDataList[Types.DataType.WITHDRAWAL][user] += depositAmount;
                totalDataList[Types.DataType.WITHDRAWAL] += depositAmount;
            }

            if (rewardAmount != 0) {
                userDataList[Types.DataType.CLAIM][user] += rewardAmount;
                totalDataList[Types.DataType.CLAIM] += rewardAmount;
            }
        }
    }
}
