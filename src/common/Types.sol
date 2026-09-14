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

    // ======================================
    // =        Stake Voucher (EIP-712)     =
    // ======================================
    /// @notice Backend-signed authorisation for one stake.
    /// @dev extraApyBps is added to the base APY (bps, 10_000 = 100%); extraLimit is added to the wallet's
    ///      controller limit for this stake; validUntil is inclusive (unix seconds); nonce is single-use per wallet.
    struct StakeVoucher {
        address wallet;
        uint256 phase;
        uint256 period;
        uint256 extraApyBps;
        uint256 extraLimit;
        uint256 validUntil;
        uint256 nonce;
    }
}
