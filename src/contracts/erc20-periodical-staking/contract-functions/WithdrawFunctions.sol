// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract WithdrawFunctions is ReadFunctions, WriteFunctions {
    /// @dev Shared body of withdrawDeposit / withdrawDepositPartial.
    ///      - Frozen: reverts `DepositFrozen`.
    ///      - TIME_LEFT: returns principal only and releases the reward reserved at stake time.
    ///      - INDEFINITE: returns principal plus the accrued reward, paid from the unreserved part of the pool
    ///        (`getCollectableReward()`, never the reserve promised to periodical deposits). When the free pool
    ///        cannot cover the whole accrued reward the payout is reduced to what is available, but only if
    ///        that reduced reward is at least `minReward`; otherwise the call reverts
    ///        `NotEnoughFundsInRewardPool(accrued, available)` and the deposit stays open and keeps accruing.
    ///        The unpaid remainder is never forfeited silently.
    function _withdrawDeposit(uint256 depositNumber, uint256 minReward) private {
        PackedDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];
        if ((targetDeposit.flags & FLAG_FROZEN) != 0) revert DepositFrozen(msg.sender, depositNumber);

        DepositStatus depositStatus = _status(targetDeposit);
        if (depositStatus != DepositStatus.TIME_LEFT && depositStatus != DepositStatus.INDEFINITE) {
            revert NotWithdrawable(depositNumber);
        }

        uint256 depositAmount = targetDeposit.amount;
        uint256 depositReward = 0;

        targetDeposit.withdrawalDate = SafeCast.toUint40(block.timestamp);

        if (depositStatus == DepositStatus.TIME_LEFT) {
            uint256 reserved = targetDeposit.rewardGenerated;
            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] -= reserved;
            totalDataList[Types.DataType.REWARD_EXPECTED] -= reserved;
            targetDeposit.rewardGenerated = 0;
        } else {
            // DepositStatus.INDEFINITE
            targetDeposit.stakingEndDate = SafeCast.toUint40(block.timestamp + 1);

            // The accrued reward is paid from the unreserved pool only (never the reserve promised to
            // periodical deposits). A shortfall is reduced to what is available, but never silently: the
            // caller's minReward floor decides whether a reduced payout is acceptable.
            depositReward = _calculateIndefiniteDepositReward(targetDeposit);
            uint256 available = getCollectableReward();
            if (depositReward > available) {
                if (available < minReward) revert NotEnoughFundsInRewardPool(depositReward, available);
                depositReward = available;
            }

            targetDeposit.rewardGenerated = SafeCast.toUint128(uint256(targetDeposit.rewardGenerated) + depositReward);
            rewardPool -= depositReward;
        }

        _updateAllDataAfterAction(
            Types.DataType.WITHDRAWAL,
            msg.sender,
            targetDeposit.stakingPhase,
            targetDeposit.stakingPeriod,
            depositAmount,
            depositReward
        );
        _updateActiveDepositStartIndex(msg.sender);

        emit Withdraw(msg.sender, depositNumber, depositAmount, depositReward);
        _sendToken(msg.sender, depositAmount + depositReward);
    }

    /// @notice Withdraw an open deposit in full.
    /// @dev TIME_LEFT (periodical, not yet matured): returns principal only; the reward reserved at stake time
    ///      is released. INDEFINITE: returns principal plus the whole accrued reward, paid from
    ///      `getCollectableReward()` (the unreserved part of the pool). If the free pool cannot cover the
    ///      accrued reward the call reverts `NotEnoughFundsInRewardPool(accrued, collectable)` and the deposit
    ///      stays open and keeps accruing; retry after a top-up, or use `withdrawDepositPartial` to close it
    ///      with a reduced reward. Reverts `NotWithdrawable` for matured or already closed deposits and
    ///      `DepositFrozen` for a frozen deposit.
    /// @param depositNumber Index of the deposit in the caller's deposit list
    function withdrawDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifAvailable(Types.DataType.WITHDRAWAL)
        ifDepositExists(depositNumber)
    {
        _withdrawDeposit(depositNumber, type(uint256).max);
    }

    /// @notice Withdraw an open deposit, accepting a reduced indefinite reward when the free pool is short.
    /// @dev Same as `withdrawDeposit`, except that an INDEFINITE deposit whose accrued reward exceeds
    ///      `getCollectableReward()` is closed with `min(accrued, collectable)` reward instead of reverting,
    ///      provided that reduced reward is at least `minReward`; otherwise the call reverts
    ///      `NotEnoughFundsInRewardPool(accrued, collectable)` and nothing changes. `minReward = 0` always
    ///      succeeds (principal is never locked behind an unpayable reward). The unpaid remainder stays in the
    ///      pool. For TIME_LEFT deposits `minReward` is ignored (they never pay a reward).
    /// @param depositNumber Index of the deposit in the caller's deposit list
    /// @param minReward Lowest reward the caller is willing to close the deposit for
    function withdrawDepositPartial(uint256 depositNumber, uint256 minReward)
        external
        nonReentrant
        ifAvailable(Types.DataType.WITHDRAWAL)
        ifDepositExists(depositNumber)
    {
        _withdrawDeposit(depositNumber, minReward);
    }
}
