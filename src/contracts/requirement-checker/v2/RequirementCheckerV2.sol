// SPDX-License-Identifier: BUSL-1.1
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import "./contract-functions/ReadFunctions.sol";

/// @title RequirementCheckerV2
/// @notice Aggregates a wallet's worth across a mutable worthToken balance, pool-based staking, periodical staking, and ERC1155 NFT holdings — with per-wallet signed admin offsets applied on every source (clamped at 0 per entity) so admins can credit or penalize specific wallets without moving real balances. Drop-in replacement for RequirementChecker via the shared IRequirementChecker interface; consumers switch by calling setRequirementChecker with a V2 address. Admin-side V1 migration uses cloneConfigFrom (enumerable config) and clonePhasePeriodRequirements (admin-supplied phase/period pairs) as two one-shot owner calls.
contract RequirementCheckerV2 is ReadFunctions {
    /// @param _worthToken ERC20 token used to measure worth
    /// @param _poolStakingContracts List of pool-based staking contracts
    /// @param _periodicalStakingContracts List of periodical staking contracts
    /// @param _defaultRequiredWorth Minimum worth required to pass the check
    constructor(
        address _worthToken,
        address[] memory _poolStakingContracts,
        address[] memory _periodicalStakingContracts,
        uint256 _defaultRequiredWorth
    ) Ownable(msg.sender) {
        if (_worthToken == address(0)) revert ZeroAddressProvided();

        worthToken = IERC20(_worthToken);
        _setPoolStakingContracts(_poolStakingContracts);
        _setPeriodicalStakingContracts(_periodicalStakingContracts);
        defaultRequiredWorth = _defaultRequiredWorth;
    }
}
