// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract ClaimFunctions is ReadFunctions, WriteFunctions {
    /// @dev Books one claim and returns the amount owed to the caller (0 when a batch caller skips the deposit).
    ///      The caller moves the cursor and transfers the tokens.
    ///      Reward accounting: the pool is NOT checked at stake time, so `rewardPool` may be below
    ///      `totalDataList[REWARD_EXPECTED]` until the owner tops up.
    ///      - Frozen: reverts `DepositFrozen` (skipped silently in batch).
    ///      - READY_TO_CLAIM: pays the reward fixed at stake time. If the pool cannot cover it the claim reverts
    ///        `NotEnoughFundsInRewardPool` (skipped silently in batch); nothing is lost, the user retries after
    ///        `provideReward`.
    ///      - INDEFINITE: pays `min(accrued, getCollectableReward())`, i.e. only from the unreserved part of
    ///        the pool. The unpaid remainder keeps accruing on the deposit and can be claimed after a top-up.
    function _claimDeposit(uint256 depositNumber, bool isBatchClaim) private returns (uint256 amountToSend) {
        PackedDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];

        if ((targetDeposit.flags & FLAG_FROZEN) != 0) {
            if (!isBatchClaim) revert DepositFrozen(msg.sender, depositNumber);
            return 0;
        }

        DepositStatus depositStatus = _status(targetDeposit);
        if (depositStatus != DepositStatus.READY_TO_CLAIM && depositStatus != DepositStatus.INDEFINITE) {
            if (!isBatchClaim) revert NotClaimable(depositNumber);
            return 0;
        }

        uint256 depositAmount = 0;
        uint256 depositReward = 0;
        uint256 pool = rewardPool;

        if (depositStatus == DepositStatus.READY_TO_CLAIM) {
            depositAmount = targetDeposit.amount;
            depositReward = targetDeposit.rewardGenerated;

            // The pool may be short (no stake-time check); the user retries after a top-up, no loss.
            if (depositReward > pool) {
                if (!isBatchClaim) revert NotEnoughFundsInRewardPool(depositReward, pool);
                return 0;
            }

            targetDeposit.withdrawalDate = SafeCast.toUint40(block.timestamp);
            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] -= depositReward;
            totalDataList[Types.DataType.REWARD_EXPECTED] -= depositReward;

            // Only here: this branch closes the deposit and returns the principal. The INDEFINITE branch below
            // pays reward only and leaves the position open, so releasing there would free the budget while the
            // principal is still staked -- a straight double-spend.
            _releaseBonus(msg.sender, depositNumber, targetDeposit.stakingPhase, targetDeposit.stakingPeriod);
        } else {
            depositReward = _calculateIndefiniteDepositReward(targetDeposit);
            uint256 collectable = getCollectableReward();
            if (depositReward > collectable) depositReward = collectable;

            if (depositReward == 0) {
                if (!isBatchClaim) revert NoRewardToClaim(depositNumber);
                return 0;
            }

            targetDeposit.rewardGenerated = SafeCast.toUint128(uint256(targetDeposit.rewardGenerated) + depositReward);
        }

        rewardPool = pool - depositReward;
        amountToSend = depositAmount + depositReward;

        _updateAllDataAfterAction(
            Types.DataType.CLAIM,
            msg.sender,
            targetDeposit.stakingPhase,
            targetDeposit.stakingPeriod,
            depositAmount,
            depositReward
        );

        emit Claim(msg.sender, depositNumber, depositAmount, depositReward);
    }

    /// @notice Claim a single deposit.
    /// @dev READY_TO_CLAIM: pays principal + the reward fixed at stake time and closes the deposit; reverts
    ///      `NotEnoughFundsInRewardPool` if the pool is short (retry after a top-up). INDEFINITE: pays
    ///      `min(accrued, getCollectableReward())`; reverts `NoRewardToClaim` when that is 0. Reverts
    ///      `DepositFrozen` for a frozen deposit.
    /// @param depositNumber Index of the deposit in the caller's deposit list
    function claimDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifAvailable(Types.DataType.CLAIM)
        ifDepositExists(depositNumber)
    {
        uint256 amountToSend = _claimDeposit(depositNumber, false);
        _updateActiveDepositStartIndex(msg.sender);
        _sendToken(msg.sender, amountToSend);
    }

    /// @notice Claim every claimable deposit of the caller. Unbounded gas; heavy stakers should use claimRange.
    /// @dev Scans from the active-deposit cursor (everything before it is closed). Non-claimable and frozen
    ///      deposits are skipped silently, so this never reverts because of a single deposit's state.
    function claimAll() external nonReentrant ifAvailable(Types.DataType.CLAIM) {
        _claimRange(stakerActiveDepositStartIndex[msg.sender], stakerDepositList[msg.sender].length);
    }

    /// @notice Claim every claimable deposit with index in [fromIndex, toIndexExclusive). Strictly bounded scan.
    /// @dev The window is caller-chosen, so it always makes progress even when the deposits at the head of the
    ///      list are still open (the active cursor never moves past an open deposit). Non-claimable and frozen
    ///      deposits inside the window are skipped silently. Reverts `InvalidRange` when the window is empty or
    ///      exceeds checkDepositCountOfAddress(msg.sender).
    /// @param fromIndex First deposit index (inclusive)
    /// @param toIndexExclusive One past the last deposit index; at most checkDepositCountOfAddress(msg.sender)
    function claimRange(uint256 fromIndex, uint256 toIndexExclusive)
        external
        nonReentrant
        ifAvailable(Types.DataType.CLAIM)
    {
        if (fromIndex >= toIndexExclusive || toIndexExclusive > stakerDepositList[msg.sender].length) {
            revert InvalidRange(fromIndex, toIndexExclusive);
        }
        _claimRange(fromIndex, toIndexExclusive);
    }

    /// @dev One cursor update and one transfer for the whole window.
    function _claimRange(uint256 fromIndex, uint256 toIndexExclusive) private {
        uint256 total = 0;
        for (uint256 depositNumber = fromIndex; depositNumber < toIndexExclusive;) {
            total += _claimDeposit(depositNumber, true);
            unchecked {
                ++depositNumber;
            }
        }
        if (total != 0) {
            _updateActiveDepositStartIndex(msg.sender);
            _sendToken(msg.sender, total);
        }
    }
}
