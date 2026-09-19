// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Freeze / unfreeze / seize for v0.4.0: access control, blocking of claim and withdraw, batch-claim
///         skipping, principal-only seizes (periodical releases its reservation, indefinite leaves its accrual in
///         the pool, the reward pool is never touched), close accounting, batches and events.
contract FreezeSeizeTest is V050Base {
    bytes4 internal constant UNAUTHORIZED = bytes4(keccak256("UnauthorizedAccess(uint8)"));
    uint8 internal constant TIER_ADMIN = 0;
    uint8 internal constant TIER_OWNER = 1;
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    uint256 internal constant AMOUNT = 1_000 * ONE;

    // ======================================
    // =              Helpers               =
    // ======================================
    function _assertConservation() internal {
        assertEq(
            token.balanceOf(address(staking)),
            staking.totalDataList(Types.DataType.STAKING) + staking.rewardPool(),
            "balance == staked + pool"
        );
    }

    function _pair(address w0, uint256 n0, address w1, uint256 n1)
        internal
        pure
        returns (address[] memory ws, uint256[] memory ns)
    {
        ws = new address[](2);
        ns = new uint256[](2);
        ws[0] = w0;
        ws[1] = w1;
        ns[0] = n0;
        ns[1] = n1;
    }

    /// @dev Empties the unreserved pool so that later reservations exceed it.
    function _drainPool() internal {
        uint256 collectable = staking.getCollectableReward();
        if (collectable != 0) staking.collectReward(collectable);
    }

    function _stakedCell(uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.phasePeriodDataList(Types.PhasePeriodDataType.STAKED, phase, period);
    }

    /// @dev The seized wallet gets nothing from deposit `n`: single claim / withdraw revert, claimAll and claimRange
    ///      pay 0, the claimable view excludes it. Checked now and again after warping past any maturity.
    function _assertSeizedPaysNothing(address wallet, uint256 n) internal {
        for (uint256 round = 0; round < 2; round++) {
            if (round == 1) _warpDays(P90 + 1);
            vm.startPrank(wallet);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, n));
            staking.claimDeposit(n);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, n));
            staking.withdrawDeposit(n);
            uint256 before = token.balanceOf(wallet);
            staking.claimAll();
            assertEq(token.balanceOf(wallet), before, "claimAll pays nothing");
            staking.claimRange(n, n + 1);
            assertEq(token.balanceOf(wallet), before, "claimRange pays nothing");
            vm.stopPrank();
            (uint256 cStake, uint256 cReward, uint256 cIndef) = staking.checkClaimableDataFor(wallet);
            assertEq(cStake + cReward + cIndef, 0, "claimable view excludes the seized deposit");
            assertEq(uint256(_status(wallet, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        }
    }

    // ======================================
    // =           Access control           =
    // ======================================
    function test_freeze_adminAndOwnerCan() external {
        uint256 n0 = stakeFor(alice, P30, AMOUNT);
        uint256 n1 = stakeFor(alice, P30, AMOUNT);

        freezeAs(admin, alice, n0);
        freezeAs(owner, alice, n1);
        assertTrue(staking.isDepositFrozen(alice, n0));
        assertTrue(staking.isDepositFrozen(alice, n1));

        vm.prank(admin);
        staking.unfreezeDeposit(alice, n0);
        staking.unfreezeDeposit(alice, n1); // owner
        assertFalse(staking.isDepositFrozen(alice, n0));
        assertFalse(staking.isDepositFrozen(alice, n1));
    }

    function test_freeze_nonAdminReverts() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);
        (address[] memory ws, uint256[] memory ns) = _pair(alice, n, alice, n);

        bytes memory err = abi.encodeWithSelector(UNAUTHORIZED, TIER_ADMIN);
        vm.startPrank(rando);
        vm.expectRevert(err);
        staking.freezeDeposit(alice, n);
        vm.expectRevert(err);
        staking.freezeDeposits(ws, ns);
        vm.stopPrank();

        // The depositor cannot freeze or unfreeze her own deposit either.
        vm.prank(alice);
        vm.expectRevert(err);
        staking.freezeDeposit(alice, n);

        freeze(alice, n);
        vm.startPrank(alice);
        vm.expectRevert(err);
        staking.unfreezeDeposit(alice, n);
        vm.expectRevert(err);
        staking.unfreezeDeposits(ws, ns);
        vm.stopPrank();
        assertTrue(staking.isDepositFrozen(alice, n));
    }

    function test_seize_onlyOwner() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);
        freeze(alice, n);
        (address[] memory ws, uint256[] memory ns) = _pair(alice, n, alice, n);
        bytes memory err = abi.encodeWithSelector(UNAUTHORIZED, TIER_OWNER);

        address[2] memory callers = [admin, rando];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(err);
            staking.seizeDeposit(alice, n);
            vm.expectRevert(err);
            staking.seizeDeposits(ws, ns);
            vm.stopPrank();
        }
        assertTrue(staking.isDepositFrozen(alice, n), "still frozen");
        assertEq(_cell(alice, 0, P30), AMOUNT, "untouched");
    }

    // ======================================
    // =        Freeze / unfreeze rules     =
    // ======================================
    function test_freeze_rejectsInvalidStates() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 5));
        staking.freezeDeposit(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 5));
        staking.isDepositFrozen(alice, 5);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, n));
        staking.unfreezeDeposit(alice, n);

        freeze(alice, n);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, n));
        staking.freezeDeposit(alice, n);

        // Closed deposits (withdrawn / claimed) cannot be frozen.
        uint256 w = stakeFor(bob, P30, AMOUNT);
        vm.prank(bob);
        staking.withdrawDeposit(w);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, bob, w));
        staking.freezeDeposit(bob, w);

        uint256 c = stakeFor(carol, P30, AMOUNT);
        _warpDays(P30);
        vm.prank(carol);
        staking.claimDeposit(c);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, carol, c));
        staking.freezeDeposit(carol, c);
    }

    function test_freeze_matureAndFlexibleDepositsCanBeFrozen() external {
        uint256 flex = stakeFor(alice, P0, AMOUNT);
        uint256 periodical = stakeFor(alice, P30, AMOUNT);
        _warpDays(P30 + 1);
        assertEq(uint256(_status(alice, periodical)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));

        freeze(alice, flex);
        freeze(alice, periodical);
        assertTrue(staking.isDepositFrozen(alice, flex));
        assertTrue(staking.isDepositFrozen(alice, periodical));
        // Freezing does not change the status.
        assertEq(uint256(_status(alice, flex)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        assertEq(uint256(_status(alice, periodical)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
    }

    function test_freeze_doesNotTouchAccounting() external {
        uint256 n = stakeFor(alice, P90, AMOUNT);
        uint256 staked = staking.totalDataList(Types.DataType.STAKING);
        uint256 expected = staking.totalDataList(Types.DataType.REWARD_EXPECTED);
        uint256 pool = staking.rewardPool();
        uint256 bal = token.balanceOf(address(staking));

        freeze(alice, n);
        unfreeze(alice, n);
        freeze(alice, n);

        assertEq(staking.totalDataList(Types.DataType.STAKING), staked);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), expected);
        assertEq(staking.rewardPool(), pool);
        assertEq(token.balanceOf(address(staking)), bal);
        assertEq(_cell(alice, 0, P90), AMOUNT);
    }

    // ======================================
    // =   Frozen blocks withdraw / claim   =
    // ======================================
    function test_frozen_blocksWithdrawAndClaim_untilUnfrozen() external {
        uint256 periodical = stakeFor(alice, P30, AMOUNT);
        uint256 flex = stakeFor(alice, P0, AMOUNT);
        freeze(alice, periodical);
        freeze(alice, flex);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, periodical));
        staking.withdrawDeposit(periodical);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, periodical));
        staking.withdrawDepositPartial(periodical, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, flex));
        staking.withdrawDeposit(flex);
        vm.stopPrank();

        _warpDays(P30);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, periodical));
        staking.claimDeposit(periodical);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, flex));
        staking.claimDeposit(flex);
        vm.stopPrank();

        // Unfreezing restores normal behaviour.
        unfreeze(alice, periodical);
        uint256 reward = _deposit(alice, periodical).rewardGenerated;
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimDeposit(periodical);
        assertEq(token.balanceOf(alice) - before, AMOUNT + reward, "claim after unfreeze");
    }

    function test_claimAll_skipsFrozen_paysTheRest() external {
        uint256[3] memory ns;
        for (uint256 i = 0; i < 3; i++) {
            ns[i] = stakeFor(alice, P30, AMOUNT);
        }
        uint256 reward = _deposit(alice, ns[0]).rewardGenerated;
        freeze(alice, ns[1]);
        _warpDays(P30);

        (uint256 cStake, uint256 cReward, uint256 cIndef) = staking.checkClaimableDataFor(alice);
        assertEq(cStake, 2 * AMOUNT, "claimable principal skips frozen");
        assertEq(cReward, 2 * reward, "claimable reward skips frozen");
        assertEq(cIndef, 0);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();

        assertEq(token.balanceOf(alice) - before, 2 * (AMOUNT + reward), "paid the unfrozen deposits");
        assertEq(uint256(_status(alice, ns[0])), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(uint256(_status(alice, ns[1])), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
        assertEq(uint256(_status(alice, ns[2])), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertTrue(staking.isDepositFrozen(alice, ns[1]));
        assertEq(staking.stakerActiveDepositStartIndex(alice), 1, "cursor stops at frozen open deposit");
        assertEq(_cell(alice, 0, P30), AMOUNT, "frozen stake still counted");
        _assertConservation();

        // All remaining deposits frozen: claimAll is a no-op, not a revert.
        before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        assertEq(token.balanceOf(alice), before);
    }

    function test_claimRange_skipsFrozen_paysTheRest() external {
        uint256 flex = stakeFor(alice, P0, AMOUNT); // 0
        uint256 a = stakeFor(alice, P30, AMOUNT); // 1
        uint256 b = stakeFor(alice, P30, AMOUNT); // 2
        uint256 reward = _deposit(alice, a).rewardGenerated;
        freeze(alice, flex);
        freeze(alice, b);
        _warpDays(P30);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRange(0, 3);

        assertEq(token.balanceOf(alice) - before, AMOUNT + reward, "only deposit 1 paid");
        assertEq(uint256(_status(alice, a)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(uint256(_status(alice, b)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
        assertEq(_deposit(alice, flex).withdrawalDate, 0, "frozen flexible untouched");
        assertEq(staking.stakerActiveDepositStartIndex(alice), 0);
    }

    // ======================================
    // =               Seize                =
    // ======================================
    function test_seize_revertsWhenNotFrozen() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, n));
        staking.seizeDeposit(alice, n);

        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 9));
        staking.seizeDeposit(alice, 9);

        // Unfrozen again -> not seizable.
        freeze(alice, n);
        unfreeze(alice, n);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, n));
        staking.seizeDeposit(alice, n);
    }

    function test_seize_revertsWhenTreasuryNotSet() external {
        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        vm.expectRevert(Errors.TreasuryNotSet.selector);
        fresh.seizeDeposit(alice, 0);
        (address[] memory ws, uint256[] memory ns) = _pair(alice, 0, alice, 1);
        vm.expectRevert(Errors.TreasuryNotSet.selector);
        fresh.seizeDeposits(ws, ns);
    }

    function test_seize_periodical_principalOnly_countersLikeAClose() external {
        uint256 other = stakeFor(bob, P30, 2 * AMOUNT); // unrelated open deposit keeps totals non-trivial
        uint256 n = stakeWith(alice, P90, AMOUNT, 150, 0);
        uint256 reward = _deposit(alice, n).rewardGenerated;
        assertEq(reward, staking.calculateReward(AMOUNT, APY_P90 + 150, P90));
        assertGt(reward, 0);
        uint256 otherReward = _deposit(bob, other).rewardGenerated;

        uint256 pool = staking.rewardPool();
        uint256 collectable = staking.getCollectableReward();
        uint256 totalWithdrawal = staking.totalDataList(Types.DataType.WITHDRAWAL);
        uint256 totalClaim = staking.totalDataList(Types.DataType.CLAIM);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 aliceBefore = token.balanceOf(alice);
        assertEq(controller.getRemaining(alice, 0, P90), DEFAULT_LIMIT - AMOUNT);

        _warpDays(10);
        freeze(alice, n);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, n, treasury, AMOUNT);
        seize(alice, n);

        // Payout: principal only, the pool is not touched and the released reservation becomes collectable.
        assertEq(token.balanceOf(treasury) - treasuryBefore, AMOUNT, "treasury gets principal only");
        assertEq(token.balanceOf(alice), aliceBefore, "wallet gets nothing");
        assertEq(staking.rewardPool(), pool, "pool untouched");
        assertEq(staking.getCollectableReward(), collectable + reward, "reservation released to collectable");

        // Deposit state
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        assertEq(d.withdrawalDate, _now(), "closed now");
        assertEq(d.rewardGenerated, 0, "unpaid reserved reward zeroed");
        assertEq(d.amount, AMOUNT);
        assertFalse(staking.isDepositFrozen(alice, n), "frozen flag cleared");

        // Counters (like a principal-only close)
        assertEq(_cell(alice, 0, P90), 0, "user STAKING cell");
        assertEq(_stakedCell(0, P90), 0, "phase/period STAKED cell");
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), 0);
        assertEq(staking.getUserData(Types.DataType.WITHDRAWAL, alice), AMOUNT);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0, "no reward booked as CLAIM");
        assertEq(staking.getUserData(Types.DataType.REWARD_EXPECTED, alice), 0);
        assertEq(staking.totalDataList(Types.DataType.STAKING), 2 * AMOUNT);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), otherReward);
        assertEq(staking.totalDataList(Types.DataType.WITHDRAWAL), totalWithdrawal + AMOUNT);
        assertEq(staking.totalDataList(Types.DataType.CLAIM), totalClaim, "total CLAIM unchanged");
        assertEq(staking.stakerActiveDepositStartIndex(alice), 1, "cursor past seized deposit");
        assertEq(controller.getRemaining(alice, 0, P90), DEFAULT_LIMIT, "limit room freed");
        _assertConservation();
    }

    function test_seize_maturedDeposit_principalOnly() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);
        uint256 reward = _deposit(alice, n).rewardGenerated;
        assertGt(reward, 0);
        _warpDays(P30 + 5);
        freeze(alice, n);
        uint256 before = token.balanceOf(treasury);
        uint256 pool = staking.rewardPool();
        seize(alice, n);
        assertEq(token.balanceOf(treasury) - before, AMOUNT, "principal only");
        assertEq(staking.rewardPool(), pool, "pool untouched");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);
        _assertConservation();
    }

    function test_seize_freedLimitAllowsFullRestake() external {
        uint256 n = stakeFor(alice, P30, DEFAULT_LIMIT);
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, AMOUNT, uint256(0))
        );
        staking.stakeWithVoucher(v, sig, AMOUNT, APY_P30);

        freezeAndSeize(alice, n);
        uint256 again = stakeFor(alice, P30, DEFAULT_LIMIT);
        assertEq(_cell(alice, 0, P30), DEFAULT_LIMIT);
        assertEq(uint256(_status(alice, again)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
    }

    function test_seize_poolShort_sendsPrincipal_releasesReservation() external {
        _drainPool();
        assertEq(staking.rewardPool(), 0);

        uint256 n = stakeFor(alice, P90, AMOUNT);
        uint256 reserved = _deposit(alice, n).rewardGenerated;
        assertGt(reserved, 0);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), reserved);

        freeze(alice, n);
        uint256 before = token.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, n, treasury, AMOUNT);
        seize(alice, n); // must not revert

        assertEq(token.balanceOf(treasury) - before, AMOUNT, "principal only");
        assertEq(staking.rewardPool(), 0);
        assertEq(_deposit(alice, n).rewardGenerated, 0, "unpaid reward zeroed");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0, "reservation released");
        assertEq(staking.getUserData(Types.DataType.REWARD_EXPECTED, alice), 0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);
        assertEq(staking.getUserData(Types.DataType.WITHDRAWAL, alice), AMOUNT);
        assertEq(_cell(alice, 0, P90), 0);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        _assertConservation();
    }

    function test_seize_flexible_principalOnly_accruedStaysInPool() external {
        uint256 extra = 125;
        uint256 n = stakeWith(alice, P0, AMOUNT, extra, 0);
        uint256 apy = APY_P0 + extra;

        _warpDays(40);
        uint256 claimed = staking.calculateReward(AMOUNT, apy, 40);
        vm.prank(alice);
        staking.claimDeposit(n); // partial reward already taken
        assertEq(_deposit(alice, n).rewardGenerated, 0, "live accrued resets after claim");

        _warpDays(60);
        uint256 accrued = staking.calculateReward(AMOUNT, apy, 100) - claimed;
        assertEq(_deposit(alice, n).rewardGenerated, accrued, "live view");
        assertGt(accrued, 0);
        assertLe(accrued, staking.getCollectableReward(), "pool could cover it");
        freeze(alice, n);

        uint256 pool = staking.rewardPool();
        uint256 collectable = staking.getCollectableReward();
        uint256 before = token.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, n, treasury, AMOUNT);
        seize(alice, n);

        assertEq(token.balanceOf(treasury) - before, AMOUNT, "principal only, accrued not paid");
        assertEq(staking.rewardPool(), pool, "accrued stays in the pool");
        assertEq(staking.getCollectableReward(), collectable);
        assertEq(_deposit(alice, n).rewardGenerated, claimed, "stored total = only what was already claimed");
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), claimed);
        assertEq(_cell(alice, 0, P0), 0);
        assertEq(_stakedCell(0, P0), 0);
        assertEq(controller.getRemaining(alice, 0, P0), DEFAULT_LIMIT);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        _assertConservation();
    }

    function test_seize_flexible_poolShort_principalOnly() external {
        _drainPool();
        uint256 n = stakeFor(alice, P0, AMOUNT);
        _warpDays(100);
        assertGt(_deposit(alice, n).rewardGenerated, 0, "accrued but unpayable");
        freeze(alice, n);

        uint256 before = token.balanceOf(treasury);
        seize(alice, n);
        assertEq(token.balanceOf(treasury) - before, AMOUNT);
        assertEq(staking.rewardPool(), 0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);
        _assertConservation();
    }

    function test_seize_flexible_neverTouchesPeriodicalReserve() external {
        _drainPool();
        uint256 periodical = stakeFor(bob, P90, AMOUNT);
        uint256 reserved = _deposit(bob, periodical).rewardGenerated;
        staking.provideReward(reserved + 1); // collectable = 1 wei
        uint256 n = stakeFor(alice, P0, AMOUNT);
        _warpDays(50);
        freeze(alice, n);

        uint256 before = token.balanceOf(treasury);
        seize(alice, n); // indefinite seize never pays a reward
        assertEq(token.balanceOf(treasury) - before, AMOUNT);
        assertEq(staking.rewardPool(), reserved + 1, "reserve intact");

        // Bob can still be paid in full.
        _warpDays(P90);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        staking.claimDeposit(periodical);
        assertEq(token.balanceOf(bob) - bobBefore, AMOUNT + reserved);
    }

    function test_seize_ignoresActionAvailability() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);
        freeze(alice, n);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, false);
        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        staking.changeActionAvailability(Types.DataType.STAKING, false);
        seize(alice, n);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
    }

    function test_seized_cannotBeClaimedWithdrawnFrozenOrSeizedAgain() external {
        uint256 n = stakeFor(alice, P30, AMOUNT);
        freezeAndSeize(alice, n);
        _warpDays(P30 + 1);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, n));
        staking.claimDeposit(n);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, n));
        staking.withdrawDeposit(n);
        uint256 before = token.balanceOf(alice);
        staking.claimAll();
        assertEq(token.balanceOf(alice), before, "claimAll pays nothing");
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, n));
        staking.seizeDeposit(alice, n);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, alice, n));
        staking.freezeDeposit(alice, n);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, n));
        staking.unfreezeDeposit(alice, n);

        (uint256 cStake, uint256 cReward,) = staking.checkClaimableDataFor(alice);
        assertEq(cStake + cReward, 0);
    }

    // ======================================
    // =   Regression: principal-only seize =
    // ======================================

    /// @notice Short pool: bob's matured reservation is the whole pool. Seizing carol (90-day, frozen on day 1)
    ///         sends exactly her principal, leaves the pool alone, and bob is still paid principal + full reward.
    function test_regression_seize_shortPool_bobStillPaidInFull() external {
        _drainPool();
        uint256 b = stakeFor(bob, P30, AMOUNT);
        uint256 bobReward = _deposit(bob, b).rewardGenerated;
        assertGt(bobReward, 0);
        staking.provideReward(bobReward);
        assertEq(staking.rewardPool(), bobReward, "pool == bob's reservation");
        assertEq(staking.getCollectableReward(), 0);

        _warpDays(P30);
        assertEq(uint256(_status(bob, b)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));

        uint256 c = stakeFor(carol, P90, AMOUNT);
        assertGt(_deposit(carol, c).rewardGenerated, 0, "carol reserved beyond the pool");
        _warpDays(1);
        freeze(carol, c);

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(carol, c, treasury, AMOUNT);
        seize(carol, c);

        assertEq(token.balanceOf(treasury) - treasuryBefore, AMOUNT, "exactly carol's principal");
        assertEq(staking.rewardPool(), bobReward, "pool unchanged");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), bobReward, "only bob's reservation left");
        assertEq(_deposit(carol, c).rewardGenerated, 0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, carol), 0);
        _assertConservation();

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        staking.claimDeposit(b);
        assertEq(token.balanceOf(bob) - bobBefore, AMOUNT + bobReward, "bob paid principal + full reward");
        assertEq(staking.rewardPool(), 0);
        _assertConservation();

        // Carol gets nothing afterwards, before and after her deposit's maturity.
        _assertSeizedPaysNothing(carol, c);
        _assertConservation();
    }

    /// @notice Indefinite seize with accrued reward and a pool that could pay it: principal only, the pool and
    ///         collectable are unchanged, and the seized deposit's view never reports the unpaid accrual.
    function test_regression_seize_indefinite_fundedPool_accrualStaysInPool_viewShowsNoAccrual() external {
        uint256 n = stakeFor(alice, P0, AMOUNT);
        _warpDays(120);
        uint256 accrued = _deposit(alice, n).rewardGenerated;
        assertGt(accrued, 0, "accrued");
        assertLe(accrued, staking.getCollectableReward(), "pool funded enough to pay it");
        freeze(alice, n);

        uint256 pool = staking.rewardPool();
        uint256 collectable = staking.getCollectableReward();
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, n, treasury, AMOUNT);
        seize(alice, n);

        assertEq(token.balanceOf(treasury) - treasuryBefore, AMOUNT, "principal only");
        assertEq(staking.rewardPool(), pool, "pool unchanged");
        assertEq(staking.getCollectableReward(), collectable, "collectable unchanged");
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);

        // Views: no unpaid accrual, now or later.
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        assertEq(_deposit(alice, n).rewardGenerated, 0, "getDeposit shows no accrual");
        assertEq(_lens(staking).getDepositsInRangeBy(alice, 0, 1)[0].rewardGenerated, 0, "range view shows no accrual");
        (,, uint256 cIndef) = staking.checkClaimableDataFor(alice);
        assertEq(cIndef, 0);

        // The unpaid accrual is company money: it is inside collectable and the owner can collect it.
        uint256 collectableNow = staking.getCollectableReward();
        assertGe(collectableNow, accrued, "collectable includes the unpaid accrual");
        uint256 ownerBefore = token.balanceOf(owner);
        staking.collectReward(collectableNow);
        assertEq(token.balanceOf(owner) - ownerBefore, collectableNow, "owner collected it");
        assertEq(staking.rewardPool(), pool - collectableNow);
        assertEq(staking.getCollectableReward(), 0);
        _assertConservation();

        // Alice gets nothing afterwards, now and after a long warp.
        _assertSeizedPaysNothing(alice, n);
        _warpDays(365);
        assertEq(_deposit(alice, n).rewardGenerated, 0, "no accrual after seize");
        assertEq(_lens(staking).getDepositsInRangeBy(alice, 0, 1)[0].rewardGenerated, 0);
        _assertConservation();
    }

    /// @notice Seizing a matured (READY_TO_CLAIM) periodical deposit: principal only, and its reservation is
    ///         released so getCollectableReward rises by exactly the reserved amount.
    function test_regression_seize_readyToClaim_principalOnly_releasesReservation() external {
        uint256 other = stakeFor(bob, P90, AMOUNT); // bystander reservation stays
        uint256 otherReward = _deposit(bob, other).rewardGenerated;
        uint256 n = stakeFor(alice, P30, AMOUNT);
        uint256 reserved = _deposit(alice, n).rewardGenerated;
        assertGt(reserved, 0);
        _warpDays(P30 + 1);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
        freeze(alice, n);

        uint256 pool = staking.rewardPool();
        uint256 collectable = staking.getCollectableReward();
        uint256 totalClaim = staking.totalDataList(Types.DataType.CLAIM);
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, n, treasury, AMOUNT);
        seize(alice, n);

        assertEq(token.balanceOf(treasury) - treasuryBefore, AMOUNT, "principal only");
        assertEq(staking.rewardPool(), pool, "pool unchanged");
        assertEq(staking.getCollectableReward(), collectable + reserved, "collectable rises by the reservation");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), otherReward);
        assertEq(staking.getUserData(Types.DataType.REWARD_EXPECTED, alice), 0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);
        assertEq(staking.totalDataList(Types.DataType.CLAIM), totalClaim);
        assertEq(_deposit(alice, n).rewardGenerated, 0);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        (uint256 cStake, uint256 cReward, uint256 cIndef) = staking.checkClaimableDataFor(alice);
        assertEq(cStake + cReward + cIndef, 0);
        _assertConservation();

        // The released reservation is company money: the owner can collect it; bob's reservation stays.
        uint256 collectableNow = staking.getCollectableReward();
        uint256 ownerBefore = token.balanceOf(owner);
        staking.collectReward(collectableNow);
        assertEq(token.balanceOf(owner) - ownerBefore, collectable + reserved, "owner collected incl. released");
        assertEq(staking.rewardPool(), otherReward, "only bob's reservation remains");
        assertEq(staking.getCollectableReward(), 0);
        _assertConservation();

        // Alice gets nothing afterwards, now and after warping past bob's maturity too.
        _assertSeizedPaysNothing(alice, n);
        _assertConservation();
    }

    // ======================================
    // =              Batches               =
    // ======================================
    function test_batch_lengthMismatch() external {
        address[] memory ws = new address[](2);
        uint256[] memory ns = new uint256[](1);
        bytes memory err = abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1);

        vm.startPrank(admin);
        vm.expectRevert(err);
        staking.freezeDeposits(ws, ns);
        vm.expectRevert(err);
        staking.unfreezeDeposits(ws, ns);
        vm.stopPrank();
        vm.expectRevert(err);
        staking.seizeDeposits(ws, ns);
    }

    function test_batch_freezeUnfreeze_eventsAndAtomicity() external {
        uint256 a = stakeFor(alice, P30, AMOUNT);
        uint256 b = stakeFor(bob, P0, AMOUNT);
        (address[] memory ws, uint256[] memory ns) = _pair(alice, a, bob, b);

        vm.expectEmit(true, true, true, true, address(staking));
        emit FreezeDeposit(alice, a, admin);
        vm.expectEmit(true, true, true, true, address(staking));
        emit FreezeDeposit(bob, b, admin);
        vm.prank(admin);
        staking.freezeDeposits(ws, ns);
        assertTrue(staking.isDepositFrozen(alice, a));
        assertTrue(staking.isDepositFrozen(bob, b));

        vm.expectEmit(true, true, true, true, address(staking));
        emit UnfreezeDeposit(alice, a, owner);
        vm.expectEmit(true, true, true, true, address(staking));
        emit UnfreezeDeposit(bob, b, owner);
        staking.unfreezeDeposits(ws, ns);
        assertFalse(staking.isDepositFrozen(alice, a));
        assertFalse(staking.isDepositFrozen(bob, b));

        // Atomic: the second entry is already frozen -> nothing is frozen.
        freeze(bob, b);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, bob, b));
        staking.freezeDeposits(ws, ns);
        assertFalse(staking.isDepositFrozen(alice, a), "first entry rolled back");

        // Atomic unfreeze: alice not frozen -> bob stays frozen.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.unfreezeDeposits(ws, ns);
        assertTrue(staking.isDepositFrozen(bob, b), "second entry untouched");
    }

    function test_batch_seize_singleTransfer_eventsAndCounters() external {
        uint256 a = stakeFor(alice, P30, AMOUNT);
        uint256 b = stakeFor(bob, P90, 3 * AMOUNT);
        uint256 rewardA = _deposit(alice, a).rewardGenerated;
        uint256 rewardB = _deposit(bob, b).rewardGenerated;
        (address[] memory ws, uint256[] memory ns) = _pair(alice, a, bob, b);
        vm.prank(admin);
        staking.freezeDeposits(ws, ns);

        uint256 pool = staking.rewardPool();
        uint256 collectable = staking.getCollectableReward();
        uint256 before = token.balanceOf(treasury);

        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, a, treasury, AMOUNT);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(bob, b, treasury, 3 * AMOUNT);
        vm.recordLogs();
        staking.seizeDeposits(ws, ns);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(token) && logs[i].topics[0] == TRANSFER_TOPIC
                    && address(uint160(uint256(logs[i].topics[1]))) == address(staking)
            ) {
                transfers++;
            }
        }
        assertEq(transfers, 1, "one transfer for the whole batch");

        assertEq(token.balanceOf(treasury) - before, 4 * AMOUNT, "principals only");
        assertEq(staking.rewardPool(), pool, "pool untouched");
        assertEq(staking.getCollectableReward(), collectable + rewardA + rewardB, "both reservations released");
        assertEq(staking.totalDataList(Types.DataType.STAKING), 0);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(staking.totalDataList(Types.DataType.CLAIM), 0);
        assertEq(_cell(alice, 0, P30), 0);
        assertEq(_cell(bob, 0, P90), 0);
        assertEq(uint256(_status(alice, a)), uint256(ProgramManager.DepositStatus.SEIZED));
        assertEq(uint256(_status(bob, b)), uint256(ProgramManager.DepositStatus.SEIZED));
        _assertConservation();
    }

    function test_batch_seize_atomic() external {
        uint256 a = stakeFor(alice, P30, AMOUNT);
        uint256 b = stakeFor(bob, P30, AMOUNT);
        freeze(alice, a); // bob's deposit is not frozen
        (address[] memory ws, uint256[] memory ns) = _pair(alice, a, bob, b);

        uint256 before = token.balanceOf(treasury);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, bob, b));
        staking.seizeDeposits(ws, ns);

        assertEq(token.balanceOf(treasury), before);
        assertTrue(staking.isDepositFrozen(alice, a), "first entry rolled back");
        assertEq(_cell(alice, 0, P30), AMOUNT);

        // Same deposit twice in one batch: second entry is no longer frozen.
        (ws, ns) = _pair(alice, a, alice, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.seizeDeposits(ws, ns);
        assertTrue(staking.isDepositFrozen(alice, a));
    }

    function test_batch_seize_shortPool_principalOnly_poolUntouched() external {
        _drainPool();
        uint256 a = stakeFor(alice, P30, AMOUNT);
        uint256 b = stakeFor(bob, P90, AMOUNT);
        uint256 rewardA = _deposit(alice, a).rewardGenerated;
        staking.provideReward(rewardA); // pool == rewardA < rewardA + rewardB
        (address[] memory ws, uint256[] memory ns) = _pair(alice, a, bob, b);
        vm.prank(admin);
        staking.freezeDeposits(ws, ns);

        uint256 before = token.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, a, treasury, AMOUNT);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(bob, b, treasury, AMOUNT);
        staking.seizeDeposits(ws, ns);

        assertEq(token.balanceOf(treasury) - before, 2 * AMOUNT, "principals only");
        assertEq(staking.rewardPool(), rewardA, "pool untouched");
        assertEq(staking.getCollectableReward(), rewardA, "whole pool is collectable again");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(_deposit(alice, a).rewardGenerated, 0);
        assertEq(_deposit(bob, b).rewardGenerated, 0);
        _assertConservation();
    }

    // ======================================
    // =               Fuzz                 =
    // ======================================
    function testFuzz_seize_periodical_principalOnly(
        uint256 amount,
        uint256 extraApy,
        bool longPeriod,
        uint256 daysWarp,
        uint256 topUp
    ) external {
        amount = bound(amount, 100, DEFAULT_LIMIT);
        extraApy = bound(extraApy, 0, MAX_EXTRA_APY_BPS);
        daysWarp = bound(daysWarp, 0, 400);
        uint256 period = longPeriod ? P90 : P30;

        _drainPool();
        uint256 n = stakeWith(alice, period, amount, extraApy, 0);
        uint256 reward = _deposit(alice, n).rewardGenerated;
        assertEq(reward, staking.calculateReward(amount, _baseApy(0, period) + extraApy, period));
        topUp = bound(topUp, 0, 2 * reward + 1);
        if (topUp != 0) staking.provideReward(topUp);

        _warpDays(daysWarp);
        freeze(alice, n);
        uint256 before = token.balanceOf(treasury);
        seize(alice, n);

        assertEq(token.balanceOf(treasury) - before, amount, "treasury gets principal only");
        assertEq(staking.rewardPool(), topUp, "pool untouched");
        assertEq(staking.getCollectableReward(), topUp, "reservation released");
        assertEq(_deposit(alice, n).rewardGenerated, 0, "stored reward zeroed");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(staking.totalDataList(Types.DataType.STAKING), 0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);
        assertEq(staking.getUserData(Types.DataType.WITHDRAWAL, alice), amount);
        assertEq(_cell(alice, 0, period), 0);
        assertEq(controller.getRemaining(alice, 0, period), DEFAULT_LIMIT);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        _assertConservation();
    }

    function testFuzz_seize_flexible_principalOnly(uint256 amount, uint256 extraApy, uint256 daysWarp) external {
        amount = bound(amount, 100, DEFAULT_LIMIT);
        extraApy = bound(extraApy, 0, MAX_EXTRA_APY_BPS);
        daysWarp = bound(daysWarp, 0, 3_650);

        uint256 n = stakeWith(alice, P0, amount, extraApy, 0);
        _warpDays(daysWarp);
        assertEq(_deposit(alice, n).rewardGenerated, staking.calculateReward(amount, APY_P0 + extraApy, daysWarp));

        freeze(alice, n);
        uint256 pool = staking.rewardPool();
        uint256 collectable = staking.getCollectableReward();
        uint256 before = token.balanceOf(treasury);
        seize(alice, n);

        assertEq(token.balanceOf(treasury) - before, amount, "principal only");
        assertEq(staking.rewardPool(), pool, "pool untouched");
        assertEq(staking.getCollectableReward(), collectable, "collectable untouched");
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), 0);
        assertEq(_deposit(alice, n).rewardGenerated, 0, "seized view shows no accrual");
        assertEq(_cell(alice, 0, P0), 0);
        _assertConservation();
    }
}
