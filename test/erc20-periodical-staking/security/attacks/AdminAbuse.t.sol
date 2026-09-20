// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";

/// @title AdminAbuse
/// @notice Owner/admin actions performed mid-flight must never lock user principal, never retroactively
///         change what a deposit pays, and must always be recoverable by the owner. Freeze / seize is the one
///         deliberate way to take a deposit: it must stay tiered (admins freeze, only the owner seizes), only
///         ever pay the treasury, never touch other deposits' reserves, and never revert because the pool is short.
contract AdminAbuseTest is VoucherAttackBase {
    event FreezeDeposit(address indexed wallet, uint256 indexed depositNumber, address indexed by);
    event UnfreezeDeposit(address indexed wallet, uint256 indexed depositNumber, address indexed by);
    event SeizeDeposit(address indexed wallet, uint256 indexed depositNumber, address indexed treasury, uint256 principal);

    // ---------------------------------------------------------------------
    // APY changes
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: lowering the APY after a periodical stake reduces what the deposit pays.
    function test_apyLowered_periodicalDeposit_paysOriginal() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 1);
        assertEq(_deposit(alice, d).rewardGenerated, reward);
        assertEq(_user(Types.DataType.REWARD_EXPECTED, alice), reward);
        _warpDays(30);
        uint256 before = token.balanceOf(alice);
        _claim(alice, d);
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + reward);
        _assertAccounting();
    }

    /// @dev Hypothesis: raising the APY after a periodical stake is not retroactive (no free reward).
    function test_apyRaised_periodicalDeposit_notRetroactive() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 9_000);
        _warpDays(30);
        uint256 before = token.balanceOf(alice);
        _claim(alice, d);
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + reward);
        _assertAccounting();
    }

    /// @dev Hypothesis: an indefinite depositor who claimed partial reward at a high APY gets locked when the
    ///      APY is lowered. The deposit stores its own APY and must stay claimable / withdrawable.
    function test_apyLowered_indefinite_afterPartialClaim_neverLocked() public {
        uint256 d = _stake(alice, 0, P0, 10_000 * ONE);
        _warpDays(10);
        _claim(alice, d);
        uint256 paid = _user(Types.DataType.CLAIM, alice);
        assertGt(paid, 0);

        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P0, 1);
        // reads must not revert
        _deposit(alice, d);
        staking.checkClaimableDataFor(alice);
        staking.checkTotalClaimableData();

        _warpDays(1);
        _claim(alice, d); // must not revert
        _warpDays(1);
        _withdraw(alice, d); // must not revert
        assertEq(_user(Types.DataType.CLAIM, alice), staking.calculateReward(10_000 * ONE, APY_PHASE0[0], 12));
        _assertAccounting();
    }

    /// @dev Hypothesis: raising the APY on the indefinite cell is not retroactive for existing deposits.
    function test_apyRaised_indefinite_existingDepositKeepsAPY() public {
        uint256 d = _stake(alice, 0, P0, 10_000 * ONE);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P0, 5000);
        _warpDays(10);
        assertEq(_deposit(alice, d).rewardGenerated, staking.calculateReward(10_000 * ONE, APY_PHASE0[0], 10));
        assertEq(_deposit(alice, d).APY, APY_PHASE0[0]);
    }

    /// @dev Hypothesis: the owner front-runs a staker by lowering the APY. expectedApyBps is a floor: a lower
    ///      effective APY reverts with exact figures, a higher one is accepted and recorded, and the voucher's
    ///      extra APY counts toward the floor.
    function test_apyChanged_frontRunsStaker_floorGuard() public {
        uint256 old = _apy(0, P30);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, old - 1);
        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, old, abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, P30, old - 1, old)
        );

        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, old + 1);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        vm.prank(alice);
        uint256 d = staking.stakeWithVoucher(v, sig, 1_000 * ONE, old);
        assertEq(_deposit(alice, d).APY, old + 1, "higher APY accepted and recorded");

        (v, sig) = _prepareVoucherStake(staking, alice, 0, P30, 5, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, P30, old + 6, old + 7));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, old + 7);
        vm.prank(alice);
        d = staking.stakeWithVoucher(v, sig, 1_000 * ONE, old + 6);
        assertEq(_deposit(alice, d).APY, old + 6);
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // Targets
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: lowering the target below STAKED underflows somewhere or blocks closing.
    function test_targetLoweredBelowStaked_noUnderflow_closingWorks() public {
        uint256 d = _stake(alice, 0, P30, 10_000 * ONE);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, 1_000 * ONE);

        // views that subtract staked from target saturate instead of underflowing
        _lens(staking).getRewardRequiredForTargets();
        _lens(staking).getRewardPoolShortfall();
        _lens(staking).getProgramDataWithUserData(alice);

        _expectStakeRevert(
            bob, 0, P30, 100, _apy(0, P30), abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P30, 1_000 * ONE)
        );

        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: setting target 0 is the documented way to disable a period; it must not lock deposits.
    function test_targetZero_disablesNewStakes_notClosing() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P0, 0);
        _expectStakeRevert(
            bob, 0, P0, 100, _apy(0, P0), abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P0, 0)
        );
        _warpDays(3);
        _withdraw(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: the owner can write STAKED directly and desync accounting.
    function test_setPhasePeriodData_cannotWriteSTAKED() public {
        vm.expectRevert(Errors.InvalidDataType.selector);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKED, 0, P30, 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAPY.selector, 0, 1));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 7));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 7, P30, 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, 77));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, 77, 1);
    }

    // ---------------------------------------------------------------------
    // Phases
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: changeStakingPhase accepts out-of-range phases.
    function test_changeStakingPhase_outOfRange_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 2));
        staking.changeStakingPhase(2);
        staking.changeStakingPhase(1);
        staking.changeStakingPhase(0);
        assertEq(staking.currentStakingPhase(), 0);
    }

    /// @dev Hypothesis: popping the current phase leaves currentStakingPhase dangling.
    function test_popStakingPhase_currentIsLast_currentAdjusts() public {
        staking.changeStakingPhase(1);
        staking.popStakingPhase();
        assertEq(staking.stakingPhaseCount(), 1);
        assertEq(staking.currentStakingPhase(), 0);
        _stake(alice, 0, P30, 1_000 * ONE);
    }

    /// @dev Hypothesis: popping down to zero phases makes staking impossible with a clear error, and a further pop reverts NoStakingPhasesAddedYet.
    function test_popStakingPhase_toZero_thenGuarded() public {
        staking.popStakingPhase();
        staking.popStakingPhase();
        assertEq(staking.stakingPhaseCount(), 0);
        assertEq(staking.currentStakingPhase(), 0);
        vm.expectRevert(Errors.NoStakingPhasesAddedYet.selector);
        staking.popStakingPhase();
        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, 0, abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 0)
        );
        vm.expectRevert(Errors.NoStakingPhasesAddedYet.selector);
        staking.changeStakingPhase(0);
    }

    /// @dev Pop phase 1 with deposits, push a new phase 1 with different config: old deposits keep their APY
    ///      and previously staked tokens count toward the new target.
    function test_popPhase_thenRepush_oldDepositsKeepAPY_stakedCountsTowardNewTarget() public {
        staking.changeStakingPhase(1);
        uint256 d = _stake(alice, 1, P30, 10_000 * ONE);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        staking.popStakingPhase();

        uint256[] memory apys = new uint256[](3);
        apys[0] = 1;
        apys[1] = 2;
        apys[2] = 3;
        uint256[] memory targets = new uint256[](3);
        targets[0] = 11_000 * ONE;
        targets[1] = 11_000 * ONE;
        targets[2] = 11_000 * ONE;
        staking.pushStakingPhase(apys, targets);
        _trackPhaseCount();
        staking.changeStakingPhase(1);

        assertEq(_deposit(alice, d).APY, APY_PHASE1[1]);
        assertEq(_deposit(alice, d).rewardGenerated, reward);
        assertEq(_staked(1, P30), 10_000 * ONE, "STAKED must survive pop");

        _expectStakeRevert(
            bob, 1, P30, 1_001 * ONE, 2, abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 1, P30, 11_000 * ONE)
        );
        _stake(bob, 1, P30, 1_000 * ONE);

        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: removing a nonexistent period, or the same period twice, corrupts the list.
    function test_removeStakingPeriod_nonexistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, 77));
        staking.removeStakingPeriod(77);
        staking.removeStakingPeriod(P30);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, P30));
        staking.removeStakingPeriod(P30);
        assertEq(staking.getStakingPeriods().length, 2);
    }

    // ---------------------------------------------------------------------
    // Reward pool
    // ---------------------------------------------------------------------

    /// @dev collectReward cannot take earmarked rewards; exact error and getCollectableReward agree.
    function test_collectReward_cannotDrainEarmark_exactError() public {
        _stake(alice, 0, P90, 50_000 * ONE);
        uint256 reserved = _total(Types.DataType.REWARD_EXPECTED);
        uint256 collectable = staking.rewardPool() - reserved;
        assertEq(staking.getCollectableReward(), collectable);

        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, collectable + 1, collectable));
        staking.collectReward(collectable + 1);

        uint256 before = token.balanceOf(owner);
        staking.collectReward(collectable);
        assertEq(token.balanceOf(owner) - before, collectable);
        assertEq(staking.rewardPool(), reserved);
        assertEq(staking.getCollectableReward(), 0);
        assertEq(_total(Types.DataType.REWARD_COLLECTED), collectable, "REWARD_COLLECTED tracked");
        assertEq(_user(Types.DataType.REWARD_COLLECTED, owner), collectable);
        _assertAccounting();
    }

    /// @dev Zero-value provide / collect are rejected.
    function test_zeroValue_provideAndCollect_rejected() public {
        vm.expectRevert(Errors.ZeroAmountProvided.selector);
        staking.provideReward(0);
        vm.expectRevert(Errors.ZeroAmountProvided.selector);
        staking.collectReward(0);
    }

    /// @dev A periodical stake is accepted against an EMPTY pool. Its reward is committed to
    ///      REWARD_EXPECTED, nothing is collectable, and getRewardPoolShortfall() reports the deficit.
    function test_stake_periodical_emptyPool_accepted() public {
        staking.collectReward(staking.getCollectableReward());
        assertEq(staking.rewardPool(), 0);
        uint256 reward = staking.calculateReward(1_000 * ONE, _apy(0, P30), P30);
        _stake(alice, 0, P30, 1_000 * ONE);
        assertEq(_total(Types.DataType.REWARD_EXPECTED), reward);
        assertEq(staking.rewardPool(), 0, "no stake-time pool check");
        assertEq(staking.getCollectableReward(), 0);
        assertGe(_lens(staking).getRewardPoolShortfall(), reward, "shortfall counts the existing deficit");
        // the owner cannot take reward promised to an open deposit, even though the pool holds nothing
        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, 1, 0));
        staking.collectReward(1);
        // indefinite is never reserved and is accepted as well
        _stake(alice, 0, P0, 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev With the pool covering exactly one deposit, a second periodical stake is still
    ///      accepted. At maturity the first claim drains the pool, the second reverts
    ///      NotEnoughFundsInRewardPool, and succeeds after a top-up with nothing lost.
    function test_stake_periodical_poolExactlySufficient_secondStakeWaitsForTopUp() public {
        uint256 reward = staking.calculateReward(1_000 * ONE, _apy(0, P30), P30);
        staking.collectReward(staking.getCollectableReward() - reward);
        uint256 a = _stake(alice, 0, P30, 1_000 * ONE);
        assertEq(staking.getCollectableReward(), 0);
        uint256 b = _stake(bob, 0, P30, 1_000 * ONE);
        assertEq(_total(Types.DataType.REWARD_EXPECTED), 2 * reward);
        assertEq(staking.rewardPool(), reward, "pool below REWARD_EXPECTED is allowed");
        assertGe(_lens(staking).getRewardPoolShortfall(), reward);
        _assertAccounting();

        _warpDays(31);
        _claim(alice, a);
        assertEq(staking.rewardPool(), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward, 0));
        staking.claimDeposit(b);
        _assertAccounting();

        staking.provideReward(reward);
        uint256 before = token.balanceOf(bob);
        _claim(bob, b);
        assertEq(token.balanceOf(bob) - before, 1_000 * ONE + reward, "no loss after top-up");
        assertEq(staking.rewardPool(), 0);
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // Action availability
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: closing CLAIM also blocks withdraw (or vice versa). They must be independent and reversible.
    function test_actionAvailability_independentAndReversible() public {
        uint256 d0 = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 d1 = _stake(alice, 0, P30, 1_000 * ONE);

        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        _withdraw(alice, d1); // withdraw still open
        staking.changeActionAvailability(Types.DataType.STAKING, false);
        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, _apy(0, P30), abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING)
        );

        _warpDays(30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.CLAIM));
        staking.claimDeposit(d0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.CLAIM));
        staking.claimAll();

        staking.changeActionAvailability(Types.DataType.CLAIM, true);
        _claim(alice, d0);
        staking.changeActionAvailability(Types.DataType.STAKING, true);
        _stake(alice, 0, P30, 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: toggling availability on a non-action DataType has side effects on real actions.
    ///      Since v0.4.0 it is rejected outright and reads as closed.
    function test_actionAvailability_nonActionTypes_rejected_noSideEffects() public {
        vm.expectRevert(Errors.InvalidDataType.selector);
        staking.changeActionAvailability(Types.DataType.REWARD_EXPECTED, false);
        vm.expectRevert(Errors.InvalidDataType.selector);
        staking.changeActionAvailability(Types.DataType.REWARD_PROVIDED, true);
        assertFalse(staking.checkActionAvailability(Types.DataType.REWARD_EXPECTED));
        assertTrue(staking.checkActionAvailability(Types.DataType.STAKING));
        assertTrue(staking.checkActionAvailability(Types.DataType.CLAIM));
        assertTrue(staking.checkActionAvailability(Types.DataType.WITHDRAWAL));
        _stake(alice, 0, P0, 1_000 * ONE);
        staking.provideReward(1);
    }

    // ---------------------------------------------------------------------
    // Freeze and seize
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: an admin can take a deposit, or seize pays someone other than the treasury.
    ///      Admins may freeze and unfreeze; only the owner seizes, and the tokens go to the treasury only.
    function test_freezeSeize_tiering_paysTreasuryOnly() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 reward = _deposit(alice, d).rewardGenerated;

        vm.expectEmit(true, true, true, true, address(staking));
        emit FreezeDeposit(alice, d, admin);
        vm.prank(admin);
        staking.freezeDeposit(alice, d);
        assertTrue(staking.isDepositFrozen(alice, d));

        vm.prank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.seizeDeposit(alice, d);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.seizeDeposits(_one(alice), _oneU(d));

        vm.expectEmit(true, true, true, true, address(staking));
        emit UnfreezeDeposit(alice, d, owner);
        staking.unfreezeDeposit(alice, d); // owner-only since the v0.5.0 audit (#10)
        vm.prank(admin);
        staking.freezeDeposit(alice, d);

        address newTreasury = makeAddr("newTreasury");
        staking.setTreasury(newTreasury);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 adminBefore = token.balanceOf(admin);
        uint256 poolBefore = staking.rewardPool();
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, d, newTreasury, 1_000 * ONE);
        _seize(alice, d);

        assertGt(reward, 0);
        assertEq(token.balanceOf(newTreasury), 1_000 * ONE, "treasury receives principal only");
        assertEq(staking.rewardPool(), poolBefore, "reserved reward stays in the pool");
        assertEq(_user(Types.DataType.REWARD_EXPECTED, alice), 0, "reservation released");
        assertEq(token.balanceOf(treasury), 0, "old treasury receives nothing");
        assertEq(token.balanceOf(owner), ownerBefore, "owner receives nothing");
        assertEq(token.balanceOf(admin), adminBefore, "admin receives nothing");
        assertFalse(staking.isDepositFrozen(alice, d), "seized clears the frozen flag");
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.SEIZED));
        _assertAccounting();
    }

    /// @dev Every enforcement edge reverts with its exact error; nothing can be frozen, seized or unfrozen twice,
    ///      and a closed or seized deposit can never be reopened through freeze/unfreeze.
    function test_freezeSeize_guards_exactErrors() public {
        uint256 a = _stake(alice, 0, P0, 1_000 * ONE);
        uint256 b = _stake(alice, 0, P30, 1_000 * ONE);

        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 9));
        staking.freezeDeposit(alice, 9);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        staking.freezeDeposit(bob, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 9));
        staking.unfreezeDeposit(alice, 9);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 9));
        staking.seizeDeposit(alice, 9);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 9));
        staking.isDepositFrozen(alice, 9);

        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.seizeDeposit(alice, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.unfreezeDeposit(alice, a);

        _freeze(alice, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, a));
        staking.freezeDeposit(alice, a);

        _seize(alice, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.seizeDeposit(alice, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, alice, a));
        staking.freezeDeposit(alice, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.unfreezeDeposit(alice, a);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, a));
        staking.withdrawDeposit(a);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, a));
        staking.claimDeposit(a);

        // a normally closed deposit cannot be frozen (so it cannot be seized either)
        _warpDays(30);
        _claim(alice, b);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, alice, b));
        staking.freezeDeposit(alice, b);
        _assertAccounting();
    }

    /// @dev Hypothesis: freezing locks principal permanently or the frozen deposit can still be exited by the
    ///      user. Frozen: single claim/withdraw revert DepositFrozen, batch claims skip it (and still pay the
    ///      rest), claimable views exclude it; after unfreeze everything is paid in full.
    function test_frozen_userCannotExit_batchSkips_unfreezeRestores() public {
        uint256 d0 = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 d1 = _stake(alice, 0, P30, 2_000 * ONE);
        uint256 d2 = _stake(alice, 0, P0, 3_000 * ONE);
        uint256 r0 = _deposit(alice, d0).rewardGenerated;
        uint256 r1 = _deposit(alice, d1).rewardGenerated;
        _freeze(alice, d0);
        _freeze(alice, d2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, d2));
        staking.withdrawDeposit(d2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, d2));
        staking.withdrawDepositPartial(d2, 0);

        _warpDays(30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, d0));
        staking.claimDeposit(d0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, d2));
        staking.claimDeposit(d2);

        (uint256 cs, uint256 cp, uint256 ci) = staking.checkClaimableDataFor(alice);
        assertEq(cs, 2_000 * ONE, "frozen principal not claimable");
        assertEq(cp, r1);
        assertEq(ci, 0, "frozen indefinite reward not claimable");

        uint256 before = token.balanceOf(alice);
        _claimAll(alice);
        assertEq(token.balanceOf(alice) - before, 2_000 * ONE + r1, "claimAll pays only the unfrozen deposit");
        vm.prank(alice);
        staking.claimRange(0, 3); // silent skip, no revert
        assertEq(token.balanceOf(alice) - before, 2_000 * ONE + r1);
        assertEq(uint256(_status(alice, d0)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
        _assertAccounting();

        staking.unfreezeDeposit(alice, d0);
        staking.unfreezeDeposit(alice, d2);
        uint256 accrued = _deposit(alice, d2).rewardGenerated;
        before = token.balanceOf(alice);
        _claim(alice, d0);
        _withdraw(alice, d2);
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + r0 + 3_000 * ONE + accrued, "nothing lost while frozen");
        _assertAccounting();
    }

    /// @dev Hypothesis: a short pool makes seize revert (letting a frozen user out-wait enforcement). A
    ///      periodical seize with an unfunded reserve pays principal only, releases the reservation and zeroes
    ///      the deposit's recorded reward.
    function test_seize_periodical_poolShort_principalOnly_neverReverts() public {
        staking.collectReward(staking.getCollectableReward()); // pool = 0
        uint256 d = _stake(alice, 0, P90, 10_000 * ONE);
        assertGt(_deposit(alice, d).rewardGenerated, 0);
        _warpDays(95); // matured too: READY_TO_CLAIM seizes the same way
        _freeze(alice, d);

        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, d, treasury, 10_000 * ONE);
        _seize(alice, d);
        assertEq(token.balanceOf(treasury), 10_000 * ONE);
        assertEq(_total(Types.DataType.REWARD_EXPECTED), 0, "reservation released");
        assertEq(_deposit(alice, d).rewardGenerated, 0, "unpaid reward is not recorded as paid");
        assertEq(_user(Types.DataType.CLAIM, alice), 0);
        assertEq(staking.rewardPool(), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: seizing an indefinite deposit takes reward reserved for someone else's periodical deposit.
    ///      Seize never pays a reward: the treasury gets principal only and the pool is untouched.
    function test_seize_indefinite_neverTakesOthersReserve() public {
        staking.collectReward(staking.getCollectableReward());
        uint256 bobReward = staking.calculateReward(1_000 * ONE, _apy(0, P90), P90);
        staking.provideReward(bobReward + 1);
        uint256 b = _stake(bob, 0, P90, 1_000 * ONE);
        uint256 a = _stake(alice, 0, P0, 100_000 * ONE);
        _warpDays(10);
        uint256 accrued = _deposit(alice, a).rewardGenerated;
        assertGt(accrued, 1, "precondition: accrued exceeds the 1-wei collectable slack");

        _freeze(alice, a);
        _seize(alice, a);
        assertEq(token.balanceOf(treasury), 100_000 * ONE, "principal only, no partial reward");
        assertEq(staking.rewardPool(), bobReward + 1, "pool untouched");
        _assertAccounting();

        _warpDays(80);
        uint256 before = token.balanceOf(bob);
        _claim(bob, b);
        assertEq(token.balanceOf(bob) - before, 1_000 * ONE + bobReward, "bob's reserve intact");
        _assertAccounting();
    }

    /// @dev Batch enforcement is atomic: one bad entry reverts everything (no partial freeze, no partial seize,
    ///      no transfer); length mismatches are typed; empty batches are harmless no-ops.
    function test_enforcementBatches_atomicAndLengthChecked() public {
        uint256 a = _stake(alice, 0, P0, 1_000 * ONE);
        uint256 b = _stake(bob, 0, P0, 1_000 * ONE);

        address[] memory w = new address[](2);
        w[0] = alice;
        w[1] = bob;
        uint256[] memory n = new uint256[](2);
        n[0] = a;
        n[1] = 5; // bob has no deposit #5
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 5));
        staking.freezeDeposits(w, n);
        assertFalse(staking.isDepositFrozen(alice, a), "freeze batch must be atomic");

        n[1] = b;
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        staking.freezeDeposits(w, _oneU(a));
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        staking.unfreezeDeposits(w, _oneU(a));
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        staking.seizeDeposits(w, _oneU(a));

        _freeze(alice, a); // bob stays unfrozen
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, bob, b));
        staking.seizeDeposits(w, n);
        assertTrue(staking.isDepositFrozen(alice, a), "seize batch must be atomic");
        assertEq(uint256(_status(alice, a)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        assertEq(token.balanceOf(treasury), 0);

        // same deposit twice in one batch: the second entry sees it already seized
        address[] memory ww = new address[](2);
        ww[0] = alice;
        ww[1] = alice;
        uint256[] memory nn = new uint256[](2);
        nn[0] = a;
        nn[1] = a;
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, alice, a));
        staking.seizeDeposits(ww, nn);
        assertTrue(staking.isDepositFrozen(alice, a));

        // Empty batches revert since the v0.5.0 audit (#37): they are always an ops mistake.
        vm.expectRevert(Errors.EmptyBatch.selector);
        staking.seizeDeposits(new address[](0), new uint256[](0));
        vm.expectRevert(Errors.EmptyBatch.selector);
        staking.freezeDeposits(new address[](0), new uint256[](0));
        assertEq(token.balanceOf(treasury), 0);
        _assertAccounting();
    }

    /// @dev Pausing claims and withdrawals does not stop enforcement, and enforcement does not reopen them.
    function test_enforcement_ignoresActionAvailability() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, false);
        staking.changeActionAvailability(Types.DataType.STAKING, false);
        vm.prank(admin);
        staking.freezeDeposit(alice, d);
        _seize(alice, d);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.SEIZED));
        assertFalse(staking.checkActionAvailability(Types.DataType.CLAIM));
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // External contract misconfiguration
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: pointing limitController at an EOA bricks the contract.
    ///      Audit finding #16: it cannot be installed any more. setLimitController asks the candidate for
    ///      stakingContract(), so an EOA (no code), a contract without that function (the token) and a real
    ///      controller deployed for ANOTHER staking contract are all refused and the old controller stays.
    ///      Unsetting the controller does NOT fall back to "no limit": staking stays closed with a typed error.
    function test_limitController_setToEOA_recoverable() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        address installed = staking.limitController();

        vm.expectRevert();
        staking.setLimitController(rando);
        vm.expectRevert();
        staking.setLimitController(address(token));
        OpenLimitController foreign = new OpenLimitController(address(token));
        vm.expectRevert(abi.encodeWithSelector(Errors.LimitControllerMismatch.selector, address(token)));
        staking.setLimitController(address(foreign));

        assertEq(staking.limitController(), installed, "refused: the working controller is still installed");
        _stake(alice, 0, P30, 1_000 * ONE);
        _lens(staking).getProgramDataWithUserData(alice);
        staking.getProgramData(); // does not consult the controller

        _warpDays(30);
        _claim(alice, d);

        staking.setLimitController(address(0));
        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, _apy(0, P30), abi.encodeWithSelector(Errors.LimitControllerNotSet.selector)
        );
        (,,,,, uint256[][] memory limits, uint256[][] memory remaining) = _lens(staking).getProgramDataWithUserData(alice);
        assertEq(limits[0][1], 0, "no controller => zero-filled limits");
        assertEq(remaining[0][1], 0, "no controller => zero-filled remaining (no whole-pool fallback)");

        staking.setLimitController(address(new OpenLimitController(address(staking))));
        _stake(alice, 0, P30, 1_000 * ONE);
        _lens(staking).getProgramDataWithUserData(alice);
        _assertAccounting();
    }

    /// @dev Hypothesis: pointing voucherSigner at a contract (here: the token) bricks something besides new
    ///      stakes. Since audit finding #39 no contract can be a signer (ECDSA only), so none is ever called. Claims, withdrawals and every view must keep working.
    function test_voucherSigner_setToNon1271Contract_recoverable() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 e = _stake(bob, 0, P0, 1_000 * ONE);
        staking.setVoucherSigner(address(token));

        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, _apy(0, P30), abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );
        staking.getProgramData();
        _lens(staking).getProgramDataWithUserData(alice);
        staking.checkClaimableDataFor(alice);

        _warpDays(30);
        _claim(alice, d);
        _withdraw(bob, e);

        staking.setVoucherSigner(_voucherSignerAddr());
        _stake(alice, 0, P30, 1_000 * ONE);
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // Ownership (two-step transfer)
    // ---------------------------------------------------------------------

    /// @dev a proposed owner has no power until acceptance; the old owner keeps power until then.
    function test_transferOwnership_twoStep_pendingHasNoPower() public {
        staking.transferOwnership(bob);
        assertEq(staking.contractOwner(), owner);
        assertEq(staking.pendingOwner(), bob);

        vm.prank(bob);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setMiniumumDeposit(1);
        staking.setMiniumumDeposit(1); // old owner still works

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, rando, bob));
        staking.acceptOwnership();

        vm.prank(bob);
        staking.acceptOwnership();
        assertEq(staking.contractOwner(), bob);
        assertEq(staking.pendingOwner(), address(0));

        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setMiniumumDeposit(2);
        vm.prank(bob);
        staking.setMiniumumDeposit(2);
    }

    /// @dev proposing address(0) cancels; a second proposal replaces the first.
    function test_transferOwnership_cancelAndReplace() public {
        staking.transferOwnership(bob);
        staking.transferOwnership(address(0));
        assertEq(staking.pendingOwner(), address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, bob, address(0)));
        staking.acceptOwnership();

        staking.transferOwnership(bob);
        staking.transferOwnership(carol);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, bob, carol));
        staking.acceptOwnership();
        vm.prank(carol);
        staking.acceptOwnership();
        assertEq(staking.contractOwner(), carol);
    }

    /// @dev transferring to self and accepting is a harmless no-op; acceptOwnership twice fails.
    function test_transferOwnership_toSelf_andDoubleAccept() public {
        staking.transferOwnership(owner);
        staking.acceptOwnership();
        assertEq(staking.contractOwner(), owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, owner, address(0)));
        staking.acceptOwnership();
    }

    /// @dev Hypothesis: an admin can escalate to owner-only functions (seize and the voucher knobs included)
    ///      or mint more admins.
    function test_admin_cannotEscalate() public {
        vm.startPrank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.addContractAdmin(rando);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.transferOwnership(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.collectReward(1);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.rescueTokens(address(token), 1);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setTreasury(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setVoucherSigner(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setMaxExtraApyBps(10_000);
        vm.stopPrank();
        staking.removeContractAdmin(admin);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.provideReward(1);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.freezeDeposit(alice, 0);
    }

    /// @dev Hypothesis: raising minimumDeposit after a small deposit blocks closing it.
    function test_minimumDepositRaised_doesNotAffectExisting() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        staking.setMiniumumDeposit(1_000_000 * ONE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMinimumDeposit.selector, 0, 1));
        staking.setMiniumumDeposit(0);
        _expectStakeRevert(
            bob,
            0,
            P30,
            1_000 * ONE,
            _apy(0, P30),
            abi.encodeWithSelector(Errors.InsufficientDeposit.selector, 1_000 * ONE, 1_000_000 * ONE)
        );
        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: the owner can drain principal through any admin path (collect / rescue / pop / remove).
    ///      The only path that moves principal is freeze + seize, and it pays the treasury, never the owner.
    function test_owner_cannotExtractPrincipal_anyPath() public {
        _stake(alice, 0, P30, 10_000 * ONE);
        _stake(bob, 0, P0, 10_000 * ONE);
        uint256 principal = _total(Types.DataType.STAKING);

        staking.collectReward(staking.getCollectableReward());
        vm.expectRevert();
        staking.rescueTokens(address(token), 1);
        staking.removeStakingPeriod(P30);
        staking.removeStakingPeriod(P0);
        staking.popStakingPhase();
        staking.popStakingPhase();
        vm.expectRevert();
        staking.rescueTokens(address(token), 1);
        vm.expectRevert();
        staking.collectReward(1);

        assertGe(token.balanceOf(address(staking)), principal, "principal must stay in the contract");
        assertEq(_total(Types.DataType.STAKING), principal);

        uint256 ownerBefore = token.balanceOf(owner);
        _freeze(bob, 0);
        _seize(bob, 0);
        assertEq(token.balanceOf(owner), ownerBefore, "seize never pays the owner");
        assertEq(token.balanceOf(treasury), 10_000 * ONE);
        vm.expectRevert();
        staking.rescueTokens(address(token), 1); // seizing creates no rescuable excess
    }
}
