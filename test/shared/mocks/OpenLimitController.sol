// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../../src/interfaces/ILimitController.sol";
import "../../../src/interfaces/IPeriodicalStakingContract.sol";

/// @notice Permissive limit controller for generic fixtures: every wallet may stake without limit, and "used"
///         is the real STAKING cell of the staking contract (so the stake path exercises the real read).
contract OpenLimitController is ILimitController {
    address public immutable staking;

    constructor(address staking_) {
        staking = staking_;
    }

    function getAllowedAndUsed(address wallet, uint256 phase, uint256 period)
        external
        view
        returns (uint256 allowed, uint256 used)
    {
        return (type(uint256).max, IPeriodicalStakingContract(staking).getUserPhasePeriodData(0, wallet, phase, period));
    }

    function getRemaining(address, uint256, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getRemainingBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (uint256[] memory remainings)
    {
        remainings = _maxArray(wallets.length);
    }

    function getAllowedBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (uint256[] memory allowed)
    {
        allowed = _maxArray(wallets.length);
    }

    function _maxArray(uint256 n) private pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = type(uint256).max;
        }
    }
}
