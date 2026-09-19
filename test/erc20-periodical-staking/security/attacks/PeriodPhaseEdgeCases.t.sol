// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";

/// @title PeriodPhaseEdgeCases
/// @notice Period 0 semantics, list sorting/removal, zero-phase operations, wrong-phase stakes, the
///         "APY != 0 iff the period is configured" rule the stake path relies on, and the numeric bounds of
///         `stakingPeriod * 1 days` / `calculateReward`.
contract PeriodPhaseEdgeCasesTest is VoucherAttackBase {
    uint256 internal constant BPS_YEAR = 3_650_000; // BPS_DENOMINATOR * DAYS_PER_YEAR

    /// @dev Hypothesis: period 0 is treated like a normal period somewhere (end date, earmark, status).
    function test_period0_isIndefinite_noEarmark() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        ProgramManager.TokenDeposit memory dep = _deposit(alice, d);
        assertEq(dep.stakingEndDate, 0);
        assertEq(dep.rewardGenerated, 0);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        assertEq(_total(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(staking.getCollectableReward(), staking.rewardPool());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, d));
        staking.claimDeposit(d);
    }

    /// @dev Hypothesis: period 0 can be removed and re-added like any other period; open indefinite deposits survive.
    function test_period0_removeAndReadd_depositsSurvive() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        staking.removeStakingPeriod(P0);
        assertFalse(staking.checkIfStakingPeriodExists(P0));
        _expectStakeRevert(bob, 0, P0, 1_000 * ONE, 0, abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, P0));
        _warpDays(5);
        _claim(alice, d);
        _addPeriod(P0, 9, TARGET);
        assertEq(staking.getStakingPeriods()[0], 0, "0 must sort first");
        _stake(bob, 0, P0, 1_000 * ONE);
        _withdraw(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: duplicate periods can be inserted.
    function test_duplicatePeriod_rejected() public {
        uint256[] memory a = _fill(2, 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPeriodExists.selector, P30));
        staking.addStakingPeriod(P30, a, a);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPeriodExists.selector, P0));
        staking.addStakingPeriod(P0, a, a);
    }

    /// @dev Hypothesis: sortStorage / removeElementByIndex mis-order the list for some insertion orders.
    function testFuzz_periodList_sortedAndUnique_afterRandomInsertsAndRemovals(uint256 seed) public {
        ERC20PeriodicalStaking s = new ERC20PeriodicalStaking(address(token));
        uint256[] memory empty = new uint256[](0);
        uint256 n = 8;
        uint256[] memory inserted = new uint256[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            uint256 p = uint256(keccak256(abi.encode(seed, i))) % 1000;
            if (s.checkIfStakingPeriodExists(p)) continue;
            s.addStakingPeriod(p, empty, empty);
            inserted[count++] = p;
        }
        _assertSortedUnique(s);
        assertEq(s.getStakingPeriods().length, count);

        // remove 3 random ones
        for (uint256 k = 0; k < 3 && count > 0; k++) {
            uint256 idx = uint256(keccak256(abi.encode(seed, "rm", k))) % count;
            uint256 victim = inserted[idx];
            s.removeStakingPeriod(victim);
            assertFalse(s.checkIfStakingPeriodExists(victim));
            inserted[idx] = inserted[count - 1];
            count--;
            _assertSortedUnique(s);
            assertEq(s.getStakingPeriods().length, count);
        }
        for (uint256 i = 0; i < count; i++) {
            assertTrue(s.checkIfStakingPeriodExists(inserted[i]));
        }
    }

    function _assertSortedUnique(ERC20PeriodicalStaking s) internal {
        uint256[] memory l = s.getStakingPeriods();
        for (uint256 i = 1; i < l.length; i++) {
            assertLt(l[i - 1], l[i], "period list not strictly ascending");
        }
    }

    /// @dev For every phase below the count, APY != 0 exactly when the period is in the list; at and past the
    ///      count every APY cell is 0 (popped phases are cleared).
    function _assertApyMatchesPeriodList(uint256[6] memory cand) internal {
        uint256 count = staking.stakingPhaseCount();
        for (uint256 ph = 0; ph < count + 2; ph++) {
            for (uint256 j = 0; j < cand.length; j++) {
                bool nonZero = _apy(ph, cand[j]) != 0;
                if (ph < count) {
                    assertEq(nonZero, staking.checkIfStakingPeriodExists(cand[j]), "APY != 0 must mean configured");
                } else {
                    assertFalse(nonZero, "APY cell of a nonexistent phase must be 0");
                }
            }
        }
    }

    /// @dev Regression for the stake path's O(1) period check (APY cell != 0 replaces the stakingPeriodList scan):
    ///      no sequence of add/remove period, push/pop phase or APY edits breaks the equivalence, and every
    ///      unconfigured period is rejected by stakeWithVoucher while every configured one is accepted.
    function testFuzz_apyNonZero_iffPeriodConfigured(uint256 seed) public {
        uint256[6] memory cand = [uint256(0), 30, 60, 90, 120, 365];
        for (uint256 i = 0; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 5;
            uint256 p = cand[(r >> 8) % cand.length];
            uint256 count = staking.stakingPhaseCount();
            uint256 apy = ((r >> 16) % 5_000) + 1;
            if (op == 0) {
                if (!staking.checkIfStakingPeriodExists(p)) _addPeriod(p, apy, TARGET);
            } else if (op == 1) {
                if (staking.checkIfStakingPeriodExists(p)) staking.removeStakingPeriod(p);
            } else if (op == 2) {
                if (count < 4) _pushPhase(apy, TARGET);
            } else if (op == 3) {
                if (count > 0) staking.popStakingPhase();
            } else if (count > 0 && staking.checkIfStakingPeriodExists(p)) {
                staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, (r >> 24) % count, p, apy);
            }
            _assertApyMatchesPeriodList(cand);
        }

        uint256 phase = staking.currentStakingPhase();
        if (phase >= staking.stakingPhaseCount()) return;
        for (uint256 j = 0; j < cand.length; j++) {
            if (staking.checkIfStakingPeriodExists(cand[j])) {
                _stake(alice, phase, cand[j], 1_000 * ONE);
            } else {
                _expectStakeRevert(
                    alice, phase, cand[j], 1_000 * ONE, 0, abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, cand[j])
                );
            }
        }
    }

    /// @dev Hypothesis: removing the first / middle / last element breaks ordering or leaves a stale tail.
    function test_removeFirstMiddleLast() public {
        _addPeriod(60, 1, TARGET);
        _addPeriod(120, 1, TARGET); // [0,30,60,90,120]
        staking.removeStakingPeriod(0); // first
        uint256[] memory l = staking.getStakingPeriods();
        assertEq(l.length, 4);
        assertEq(l[0], 30);
        staking.removeStakingPeriod(60); // middle
        l = staking.getStakingPeriods();
        assertEq(l.length, 3);
        assertEq(l[0], 30);
        assertEq(l[1], 90);
        assertEq(l[2], 120);
        staking.removeStakingPeriod(120); // last
        l = staking.getStakingPeriods();
        assertEq(l.length, 2);
        assertEq(l[1], 90);
        assertFalse(staking.checkIfStakingPeriodExists(120));
        assertTrue(staking.checkIfStakingPeriodExists(90));
        // remove everything
        staking.removeStakingPeriod(30);
        staking.removeStakingPeriod(90);
        assertEq(staking.getStakingPeriods().length, 0);
        // push a phase with zero periods is legal
        staking.pushStakingPhase(new uint256[](0), new uint256[](0));
    }

    /// @dev Hypothesis: a fresh contract (0 phases) misbehaves on admin/user operations. Without a signer and
    ///      controller it refuses stakes with typed errors, in that order; once enabled, the phase check applies.
    function test_zeroPhases_operations() public {
        ERC20PeriodicalStaking s = new ERC20PeriodicalStaking(address(token));
        vm.expectRevert(Errors.NoStakingPhasesAddedYet.selector);
        s.popStakingPhase();
        vm.expectRevert(Errors.NoStakingPhasesAddedYet.selector);
        s.changeStakingPhase(0);
        _expectStakeRevertOn(s, alice, 0, 0, 1_000 * ONE, 0, abi.encodeWithSelector(Errors.VoucherSignerNotSet.selector));
        s.setVoucherSigner(_voucherSignerAddr());
        _expectStakeRevertOn(s, alice, 0, 0, 1_000 * ONE, 0, abi.encodeWithSelector(Errors.LimitControllerNotSet.selector));
        _enableVoucherStaking(s);
        _expectStakeRevertOn(
            s, alice, 0, 0, 1_000 * ONE, 0, abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 0)
        );
        // periods can be added with empty config arrays
        s.addStakingPeriod(30, new uint256[](0), new uint256[](0));
        // pushing a phase now needs 1-length arrays
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 1, 0));
        s.pushStakingPhase(new uint256[](0), new uint256[](0));
        s.pushStakingPhase(_fill(1, 5), _fill(1, TARGET));
        assertEq(s.stakingPhaseCount(), 1);
        // views work
        s.getProgramData();
        _lens(s).getProgramDataWithUserData(alice);
        s.checkTotalClaimableData();
    }

    /// @dev Hypothesis: a stake on a non-current (but existing) phase is accepted, e.g. by replaying a voucher
    ///      issued for the previous phase after the owner switched phases.
    function test_stakeWrongPhase_exactError() public {
        _expectStakeRevert(
            alice, 1, P30, 1_000 * ONE, _apy(1, P30), abi.encodeWithSelector(Errors.IncorrectStakingPhase.selector, 1, 0)
        );
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        uint256 apy = _apy(0, P30);
        staking.changeStakingPhase(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.IncorrectStakingPhase.selector, 0, 1));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce));
        // switching back makes the same voucher usable again (the voucher, not the call, fixes the phase)
        staking.changeStakingPhase(0);
        vm.prank(alice);
        uint256 d = staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        assertEq(_deposit(alice, d).stakingPhase, 0);
    }

    /// @dev Hypothesis: the deposit's recorded phase can differ from the validated phase argument.
    function test_depositRecordsValidatedPhase() public {
        staking.changeStakingPhase(1);
        uint256 d = _stake(alice, 1, P90, 1_000 * ONE);
        assertEq(_deposit(alice, d).stakingPhase, 1);
        assertEq(_deposit(alice, d).stakingPeriod, P90);
        assertEq(_deposit(alice, d).APY, APY_PHASE1[2]);
        assertEq(_upp(Types.DataType.STAKING, alice, 1, P90), 1_000 * ONE);
        assertEq(_upp(Types.DataType.STAKING, alice, 0, P90), 0);
    }

    /// @dev Hypothesis: length-mismatched config arrays are accepted or produce the wrong error values.
    function test_configLengthMismatch_exactErrors() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 3, 2));
        staking.pushStakingPhase(_fill(2, 1), _fill(3, 1));
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 3, 4));
        staking.pushStakingPhase(_fill(3, 1), _fill(4, 1));
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        staking.addStakingPeriod(60, _fill(1, 1), _fill(2, 1));
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 3));
        staking.addStakingPeriod(60, _fill(2, 1), _fill(3, 1));
        assertFalse(staking.checkIfStakingPeriodExists(60), "failed add must not leave the period behind");
    }

    /// @dev Hypothesis: a zero APY slips through pushStakingPhase / addStakingPeriod, which would also make the
    ///      period look unconfigured to the stake path.
    function test_zeroAPY_rejected_atomically() public {
        uint256[] memory apys = _fill(3, 1);
        apys[2] = 0;
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAPY.selector, 0, 1));
        staking.pushStakingPhase(apys, _fill(3, 1));
        assertEq(staking.stakingPhaseCount(), 2);

        uint256[] memory a2 = _fill(2, 1);
        a2[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAPY.selector, 0, 1));
        staking.addStakingPeriod(60, a2, _fill(2, 1));
        assertFalse(staking.checkIfStakingPeriodExists(60), "atomic: period must not be added");
        assertEq(staking.getStakingPeriods().length, 3);
    }

    /// @dev Hypothesis: a huge period value makes `stakingPeriod * 1 days` wrap, producing a deposit with a past end date.
    function test_hugePeriod_stakeRevertsInsteadOfWrapping() public {
        uint256 huge = type(uint256).max / 1 days + 1;
        _addPeriod(huge, 1, TARGET);
        uint256 bal = token.balanceOf(alice);
        _expectStakeRevert(alice, 0, huge, 1_000 * ONE, 1, "");
        assertEq(token.balanceOf(alice), bal);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
        // the period can still be removed
        staking.removeStakingPeriod(huge);
    }

    /// @dev Hypothesis: the largest period that fits `stakingPeriod * 1 days` still overflows the end date silently.
    function test_maxFittingPeriod_behaviour() public {
        uint256 maxP = type(uint256).max / 1 days;
        _addPeriod(maxP, 1, TARGET);
        // end date = now + maxP days overflows uint256 for any _now() > 0 -> must revert, never wrap
        _expectStakeRevert(alice, 0, maxP, 1_000 * ONE, 1, "");
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
    }

    /// @dev Hypothesis: a period whose end date fits uint256 but not the packed uint40 / uint32 storage is
    ///      truncated. It must revert with SafeCast's typed error instead.
    function test_periodBeyondPackedWidth_revertsNotTruncated() public {
        uint256 p = uint256(type(uint32).max) + 1;
        _addPeriod(p, 1, TARGET);
        _expectStakeRevert(alice, 0, p, 1_000 * ONE, 1, "");
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
    }

    /// @dev Hypothesis: a very long but sane period (100 years) works end to end.
    function test_longPeriod_100years_works() public {
        uint256 p = 36_500;
        _addPeriod(p, 1, TARGET);
        uint256 d = _stake(alice, 0, p, 1_000 * ONE);
        assertEq(_deposit(alice, d).rewardGenerated, staking.calculateReward(1_000 * ONE, 1, p));
        assertEq(_deposit(alice, d).rewardGenerated, 1_000 * ONE * p / BPS_YEAR);
        _warpDays(p);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: calculateReward silently overflows near uint256 max. rate*days is checked and the final
    ///      mulDiv reverts when the quotient does not fit.
    function test_calculateReward_overflowsRevert() public {
        vm.expectRevert();
        staking.calculateReward(type(uint256).max, 10_000, 366); // quotient > max
        vm.expectRevert();
        staking.calculateReward(1, type(uint256).max, 30); // rate * days overflows
        vm.expectRevert();
        staking.calculateReward(1, 5, type(uint256).max);
        // sane extremes do not revert
        assertEq(staking.calculateReward(1e30, 1e18, 36_500), 1e46);
        // a rate*days below one year's bps scales the amount down, so even max amount fits
        staking.calculateReward(type(uint256).max, 5, 30);
    }

    /// @dev Fuzz: calculateReward in a realistic domain never reverts and equals the exact floor of
    ///      amount * apyBps * days / 3_650_000 (one truncation, no intermediate rounding loss).
    function testFuzz_calculateReward_boundsAndRounding(uint256 amount, uint256 apy, uint256 period) public {
        amount = bound(amount, 0, 1e30);
        apy = bound(apy, 1, 1e6);
        period = bound(period, 0, 36_500);
        uint256 r = staking.calculateReward(amount, apy, period);
        uint256 product = amount * apy * period;
        assertEq(r, product / BPS_YEAR, "reward is not the exact floor");
        assertLe(r * BPS_YEAR, product, "reward rounds up");
        assertGt((r + 1) * BPS_YEAR, product, "reward loses more than one unit to truncation");
    }

    /// @dev Fuzz: calculateReward is monotone non-decreasing in every argument.
    function testFuzz_calculateReward_monotone(uint256 amount, uint256 apy, uint256 period, uint256 delta) public {
        amount = bound(amount, 0, 1e30);
        apy = bound(apy, 1, 1e6);
        period = bound(period, 0, 36_500);
        delta = bound(delta, 1, 1e6);
        uint256 base = staking.calculateReward(amount, apy, period);
        assertGe(staking.calculateReward(amount + delta, apy, period), base, "not monotone in amount");
        assertGe(staking.calculateReward(amount, apy + delta, period), base, "not monotone in apy");
        assertGe(staking.calculateReward(amount, apy, period + delta), base, "not monotone in period");
    }

    /// @dev Hypothesis: after removing a period, `getProgramData` and `getPhasePeriodDataAll` still index correctly.
    function test_viewsAfterRemoval_consistentIndexing() public {
        _stake(alice, 0, P90, 1_000 * ONE);
        staking.removeStakingPeriod(P30);
        (, uint256[] memory periods,, uint256[][] memory apys, uint256[][] memory staked) = staking.getProgramData();
        assertEq(periods.length, 2);
        assertEq(periods[1], P90);
        assertEq(apys[0][1], APY_PHASE0[2]);
        assertEq(staked[0][1], 1_000 * ONE);
        uint256[][] memory all = _lens(staking).getPhasePeriodDataAll(Types.PhasePeriodDataType.STAKED);
        assertEq(all[0][1], 1_000 * ONE);
        assertEq(all.length, 2);
    }
}
