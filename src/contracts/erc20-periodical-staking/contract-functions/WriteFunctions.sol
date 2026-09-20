// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";
import "../../../common/Types.sol";

abstract contract WriteFunctions is ComplianceCheck {
    /// @dev Most deposits one cursor update may walk. Bounds the gas a close can be charged for the scan
    ///      (each step is a cold deposit read) no matter how many closed deposits sit behind the one closing.
    uint256 internal constant MAX_CURSOR_SCAN = 256;

    /// @dev Most deposits one permissionless `advanceCursor` call may walk. Higher than MAX_CURSOR_SCAN because
    ///      the caller chooses to pay for it and is not piggybacking on someone's claim or withdrawal.
    uint256 internal constant MAX_CURSOR_ADVANCE = 1024;

    /// @notice Pay down a lagging active-deposit cursor for any wallet. Permissionless.
    /// @dev Maintenance only: it moves the cursor past deposits that are already closed and can never move it
    ///      past an open one, so it changes no balance, no counter and no deposit. It exists because the close
    ///      paths only run the scan as a side effect of a claim / withdrawal / seize: once every deposit of a
    ///      wallet is closed, nothing triggers the scan again and a cursor left behind by the MAX_CURSOR_SCAN
    ///      cap would stay there forever, making every later `claimAll` and `checkClaimableDataFor` re-walk the
    ///      closed tail. Anyone (an ops bot, the wallet itself, an indexer) can call this to bring it forward.
    ///      Idempotent: a call that finds nothing to skip writes nothing.
    /// @param wallet The wallet whose cursor to advance
    /// @param maxSteps Deposits to walk at most; 0 or a value above MAX_CURSOR_ADVANCE means MAX_CURSOR_ADVANCE
    /// @return newStartIndex The wallet's cursor after this call
    function advanceCursor(address wallet, uint256 maxSteps) external returns (uint256 newStartIndex) {
        if (maxSteps == 0 || maxSteps > MAX_CURSOR_ADVANCE) maxSteps = MAX_CURSOR_ADVANCE;
        _advanceCursor(wallet, maxSteps);
        return stakerActiveDepositStartIndex[wallet];
    }

    /// @dev Advance the user's active-deposit cursor past closed (WITHDRAWN/CLAIMED/SEIZED) deposits, at most
    ///      MAX_CURSOR_SCAN of them per call; the progress made is stored and the next close carries on from
    ///      there. The cursor is therefore a LOWER-BOUND HINT: everything before it is closed, but deposits at
    ///      or after it may be closed too, and it may sit below the deposit count when every deposit is closed.
    ///      Every reader (claimAll, checkClaimableDataFor) checks each deposit's status itself, so a lagging
    ///      cursor costs them gas, never correctness. Do not write code that assumes the cursor is exact.
    ///      `advanceCursor` can always pay a lagging cursor down without closing anything.
    function _updateActiveDepositStartIndex(address userAddress) internal {
        _advanceCursor(userAddress, MAX_CURSOR_SCAN);
    }

    /// @dev Shared bounded scan behind both the close paths and `advanceCursor`. Stops at the first deposit
    ///      that is still open (TIME_LEFT / READY_TO_CLAIM / INDEFINITE), at `maxSteps` steps, or at the end of
    ///      the deposit list, whichever comes first, and only writes when it actually moved.
    function _advanceCursor(address userAddress, uint256 maxSteps) private {
        PackedDeposit[] storage deposits = stakerDepositList[userAddress];

        uint256 currentIndex = stakerActiveDepositStartIndex[userAddress];
        uint256 scanEnd = currentIndex + maxSteps;
        {
            uint256 userDepositCount = deposits.length;
            if (scanEnd > userDepositCount) scanEnd = userDepositCount;
        }

        uint256 newStartIndex = currentIndex;
        while (newStartIndex < scanEnd) {
            DepositStatus status = _status(deposits[newStartIndex]);
            if (
                status == DepositStatus.TIME_LEFT || status == DepositStatus.READY_TO_CLAIM
                    || status == DepositStatus.INDEFINITE
            ) break;
            unchecked {
                ++newStartIndex;
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
