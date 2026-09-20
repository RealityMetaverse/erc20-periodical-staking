// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {V050Base} from "../../v050/V050Base.sol";
import {Types} from "../../../src/common/Types.sol";
import {ProgramManager} from "../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Errors} from "../../../src/common/Errors.sol";

/// @notice Round-2 adversarial verification of the NEW permissionless `advanceCursor`.
///         Focus: can a third party HARM a wallet with it, and is the "closed" predicate the scan relies on
///         genuinely irreversible?
contract CursorAdversarial is V050Base, Errors {
    // ------------------------------------------------------------------
    // Harm: a third party must never be able to make a wallet's claimAll pay less
    // ------------------------------------------------------------------

    /// @dev Layout: closed prefix, then an OPEN matured deposit, then more. An attacker calling advanceCursor
    ///      with every interesting maxSteps must never move the cursor past the open one, and claimAll must
    ///      pay exactly the same as it would have without the attacker's calls.
    function test_v2_attackerCannotSkipAnOpenDeposit() public {
        for (uint256 i = 0; i < 5; i++) {
            stakeFor(alice, P30, 1e18);
        }
        stakeFor(alice, P90, 1e18); // index 5: matures later -> still TIME_LEFT at day 31
        for (uint256 i = 0; i < 5; i++) {
            stakeFor(alice, P30, 1e18); // 6..10
        }
        _warpDays(31);

        // Close 0..4 only.
        vm.prank(alice);
        staking.claimRange(0, 5);
        assertEq(staking.stakerActiveDepositStartIndex(alice), 5, "cursor at the open P90 deposit");

        uint256[6] memory steps = [uint256(0), 1, 5, 1023, 1024, type(uint256).max];
        for (uint256 i = 0; i < steps.length; i++) {
            vm.prank(rando);
            assertEq(staking.advanceCursor(alice, steps[i]), 5, "attacker moved the cursor past an open deposit");
        }

        // Everything 6..10 is claimable and must still be paid.
        (uint256 cs, uint256 cpr,) = staking.checkClaimableDataFor(alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        assertEq(token.balanceOf(alice) - before, cs + cpr, "claimAll paid less after the attacker's calls");
        assertGt(cs, 0, "sanity: something had to be claimable");

        // The P90 deposit is still open and still claimable later.
        assertEq(uint256(_status(alice, 5)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
        _warpDays(90);
        vm.prank(rando);
        staking.advanceCursor(alice, 0);
        before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        assertGt(token.balanceOf(alice) - before, 1e18, "the deposit the attacker tried to skip was lost");
    }

    /// @dev The closed predicate must be irreversible. A SEIZED deposit cannot be unfrozen back into an open
    ///      state, so a cursor advanced past it can never be wrong afterwards.
    function test_v2_seizedIsPermanentlyClosed() public {
        stakeFor(alice, P0, 1e18);
        stakeFor(alice, P0, 1e18);
        freezeAndSeize(alice, 0);
        assertEq(uint256(_status(alice, 0)), uint256(ProgramManager.DepositStatus.SEIZED));

        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 0), 1, "cursor should pass the seized deposit and stop at 1");

        // seize cleared FLAG_FROZEN, so unfreeze cannot resurrect it.
        vm.expectRevert(abi.encodeWithSelector(DepositNotFrozen.selector, alice, uint256(0)));
        staking.unfreezeDeposit(alice, 0);
        assertEq(uint256(_status(alice, 0)), uint256(ProgramManager.DepositStatus.SEIZED));
    }

    /// @dev A FROZEN but still-open deposit must stop the scan: freezing is reversible, so skipping it would
    ///      be the real loss-of-funds bug.
    function test_v2_frozenOpenDepositStopsTheScanAndSurvivesUnfreeze() public {
        stakeFor(alice, P30, 1e18);
        stakeFor(alice, P30, 1e18);
        stakeFor(alice, P30, 1e18);
        _warpDays(31);
        freeze(alice, 0);

        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 1024), 0, "scan must stop at a frozen OPEN deposit");

        unfreeze(alice, 0);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        assertGt(token.balanceOf(alice) - before, 3e18, "frozen-then-unfrozen deposit was skipped");
    }

    // ------------------------------------------------------------------
    // Bounds
    // ------------------------------------------------------------------

    /// @dev maxSteps clamping, monotonicity, and the count bound, over a closed 1500-deposit prefix.
    function test_v2_clampMonotonicityAndCountBound() public {
        uint256 n = 1500;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);
        vm.prank(alice);
        staking.claimRange(0, n);
        uint256 c = staking.stakerActiveDepositStartIndex(alice);
        assertEq(c, 256, "MAX_CURSOR_SCAN");

        // 0 clamps up to 1024.
        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 0), 256 + 1024);
        // > 1024 clamps down to 1024 (would otherwise reach 1500 in one call).
        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, type(uint256).max), n, "clamped to 1024 then hit the count bound");
        // Never exceeds the count, never moves backwards.
        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 1024), n);
        assertEq(staking.checkDepositCountOfAddress(alice), n);
    }

    /// @dev maxSteps is honoured exactly below the cap: from a lagging cursor, step sizes 1, 2 and 3 move the
    ///      cursor by exactly that much and never more.
    function test_v2_maxStepsIsExact() public {
        uint256 n = 300;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);
        vm.prank(alice);
        staking.claimRange(0, n);
        uint256 c = staking.stakerActiveDepositStartIndex(alice);
        assertEq(c, 256, "cursor must lag at MAX_CURSOR_SCAN");

        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 1), c + 1);
        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 2), c + 3);
        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 3), c + 6);
    }

    /// @dev Zero-deposit wallet, and an address that is a contract / address(0): no revert, no write.
    function test_v2_zeroDepositWalletIsNoOp() public {
        vm.prank(rando);
        assertEq(staking.advanceCursor(carol, 0), 0);
        vm.prank(rando);
        assertEq(staking.advanceCursor(address(0), 1024), 0);
        vm.prank(rando);
        assertEq(staking.advanceCursor(address(staking), 1024), 0);
    }

    /// @dev advanceCursor has no `ifAvailable` guard: it still works while every action is closed. Documented
    ///      here so the behaviour is explicit (it is maintenance, not an action).
    function test_v2_worksWhileAllActionsClosed() public {
        uint256 n = 300;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);
        vm.prank(alice);
        staking.claimRange(0, n);
        assertEq(staking.stakerActiveDepositStartIndex(alice), 256);

        staking.changeActionAvailability(Types.DataType.STAKING, false);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, false);
        staking.changeActionAvailability(Types.DataType.CLAIM, false);

        vm.prank(rando);
        assertEq(staking.advanceCursor(alice, 0), n, "cursor maintenance blocked while paused");
    }

    // ------------------------------------------------------------------
    // Gas / griefing
    // ------------------------------------------------------------------

    /// @dev Worst-case gas for a full 1024-step call, and proof that repeated calls by an attacker cost the
    ///      attacker and change nothing (idempotent -> no cursor thrash, no SSTORE churn on the victim).
    function test_v2_worstCaseGasAndIdempotence() public {
        uint256 n = 1100;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);
        vm.prank(alice);
        staking.claimRange(0, n);
        assertEq(staking.stakerActiveDepositStartIndex(alice), 256);

        vm.prank(rando);
        uint256 g = gasleft();
        staking.advanceCursor(alice, 1024);
        uint256 usedFull = g - gasleft();
        emit log_named_uint("advanceCursor(1024) worst-case gas", usedFull);
        assertLt(usedFull, 5_000_000, "a full 1024-step call must fit comfortably in a block");

        vm.prank(rando);
        g = gasleft();
        staking.advanceCursor(alice, 1024);
        uint256 usedNoop = g - gasleft();
        emit log_named_uint("advanceCursor no-op gas", usedNoop);
        assertLt(usedNoop, usedFull / 10, "a no-op call must not rewrite the cursor");
    }

    /// @dev A third party advancing the cursor can only ever make the wallet's later calls CHEAPER.
    function test_v2_thirdPartyAdvanceOnlyReducesVictimGas() public {
        uint256 n = 800;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
            stakeFor(bob, P30, 1e18);
        }
        _warpDays(31);
        vm.prank(alice);
        staking.claimRange(0, n);
        vm.prank(bob);
        staking.claimRange(0, n);

        vm.prank(rando);
        staking.advanceCursor(alice, 0); // alice gets the "help", bob does not

        uint256 g = gasleft();
        staking.checkClaimableDataFor(alice);
        uint256 helped = g - gasleft();
        g = gasleft();
        staking.checkClaimableDataFor(bob);
        uint256 unhelped = g - gasleft();
        emit log_named_uint("read gas, cursor advanced", helped);
        emit log_named_uint("read gas, cursor stale", unhelped);
        assertLt(helped, unhelped, "advancing must never make the victim's reads more expensive");
    }

    // ------------------------------------------------------------------
    // Fuzz: the cursor invariant under arbitrary third-party interference
    // ------------------------------------------------------------------

    /// @dev For any maxSteps and any close pattern, nothing below the cursor may be open.
    function testFuzz_v2_nothingOpenBelowCursor(uint256 maxSteps, uint8 closeUpTo) public {
        uint256 n = 12;
        for (uint256 i = 0; i < n; i++) {
            // mix of P30 (matures) and P0 (INDEFINITE, never auto-closes)
            stakeFor(alice, i % 4 == 3 ? P0 : P30, 1e18);
        }
        _warpDays(31);

        uint256 upTo = bound(uint256(closeUpTo), 1, n);
        vm.prank(alice);
        staking.claimRange(0, upTo);

        vm.prank(rando);
        uint256 cursor = staking.advanceCursor(alice, maxSteps);

        assertLe(cursor, staking.checkDepositCountOfAddress(alice), "cursor past the deposit count");
        for (uint256 i = 0; i < cursor; i++) {
            ProgramManager.DepositStatus s = _status(alice, i);
            assertTrue(
                s == ProgramManager.DepositStatus.WITHDRAWN || s == ProgramManager.DepositStatus.CLAIMED
                    || s == ProgramManager.DepositStatus.SEIZED,
                "an OPEN deposit sits below the cursor"
            );
        }
    }
}
