// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

/// @title Periodical Staking Contract Interface
/// @notice Interface for querying staking data from the ERC20PeriodicalStaking contract
interface IPeriodicalStakingContract {
    /// @notice Get aggregated user data (e.g., total staked)
    /// @param dataType The data type (0 = STAKING, 1 = WITHDRAWAL, etc.)
    /// @param userAddress The user address
    /// @return The aggregated data value for the user
    function userDataList(uint8 dataType, address userAddress) external view returns (uint256);

    /// @notice Get user phase period data (e.g., staking amount)
    /// @param dataType The data type (0 = STAKING, 1 = WITHDRAWAL, etc.)
    /// @param userAddress The user address
    /// @param stakingPhase The staking phase
    /// @param stakingPeriod The staking period
    /// @return The data value
    function getUserPhasePeriodData(uint8 dataType, address userAddress, uint256 stakingPhase, uint256 stakingPeriod)
        external
        view
        returns (uint256);

    /// @notice Batch get user phase period data for multiple combinations
    /// @param dataType The data type (0 = STAKING, 1 = WITHDRAWAL, etc.)
    /// @param userAddresses Array of user addresses
    /// @param stakingPhases Array of staking phases
    /// @param stakingPeriods Array of staking periods
    /// @return values Array of data values
    function getUserPhasePeriodDataBatch(
        uint8 dataType,
        address[] calldata userAddresses,
        uint256[] calldata stakingPhases,
        uint256[] calldata stakingPeriods
    ) external view returns (uint256[] memory values);
}
