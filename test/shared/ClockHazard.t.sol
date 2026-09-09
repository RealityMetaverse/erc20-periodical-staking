// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Clock} from "./Clock.sol";

/// @title ClockHazard
/// @notice Documents the via_ir `block.timestamp` caching hazard that test/shared/Clock.sol works around.
/// @dev `test_hazard_*` show the raw pattern; `test_clock_*` show that routing the read through Clock is safe.
///      Which of the raw patterns is actually miscompiled depends on the solc version / optimizer settings,
///      so the raw tests only log and never fail; the Clock-based tests must always pass.
contract ClockHazardTest is Test {
    Clock internal clock = new Clock();

    function _now() internal view returns (uint256) {
        return clock.now();
    }

    /// @dev Raw pattern: read, warp, read. Records whether the second raw read observed the warp.
    function test_hazard_rawTimestampAfterWarp_isLogged() public {
        uint256 before = block.timestamp;
        vm.warp(before + 10 days);
        uint256 rawAfter = block.timestamp;
        uint256 clockAfter = _now();
        emit log_named_uint("raw block.timestamp after warp", rawAfter);
        emit log_named_uint("Clock.now() after warp", clockAfter);
        emit log_named_string(
            "verdict", rawAfter == clockAfter ? "raw read observed warp (no CSE)" : "raw read STALE (CSE hazard)"
        );
        assertEq(clockAfter, before + 10 days, "Clock must always see the warp");
    }

    /// @dev Raw pattern in a loop: `vm.warp(block.timestamp + 1 days)` three times. On solc 0.8.20 + via_ir
    ///      (pinned by this repo's pragma) TIMESTAMP is hoisted out of the loop, so every iteration warps to
    ///      the SAME target and only one day passes. This test asserts the hazard is present; if it ever
    ///      fails, the toolchain changed and the Clock workaround may be revisited (do not just delete it).
    function test_hazard_warpLoopFromRawTimestamp_losesWarps() public {
        uint256 start = _now();
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 1 days);
        }
        uint256 clockAfter = _now();
        emit log_named_uint("intended", start + 3 days);
        emit log_named_uint("actual (Clock)", clockAfter);
        assertEq(clockAfter, start + 1 days, "hazard no longer reproducible: revisit Clock workaround");

        // The same loop driven through Clock composes correctly.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(_now() + 1 days);
        }
        assertEq(_now(), start + 4 days, "Clock-driven loop must compose");
    }

    /// @dev Safe pattern: every read goes through Clock.
    function test_clock_seesEveryWarp() public {
        uint256 t0 = _now();
        vm.warp(t0 + 1 days);
        assertEq(_now(), t0 + 1 days);
        skip(2 days);
        assertEq(_now(), t0 + 3 days);
        vm.warp(_now() + 5 days);
        assertEq(_now(), t0 + 8 days);
    }
}
