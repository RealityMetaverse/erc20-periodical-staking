// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./Types.sol";

/// @title Events
/// @notice Centralized event definitions for the staking system
abstract contract Events {
    event TransferOwnership(address from, address to);

    event AddContractAdmin(address indexed user);
    event RemoveContractAdmin(address indexed user);

    event Stake(
        address indexed by,
        uint256 indexed stakingPhase,
        uint256 indexed stakingPeriod,
        uint256 APY,
        uint256 tokenAmount,
        uint256 depositNumber
    );
    event Withdraw(address indexed by, uint256 indexed depositNumber, uint256 stakedAmount, uint256 reward);
    event Claim(address indexed by, uint256 indexed depositNumber, uint256 stakedAmount, uint256 reward);

    event ProvideReward(address indexed by, uint256 tokenAmount);
    event CollectReward(address indexed by, uint256 tokenAmount);

    event UpdatePhasePeriodData(
        Types.PhasePeriodDataType indexed dataType,
        uint256 indexed stakingPhase,
        uint256 indexed stakingPeriod,
        uint256 newValue
    );

    event UpdateMinimumDeposit(uint256 newMinimumDeposit);
    event UpdateActionAvailability(Types.DataType action, bool isOpen);

    event AddStakingPhase(uint256 indexed newStakingPhase);
    event RemoveStakingPhase(uint256 indexed stakingPhase);
    event ChangeStakingPhase(uint256 indexed to);

    event AddStakingPeriod(uint256 indexed newStakingPeriod);
    event RemoveStakingPeriod(uint256 indexed stakingPeriod);

    event UpdateWhitelistStatus(bool enabled);
    event UpdateWhitelist(address indexed user, bool isWhitelisted);

    event UpdateLimitController(address indexed controller);

    event UpdateRequirementChecker(address indexed checker);
}
