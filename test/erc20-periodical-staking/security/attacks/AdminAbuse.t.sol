// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";

/// @title AdminAbuse
/// @notice Owner/admin actions performed mid-flight must never lock user principal, never retroactively
///         change what a deposit pays, and must always be recoverable by the owner.
contract AdminAbuseTest is AttackBase {
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
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 1000);
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

    /// @dev Hypothesis: safeStake's expectedAPY guard protects users from an APY change in the same block.
    function test_apyChanged_frontRunsStaker_exactError() public {
        uint256 old = _apy(0, P30);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, old - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.PhasePeriodAPYChanged.selector, 0, P30, old - 1));
        staking.safeStake(0, P30, 1_000 * ONE, old);
    }

    // ---------------------------------------------------------------------
    // Targets
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: lowering the target below STAKED underflows somewhere or blocks closing.
    function test_targetLoweredBelowStaked_noUnderflow_closingWorks() public {
        uint256 d = _stake(alice, 0, P30, 10_000 * ONE);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, 1_000 * ONE);

        (bool exceeds, uint256 remaining) = staking.checkIfUserExceedsLimit(alice, 0, P30, 1);
        assertFalse(exceeds);
        assertEq(remaining, 0);
        (, uint256[][] memory rem,) = staking.getPhasePeriodUserData(alice);
        assertEq(rem[0][1], 0);

        uint256 h1 = _apy(0, P30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P30, 1_000 * ONE));
        staking.safeStake(0, P30, 100, h1);

        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: setting target 0 is the documented way to disable a period; it must not lock deposits.
    function test_targetZero_disablesNewStakes_notClosing() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P0, 0);
        uint256 h2 = _apy(0, P0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P0, 0));
        staking.safeStake(0, P0, 100, h2);
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
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 0));
        staking.safeStake(0, P30, 1_000 * ONE, 0);
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

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 1, P30, 11_000 * ONE));
        staking.safeStake(1, P30, 1_001 * ONE, 2);
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
        assertGe(staking.getRewardPoolShortfall(), reward, "shortfall counts the existing deficit");
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
        assertGe(staking.getRewardPoolShortfall(), reward);
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
    // Action availability & whitelist
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: closing CLAIM also blocks withdraw (or vice versa). They must be independent and reversible.
    function test_actionAvailability_independentAndReversible() public {
        uint256 d0 = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 d1 = _stake(alice, 0, P30, 1_000 * ONE);

        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        _withdraw(alice, d1); // withdraw still open
        staking.changeActionAvailability(Types.DataType.STAKING, false);
        uint256 h5 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING));
        staking.safeStake(0, P30, 1_000 * ONE, h5);

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
    function test_actionAvailability_nonActionTypes_noSideEffects() public {
        staking.changeActionAvailability(Types.DataType.REWARD_EXPECTED, false);
        staking.changeActionAvailability(Types.DataType.REWARD_PROVIDED, false);
        assertTrue(staking.checkActionAvailability(Types.DataType.STAKING));
        assertTrue(staking.checkActionAvailability(Types.DataType.CLAIM));
        assertTrue(staking.checkActionAvailability(Types.DataType.WITHDRAWAL));
        _stake(alice, 0, P0, 1_000 * ONE);
        staking.provideReward(1);
    }

    /// @dev Hypothesis: enabling the whitelist after a deposit blocks closing that deposit.
    function test_whitelistToggle_midDeposit_onlyBlocksNewStakes() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 e = _stake(alice, 0, P0, 1_000 * ONE);
        staking.setWhitelistEnabled(true);
        uint256 h6 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWhitelisted.selector, alice));
        staking.safeStake(0, P30, 1_000 * ONE, h6);
        _withdraw(alice, e);
        _warpDays(30);
        _claim(alice, d);

        staking.setWhitelistAddress(alice, true);
        uint256 f = _stake(alice, 0, P0, 1_000 * ONE);
        staking.setWhitelistAddress(alice, false);
        _withdraw(alice, f);
        _assertAccounting();
    }

    /// @dev Hypothesis: whitelist helpers accept address(0) (poisoning the mapping).
    function test_whitelist_zeroAddress_rejected() public {
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        staking.setWhitelistAddress(address(0), true);
        address[] memory a = new address[](2);
        a[0] = alice;
        a[1] = address(0);
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        staking.setWhitelistAddresses(a, true);
        assertFalse(staking.isWhitelisted(alice), "batch must be atomic");
    }

    // ---------------------------------------------------------------------
    // External contract misconfiguration
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: pointing limitController at an EOA bricks the contract.
    ///      It may only block new stakes and controller-dependent views; owner must be able to recover.
    function test_limitController_setToEOA_recoverable() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        staking.setLimitController(rando);

        uint256 h7 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert();
        staking.safeStake(0, P30, 1_000 * ONE, h7);
        vm.expectRevert();
        staking.getProgramDataWithUserData(alice);
        staking.getProgramData(); // does not consult the controller

        _warpDays(30);
        _claim(alice, d);

        staking.setLimitController(address(0));
        _stake(alice, 0, P30, 1_000 * ONE);
        staking.getProgramDataWithUserData(alice);
        _assertAccounting();
    }

    /// @dev Hypothesis: pointing requirementChecker at an EOA bricks *all* program views including getProgramData.
    ///      Claims/withdrawals must still work and the owner must be able to recover.
    function test_requirementChecker_setToEOA_recoverable() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        staking.setRequirementChecker(rando);

        uint256 h8 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert();
        staking.safeStake(0, P30, 1_000 * ONE, h8);
        vm.expectRevert();
        staking.getProgramData();
        // user-facing reads that don't need the checker
        staking.checkClaimableDataFor(alice);
        staking.getDeposit(alice, d);

        _warpDays(30);
        _claim(alice, d);

        staking.setRequirementChecker(address(0));
        staking.getProgramData();
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

    /// @dev Hypothesis: an admin can escalate to owner-only functions or mint more admins.
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
        vm.stopPrank();
        staking.removeContractAdmin(admin);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.provideReward(1);
    }

    /// @dev Hypothesis: raising minimumDeposit after a small deposit blocks closing it.
    function test_minimumDepositRaised_doesNotAffectExisting() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        staking.setMiniumumDeposit(1_000_000 * ONE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMinimumDeposit.selector, 0, 1));
        staking.setMiniumumDeposit(0);
        uint256 h9 = _apy(0, P30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientDeposit.selector, 1_000 * ONE, 1_000_000 * ONE));
        staking.safeStake(0, P30, 1_000 * ONE, h9);
        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: the owner can drain principal through any admin path (collect / rescue / pop / remove).
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
    }
}
