// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title Clock
/// @notice Reads `block.timestamp` through an external call.
/// @dev With `via_ir = true` the Yul optimizer may treat TIMESTAMP as loop/function-invariant and CSE two
///      reads inside one test function, so `block.timestamp` read after `vm.warp` / `skip` can return the
///      pre-warp value. An external call is an optimization barrier, so `now()` always returns the live value.
///      See test/shared/ClockHazard.t.sol.
contract Clock {
    function now() external view returns (uint256) {
        return block.timestamp;
    }
}
