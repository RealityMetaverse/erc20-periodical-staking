// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

/// @title Types
/// @notice Common type definitions for the staking system
library Types {
    // ======================================
    // =        DataType Enum               =
    // ======================================
    enum DataType {
        STAKING,
        WITHDRAWAL,
        CLAIM,
        REWARD_EXPECTED,
        REWARD_PROVIDED,
        REWARD_COLLECTED
    }

    // ======================================
    // =    PhasePeriodDataType Enum        =
    // ======================================
    enum PhasePeriodDataType {
        STAKING_TARGET,
        APY,
        STAKED
    }
}
