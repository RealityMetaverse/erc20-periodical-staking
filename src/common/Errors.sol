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
    error LengthMismatch(uint256 expectedLength, uint256 actualLength);

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
    error NotWithdrawable(uint256 depositNumber);
    error NotClaimable(uint256 depositNumber);
    error InsufficientDeposit(uint256 _tokenSent, uint256 _requiredAmount);

    // ======================================
    // =        Target & Limit Errors       =
    // ======================================
    error AmountExceedsTarget(uint256 stakingPhase, uint256 stakingPeriod, uint256 stakingTarget);
    error StakingLimitExceeded(address wallet, uint256 phase, uint256 period, uint256 requested, uint256 allowed);

    // ======================================
    // =        Reward Errors               =
    // ======================================
    error NotEnoughFundsInRewardPool(uint256 requestedAmount, uint256 availableAmount);
    error NoRewardToClaim(uint256 depositNumber);

    // ======================================
    // =        Validation Errors           =
    // ======================================
    error InvalidAPY(uint256 providedValue, uint256 minValue);
    error InvalidMinimumDeposit(uint256 providedValue, uint256 minValue);
    error InvalidDataType();
    error PhasePeriodAPYChanged(uint256 stakingPhase, uint256 stakingPeriod, uint256 currentAPY);

    // ======================================
    // =        Access Control Errors       =
    // ======================================
    error NotOpen(Types.DataType action);
    error NotWhitelisted(address user);
    error RequirementNotMet(uint256 requiredWorth, uint256 actualWorth);

    // ======================================
    // =        ERC1155 Errors              =
    // ======================================
    error ERC1155ContractNotFound(address token);
    error EmptyIdsArray();
}
