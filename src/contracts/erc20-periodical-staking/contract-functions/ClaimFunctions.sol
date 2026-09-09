// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract ClaimFunctions is ReadFunctions, WriteFunctions {
    /// @dev Returns true when a payout actually happened (batch callers skip silently on false).
    ///      Reward accounting: the pool is NOT checked at stake time, so `rewardPool` may be below
    ///      `totalDataList[REWARD_EXPECTED]` until the owner tops up.
    ///      - READY_TO_CLAIM: pays the reward fixed at stake time. If the pool cannot cover it the claim reverts
    ///        `NotEnoughFundsInRewardPool` (skipped silently in batch); nothing is lost, the user retries after
    ///        `provideReward`.
    ///      - INDEFINITE: pays `min(accrued, getCollectableReward())`, i.e. only from the unreserved part of
    ///        the pool. The unpaid remainder keeps accruing on the deposit and can be claimed after a top-up.
    function _claimDeposit(uint256 depositNumber, bool isBatchClaim) private returns (bool) {
        DepositStatus depositStatus = checkDepositStatus(msg.sender, depositNumber);
        TokenDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];

        uint256 depositAmount = 0;
        uint256 depositReward = 0;

        if (depositStatus != DepositStatus.READY_TO_CLAIM && depositStatus != DepositStatus.INDEFINITE) {
            if (!isBatchClaim) revert NotClaimable(depositNumber);
            return false;
        }

        if (depositStatus == DepositStatus.READY_TO_CLAIM) {
            depositAmount = targetDeposit.amount;
            depositReward = targetDeposit.rewardGenerated;

            // The pool may be short (no stake-time check); the user retries after a top-up, no loss.
            if (depositReward > rewardPool) {
                if (!isBatchClaim) revert NotEnoughFundsInRewardPool(depositReward, rewardPool);
                return false;
            }

            targetDeposit.withdrawalDate = block.timestamp;
            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] -= depositReward;
            totalDataList[Types.DataType.REWARD_EXPECTED] -= depositReward;
            userPhasePeriodDataList[Types.DataType.REWARD_EXPECTED][targetDeposit.stakingPhase][targetDeposit
                .stakingPeriod][msg.sender] -= depositReward;
        } else {
            depositReward = _calculateIndefiniteDepositReward(targetDeposit);
            uint256 collectable = getCollectableReward();
            if (depositReward > collectable) depositReward = collectable;

            if (depositReward == 0) {
                if (!isBatchClaim) revert NoRewardToClaim(depositNumber);
                return false;
            }

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
        return true;
    }

    /// @notice Claim a single deposit.
    /// @dev READY_TO_CLAIM: pays principal + the reward fixed at stake time and closes the deposit; reverts
    ///      `NotEnoughFundsInRewardPool` if the pool is short (retry after a top-up). INDEFINITE: pays
    ///      `min(accrued, getCollectableReward())`; reverts `NoRewardToClaim` when that is 0.
    /// @param depositNumber Index of the deposit in the caller's deposit list
    function claimDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifAvailable(Types.DataType.CLAIM)
        ifDepositExists(depositNumber)
    {
        _claimDeposit(depositNumber, false);
    }

    /// @notice Claim every claimable deposit of the caller. Unbounded gas; heavy stakers should use claimRange.
    /// @dev Scans from the active-deposit cursor (everything before it is closed). Non-claimable deposits are
    ///      skipped silently, so this never reverts because of a single deposit's state.
    function claimAll() external nonReentrant ifAvailable(Types.DataType.CLAIM) {
        _claimRange(stakerActiveDepositStartIndex[msg.sender], stakerDepositList[msg.sender].length);
    }

    /// @notice Claim every claimable deposit with index in [fromIndex, toIndexExclusive). Strictly bounded scan.
    /// @dev The window is caller-chosen, so it always makes progress even when the deposits at the head of the
    ///      list are still open (the active cursor never moves past an open deposit). Non-claimable deposits
    ///      inside the window are skipped silently. Reverts `InvalidRange` when the window is empty or exceeds
    ///      checkDepositCountOfAddress(msg.sender).
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

    function _claimRange(uint256 fromIndex, uint256 toIndexExclusive) private {
        for (uint256 depositNumber = fromIndex; depositNumber < toIndexExclusive; depositNumber++) {
            _claimDeposit(depositNumber, true);
        }
    }
}
