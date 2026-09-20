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
    /// @notice A freeze / unfreeze / seize / wallet-block batch was empty.
    error EmptyBatch();
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
    /// @notice An APY (bps), extra-APY ceiling (bps) or staking period (days) is above its hard upper bound.
    error ValueTooHigh(uint256 providedValue, uint256 maxValue);
    error InvalidMinimumDeposit(uint256 providedValue, uint256 minValue);
    error InvalidDataType();
    error ApyBelowExpected(uint256 stakingPhase, uint256 stakingPeriod, uint256 effectiveApyBps, uint256 expectedApyBps);

    // ======================================
    // =        Voucher Errors              =
    // ======================================
    error VoucherSignerNotSet();
    error LimitControllerNotSet();
    /// @notice The controller's stakingContract() is not this staking contract.
    error LimitControllerMismatch(address controllerStakingContract);
    error TreasuryNotSet();
    /// @notice The treasury cannot be the staking contract itself.
    error InvalidTreasury();
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
    /// @notice The voucher's signed lifetime (validUntil - issuedAt) is longer than `maxVoucherValidity` allows.
    /// @param maxValidUntil issuedAt + maxVoucherValidity
    error VoucherValidityTooLong(uint256 validUntil, uint256 maxValidUntil);
    /// @notice The voucher's issuedAt is in the future.
    error VoucherNotYetValid(uint256 issuedAt, uint256 currentTime);
    /// @notice The voucher was signed for another epoch (the owner called bumpVoucherEpoch since).
    error VoucherEpochMismatch(uint256 voucherEpoch, uint256 currentEpoch);
    /// @notice The wallet is barred from opening new stakes. Its existing deposits are unaffected and it can
    ///         still withdraw and claim -- a block never traps funds.
    error WalletBlocked(address wallet);

    // ======================================
    // =        Access Control Errors       =
    // ======================================
    error NotOpen(Types.DataType action);
    error NotPendingOwner(address caller, address pendingOwner);
    /// @notice renounceOwnership is disabled on the Ownable2Step-based satellite contracts (LimitController,
    ///         RequirementCheckerV2): an ownerless controller/checker could never be reconfigured again.
    error RenounceOwnershipDisabled();

    // ======================================
    // =   Requirement Checker v2 Errors    =
    // ======================================
    /// @notice The same address appears more than once in a pool / periodical staking contract list
    ///         (it would be counted once per occurrence by the worth reads).
    error DuplicateAddress(address entry);
    /// @notice The same ERC1155 id appears more than once in an ids array (it would be double counted).
    error DuplicateId(uint256 id);
    /// @notice An admin offset is outside [-MAX_ABS_OFFSET, MAX_ABS_OFFSET].
    error OffsetOutOfBounds(int256 offset, int256 maxAbsOffset);
    /// @notice A non-zero address with no code was supplied where a contract is required. Worth reads call it on
    ///         every wallet, and because meetsRequirementBatch isolates each entry, the failure would surface as a
    ///         SUCCESSFUL all-false batch -- indistinguishable from "nobody qualifies".
    error NotAContract(address supplied);

    // ======================================
    // =        ERC1155 Errors              =
    // ======================================
    error ERC1155ContractNotFound(address token);
    error EmptyIdsArray();
}
