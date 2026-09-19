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
    /// @dev extraApyBps is added to the base APY (bps, 10_000 = 100%); validUntil is inclusive (unix seconds);
    ///      nonce is single-use per wallet.
    ///
    ///      The two extra-limit fields are a BUDGET, not a per-stake grant. The staking contract meters what the
    ///      wallet has actually spent above its controller limit and subtracts it, so re-presenting a voucher (or
    ///      presenting a fresh one with the same numbers) never hands out the bonus again:
    ///        - extraLimitTotal   caps the bonus the wallet may hold open across ALL cells, in every phase;
    ///        - extraLimitPerCell caps the bonus it may hold open inside any single cell, a cell being one
    ///          (phase, period) pair -- the same period in a new phase is a different cell with its own cap.
    ///      Both are concurrent, matching the LimitController's own limits: closing a deposit frees its bonus.
    ///      Advancing the phase does NOT refill the budget -- it is one budget for the whole programme.
    ///      Example: extraLimitTotal = 50_000e18 with extraLimitPerCell = 50_000e18 lets a wallet put all 50,000
    ///      into one cell or split it across several, never holding more than 50,000 open at once; dropping
    ///      extraLimitPerCell to 10_000e18 forces the same total across at least five cells.
    struct StakeVoucher {
        address wallet;
        uint256 phase;
        uint256 period;
        uint256 extraApyBps;
        /// @dev The wallet's bonus budget for the whole programme, metered across every cell.
        uint256 extraLimitTotal;
        /// @dev How much of that budget is usable in any one (phase, period) cell. The cap exists to stop a
        ///      wallet pouring its whole bonus into a single period WITHIN a phase. Spreading it across phases
        ///      is deliberate and accepted -- a phase runs about a year, so the same period in consecutive
        ///      phases is not the concentration this guards against -- and extraLimitTotal is the ceiling that
        ///      spans them. Do NOT "fix" this by re-keying walletBonusUsedInCell to span phases: it would stop
        ///      matching the controller's per-(phase, period) `used`, and the base over-grant comes straight
        ///      back.
        uint256 extraLimitPerCell;
        uint256 validUntil;
        uint256 nonce;
    }
}
