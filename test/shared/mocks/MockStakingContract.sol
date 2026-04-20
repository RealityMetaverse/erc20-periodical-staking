// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../../src/interfaces/IStakingContract.sol";

contract MockStakingContract is IStakingContract {
    uint256 internal _poolCount;
    mapping(address => mapping(uint256 => uint256)) internal _staked;

    constructor(uint256 poolCount_) {
        _poolCount = poolCount_;
    }

    function setStaked(address user, uint256 poolId, uint256 amount) external {
        _staked[user][poolId] = amount;
    }

    function checkPoolCount() external view returns (uint256) {
        return _poolCount;
    }

    function checkStakedAmountBy(address user, uint256 poolId) external view returns (uint256) {
        return _staked[user][poolId];
    }
}
