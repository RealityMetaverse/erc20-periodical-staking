// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";

/// @title AccountingConsistency
/// @notice Every sequence of {stake, early withdraw, mature claim, indefinite partial claim, indefinite withdraw}
///         must leave the contract with: balance == totalStaked + rewardPool, per-user sums == totals,
///         per-cell sums == totals, REWARD_EXPECTED == open periodical rewards. (`rewardPool >= REWARD_EXPECTED`
///         is not an invariant: stakes are never blocked by the pool, so it is only asserted in the scenarios
///         where the pool was funded beforehand.)
contract AccountingConsistencyTest is AttackBase {
    /// @dev Hypothesis: a single periodical deposit that matures and is claimed leaves no residue.
    function test_periodical_stakeThenMatureClaim() public {
        uint256 amt = 1_000 * ONE;
        uint256 n = _stake(alice, 0, P30, amt);
        _assertAccounting();
        uint256 reward = _deposit(alice, n).rewardGenerated;
        assertEq(reward, staking.calculateReward(amt, APY_PHASE0[1], P30));

        _warpDays(30);
        uint256 before = token.balanceOf(alice);
        _claim(alice, n);
        assertEq(token.balanceOf(alice) - before, amt + reward, "payout != principal + reward");
        _assertAccounting();
        assertEq(_user(Types.DataType.REWARD_EXPECTED, alice), 0);
        assertEq(_user(Types.DataType.STAKING, alice), 0);
    }

    /// @dev Hypothesis: an early withdrawal releases the earmarked reward and pays no reward.
    function test_periodical_earlyWithdraw_releasesEarmark() public {
        uint256 amt = 5_000 * ONE;
        uint256 poolBefore = staking.rewardPool();
        uint256 n = _stake(alice, 0, P90, amt);
        _warpDays(10);
        uint256 before = token.balanceOf(alice);
        _withdraw(alice, n);
        assertEq(token.balanceOf(alice) - before, amt, "early withdraw must pay exactly principal");
        assertEq(staking.rewardPool(), poolBefore, "rewardPool must be untouched by early withdraw");
        assertEq(_total(Types.DataType.REWARD_EXPECTED), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: partial indefinite claims followed by a withdraw pay exactly calculateReward(totalDays).
    function test_indefinite_partialClaims_thenWithdraw_exactTotal() public {
        uint256 amt = 10_000 * ONE;
        uint256 n = _stake(alice, 0, P0, amt);
        uint256 apy = APY_PHASE0[0];
        uint256 paid;
        uint256 before = token.balanceOf(alice);

        _warpDays(3);
        _claim(alice, n);
        _assertAccounting();
        _warpDays(7);
        _claim(alice, n);
        _assertAccounting();
        _warpDays(1);
        _withdraw(alice, n);
        _assertAccounting();

        paid = token.balanceOf(alice) - before;
        assertEq(paid, amt + staking.calculateReward(amt, apy, 11), "total paid != principal + reward(11 days)");
        assertEq(_user(Types.DataType.CLAIM, alice), staking.calculateReward(amt, apy, 11));
    }

    /// @dev Hypothesis: mixed deposits from several users across two phases close cleanly in any order.
    function test_multiUser_multiPhase_mixedClosing() public {
        uint256 a0 = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 b0 = _stake(bob, 0, P90, 2_000 * ONE);
        uint256 c0 = _stake(carol, 0, P0, 3_000 * ONE);
        _assertAccounting();

        staking.changeStakingPhase(1);
        uint256 a1 = _stake(alice, 1, P30, 500 * ONE);
        uint256 d1 = _stake(dave, 1, P0, 700 * ONE);
        _assertAccounting();

        _warpDays(31);
        _claim(alice, a0); // matured
        _assertAccounting();
        _claim(alice, a1); // matured
        _assertAccounting();
        _withdraw(bob, b0); // early
        _assertAccounting();
        _claim(carol, c0); // partial indefinite
        _assertAccounting();
        _withdraw(dave, d1); // indefinite withdraw
        _assertAccounting();
        _warpDays(100);
        _withdraw(carol, c0);
        _assertAccounting();

        assertEq(_total(Types.DataType.STAKING), 0, "everything closed => nothing staked");
        assertEq(_total(Types.DataType.REWARD_EXPECTED), 0);
    }

    /// @dev Hypothesis: switching the phase back and forth never breaks closing of old-phase deposits.
    function test_phaseSwitching_backAndForth_oldDepositsStillClose() public {
        uint256 a = _stake(alice, 0, P30, 1_000 * ONE);
        staking.changeStakingPhase(1);
        uint256 b = _stake(bob, 1, P30, 1_000 * ONE);
        staking.changeStakingPhase(0);
        uint256 c = _stake(carol, 0, P90, 1_000 * ONE);
        staking.changeStakingPhase(1);
        _assertAccounting();

        _warpDays(30);
        _claim(alice, a);
        _claim(bob, b);
        _withdraw(carol, c);
        _assertAccounting();
        assertEq(_deposit(alice, a).stakingPhase, 0);
        assertEq(_deposit(bob, b).stakingPhase, 1);
    }

    /// @dev removing a period with live deposits must leave accounting intact and deposits closable.
    function test_removePeriod_liveDeposits_accountingIntact() public {
        uint256 a = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 b = _stake(bob, 0, P30, 2_000 * ONE);
        uint256 c = _stake(carol, 0, P90, 1_000 * ONE);
        _assertAccounting();

        staking.removeStakingPeriod(P30);
        // configuration cells cleared
        assertEq(_apy(0, P30), 0);
        assertEq(_target(0, P30), 0);
        // accounting cells intact
        assertEq(_staked(0, P30), 3_000 * ONE, "STAKED must survive period removal");
        assertEq(_upp(Types.DataType.STAKING, alice, 0, P30), 1_000 * ONE);
        _assertAccounting();

        _warpDays(30);
        _claim(alice, a);
        _claim(bob, b);
        _assertAccounting();
        _warpDays(60);
        _claim(carol, c);
        _assertAccounting();
    }

    /// @dev Bob path: a READY_TO_CLAIM deposit in a removed period is claimed, not withdrawn.
    function test_removePeriod_matureClaimAndEarlyWithdraw() public {
        uint256 a = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 b = _stake(bob, 0, P30, 2_000 * ONE);
        staking.removeStakingPeriod(P30);
        _withdraw(bob, b); // early withdraw on removed period
        _assertAccounting();
        _warpDays(30);
        _claim(alice, a); // mature claim on removed period
        _assertAccounting();
        assertEq(_staked(0, P30), 0);
    }

    /// @dev popping a phase with live deposits must leave accounting intact and deposits closable.
    function test_popPhase_liveDeposits_accountingIntact() public {
        staking.changeStakingPhase(1);
        uint256 a = _stake(alice, 1, P30, 1_000 * ONE);
        uint256 b = _stake(bob, 1, P0, 2_000 * ONE);
        _assertAccounting();

        staking.popStakingPhase();
        assertEq(staking.stakingPhaseCount(), 1);
        assertEq(staking.currentStakingPhase(), 0);
        assertEq(_staked(1, P30), 1_000 * ONE, "STAKED must survive phase pop");
        _assertAccounting();

        _warpDays(30);
        _claim(alice, a);
        _claim(bob, b);
        _withdraw(bob, b);
        _assertAccounting();
    }

    /// @dev after removal and re-add with a different target, previously staked tokens count toward the new target.
    function test_readdPeriod_existingStakedCountsTowardTarget() public {
        _stake(alice, 0, P30, 10_000 * ONE);
        staking.removeStakingPeriod(P30);
        uint256[] memory apys = new uint256[](2);
        apys[0] = 50;
        apys[1] = 60;
        uint256[] memory targets = new uint256[](2);
        targets[0] = 12_000 * ONE;
        targets[1] = 12_000 * ONE;
        staking.addStakingPeriod(P30, apys, targets);
        _trackPeriod(P30);

        assertEq(_staked(0, P30), 10_000 * ONE);
        // Only 2_000 left under the new target
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P30, 12_000 * ONE));
        staking.safeStake(0, P30, 2_001 * ONE, 50);
        _stake(bob, 0, P30, 2_000 * ONE);
        _assertAccounting();
        // old deposit keeps its APY
        assertEq(_deposit(alice, 0).APY, APY_PHASE0[1]);
    }

    /// @dev the owner cannot collect rewards that are earmarked for open periodical deposits.
    function test_collectReward_cannotBreakSolvency() public {
        _stake(alice, 0, P90, 100_000 * ONE);
        uint256 expected = _total(Types.DataType.REWARD_EXPECTED);
        uint256 pool = staking.rewardPool();
        assertGt(expected, 0);

        // Collecting everything above the earmark is fine
        staking.collectReward(pool - expected);
        assertEq(staking.rewardPool(), expected);
        _assertAccounting();

        // One more wei must fail
        vm.expectRevert();
        staking.collectReward(1);
        _assertAccounting();

        _warpDays(90);
        _claim(alice, 0);
        _assertAccounting();
    }

    /// @dev Indefinite rewards are not reserved; when the pool is empty the indefinite claim reverts
    ///      NoRewardToClaim, a partial refill pays exactly the collectable part, the full withdraw refuses to
    ///      forfeit the remainder, and principal is always recoverable through the opt-in partial withdraw.
    ///      Accounting stays consistent throughout.
    function test_indefinite_poolShort_partialPayAccountingIntact() public {
        _stake(alice, 0, P0, 100_000 * ONE);
        staking.collectReward(staking.rewardPool());
        _warpDays(365);
        uint256 reward = _deposit(alice, 0).rewardGenerated;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, 0));
        staking.claimDeposit(0);
        _assertAccounting();

        // partial refill: claim pays the whole free pool, remainder keeps accruing
        staking.provideReward(reward / 3);
        _claim(alice, 0);
        assertEq(staking.rewardPool(), 0);
        assertEq(_deposit(alice, 0).rewardGenerated, reward - reward / 3);
        _assertAccounting();

        // withdraw with an empty pool: the full withdraw refuses (deposit stays open), the partial one with a
        // zero floor pays principal only
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward - reward / 3, 0));
        staking.withdrawDeposit(0);
        _assertAccounting();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdrawDepositPartial(0, 0);
        assertEq(token.balanceOf(alice), before + 100_000 * ONE);
        _assertAccounting();
        assertEq(staking.rewardPool(), 0);
    }

    /// @dev Indefinite withdraw with a partially funded pool: the full withdraw reverts rather than touching
    ///      the reserve, and the partial withdraw pays min(accrued, collectable) and never the reserve.
    function test_indefinite_withdraw_paysCollectableOnly_reserveIntact() public {
        staking.collectReward(staking.rewardPool());
        uint256 bobReward = staking.calculateReward(1_000 * ONE, _apy(0, P90), P90);
        staking.provideReward(bobReward + 3);
        uint256 b = _stake(bob, 0, P90, 1_000 * ONE);
        uint256 a = _stake(alice, 0, P0, 100_000 * ONE);
        assertEq(staking.getCollectableReward(), 3);
        _warpDays(10);
        uint256 accrued = _deposit(alice, a).rewardGenerated;
        assertGt(accrued, 3);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 3));
        staking.withdrawDeposit(a);
        assertEq(staking.rewardPool(), bobReward + 3, "nothing moved");

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdrawDepositPartial(a, 3);
        assertEq(token.balanceOf(alice), before + 100_000 * ONE + 3);
        assertEq(staking.rewardPool(), bobReward, "reserve intact");
        _assertAccounting();

        _warpDays(80);
        _claim(bob, b);
        assertEq(staking.rewardPool(), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: hundreds of dust deposits never create rounding residue in the token conservation identity.
    function test_dustDeposits_conservationExact() public {
        staking.setMiniumumDeposit(1);
        for (uint256 i = 0; i < 50; i++) {
            _stake(alice, 0, P30, 3 + i); // tiny amounts => reward rounds to 0
            _stake(bob, 0, P0, 7 + i);
        }
        _assertAccounting();
        _warpDays(31);
        _claimAll(alice);
        _claimAll(bob);
        _assertAccounting();
        for (uint256 i = 0; i < 50; i++) {
            _withdraw(bob, i);
        }
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // Seeded random action sequence — invariant re-checked after every step
    // ---------------------------------------------------------------------
    /// @dev Hypothesis: no sequence of user + admin actions breaks the accounting identities.
    function testFuzz_randomActionSequence(uint256 seed) public {
        uint256 steps = 40;
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address u = users[r % users.length];
            uint256 action = (r >> 8) % 8;
            uint256 phase = staking.currentStakingPhase();

            if (action == 0 || action == 1) {
                uint256 period = PERIODS[(r >> 16) % PERIODS.length];
                if (!staking.checkIfStakingPeriodExists(period)) continue;
                uint256 amount = bound((r >> 32) % (10_000 * ONE), 100, 10_000 * ONE);
                if (token.balanceOf(u) < amount) continue;
                uint256 tgt = _target(phase, period);
                if (_staked(phase, period) + amount > tgt) continue;
                uint256 newReward = period == 0 ? 0 : staking.calculateReward(amount, _apy(phase, period), period);
                if (staking.rewardPool() < _total(Types.DataType.REWARD_EXPECTED) + newReward) continue;
                _stake(u, phase, period, amount);
            } else if (action == 2) {
                uint256 n = staking.checkDepositCountOfAddress(u);
                if (n == 0) continue;
                uint256 d = (r >> 40) % n;
                ProgramManager.DepositStatus st = _status(u, d);
                if (
                    st == ProgramManager.DepositStatus.TIME_LEFT
                        || (
                            st == ProgramManager.DepositStatus.INDEFINITE
                                && staking.rewardPool() >= _deposit(u, d).rewardGenerated
                        )
                ) {
                    _withdraw(u, d);
                }
            } else if (action == 3) {
                uint256 n = staking.checkDepositCountOfAddress(u);
                if (n == 0) continue;
                uint256 d = (r >> 40) % n;
                ProgramManager.DepositStatus st = _status(u, d);
                if (st == ProgramManager.DepositStatus.READY_TO_CLAIM) {
                    _claim(u, d);
                } else if (st == ProgramManager.DepositStatus.INDEFINITE) {
                    uint256 rew = _deposit(u, d).rewardGenerated;
                    if (rew > 0 && staking.rewardPool() >= rew) _claim(u, d);
                }
            } else if (action == 4) {
                _claimAll(u);
            } else if (action == 5) {
                _warpDays(((r >> 48) % 45) + 1);
            } else if (action == 6) {
                staking.changeStakingPhase((r >> 56) % staking.stakingPhaseCount());
            } else {
                // owner collects whatever is not earmarked or tops up
                if ((r >> 64) % 2 == 0) {
                    uint256 free = staking.rewardPool() - _total(Types.DataType.REWARD_EXPECTED);
                    if (free > 1) staking.collectReward(free / 2);
                } else {
                    staking.provideReward(1_000 * ONE);
                }
            }
            _assertAccounting();
        }
    }
}
