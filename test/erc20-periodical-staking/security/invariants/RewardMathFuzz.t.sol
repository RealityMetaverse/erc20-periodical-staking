// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {stdError} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TestToken} from "../../../shared/TestToken.sol";
import {VoucherHelper} from "../../../shared/VoucherHelper.sol";
import {ERC20PeriodicalStaking} from
    "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Types} from "../../../../src/common/Types.sol";

/// @title RewardMathFuzz
/// @notice Stateless / lightly stateful fuzz tests for the reward arithmetic of ERC20PeriodicalStaking (v0.4.0, bps).
/// @dev calculateReward(a, apyBps, p) = mulDiv(a, apyBps * p, 10_000 * 365)
///
///      Overflow analysis (all uint256):
///        - a * (apyBps * p) is computed in 512 bits by mulDiv, so the amount can never overflow on its own;
///          the result overflows only when it does not fit 256 bits, i.e. when apyBps * p > 3_650_000 and
///          a is close to uint.max (MathOverflowedMulDiv).
///        - apyBps * p is a checked 256-bit product. Stored deposits have apyBps < 2^32 and p < 2^32, so it
///          is at most 2^64; indefinite accrual uses daysPassed < 2^25. Only absurd view inputs can overflow.
///      There is a single truncating division, so the result is exactly floor(a * apyBps * p / 3_650_000).
contract RewardMathFuzz is VoucherHelper {
    uint256 internal constant DENOMINATOR = 3_650_000; // 10_000 bps * 365 days
    uint256 internal constant APY_BPS = 2000; // 20%
    uint256 internal constant MAX_EXTRA_FUZZ = 5000; // keeps long accruals within the funded pool

    TestToken internal token;
    ERC20PeriodicalStaking internal staking;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    // Bounds under which the reference a * apy * p is overflow-free.
    uint256 internal constant A_MAX = 1e40; // wei
    uint256 internal constant APY_MAX = 1e5; // bps (1000%)
    uint256 internal constant P_MAX = 36_500; // days (100 years)

    function setUp() external {
        token = new TestToken(18);
        vm.prank(owner);
        staking = new ERC20PeriodicalStaking(address(token));

        // Program: period 0 (indefinite) in phase 0 at 20% APY, big target.
        uint256[] memory empty = new uint256[](0);
        vm.startPrank(owner);
        staking.addStakingPeriod(0, empty, empty);
        uint256[] memory apy = new uint256[](1);
        uint256[] memory target = new uint256[](1);
        apy[0] = APY_BPS;
        target[0] = type(uint128).max;
        staking.pushStakingPhase(apy, target);
        _enableVoucherStaking(staking);
        vm.stopPrank();

        token.transfer(user, 1_000_000e18);
        vm.prank(user);
        token.approve(address(staking), type(uint256).max);

        // Fund the pool generously (owner is an admin).
        token.transfer(owner, 8_000_000e18);
        vm.startPrank(owner);
        token.approve(address(staking), type(uint256).max);
        staking.provideReward(8_000_000e18);
        vm.stopPrank();
    }

    // ======================================
    // =        Pure reward function        =
    // ======================================

    /// @notice Reference implementation of the on-chain formula, used to spot silent formula changes.
    function _ref(uint256 a, uint256 apyBps, uint256 p) internal pure returns (uint256) {
        return a * apyBps * p / DENOMINATOR;
    }

    function testFuzz_calculateReward_matchesReference(uint256 a, uint256 apyBps, uint256 p) external {
        a = bound(a, 0, A_MAX);
        apyBps = bound(apyBps, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        assertEq(staking.calculateReward(a, apyBps, p), _ref(a, apyBps, p));
    }

    /// @notice Whole-percent and fractional-percent APYs are exact in bps.
    function test_calculateReward_bpsPrecision() external {
        assertEq(staking.calculateReward(1000e18, 225, 365), 22.5e18, "2.25% for a year");
        assertEq(staking.calculateReward(1000e18, 1, 365), 0.1e18, "0.01% for a year");
        assertEq(staking.calculateReward(1000e18, 10_000, 365), 1000e18, "100% for a year");
        assertEq(staking.calculateReward(1000e18, 2000, 73), 40e18, "20% for 73 days = 4%");
        // Dust below one unit truncates to 0 rather than rounding up.
        assertEq(staking.calculateReward(1, 9_999, 365), 0);
    }

    /// @notice For any rate up to 100% over at most a year the result never exceeds the amount, so any
    ///         uint256 amount is safe (mulDiv carries the 512-bit intermediate).
    function testFuzz_calculateReward_noOverflowForAnyAmount(uint256 a, uint256 apyBps, uint256 p) external {
        apyBps = bound(apyBps, 0, 10_000);
        p = bound(p, 0, 365);
        assertLe(staking.calculateReward(a, apyBps, p), a);
    }

    /// @notice Pins the only two overflow sources.
    function test_calculateReward_overflowBounds() external {
        // The largest amount at exactly 100% for one year is returned unchanged.
        assertEq(staking.calculateReward(type(uint256).max, 10_000, 365), type(uint256).max);

        // Result above 256 bits: mulDiv reverts.
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        staking.calculateReward(type(uint256).max, 10_000, 366);

        // Checked rate * days product.
        vm.expectRevert(stdError.arithmeticError);
        staking.calculateReward(1, type(uint256).max, 2);

        // Stored-deposit extremes (uint32 APY and period) are far from both limits for real amounts.
        uint256 r = staking.calculateReward(1e30, type(uint32).max, type(uint32).max);
        assertEq(r, Math.mulDiv(1e30, uint256(type(uint32).max) * type(uint32).max, DENOMINATOR));
    }

    /// @notice Exactly one truncation: reward = floor(a * apy * p / 3_650_000).
    function testFuzz_calculateReward_singleTruncation(uint256 a, uint256 apyBps, uint256 p) external {
        a = bound(a, 0, A_MAX);
        apyBps = bound(apyBps, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        uint256 reward = staking.calculateReward(a, apyBps, p);
        uint256 exact = a * apyBps * p;
        assertLe(reward * DENOMINATOR, exact, "reward rounds up above exact value");
        assertGt((reward + 1) * DENOMINATOR, exact, "reward lost more than one unit to rounding");
    }

    function testFuzz_calculateReward_monotoneInAmount(uint256 a1, uint256 a2, uint256 apyBps, uint256 p)
        external
    {
        a1 = bound(a1, 0, A_MAX);
        a2 = bound(a2, a1, A_MAX);
        apyBps = bound(apyBps, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        assertLe(staking.calculateReward(a1, apyBps, p), staking.calculateReward(a2, apyBps, p));
    }

    function testFuzz_calculateReward_monotoneInAPY(uint256 a, uint256 apy1, uint256 apy2, uint256 p) external {
        a = bound(a, 0, A_MAX);
        apy1 = bound(apy1, 0, APY_MAX);
        apy2 = bound(apy2, apy1, APY_MAX);
        p = bound(p, 0, P_MAX);
        assertLe(staking.calculateReward(a, apy1, p), staking.calculateReward(a, apy2, p));
    }

    function testFuzz_calculateReward_monotoneInPeriod(uint256 a, uint256 apyBps, uint256 p1, uint256 p2)
        external
    {
        a = bound(a, 0, A_MAX);
        apyBps = bound(apyBps, 0, APY_MAX);
        p1 = bound(p1, 0, P_MAX);
        p2 = bound(p2, p1, P_MAX);
        assertLe(staking.calculateReward(a, apyBps, p1), staking.calculateReward(a, apyBps, p2));
    }

    /// @notice Splitting a deposit into n parts never earns more than the combined deposit, and the
    ///         combined deposit earns less than n units more than the parts (one truncation per part).
    function testFuzz_calculateReward_splitNeverBeatsCombined(
        uint256[8] memory parts,
        uint256 n,
        uint256 apyBps,
        uint256 p
    ) external {
        n = bound(n, 2, 8);
        apyBps = bound(apyBps, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        uint256 combined;
        uint256 sumParts;
        for (uint256 i = 0; i < n; i++) {
            uint256 part = bound(parts[i], 0, 1e30);
            combined += part;
            sumParts += staking.calculateReward(part, apyBps, p);
        }
        uint256 combinedReward = staking.calculateReward(combined, apyBps, p);
        assertLe(sumParts, combinedReward, "split deposits earned more than a single deposit");
        assertLt(combinedReward, sumParts + n, "combined deposit earned n or more units over the split");
    }

    // ======================================
    // =   Indefinite (period 0) accrual    =
    // ======================================

    /// @notice Pending indefinite reward is non-decreasing in time and uses the effective (base + extra) APY.
    function testFuzz_indefiniteAccrualMonotoneInTime(uint256 amount, uint256 extraApy, uint256 t1, uint256 t2)
        external
    {
        amount = bound(amount, staking.minimumDeposit(), 1_000_000e18);
        extraApy = bound(extraApy, 0, MAX_EXTRA_FUZZ);
        t1 = bound(t1, 0, 3650 days);
        t2 = bound(t2, t1, 3650 days);
        uint256 apy = APY_BPS + extraApy;

        _stakeVWith(staking, user, 0, 0, amount, extraApy, 0);
        // External-call sourced start (see note in testFuzz_indefiniteInstallmentsEqualLumpSum).
        ProgramManager.TokenDeposit memory d = staking.getDeposit(user, 0);
        assertEq(d.APY, apy, "deposit APY != base + voucher extra");
        uint256 start = d.stakingStartDate;

        vm.warp(start + t1);
        uint256 r1 = staking.getDeposit(user, 0).rewardGenerated;
        (,, uint256 c1) = staking.checkClaimableDataFor(user);
        assertEq(r1, c1, "getDeposit pending != checkClaimableDataFor pending");
        assertEq(r1, staking.calculateReward(amount, apy, t1 / 1 days), "pending != calculateReward(daysPassed)");

        vm.warp(start + t2);
        uint256 r2 = staking.getDeposit(user, 0).rewardGenerated;
        assertLe(r1, r2, "indefinite pending reward decreased over time");
    }

    /// @notice Claiming an indefinite deposit in installments pays exactly the same total as one
    ///         lump-sum withdrawal at the end (rewardGenerated tracks the cumulative exactly).
    function testFuzz_indefiniteInstallmentsEqualLumpSum(uint256 amount, uint256 extraApy, uint256[5] memory gaps)
        external
    {
        amount = bound(amount, staking.minimumDeposit(), 1_000_000e18);
        extraApy = bound(extraApy, 0, MAX_EXTRA_FUZZ);

        _stakeVWith(staking, user, 0, 0, amount, extraApy, 0);
        // NOTE: with via_ir the optimizer rematerializes `block.timestamp` at its use site, so a local
        // captured before vm.warp can silently re-read the warped clock later in the same frame.
        // Take the start from the contract (external call result cannot be rematerialized) and drive
        // the clock from an explicit local.
        uint256 start = staking.getDeposit(user, 0).stakingStartDate;
        uint256 clock = start;
        uint256 balBefore = token.balanceOf(user);

        for (uint256 i = 0; i < gaps.length; i++) {
            clock += bound(gaps[i], 0, 200 days);
            vm.warp(clock);
            vm.prank(user);
            try staking.claimDeposit(0) {} catch {} // NoRewardToClaim when < 1 day elapsed is fine
        }
        clock += 1 days;
        vm.warp(clock);

        vm.prank(user);
        staking.withdrawDeposit(0);

        uint256 totalReceived = token.balanceOf(user) - balBefore;
        uint256 daysPassed = (clock - start) / 1 days;
        assertEq(
            totalReceived,
            amount + staking.calculateReward(amount, APY_BPS + extraApy, daysPassed),
            "installment claims + final withdraw != principal + lump-sum reward"
        );
        // Post-condition: nothing left to claim, and the deposit is closed.
        (,, uint256 pendingAfter) = staking.checkClaimableDataFor(user);
        assertEq(pendingAfter, 0);
        assertTrue(staking.checkDepositStatus(user, 0) == ProgramManager.DepositStatus.WITHDRAWN);
    }

    /// @notice Closing a matured periodical deposit pays exactly principal + the reward committed at stake time
    ///         (at base + voucher extra APY), regardless of base APY changes made after staking.
    function testFuzz_periodicalPayoutIsCommittedAtStakeTime(
        uint256 amount,
        uint256 period,
        uint256 extraApy,
        uint256 newApy
    ) external {
        period = bound(period, 1, 400);
        extraApy = bound(extraApy, 0, 10_000);
        newApy = bound(newApy, 1, 10_000);
        amount = bound(amount, staking.minimumDeposit(), 100_000e18);

        // Add the fuzzed period to phase 0 at 20% APY.
        uint256[] memory apy = new uint256[](1);
        uint256[] memory target = new uint256[](1);
        apy[0] = APY_BPS;
        target[0] = type(uint128).max;
        vm.prank(owner);
        staking.addStakingPeriod(period, apy, target);

        uint256 committed = staking.calculateReward(amount, APY_BPS + extraApy, period);
        _stakeVWith(staking, user, 0, period, amount, extraApy, 0);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), committed);
        assertEq(staking.getDeposit(user, 0).rewardGenerated, committed);

        // Owner changes the base APY after the fact -- must not affect the deposit.
        vm.prank(owner);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, period, newApy);

        vm.warp(staking.getDeposit(user, 0).stakingEndDate);
        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(user) - balBefore, amount + committed, "payout != principal + committed reward");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0, "reservation not released");
    }
}
