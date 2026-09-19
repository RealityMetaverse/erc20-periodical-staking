// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice v0.4.0 APYs in basis points (x.yz%) and the voucher extra-APY / extra-limit caps.
contract ApyBpsTest is V050Base {
    uint256 internal constant REF_DENOMINATOR = 10_000 * 365;

    /// @dev Exact floor(amount * apyBps * days / 3_650_000) computed independently of mulDiv:
    ///      amount = q*D + r  =>  amount*rate/D = q*rate + floor(r*rate/D). Exact while q*rate fits in 256 bits.
    function _ref(uint256 amount, uint256 apyBps, uint256 daysCount) internal pure returns (uint256) {
        uint256 rate = apyBps * daysCount;
        return (amount / REF_DENOMINATOR) * rate + ((amount % REF_DENOMINATOR) * rate) / REF_DENOMINATOR;
    }

    function _pickPeriod(uint256 seed) internal pure returns (uint256) {
        return seed % 2 == 0 ? P30 : P90;
    }

    // ======================================
    // =        Base APY in bps (x.yz%)      =
    // ======================================
    function test_baseApy_fractionalBps_setAndRead() external {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 225);

        assertEq(_baseApy(0, P30), 225, "phasePeriodDataList");
        assertEq(staking.getPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30), 225, "getPhasePeriodData");
        (,,, uint256[][] memory apys,) = staking.getProgramData();
        assertEq(apys[0][1], 225, "getProgramData apysBps[0][P30]");
        assertEq(apys[0][0], APY_P0, "other cells untouched");
        assertEq(apys[1][1], APY_P30 + PHASE1_APY_BONUS, "phase 1 untouched");

        uint256 amount = 1_000 * ONE;
        uint256 n = stakeFor(alice, P30, amount);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, 225, "deposit APY is bps");
        assertEq(d.rewardGenerated, _ref(amount, 225, P30), "reward at 2.25%");
        // 1000 * 2.25% * 30/365 = 1.849315068493150684...
        assertEq(d.rewardGenerated, 1_849_315_068_493_150_684, "hard-coded reward");
    }

    function test_calculateReward_knownValues() external {
        assertEq(staking.calculateReward(1_000 * ONE, 225, 365), 22.5e18, "2.25% for a year");
        assertEq(staking.calculateReward(1_000 * ONE, 1, 365), 0.1e18, "0.01% for a year");
        assertEq(staking.calculateReward(1_000 * ONE, 10_000, 365), 1_000 * ONE, "100% for a year");
        assertEq(staking.calculateReward(1_000 * ONE, 225, 0), 0, "zero days");
        assertEq(staking.calculateReward(0, 225, 365), 0, "zero amount");
        // Single truncation at the end: 3_649_999 * 1 * 1 / 3_650_000 floors to 0, 3_650_000 gives exactly 1.
        assertEq(staking.calculateReward(3_649_999, 1, 1), 0);
        assertEq(staking.calculateReward(3_650_000, 1, 1), 1);
    }

    function test_setPhasePeriodData_rejectsZeroApy() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAPY.selector, 0, 1));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 0);
    }

    // ======================================
    // =            Reward math             =
    // ======================================
    function testFuzz_calculateReward_matchesExactReference(uint256 amount, uint256 apyBps, uint256 daysCount)
        external
    {
        amount = bound(amount, 0, type(uint128).max);
        apyBps = bound(apyBps, 0, type(uint32).max);
        daysCount = bound(daysCount, 0, type(uint32).max);
        uint256 got = staking.calculateReward(amount, apyBps, daysCount);
        assertEq(got, _ref(amount, apyBps, daysCount), "exact floor");
    }

    function testFuzz_calculateReward_monotonicInDays(uint256 amount, uint256 apyBps, uint256 d1, uint256 d2)
        external
    {
        amount = bound(amount, 0, type(uint128).max);
        apyBps = bound(apyBps, 1, type(uint32).max);
        d1 = bound(d1, 0, type(uint32).max);
        d2 = bound(d2, d1, type(uint32).max);
        uint256 r1 = staking.calculateReward(amount, apyBps, d1);
        uint256 r2 = staking.calculateReward(amount, apyBps, d2);
        assertLe(r1, r2);
        // Splitting the period never gains more than 1 wei of truncation versus computing it in one go.
        uint256 split = r1 + staking.calculateReward(amount, apyBps, d2 - d1);
        assertLe(split, r2);
        assertLe(r2 - split, 1);
    }

    function test_calculateReward_noOverflowAtMaxValues() external {
        uint256 maxAmount = type(uint128).max;
        uint256 maxApy = type(uint32).max;
        uint256 maxDays = type(uint32).max;
        assertEq(staking.calculateReward(maxAmount, maxApy, maxDays), _ref(maxAmount, maxApy, maxDays));
        // amount * rate overflows 256 bits here; mulDiv is 512-bit and still exact.
        assertEq(staking.calculateReward(type(uint256).max, 10_000, 365), type(uint256).max, "100% of max");
        assertEq(
            staking.calculateReward(type(uint256).max, 5_000, 365), type(uint256).max / 2, "50% of max floors"
        );
    }

    function testFuzz_periodicalDeposit_rewardAndEffectiveApy(
        uint256 amount,
        uint256 baseApyBps,
        uint256 extraApyBps,
        uint256 periodSeed
    ) external {
        uint256 period = _pickPeriod(periodSeed);
        amount = bound(amount, staking.minimumDeposit(), DEFAULT_LIMIT);
        baseApyBps = bound(baseApyBps, 1, 50_000);
        extraApyBps = bound(extraApyBps, 0, MAX_EXTRA_APY_BPS);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, period, baseApyBps);

        uint256 effective = baseApyBps + extraApyBps;
        uint256 expectedReward = _ref(amount, effective, period);

        uint256 n = stakeWith(alice, period, amount, extraApyBps, 0);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, effective, "effective apy stored");
        assertEq(d.rewardGenerated, expectedReward, "reward");
        assertEq(staking.getUserData(Types.DataType.REWARD_EXPECTED, alice), expectedReward, "user reserved");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), expectedReward, "total reserved");

        _warpDays(period);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimDeposit(n);
        assertEq(token.balanceOf(alice) - before, amount + expectedReward, "claim payout");
        assertEq(staking.rewardPool(), POOL - expectedReward, "pool debited");
    }

    function testFuzz_indefiniteDeposit_rewardAccrualInBps(
        uint256 amount,
        uint256 baseApyBps,
        uint256 extraApyBps,
        uint256 daysPassed,
        uint256 extraSeconds
    ) external {
        amount = bound(amount, staking.minimumDeposit(), DEFAULT_LIMIT);
        baseApyBps = bound(baseApyBps, 1, 5_000);
        extraApyBps = bound(extraApyBps, 0, MAX_EXTRA_APY_BPS);
        daysPassed = bound(daysPassed, 0, 1_825);
        extraSeconds = bound(extraSeconds, 0, 1 days - 1);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P0, baseApyBps);
        uint256 effective = baseApyBps + extraApyBps;

        uint256 n = stakeWith(alice, P0, amount, extraApyBps, 0);
        assertEq(_deposit(alice, n).APY, effective, "effective apy stored");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0, "indefinite reserves nothing");

        vm.warp(_now() + daysPassed * 1 days + extraSeconds);
        uint256 expected = _ref(amount, effective, daysPassed); // partial days do not accrue
        assertEq(_deposit(alice, n).rewardGenerated, expected, "live accrued reward");

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        if (expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, n));
            staking.claimDeposit(n);
            return;
        }
        staking.claimDeposit(n);
        assertEq(token.balanceOf(alice) - before, expected, "claim pays accrued");

        // A later claim pays only the increment accrued since, computed on the total.
        _warpDays(30);
        uint256 total = _ref(amount, effective, daysPassed + 30);
        assertEq(_deposit(alice, n).rewardGenerated, total - expected, "incremental accrual");
    }

    function test_realisticMaxValues_stakeAndClaimWithoutOverflow() external {
        uint256 amount = 1e33; // far beyond any real supply, still < 2^128
        uint256 baseApyBps = type(uint32).max - MAX_EXTRA_APY_BPS;
        _openCell(P90, baseApyBps);
        deal(address(token), alice, amount);
        uint256 expectedReward = _ref(amount, type(uint32).max, P90);
        _fundPool(expectedReward);

        uint256 n = stakeWith(alice, P90, amount, MAX_EXTRA_APY_BPS, 0);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, type(uint32).max, "apy at uint32 max");
        assertEq(d.amount, amount);
        assertEq(d.rewardGenerated, expectedReward);

        _warpDays(P90);
        vm.prank(alice);
        staking.claimDeposit(n);
        assertEq(token.balanceOf(alice), amount + expectedReward, "paid in full");
    }

    function test_realisticMaxValues_indefiniteHundredYears() external {
        uint256 amount = 1e33;
        _openCell(P0, 100_000); // 1000%
        deal(address(token), alice, amount);
        uint256 n = stakeFor(alice, P0, amount);

        _warpDays(36_500);
        assertEq(_deposit(alice, n).rewardGenerated, _ref(amount, 100_000, 36_500), "accrued over 100 years");
    }

    function test_effectiveApyAboveUint32_revertsSafeCast() external {
        _openCell(P30, type(uint32).max);
        Types.StakeVoucher memory v = voucherFor(alice, P30, 1, 0);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, uint256(type(uint32).max) + 1)
        );
        staking.stakeWithVoucher(v, sig, ONE, 0);
    }

    function test_amountAboveUint128_revertsSafeCast() external {
        uint256 amount = uint256(type(uint128).max) + 1;
        _openCell(P30, APY_P30);
        deal(address(token), alice, amount);
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, amount));
        staking.stakeWithVoucher(v, sig, amount, 0);
    }

    // ======================================
    // =   Effective APY and the Stake event =
    // ======================================
    function testFuzz_stakeEvent_carriesEffectiveAndExtraApy(uint256 extraApyBps, uint256 amount) external {
        extraApyBps = bound(extraApyBps, 0, MAX_EXTRA_APY_BPS);
        amount = bound(amount, staking.minimumDeposit(), DEFAULT_LIMIT - ONE);
        stakeFor(alice, P90, ONE); // depositNumber 0, nonce 0

        Types.StakeVoucher memory v = voucherFor(alice, P90, extraApyBps, 0);
        bytes memory sig = signVoucher(v);
        uint256 effective = APY_P90 + extraApyBps;
        assertEq(v.nonce, 1);

        vm.expectEmit(true, true, true, true, address(staking));
        emit Stake(alice, 0, P90, effective, extraApyBps, amount, 1, 1);
        vm.prank(alice);
        uint256 n = staking.stakeWithVoucher(v, sig, amount, effective);

        assertEq(n, 1);
        assertEq(_deposit(alice, n).APY, effective, "stored = event");
    }

    function testFuzz_expectedApy_isAFloor(uint256 extraApyBps, uint256 expected) external {
        extraApyBps = bound(extraApyBps, 0, MAX_EXTRA_APY_BPS);
        uint256 effective = APY_P30 + extraApyBps;

        expected = bound(expected, 0, effective);
        Types.StakeVoucher memory v = voucherFor(alice, P30, extraApyBps, 0);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        uint256 n = staking.stakeWithVoucher(v, sig, ONE, expected);
        assertEq(_deposit(alice, n).APY, effective, "lower/equal expectation accepted");

        v = voucherFor(alice, P30, extraApyBps, 0);
        sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, P30, effective, effective + 1)
        );
        staking.stakeWithVoucher(v, sig, ONE, effective + 1);
    }

    // ======================================
    // =          Extra APY cap             =
    // ======================================
    function test_extraApy_equalToMax_passes() external {
        uint256 n = stakeWith(alice, P30, 1_000 * ONE, MAX_EXTRA_APY_BPS, 0);
        assertEq(_deposit(alice, n).APY, APY_P30 + MAX_EXTRA_APY_BPS);
    }

    function testFuzz_extraApy_aboveMax_reverts(uint256 extraApyBps) external {
        extraApyBps = bound(extraApyBps, MAX_EXTRA_APY_BPS + 1, type(uint256).max);
        Types.StakeVoucher memory v = voucherFor(alice, P30, extraApyBps, 0);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.VoucherExtraApyTooHigh.selector, extraApyBps, MAX_EXTRA_APY_BPS)
        );
        staking.stakeWithVoucher(v, sig, ONE, 0);
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce), "nonce not burnt");
    }

    function test_extraApy_capChangeAppliesToNextStake() external {
        staking.setMaxExtraApyBps(0);
        assertEq(staking.maxExtraApyBps(), 0);

        Types.StakeVoucher memory v = voucherFor(alice, P30, 1, 0);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherExtraApyTooHigh.selector, 1, 0));
        staking.stakeWithVoucher(v, sig, ONE, 0);

        // Zero extra still works with a zero cap.
        uint256 n = stakeFor(alice, P30, ONE);
        assertEq(_deposit(alice, n).APY, APY_P30);

        staking.setMaxExtraApyBps(1);
        vm.prank(alice);
        n = staking.stakeWithVoucher(v, sig, ONE, APY_P30 + 1); // the same signed voucher is now within the cap
        assertEq(_deposit(alice, n).APY, APY_P30 + 1);
    }

    function test_setMaxExtraApyBps_onlyOwnerAndUint32() external {
        vm.expectEmit(true, true, true, true, address(staking));
        emit UpdateMaxExtraApyBps(125);
        staking.setMaxExtraApyBps(125);
        assertEq(staking.maxExtraApyBps(), 125);

        uint256 tooBig = uint256(type(uint32).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, tooBig));
        staking.setMaxExtraApyBps(tooBig);

        vm.prank(admin);
        vm.expectRevert();
        staking.setMaxExtraApyBps(1);
        assertEq(staking.maxExtraApyBps(), 125, "unchanged");
    }

    // ======================================
    // =         Extra limit cap            =
    // ======================================
    function test_extraLimit_equalToMax_passesAndAddsHeadroom() external {
        uint256 amount = DEFAULT_LIMIT + MAX_EXTRA_LIMIT_TOTAL;
        uint256 n = stakeWith(alice, P30, amount, 0, MAX_EXTRA_LIMIT_TOTAL);
        assertEq(_deposit(alice, n).amount, amount);
        assertEq(_cell(alice, 0, P30), amount);

        // The extra limit is per stake, not persistent: without enough extra there is no headroom left.
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, MAX_EXTRA_LIMIT_TOTAL);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, ONE, 0));
        staking.stakeWithVoucher(v, sig, ONE, 0);
    }

    function test_extraLimit_oneOverHeadroom_reverts() external {
        uint256 headroom = DEFAULT_LIMIT + MAX_EXTRA_LIMIT_TOTAL;
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, MAX_EXTRA_LIMIT_TOTAL);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, headroom + 1, headroom)
        );
        staking.stakeWithVoucher(v, sig, headroom + 1, 0);
    }

    function testFuzz_extraLimit_aboveMax_reverts(uint256 extraLimit) external {
        extraLimit = bound(extraLimit, MAX_EXTRA_LIMIT_TOTAL + 1, type(uint256).max);
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, extraLimit);
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.VoucherExtraLimitTotalTooHigh.selector, extraLimit, MAX_EXTRA_LIMIT_TOTAL)
        );
        staking.stakeWithVoucher(v, sig, ONE, 0);
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce), "nonce not burnt");
    }

    function test_setMaxExtraLimitTotal_uint128Bound() external {
        staking.setMaxExtraLimitTotal(type(uint128).max);
        assertEq(staking.maxExtraLimitTotal(), type(uint128).max);

        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooBig));
        staking.setMaxExtraLimitTotal(tooBig);
    }

    // ======================================
    // =  Base APY change after the stake   =
    // ======================================
    function testFuzz_baseApyChange_doesNotAffectPeriodicalDeposit(uint256 newBaseApyBps, uint256 extraApyBps)
        external
    {
        newBaseApyBps = bound(newBaseApyBps, 1, 100_000);
        extraApyBps = bound(extraApyBps, 0, MAX_EXTRA_APY_BPS);
        uint256 amount = 10_000 * ONE;
        uint256 originalEffective = APY_P30 + extraApyBps;
        uint256 originalReward = _ref(amount, originalEffective, P30);

        uint256 n = stakeWith(alice, P30, amount, extraApyBps, 0);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, newBaseApyBps);

        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, originalEffective, "apy fixed for life");
        assertEq(d.rewardGenerated, originalReward, "reward fixed for life");

        // A new stake uses the new base.
        uint256 m = stakeWith(bob, P30, amount, extraApyBps, 0);
        assertEq(_deposit(bob, m).APY, newBaseApyBps + extraApyBps, "new stake uses new base");

        _warpDays(P30);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimDeposit(n);
        assertEq(token.balanceOf(alice) - before, amount + originalReward, "claim pays the original reward");
    }

    function test_baseApyChange_doesNotAffectIndefiniteAccrual() external {
        uint256 amount = 10_000 * ONE;
        uint256 n = stakeWith(alice, P0, amount, 150, 0);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P0, 9_999);

        _warpDays(100);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, APY_P0 + 150);
        assertEq(d.rewardGenerated, _ref(amount, APY_P0 + 150, 100), "accrues at the original effective rate");

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdrawDeposit(n);
        assertEq(token.balanceOf(alice) - before, amount + _ref(amount, APY_P0 + 150, 100), "withdraw payout");
    }

    function test_maxExtraApyChange_doesNotAffectExistingDeposit() external {
        uint256 n = stakeWith(alice, P90, 1_000 * ONE, MAX_EXTRA_APY_BPS, 0);
        staking.setMaxExtraApyBps(0);
        assertEq(_deposit(alice, n).APY, APY_P90 + MAX_EXTRA_APY_BPS);
        assertEq(_deposit(alice, n).rewardGenerated, _ref(1_000 * ONE, APY_P90 + MAX_EXTRA_APY_BPS, P90));
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    /// @dev Set a phase-0 cell's base APY and lift its target and default limit so huge stakes fit.
    function _openCell(uint256 period, uint256 apyBps) internal {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, period, apyBps);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, period, type(uint256).max);
        controller.setDefaultLimit(0, period, type(uint256).max);
    }

    function _fundPool(uint256 amount) internal {
        deal(address(token), address(this), token.balanceOf(address(this)) + amount);
        staking.provideReward(amount);
    }
}
