// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";
import {OpenLimitController} from "../../../shared/mocks/OpenLimitController.sol";

/// @title VoucherAttackBase
/// @notice AttackBase plus voucher-stake helpers shared by the attack suites: revert expectations that sign the
///         voucher BEFORE the prank (so no cheatcode or view call consumes it), raw calldata for low-level and
///         gas-measured stakes, and freeze/seize shorthands (the test contract is the owner).
abstract contract VoucherAttackBase is AttackBase {
    /// @dev Calldata for a validly signed stakeWithVoucher on `s` (no extras). Consumes a helper nonce.
    function _stakeData(
        ERC20PeriodicalStaking s,
        address u,
        uint256 phase,
        uint256 period,
        uint256 amount,
        uint256 expectedApyBps
    ) internal returns (bytes memory) {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(s, u, phase, period, 0, 0);
        return abi.encodeCall(s.stakeWithVoucher, (v, sig, amount, expectedApyBps));
    }

    /// @dev Expects a validly signed stake on `staking` to revert with exactly `err` (any revert when empty).
    function _expectStakeRevert(
        address u,
        uint256 phase,
        uint256 period,
        uint256 amount,
        uint256 expectedApyBps,
        bytes memory err
    ) internal {
        _expectStakeRevertOn(staking, u, phase, period, amount, expectedApyBps, err);
    }

    function _expectStakeRevertOn(
        ERC20PeriodicalStaking s,
        address u,
        uint256 phase,
        uint256 period,
        uint256 amount,
        uint256 expectedApyBps,
        bytes memory err
    ) internal {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(s, u, phase, period, 0, 0);
        vm.prank(u);
        if (err.length == 0) vm.expectRevert();
        else vm.expectRevert(err);
        s.stakeWithVoucher(v, sig, amount, expectedApyBps);
    }

    /// @dev Low-level signed stake on `staking`; returns whether it succeeded.
    function _tryStake(address u, uint256 phase, uint256 period, uint256 amount) internal returns (bool ok) {
        bytes memory data = _stakeData(staking, u, phase, period, amount, _apy(phase, period));
        vm.prank(u);
        (ok,) = address(staking).call(data);
    }

    function _freeze(address u, uint256 n) internal {
        staking.freezeDeposit(u, n);
    }

    function _seize(address u, uint256 n) internal {
        staking.seizeDeposit(u, n);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _oneU(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = x;
    }
}
