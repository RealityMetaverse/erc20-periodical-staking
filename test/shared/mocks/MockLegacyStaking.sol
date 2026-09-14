// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../../src/interfaces/IPeriodicalStakingContract.sol";

/// @notice Stand-in for the closed legacy VIP staking contract: a settable STAKING cell per
///         (wallet, phase, period). Unknown cells read 0 and never revert, like the real v0.2.4 mapping.
contract MockLegacyStaking is IPeriodicalStakingContract {
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _staked;
    mapping(address => uint256) internal _total;

    function setStaked(address wallet, uint256 phase, uint256 period, uint256 amount) external {
        _total[wallet] = _total[wallet] - _staked[wallet][phase][period] + amount;
        _staked[wallet][phase][period] = amount;
    }

    function userDataList(uint8 dataType, address wallet) external view returns (uint256) {
        return dataType == 0 ? _total[wallet] : 0;
    }

    function getUserPhasePeriodData(uint8 dataType, address wallet, uint256 phase, uint256 period)
        public
        view
        returns (uint256)
    {
        return dataType == 0 ? _staked[wallet][phase][period] : 0;
    }

    function getUserPhasePeriodDataBatch(
        uint8 dataType,
        address[] calldata wallets,
        uint256[] calldata phases,
        uint256[] calldata periods
    ) external view returns (uint256[] memory values) {
        values = new uint256[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            values[i] = getUserPhasePeriodData(dataType, wallets[i], phases[i], periods[i]);
        }
    }
}
