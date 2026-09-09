// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, stdError} from "forge-std/Test.sol";

import {TestToken} from "../../../shared/TestToken.sol";
import {ERC20PeriodicalStaking} from
    "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Types} from "../../../../src/common/Types.sol";

/// @title RewardMathFuzz
/// @notice Stateless / lightly stateful fuzz tests for the reward arithmetic of ERC20PeriodicalStaking.
/// @dev calculateReward(a, apy, p) = ((a * ((1e18 * apy / 365) * p)) / 100) / 1e18
///
///      Overflow analysis (all uint256):
///        step 1: 1e18 * apy              overflows iff apy  > ~1.157e59
///        step 2: (1e18*apy/365) * p      overflows iff p    > uint.max / (1e18*apy/365)
///        step 3: a * inner               overflows iff a    > uint.max / inner
///      For any realistic apy (<= 1e6 %) and p (<= 100 years) the binding constraint is step 3:
///        inner(apy=100, p=365) = 99_999_999_999_999_999_855  (~1e20)
///        a_max = uint.max / inner ~= 1.158e57 wei = 1.158e39 whole tokens at 18 decimals.
///      Real supplies are ~1e27 wei, so overflow is unreachable in practice; the bound is
///      documented and pinned by test_calculateReward_overflowBound below.
contract RewardMathFuzz is Test {
    uint256 internal constant FP = 1e18;

    TestToken internal token;
    ERC20PeriodicalStaking internal staking;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    // Bounds under which every arithmetic step is provably overflow-free.
    uint256 internal constant A_MAX = 1e40; // wei
    uint256 internal constant APY_MAX = 1e4; // percent
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
        apy[0] = 20;
        target[0] = type(uint128).max;
        staking.pushStakingPhase(apy, target);
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
    function _ref(uint256 a, uint256 apy, uint256 p) internal pure returns (uint256) {
        return ((a * ((FP * apy / 365) * p)) / 100) / FP;
    }

    function testFuzz_calculateReward_matchesReference(uint256 a, uint256 apy, uint256 p) external {
        a = bound(a, 0, A_MAX);
        apy = bound(apy, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        assertEq(staking.calculateReward(a, apy, p), _ref(a, apy, p));
    }

    /// @notice No overflow anywhere inside a generous but realistic envelope (a<=1e50 wei, apy<=1e6%, p<=100y).
    function testFuzz_calculateReward_noOverflowWithinBounds(uint256 a, uint256 apy, uint256 p) external view {
        a = bound(a, 0, 1e50);
        apy = bound(apy, 0, 1e6);
        p = bound(p, 0, P_MAX);
        // inner <= 1e18*1e6/365*36500 = 1e26 ; a * inner <= 1e76 < 2^256 (~1.16e77)
        staking.calculateReward(a, apy, p);
    }

    /// @notice Pins the exact overflow bound for a canonical (apy=100, p=365) configuration.
    function test_calculateReward_overflowBound() external {
        uint256 inner = (FP * 100 / 365) * 365;
        uint256 aMax = type(uint256).max / inner;

        // Just below the bound: works and equals the reference.
        assertEq(staking.calculateReward(aMax, 100, 365), _ref(aMax, 100, 365));
        // aMax is ~1.158e57 wei (1.158e39 tokens at 18 decimals) -- unreachable for any real supply.
        assertGt(aMax, 1e57);
        assertLt(aMax, 2e57);

        // One wei above: Panic(0x11).
        vm.expectRevert(stdError.arithmeticError);
        staking.calculateReward(aMax + 1, 100, 365);
    }

    /// @notice Rounding loss is bounded: reward <= exact and exact - reward <= a*p/1e20 + 1.
    function testFuzz_calculateReward_roundingBounded(uint256 a, uint256 apy, uint256 p) external {
        a = bound(a, 0, A_MAX);
        apy = bound(apy, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        uint256 reward = staking.calculateReward(a, apy, p);
        uint256 exact = a * apy * p / 36_500; // a*apy*p <= 3.65e48, no overflow
        assertLe(reward, exact, "reward rounds up above exact value");
        // (1e18*apy/365) loses < 1 per 1e18 of scale; multiplied by a*p and divided by 100e18.
        assertLe(exact - reward, a * p / 100e18 + 1, "rounding loss larger than analytical bound");
    }

    function testFuzz_calculateReward_monotoneInAmount(uint256 a1, uint256 a2, uint256 apy, uint256 p)
        external
    {
        a1 = bound(a1, 0, A_MAX);
        a2 = bound(a2, a1, A_MAX);
        apy = bound(apy, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        assertLe(staking.calculateReward(a1, apy, p), staking.calculateReward(a2, apy, p));
    }

    function testFuzz_calculateReward_monotoneInAPY(uint256 a, uint256 apy1, uint256 apy2, uint256 p)
        external
    {
        a = bound(a, 0, A_MAX);
        apy1 = bound(apy1, 0, APY_MAX);
        apy2 = bound(apy2, apy1, APY_MAX);
        p = bound(p, 0, P_MAX);
        assertLe(staking.calculateReward(a, apy1, p), staking.calculateReward(a, apy2, p));
    }

    function testFuzz_calculateReward_monotoneInPeriod(uint256 a, uint256 apy, uint256 p1, uint256 p2)
        external
    {
        a = bound(a, 0, A_MAX);
        apy = bound(apy, 0, APY_MAX);
        p1 = bound(p1, 0, P_MAX);
        p2 = bound(p2, p1, P_MAX);
        assertLe(staking.calculateReward(a, apy, p1), staking.calculateReward(a, apy, p2));
    }

    /// @notice Splitting a deposit into n parts never earns more than the combined deposit, and the
    ///         combined deposit earns at most n wei more than the parts (one rounding per part).
    function testFuzz_calculateReward_splitNeverBeatsCombined(uint256[8] memory parts, uint256 n, uint256 apy, uint256 p)
        external
    {
        n = bound(n, 2, 8);
        apy = bound(apy, 0, APY_MAX);
        p = bound(p, 0, P_MAX);
        uint256 combined;
        uint256 sumParts;
        for (uint256 i = 0; i < n; i++) {
            uint256 part = bound(parts[i], 0, 1e30);
            combined += part;
            sumParts += staking.calculateReward(part, apy, p);
        }
        uint256 combinedReward = staking.calculateReward(combined, apy, p);
        assertLe(sumParts, combinedReward, "split deposits earned more than a single deposit");
        assertLe(combinedReward, sumParts + n, "combined deposit earned more than n wei over the split");
    }

    // ======================================
    // =   Indefinite (period 0) accrual    =
    // ======================================

    /// @notice Pending indefinite reward is non-decreasing in time.
    function testFuzz_indefiniteAccrualMonotoneInTime(uint256 amount, uint256 t1, uint256 t2) external {
        amount = bound(amount, staking.minimumDeposit(), 1_000_000e18);
        t1 = bound(t1, 0, 3650 days);
        t2 = bound(t2, t1, 3650 days);

        vm.prank(user);
        staking.safeStake(0, 0, amount, 20);
        // External-call sourced start (see note in testFuzz_indefiniteInstallmentsEqualLumpSum).
        uint256 start = staking.getDeposit(user, 0).stakingStartDate;

        vm.warp(start + t1);
        uint256 r1 = staking.getDeposit(user, 0).rewardGenerated;
        (,, uint256 c1) = staking.checkClaimableDataFor(user);
        assertEq(r1, c1, "getDeposit pending != checkClaimableDataFor pending");
        assertEq(r1, staking.calculateReward(amount, 20, t1 / 1 days), "pending != calculateReward(daysPassed)");

        vm.warp(start + t2);
        uint256 r2 = staking.getDeposit(user, 0).rewardGenerated;
        assertLe(r1, r2, "indefinite pending reward decreased over time");
    }

    /// @notice Claiming an indefinite deposit in installments pays exactly the same total as one
    ///         lump-sum withdrawal at the end (rewardGenerated tracks the cumulative exactly).
    function testFuzz_indefiniteInstallmentsEqualLumpSum(uint256 amount, uint256[5] memory gaps) external {
        amount = bound(amount, staking.minimumDeposit(), 1_000_000e18);

        vm.prank(user);
        staking.safeStake(0, 0, amount, 20);
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
            amount + staking.calculateReward(amount, 20, daysPassed),
            "installment claims + final withdraw != principal + lump-sum reward"
        );
        // Post-condition: nothing left to claim, and the deposit is closed.
        (,, uint256 pendingAfter) = staking.checkClaimableDataFor(user);
        assertEq(pendingAfter, 0);
        assertTrue(staking.checkDepositStatus(user, 0) == ProgramManager.DepositStatus.WITHDRAWN);
    }

    /// @notice Closing a matured periodical deposit pays exactly principal + the reward committed at stake time,
    ///         regardless of APY changes made after staking.
    function testFuzz_periodicalPayoutIsCommittedAtStakeTime(uint256 amount, uint256 period, uint256 newApy) external {
        period = bound(period, 1, 400);
        newApy = bound(newApy, 1, 1000);
        amount = bound(amount, staking.minimumDeposit(), 100_000e18);

        // Add the fuzzed period to phase 0 at 20% APY.
        uint256[] memory apy = new uint256[](1);
        uint256[] memory target = new uint256[](1);
        apy[0] = 20;
        target[0] = type(uint128).max;
        vm.prank(owner);
        staking.addStakingPeriod(period, apy, target);

        uint256 committed = staking.calculateReward(amount, 20, period);
        vm.prank(user);
        staking.safeStake(0, period, amount, 20);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), committed);

        // Owner changes APY after the fact -- must not affect the deposit.
        vm.prank(owner);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, period, newApy);

        vm.warp(block.timestamp + period * 1 days);
        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(user) - balBefore, amount + committed, "payout != principal + committed reward");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0, "reservation not released");
    }
}
