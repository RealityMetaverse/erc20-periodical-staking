// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

/// @title Limit Controller Interface
/// @notice Interface for the limit controller contract
interface ILimitController {
    /// @notice Get the remaining allowed stake for a wallet in a phase period
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return remaining The remaining amount the wallet can stake
    function getRemaining(address wallet, uint256 phase, uint256 period) external view returns (uint256 remaining);

    /// @notice Batch get remaining allowed stakes for multiple wallet/phase/period combinations
    /// @param wallets Array of wallet addresses
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return remainings Array of remaining amounts each wallet can stake
    function getRemainingBatch(address[] calldata wallets, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory remainings);

    /// @notice Batch get maximum allowed stakes for multiple wallet/phase/period combinations
    /// @param wallets Array of wallet addresses
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return allowed Array of maximum amounts each wallet can stake
    function getAllowedBatch(address[] calldata wallets, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory allowed);
}
