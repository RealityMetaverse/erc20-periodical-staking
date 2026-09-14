// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./Types.sol";

/// @title Events
/// @notice Centralized event definitions for the staking system
abstract contract Events {
    /// @notice Emitted when ownership transfer completes (pending owner accepted).
    event TransferOwnership(address from, address to);
    /// @notice Emitted when the owner proposes a new owner; transfer completes on acceptOwnership.
    event OwnershipTransferStarted(address indexed from, address indexed to);

    event AddContractAdmin(address indexed user);
    event RemoveContractAdmin(address indexed user);

    /// @param apyBps Effective APY of the deposit (base + voucher extra), in bps
    /// @param extraApyBps The voucher's extra APY, in bps
    event Stake(
        address indexed by,
        uint256 indexed stakingPhase,
        uint256 indexed stakingPeriod,
        uint256 apyBps,
        uint256 extraApyBps,
        uint256 tokenAmount,
        uint256 depositNumber,
        uint256 voucherNonce
    );
    event Withdraw(address indexed by, uint256 indexed depositNumber, uint256 stakedAmount, uint256 reward);
    event Claim(address indexed by, uint256 indexed depositNumber, uint256 stakedAmount, uint256 reward);

    event ProvideReward(address indexed by, uint256 tokenAmount);
    event CollectReward(address indexed by, uint256 tokenAmount);
    event RescueTokens(address indexed token, address indexed to, uint256 tokenAmount);

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

    event UpdateLimitController(address indexed controller);

    event UpdateVoucherSigner(address indexed signer);
    event UpdateMaxExtraApyBps(uint256 maxExtraApyBps);
    event UpdateMaxExtraLimit(uint256 maxExtraLimit);
    event UpdateTreasury(address indexed treasury);

    event FreezeDeposit(address indexed wallet, uint256 indexed depositNumber, address indexed by);
    event UnfreezeDeposit(address indexed wallet, uint256 indexed depositNumber, address indexed by);
    event SeizeDeposit(address indexed wallet, uint256 indexed depositNumber, address indexed treasury, uint256 principal);
}
