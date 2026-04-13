// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

/// @title Staking Contract Interface
/// @notice Interface for pool-based staking contracts
interface IStakingContract {
    function checkPoolCount() external view returns (uint256);
    function checkStakedAmountBy(address userAddress, uint256 poolId) external view returns (uint256);
}
