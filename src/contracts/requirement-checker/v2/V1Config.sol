// SPDX-License-Identifier: BUSL-1.1
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

/// @dev Minimal read-only interface over V1's public getters, used by cloneConfigFrom
///      and clonePhasePeriodRequirements to migrate V1 configuration into this V2.
interface IRequirementCheckerV1Config {
    function worthToken() external view returns (address);
    function defaultRequiredWorth() external view returns (uint256);
    function stakingContractCount() external view returns (uint256);
    function stakingContracts(uint256) external view returns (address);
    function periodicalStakingContractCount() external view returns (uint256);
    function periodicalStakingContracts(uint256) external view returns (address);
    function erc1155ContractCount() external view returns (uint256);
    function erc1155Contracts(uint256) external view returns (address);
    function erc1155TrackedIds(address, uint256) external view returns (uint256);
    function erc1155IdWorth(address, uint256) external view returns (uint256);
    function requiredWorthPhasePeriod(uint256, uint256) external view returns (uint256);
}
