// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";

/// @title Bounded claimRange(fromIndex, toIndexExclusive) and active-index advancement
/// @dev A cursor-relative bounded claim (scan `[cursor, cursor + max)`) cannot guarantee progress: the cursor
///      never moves past an open deposit, so open-but-unmatured deposits at the head would make it rescan the
///      same window forever. `claimRange` takes a caller-chosen window instead, so it always makes progress.
contract BoundedClaimAllTest is V030Base {
    function _stakeMany(address user, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _stakeFor(user, PERIOD_SHORT, STAKE_AMOUNT);
        }
    }

    function _isClosed(address user, uint256 i) internal view returns (bool) {
        return stakingContract.getDeposit(user, i).withdrawalDate != 0;
    }

    function test_ClaimRange_ProcessesOnlyTheWindow() public {
        _setupProgram(true);
        _stakeMany(userOne, 5);
        skip(PERIOD_SHORT * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimRange(0, 2);
        assertTrue(_isClosed(userOne, 0));
        assertTrue(_isClosed(userOne, 1));
        assertFalse(_isClosed(userOne, 2));
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 2);

        vm.prank(userOne);
        stakingContract.claimRange(2, 4);
        assertTrue(_isClosed(userOne, 3));
        assertFalse(_isClosed(userOne, 4));
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 4);

        vm.prank(userOne);
        stakingContract.claimRange(4, 5);
        assertTrue(_isClosed(userOne, 4));
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 5);
        assertEq(stakingContract.totalDataList(Types.DataType.STAKING), 0);
    }

    function test_ClaimRange_InvalidWindowsRevert() public {
        _setupProgram(true);
        _stakeMany(userOne, 5);
        skip(PERIOD_SHORT * 1 days + 1);

        vm.startPrank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 3, 3));
        stakingContract.claimRange(3, 3);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 4, 2));
        stakingContract.claimRange(4, 2);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 6));
        stakingContract.claimRange(0, 6);
        vm.stopPrank();

        // Empty deposit list: every window is invalid.
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 1));
        stakingContract.claimRange(0, 1);
    }

    function test_ClaimAllUnbounded_StillClaimsEverything() public {
        _setupProgram(true);
        _stakeMany(userOne, 6);
        skip(PERIOD_SHORT * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimAll();
        for (uint256 i = 0; i < 6; i++) {
            assertTrue(_isClosed(userOne, i));
        }
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 6);
    }

    /// @notice Open deposits at the head of the list never starve a bounded claim: the caller picks the window,
    ///         so a fixed-size window walked forward reaches every claimable deposit.
    function test_ClaimRange_HeadBlockedByOpenDeposits_StillMakesProgress() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT); // 0: open for 90 days
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT); // 1: open for 90 days
        _stakeMany(userOne, 3); // 2, 3, 4 matured after 7 days
        skip(PERIOD_SHORT * 1 days + 1);

        // Walk windows of size 2 from the cursor; the cursor stays at 0 because deposit 0 is open.
        uint256 count = stakingContract.checkDepositCountOfAddress(userOne);
        for (uint256 from = stakingContract.stakerActiveDepositStartIndex(userOne); from < count; from += 2) {
            uint256 to = from + 2 > count ? count : from + 2;
            vm.prank(userOne);
            stakingContract.claimRange(from, to);
        }

        assertFalse(_isClosed(userOne, 0));
        assertFalse(_isClosed(userOne, 1));
        assertTrue(_isClosed(userOne, 2));
        assertTrue(_isClosed(userOne, 3));
        assertTrue(_isClosed(userOne, 4));
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 0); // deposit 0 still open
        assertEq(stakingContract.userDataList(Types.DataType.STAKING, userOne), 2 * STAKE_AMOUNT);
    }

    function test_ClaimRange_SkipsNonClaimableSilently() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT); // 0 open
        _stakeMany(userOne, 4); // 1..4 matured
        skip(PERIOD_SHORT * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimRange(2, 4); // pays 2 and 3 only
        assertFalse(_isClosed(userOne, 0));
        assertFalse(_isClosed(userOne, 1));
        assertTrue(_isClosed(userOne, 2));
        assertTrue(_isClosed(userOne, 3));
        assertFalse(_isClosed(userOne, 4));

        // Open deposit and already-claimed deposits inside the window are skipped silently.
        vm.prank(userOne);
        stakingContract.claimRange(0, 5);
        assertFalse(_isClosed(userOne, 0));
        assertTrue(_isClosed(userOne, 1));
        assertTrue(_isClosed(userOne, 4));

        // A window with nothing claimable is a no-op, not a revert.
        vm.prank(userOne);
        stakingContract.claimRange(0, 5);
    }

    function test_ActiveIndex_AdvancesPastFullyClosedTail() public {
        _setupProgram(true);
        _stakeFor(userOne, 0, STAKE_AMOUNT);
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 0);

        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);
        // v0.2.4 left this at count-1 (0); v0.3.0 moves it to count so future loops are empty.
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 1);

        (uint256 s, uint256 p, uint256 i) = stakingContract.checkClaimableDataFor(userOne);
        assertEq(s + p + i, 0);

        // New deposit after everything was closed starts from the fresh index.
        _stakeFor(userOne, 0, STAKE_AMOUNT);
        skip(10 days);
        vm.prank(userOne);
        stakingContract.claimRange(1, 2);
        assertEq(stakingContract.getDeposit(userOne, 1).rewardGenerated, 0);
        assertEq(stakingContract.userDataList(Types.DataType.CLAIM, userOne), _periodicalReward(STAKE_AMOUNT, 10));
    }

    function test_ActiveIndex_StopsAtFirstOpenDeposit() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT); // 0
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT); // 1 stays open
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT); // 2
        skip(PERIOD_SHORT * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimAll();
        assertTrue(_isClosed(userOne, 0));
        assertFalse(_isClosed(userOne, 1));
        assertTrue(_isClosed(userOne, 2));
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 1);

        skip(PERIOD_LONG * 1 days);
        vm.prank(userOne);
        stakingContract.claimRange(1, 2);
        assertTrue(_isClosed(userOne, 1));
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 3);
    }

    /// @notice Gas for a bounded claim must not grow with the total number of deposits behind the cursor.
    function test_ClaimRange_GasIndependentOfHistory() public {
        _setupProgram(true);
        _stakeMany(userOne, 3);
        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        uint256 g0 = gasleft();
        stakingContract.claimRange(0, 1);
        uint256 gasSmall = g0 - gasleft();

        _stakeMany(userTwo, 60);
        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userTwo);
        uint256 g1 = gasleft();
        stakingContract.claimRange(0, 1);
        uint256 gasLarge = g1 - gasleft();

        // Allow modest variance (warm/cold slots) but not linear growth.
        assertLt(gasLarge, gasSmall * 2);
    }
}
