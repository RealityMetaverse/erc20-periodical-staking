// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";

/// @title DepositIndex
/// @notice `stakerActiveDepositStartIndex` must never point past an open deposit, `claimAll` must never skip a
///         claimable deposit, and bounded `claimRange` must make progress. Bad indexes must revert with custom errors.
contract DepositIndexTest is AttackBase {
    function _idx(address u) internal view returns (uint256) {
        return staking.stakerActiveDepositStartIndex(u);
    }

    /// @dev Everything before the cursor must be closed; the cursor never exceeds the deposit count.
    function _assertCursorSound(address u) internal {
        uint256 n = staking.checkDepositCountOfAddress(u);
        uint256 c = _idx(u);
        assertLe(c, n, "cursor beyond deposit count");
        for (uint256 i = 0; i < c; i++) {
            ProgramManager.DepositStatus st = _status(u, i);
            assertTrue(
                st == ProgramManager.DepositStatus.WITHDRAWN || st == ProgramManager.DepositStatus.CLAIMED,
                "open deposit before cursor"
            );
        }
    }

    /// @dev Hypothesis: claimAll skips a claimable deposit when statuses are interleaved.
    function test_claimAll_interleavedStatuses_claimsEveryClaimable() public {
        uint256 d0 = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 d1 = _stake(alice, 0, P0, 1_000 * ONE);
        uint256 d2 = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 d3 = _stake(alice, 0, P90, 1_000 * ONE);
        uint256 r30 = _deposit(alice, d0).rewardGenerated;
        _warpDays(30);
        uint256 rIndef = _deposit(alice, d1).rewardGenerated;
        assertGt(rIndef, 0);

        uint256 before = token.balanceOf(alice);
        _claimAll(alice);
        assertEq(token.balanceOf(alice) - before, 2 * (1_000 * ONE + r30) + rIndef, "every claimable paid");
        assertEq(uint256(_status(alice, d0)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(uint256(_status(alice, d2)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(uint256(_status(alice, d3)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
        assertEq(_deposit(alice, d1).rewardGenerated, 0, "indefinite reward fully claimed");
        assertEq(_idx(alice), 1, "cursor stops at first open deposit");
        _assertCursorSound(alice);
        _assertAccounting();
    }

    /// @dev when every deposit is closed the cursor equals the count; a new deposit is then the first scanned.
    function test_cursor_advancesPastClosedTail() public {
        _stake(alice, 0, P30, 1_000 * ONE);
        _stake(alice, 0, P30, 1_000 * ONE);
        _stake(alice, 0, P30, 1_000 * ONE);
        _warpDays(30);
        _claimAll(alice);
        assertEq(_idx(alice), 3, "cursor == count when all closed");
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        assertEq(d, 3);
        _warpDays(30);
        _claimAll(alice);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(_idx(alice), 4);
        _assertCursorSound(alice);
    }

    /// @dev Hypothesis: closing a later deposit moves the cursor past an earlier open one.
    function test_cursor_neverSkipsEarlierOpen() public {
        uint256 d0 = _stake(alice, 0, P90, 1_000 * ONE);
        uint256 d1 = _stake(alice, 0, P30, 1_000 * ONE);
        _warpDays(30);
        _claim(alice, d1);
        assertEq(_idx(alice), 0);
        _assertCursorSound(alice);
        _warpDays(60);
        _claimAll(alice);
        assertEq(uint256(_status(alice, d0)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(_idx(alice), 2);
    }

    /// @dev Hypothesis: early withdrawals in the middle confuse the cursor.
    function test_cursor_earlyWithdrawMiddle_exactValues() public {
        for (uint256 i = 0; i < 5; i++) {
            _stake(alice, 0, P30, 1_000 * ONE);
        }
        _withdraw(alice, 2);
        assertEq(_idx(alice), 0);
        _warpDays(30);
        _claim(alice, 0);
        assertEq(_idx(alice), 1);
        _claim(alice, 1);
        assertEq(_idx(alice), 3, "must jump over the withdrawn #2");
        _claim(alice, 4);
        assertEq(_idx(alice), 3, "#3 still open");
        _claim(alice, 3);
        assertEq(_idx(alice), 5);
        _assertCursorSound(alice);
        _assertAccounting();
    }

    /// @dev Hypothesis: claimAll silently skipping an indefinite deposit for lack of pool loses it forever.
    function test_claimAll_poolShort_silentSkip_thenRefillClaims() public {
        uint256 d = _stake(alice, 0, P0, 100_000 * ONE);
        staking.collectReward(staking.getCollectableReward());
        _warpDays(365);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        assertGt(reward, staking.rewardPool());

        uint256 before = token.balanceOf(alice);
        _claimAll(alice); // must not revert
        assertEq(token.balanceOf(alice), before, "nothing paid");
        assertEq(_idx(alice), 0);

        staking.provideReward(reward);
        _claimAll(alice);
        assertEq(token.balanceOf(alice) - before, reward);
        _assertAccounting();
    }

    /// @dev claimRange claims exactly the window per call and advances the cursor; bad windows revert.
    function test_claimRange_progressAndCursor() public {
        for (uint256 i = 0; i < 10; i++) {
            _stake(alice, 0, P30, 1_000 * ONE);
        }
        _warpDays(30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 0));
        staking.claimRange(0, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 11));
        staking.claimRange(0, 11);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 5, 4));
        staking.claimRange(5, 4);

        vm.prank(alice);
        staking.claimRange(0, 4);
        assertEq(_idx(alice), 4);
        assertEq(_user(Types.DataType.STAKING, alice), 6_000 * ONE);
        vm.prank(alice);
        staking.claimRange(4, 8);
        assertEq(_idx(alice), 8);
        vm.prank(alice);
        staking.claimRange(8, 10);
        assertEq(_idx(alice), 10);
        assertEq(_user(Types.DataType.STAKING, alice), 0);
        _assertCursorSound(alice);
        _assertAccounting();
    }

    /// @dev The old `claimAll(max)` scanned `[cursor, cursor+max)`; with open deposits at the head it never
    ///      reached claimable deposits further down. `claimRange` windows walked forward must reach them.
    function test_claimRange_headBlockedByOpenDeposit_stillMakesProgress() public {
        _stake(alice, 0, P90, 1_000 * ONE); // #0: TIME_LEFT for 90 days
        _stake(alice, 0, P90, 1_000 * ONE); // #1: TIME_LEFT
        uint256 d2 = _stake(alice, 0, P30, 1_000 * ONE); // #2: matured after 30 days
        uint256 d3 = _stake(alice, 0, P30, 1_000 * ONE); // #3: matured after 30 days
        _warpDays(30);

        uint256 count = staking.checkDepositCountOfAddress(alice);
        for (uint256 from = _idx(alice); from < count; from += 2) {
            uint256 to = from + 2 > count ? count : from + 2;
            vm.prank(alice);
            staking.claimRange(from, to);
        }
        assertEq(uint256(_status(alice, d2)), uint256(ProgramManager.DepositStatus.CLAIMED), "must reach #2");
        assertEq(uint256(_status(alice, d3)), uint256(ProgramManager.DepositStatus.CLAIMED), "must reach #3");
        assertEq(uint256(_status(alice, 0)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
        assertEq(_idx(alice), 0, "cursor stays on the open head");
        _assertCursorSound(alice);
        _assertAccounting();
    }

    /// @dev getDepositsInRangeBy rejects bad ranges with InvalidRange, never a panic.
    function test_getDepositsInRangeBy_badRanges_customError() public {
        _stake(alice, 0, P30, 1_000 * ONE);
        _stake(alice, 0, P30, 1_000 * ONE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 2, 1));
        staking.getDepositsInRangeBy(alice, 2, 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 3));
        staking.getDepositsInRangeBy(alice, 0, 3);
        assertEq(staking.getDepositsInRangeBy(alice, 1, 1).length, 0);
        assertEq(staking.getDepositsInRangeBy(alice, 0, 2).length, 2);
        assertEq(staking.getDepositsInRangeBy(bob, 0, 0).length, 0);
        (bool ok, bytes memory ret) = address(staking).staticcall(
            abi.encodeCall(staking.getDepositsInRangeBy, (alice, type(uint256).max, 0))
        );
        assertFalse(ok);
        assertFalse(_isPanic(ret), "must not panic");
    }

    /// @dev every deposit-indexed function reverts DepositDoesNotExist on a bad index, never a panic.
    function test_nonexistentDeposit_customErrorsEverywhere() public {
        bytes memory expected = abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0);
        vm.expectRevert(expected);
        staking.checkDepositStatus(alice, 0);
        vm.expectRevert(expected);
        staking.getDeposit(alice, 0);
        vm.prank(alice);
        vm.expectRevert(expected);
        staking.claimDeposit(0);
        vm.prank(alice);
        vm.expectRevert(expected);
        staking.withdrawDeposit(0);

        _stake(alice, 0, P30, 1_000 * ONE);
        expected = abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 1);
        vm.expectRevert(expected);
        staking.getDeposit(alice, 1);
        vm.prank(alice);
        vm.expectRevert(expected);
        staking.claimDeposit(1);
        // another user's deposit number is not mine
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        staking.withdrawDeposit(0);
    }

    /// @dev Hypothesis: a claimed deposit can be claimed or withdrawn again.
    function test_closedDeposit_cannotBeReopened() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 e = _stake(alice, 0, P0, 1_000 * ONE);
        _warpDays(30);
        _claim(alice, d);
        _withdraw(alice, e);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, d));
        staking.claimDeposit(d);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, d));
        staking.withdrawDeposit(d);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, e));
        staking.claimDeposit(e);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, e));
        staking.withdrawDeposit(e);
        vm.stopPrank();
        assertEq(uint256(_status(alice, e)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        _warpDays(1000);
        assertEq(uint256(_status(alice, e)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        assertEq(_deposit(alice, e).rewardGenerated, _user(Types.DataType.CLAIM, alice) - _deposit(alice, d).rewardGenerated);
    }

    /// @dev Hypothesis: a matured deposit can be withdrawn early (bypassing claim accounting).
    function test_maturedDeposit_notWithdrawable_timeLeftNotClaimable() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, d));
        staking.claimDeposit(d);
        _warpDays(30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, d));
        staking.withdrawDeposit(d);
    }

    /// @dev Hypothesis: the exact maturity second is handled consistently (>= end date is claimable).
    function test_maturityBoundary_exactSecond() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 end = _deposit(alice, d).stakingEndDate;
        vm.warp(end - 1);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
        vm.warp(end);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
        _claim(alice, d);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.CLAIMED));
    }

    /// @dev Fuzz: random open/close sequences never leave an open deposit behind the cursor and claimAll
    ///      always empties every READY_TO_CLAIM deposit.
    function testFuzz_cursorNeverSkipsClaimable(uint256 seed) public {
        for (uint256 i = 0; i < 30; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = r % 5;
            if (a == 0) {
                _stake(alice, 0, PERIODS[(r >> 8) % 3], 1_000 * ONE);
            } else if (a == 1) {
                uint256 n = staking.checkDepositCountOfAddress(alice);
                if (n > 0) {
                    uint256 d = (r >> 16) % n;
                    ProgramManager.DepositStatus st = _status(alice, d);
                    if (st == ProgramManager.DepositStatus.TIME_LEFT || st == ProgramManager.DepositStatus.INDEFINITE) {
                        _withdraw(alice, d);
                    }
                }
            } else if (a == 2) {
                _claimAll(alice);
            } else if (a == 3) {
                _warpDays(((r >> 24) % 40) + 1);
            } else {
                uint256 n = staking.checkDepositCountOfAddress(alice);
                if (n > 0) {
                    uint256 d = (r >> 16) % n;
                    if (_status(alice, d) == ProgramManager.DepositStatus.READY_TO_CLAIM) _claim(alice, d);
                }
            }
            _assertCursorSound(alice);
        }
        _claimAll(alice);
        uint256 cnt = staking.checkDepositCountOfAddress(alice);
        for (uint256 i = 0; i < cnt; i++) {
            assertTrue(
                _status(alice, i) != ProgramManager.DepositStatus.READY_TO_CLAIM, "claimAll left a claimable deposit"
            );
        }
        _assertCursorSound(alice);
        _assertAccounting();
    }
}
