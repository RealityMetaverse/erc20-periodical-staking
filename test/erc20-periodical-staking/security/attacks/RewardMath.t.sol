// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";

/// @title RewardMath
/// @notice Rounding must always favour the contract, splitting/churning must never extract extra reward,
///         day-boundary timing must not be gameable, and extreme parameters must fail loudly not silently.
contract RewardMathTest is AttackBase {
    /// @dev Fuzz: splitting one deposit into n smaller ones never yields more reward than the single deposit.
    function testFuzz_splitting_neverExtractsMore(uint256 amount, uint256 n) public {
        amount = bound(amount, 1_000, 50_000 * ONE);
        n = bound(n, 1, 20);
        staking.setMiniumumDeposit(1);
        uint256 single = staking.calculateReward(amount, _apy(0, P30), P30);
        uint256 each = amount / n;
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            uint256 a = (i == n - 1) ? amount - each * (n - 1) : each;
            if (a == 0) continue;
            uint256 d = _stake(alice, 0, P30, a);
            sum += _deposit(alice, d).rewardGenerated;
        }
        assertLe(sum, single, "splitting extracted extra reward");
        assertEq(_user(Types.DataType.REWARD_EXPECTED, alice), sum);
    }

    /// @dev Hypothesis: claiming right before / after a day rollover pays for a partial day.
    function test_indefinite_dayBoundary_exact() public {
        uint256 amt = 10_000 * ONE;
        uint256 d = _stake(alice, 0, P0, amt);
        vm.warp(_now() + 1 days - 1);
        assertEq(_deposit(alice, d).rewardGenerated, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, d));
        staking.claimDeposit(d);
        vm.warp(_now() + 1);
        assertEq(_deposit(alice, d).rewardGenerated, staking.calculateReward(amt, APY_PHASE0[0], 1));
        _claim(alice, d);
        assertEq(_deposit(alice, d).rewardGenerated, 0);
        // one second later still nothing new
        vm.warp(_now() + 1);
        assertEq(_deposit(alice, d).rewardGenerated, 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: withdraw+restake churn around the day boundary extracts more than holding.
    function test_indefinite_churn_neverBeatsHolding() public {
        uint256 amt = 10_000 * ONE;
        uint256 apy = APY_PHASE0[0];
        uint256 start = _now();
        uint256 before = token.balanceOf(alice);
        // churner: withdraws and restakes every 23 hours (never completing a day) for 11 cycles
        uint256 d = _stake(alice, 0, P0, amt);
        for (uint256 i = 0; i < 11; i++) {
            vm.warp(_now() + 23 hours);
            _withdraw(alice, d);
            d = _stake(alice, 0, P0, amt);
        }
        vm.warp(start + 12 days); // last leg = 12*24h - 11*23h = 35h => exactly 1 full day
        _withdraw(alice, d);
        uint256 churnerGain = token.balanceOf(alice) - before;
        uint256 holderGain = staking.calculateReward(amt, apy, 12);
        assertLe(churnerGain, holderGain, "churning must not beat holding");
        assertEq(churnerGain, staking.calculateReward(amt, apy, 1), "churner only earns the last full day");
        _assertAccounting();
    }

    /// @dev Hypothesis: claiming every day yields more than claiming once (compounding via rounding).
    function test_indefinite_dailyClaims_equalSingleClaim() public {
        uint256 amt = 12_345 * ONE + 6789;
        uint256 apy = APY_PHASE0[0];
        uint256 dA = _stake(alice, 0, P0, amt);
        uint256 dB = _stake(bob, 0, P0, amt);
        for (uint256 i = 0; i < 30; i++) {
            _warpDays(1);
            _claim(alice, dA);
        }
        _claim(bob, dB);
        assertEq(_user(Types.DataType.CLAIM, alice), _user(Types.DataType.CLAIM, bob), "daily claims != single claim");
        assertEq(_user(Types.DataType.CLAIM, bob), staking.calculateReward(amt, apy, 30));
        _assertAccounting();
    }

    /// @dev Hypothesis: a periodical reward keeps growing after maturity if the user waits.
    function test_periodical_rewardFrozenAtStake() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        _warpDays(400);
        assertEq(_deposit(alice, d).rewardGenerated, reward);
        uint256 before = token.balanceOf(alice);
        _claim(alice, d);
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + reward);
    }

    /// @dev Hypothesis: extreme APY on a periodical cell lets a user commit more reward than the pool holds.
    ///      The stake is accepted (there is no stake-time pool check). The owner can no longer collect anything,
    ///      the matured claim reverts NotEnoughFundsInRewardPool until a top-up, then pays in full.
    function test_extremeAPY_periodical_acceptedButClaimWaitsForTopUp() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 1e18);
        uint256 reward = staking.calculateReward(1_000 * ONE, 1e18, P30);
        uint256 pool = staking.rewardPool();
        assertGt(reward, pool);
        vm.prank(alice);
        staking.safeStake(0, P30, 1_000 * ONE, 1e18);
        assertEq(_total(Types.DataType.REWARD_EXPECTED), reward);
        assertEq(staking.getCollectableReward(), 0, "owner cannot collect promised reward");
        assertGe(staking.getRewardPoolShortfall(), reward - pool, "shortfall includes the deficit");
        _assertAccounting();

        _warpDays(31);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward, pool));
        staking.claimDeposit(0);

        deal(address(token), owner, reward);
        staking.provideReward(reward - pool);
        uint256 before = token.balanceOf(alice);
        _claim(alice, 0);
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + reward, "principal + full reward after top-up");
        assertEq(staking.rewardPool(), 0);
    }

    /// @dev Hypothesis: extreme APY on the indefinite cell + a short pool locks the principal.
    ///      The full withdraw refuses with a typed error (it will not silently forfeit the unpayable reward),
    ///      but an indefinite depositor must always be able to recover principal through the opt-in partial
    ///      withdraw with a zero reward floor, regardless of reward pool state.
    function test_indefinite_principalRecoverable_whenPoolCannotPayReward() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P0, 1e18);
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        _warpDays(1);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        uint256 pool = staking.rewardPool(); // no periodical deposit is open, so the whole pool is free
        assertGt(reward, pool, "precondition: pool cannot pay");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward, pool));
        staking.withdrawDeposit(d);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.INDEFINITE));

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        (bool ok,) = address(staking).call(abi.encodeWithSignature("withdrawDepositPartial(uint256,uint256)", d, 0));
        assertTrue(ok, "indefinite principal locked behind unpayable reward");
        assertGe(token.balanceOf(alice) - before, 1_000 * ONE);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
    }

    /// @dev Hypothesis: calculateReward near uint256 max silently wraps.
    function test_amountNearUintMax_reverts_realisticNoRevert() public {
        vm.expectRevert();
        staking.calculateReward(type(uint256).max, 5, 30);
        vm.expectRevert();
        staking.calculateReward(type(uint256).max / 2, 5, 30);
        // The largest amount that fits for (APY 5, 30 days): amount * X where X = (1e18*5/365)*30
        uint256 x = (uint256(1e18) * 5 / 365) * 30;
        uint256 maxAmount = type(uint256).max / x;
        staking.calculateReward(maxAmount, 5, 30);
        vm.expectRevert();
        staking.calculateReward(maxAmount + 1, 5, 30);
    }

    /// @dev Fuzz: the reward never rounds up relative to the exact rational amount*apy*period/36500.
    function testFuzz_rewardNeverRoundsUp(uint256 amount, uint256 apy, uint256 period) public {
        amount = bound(amount, 0, 1e32);
        apy = bound(apy, 1, 1e9);
        period = bound(period, 0, 100_000);
        uint256 r = staking.calculateReward(amount, apy, period);
        assertLe(r, (amount * apy * period) / 36_500);
    }

    /// @dev Fuzz: an indefinite deposit's accrued reward over d days equals calculateReward(amount, apy, d) exactly,
    ///      regardless of how the claims are spread out.
    function testFuzz_indefinite_spreadClaims_exactTotal(uint256 amount, uint256 seed) public {
        amount = bound(amount, 100, 100_000 * ONE);
        uint256 d = _stake(alice, 0, P0, amount);
        uint256 totalDays;
        for (uint256 i = 0; i < 8; i++) {
            uint256 dd = (uint256(keccak256(abi.encode(seed, i))) % 10) + 1;
            uint256 secs = uint256(keccak256(abi.encode(seed, i, "s"))) % 86_400;
            totalDays += dd;
            vm.warp(_now() + dd * 1 days);
            uint256 t = _now();
            vm.warp(t + secs); // intra-day jitter
            if (_deposit(alice, d).rewardGenerated > 0) _claim(alice, d);
            vm.warp(t); // roll jitter back so day accounting stays exact for the next step
        }
        assertEq(_user(Types.DataType.CLAIM, alice), staking.calculateReward(amount, APY_PHASE0[0], totalDays));
        _assertAccounting();
    }

    /// @dev Hypothesis: a stake at the very edge of the target (target - staked == amount) is accepted, +1 wei rejected.
    function test_targetBoundary_exact() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P0, 5_000 * ONE);
        _stake(alice, 0, P0, 3_000 * ONE);
        uint256 h1 = _apy(0, P0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P0, 5_000 * ONE));
        staking.safeStake(0, P0, 2_000 * ONE + 1, h1);
        _stake(bob, 0, P0, 2_000 * ONE);
        assertEq(_staked(0, P0), 5_000 * ONE);
    }
}
