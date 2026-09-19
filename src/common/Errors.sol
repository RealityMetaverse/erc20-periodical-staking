// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./Types.sol";

/// @title Errors
/// @notice Centralized error definitions for the staking system
abstract contract Errors {
    // ======================================
    // =        Common Errors               =
    // ======================================
    error ZeroAddressProvided();
    error ZeroAmountProvided();
    error LengthMismatch(uint256 expectedLength, uint256 actualLength);
    /// @notice The token balance delta observed on transfer-in differs from the requested amount
    ///         (fee-on-transfer / rebasing tokens are unsupported).
    error UnexpectedTokenAmount(uint256 expectedAmount, uint256 receivedAmount);
    /// @notice Rescue would touch staked principal or the reward pool.
    error RescueAmountExceedsExcess(uint256 requestedAmount, uint256 excessAmount);

    // ======================================
    // =    Staking Phase/Period Errors     =
    // ======================================
    error NoStakingPhasesAddedYet();
    error StakingPhaseDoesNotExist(uint256 stakingPhase);
    error IncorrectStakingPhase(uint256 expectedPhase, uint256 currentPhase);
    error StakingPeriodExists(uint256 stakingPeriod);
    error StakingPeriodDoesNotExist(uint256 stakingPeriod);

    // ======================================
    // =        Deposit Errors              =
    // ======================================
    error DepositDoesNotExist(uint256 depositNumber);
    error InvalidRange(uint256 fromIndex, uint256 toIndex);
    error NotWithdrawable(uint256 depositNumber);
    error NotClaimable(uint256 depositNumber);
    error InsufficientDeposit(uint256 _tokenSent, uint256 _requiredAmount);
    error DepositFrozen(address wallet, uint256 depositNumber);
    error DepositNotFrozen(address wallet, uint256 depositNumber);
    error DepositNotOpen(address wallet, uint256 depositNumber);

    // ======================================
    // =        Target & Limit Errors       =
    // ======================================
    error AmountExceedsTarget(uint256 stakingPhase, uint256 stakingPeriod, uint256 stakingTarget);
    /// @param allowed Remaining headroom for this stake (unused controller limit + unspent voucher bonus), 0 if none.
    error StakingLimitExceeded(address wallet, uint256 phase, uint256 period, uint256 requested, uint256 allowed);

    // ======================================
    // =        Reward Errors               =
    // ======================================
    error NotEnoughFundsInRewardPool(uint256 requestedAmount, uint256 availableAmount);
    error NoRewardToClaim(uint256 depositNumber);
    /// @notice Collecting this amount would leave the pool below the reward already committed to open deposits.
    error RewardPoolBelowReserved(uint256 requestedAmount, uint256 collectableAmount);

    // ======================================
    // =        Validation Errors           =
    // ======================================
    error InvalidAPY(uint256 providedValue, uint256 minValue);
    error InvalidMinimumDeposit(uint256 providedValue, uint256 minValue);
    error InvalidDataType();
    error ApyBelowExpected(uint256 stakingPhase, uint256 stakingPeriod, uint256 effectiveApyBps, uint256 expectedApyBps);

    // ======================================
    // =        Voucher Errors              =
    // ======================================
    error VoucherSignerNotSet();
    error LimitControllerNotSet();
    error TreasuryNotSet();
    error InvalidVoucherSignature();
    error VoucherWalletMismatch(address voucherWallet, address caller);
    error VoucherExpired(uint256 validUntil, uint256 currentTime);
    error VoucherNonceUsed(address wallet, uint256 nonce);
    error VoucherExtraApyTooHigh(uint256 extraApyBps, uint256 maxExtraApyBps);
    /// @notice The voucher's total bonus budget exceeds `maxExtraLimitTotal`. The budget is GLOBAL -- one budget
    ///         per wallet across every phase, which advancing the phase does not refill.
    error VoucherExtraLimitTotalTooHigh(uint256 extraLimitTotal, uint256 maxExtraLimitTotal);
    /// @notice The voucher's per-cell bonus allowance exceeds `maxExtraLimitPerCell`.
    error VoucherExtraLimitPerCellTooHigh(uint256 extraLimitPerCell, uint256 maxExtraLimitPerCell);
    /// @notice The voucher is valid for longer than `maxVoucherValidity` allows, measured from now.
    /// @dev Bounds the blast radius of a leaked signer key: a stolen key cannot mint vouchers good for years.
    error VoucherValidityTooLong(uint256 validUntil, uint256 maxValidUntil);
    /// @notice The wallet is barred from opening new stakes. Its existing deposits are unaffected and it can
    ///         still withdraw and claim -- a block never traps funds.
    error WalletBlocked(address wallet);

    // ======================================
    // =        Access Control Errors       =
    // ======================================
    error NotOpen(Types.DataType action);
    error NotPendingOwner(address caller, address pendingOwner);

    // ======================================
    // =        ERC1155 Errors              =
    // ======================================
    error ERC1155ContractNotFound(address token);
    error EmptyIdsArray();
}
