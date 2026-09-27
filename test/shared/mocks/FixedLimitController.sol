// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ILimitController} from "../../../src/interfaces/ILimitController.sol";
import {IPeriodicalStakingContract} from "../../../src/interfaces/IPeriodicalStakingContract.sol";

/// @notice Controller that returns fixed (possibly hostile) figures, to attack the stake-side headroom math.
/// @dev Its own file on purpose: implementing a src interface makes the file a forge "mock" (see foundry.toml), and a
///      mock is not rewritten by dynamic_test_linking, so a test file that DEFINED it inlined every src contract it
///      deploys and recompiled on every src body edit. Importing it from here keeps the test files ordinary.
contract FixedLimitController is ILimitController {
    uint256 public allowed;
    uint256 public used;
    /// @dev setLimitController only installs a controller whose stakingContract() is the staking contract.
    IPeriodicalStakingContract public immutable stakingContract;

    constructor(address staking_) {
        stakingContract = IPeriodicalStakingContract(staking_);
    }

    function set(uint256 allowed_, uint256 used_) external {
        allowed = allowed_;
        used = used_;
    }

    function getAllowedAndUsed(address, uint256, uint256) external view returns (uint256, uint256) {
        return (allowed, used);
    }

    function getRemaining(address, uint256, uint256) external view returns (uint256) {
        return used >= allowed ? 0 : allowed - used;
    }

    function getRemainingBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (uint256[] memory)
    {
        return new uint256[](wallets.length);
    }

    function getAllowedBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (uint256[] memory)
    {
        return new uint256[](wallets.length);
    }
}
