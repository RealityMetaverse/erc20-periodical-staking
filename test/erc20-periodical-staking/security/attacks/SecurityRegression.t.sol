// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title Security regression tests for ERC20PeriodicalStaking
/// @notice Deterministic reproductions of the v0.2.4 weaknesses (period-removal lockup, unprotected reward
///         pool, unbounded admin loops, panicking views), checks of the v0.3.0 behaviour that replaced them, and
///         the v0.4.0 regressions (no stake without a voucher, no whole-pool fallback without a controller).
///
///  History: the file was written to compile against both v0.2.4 and v0.3.0 and still branches on `_isV030()`,
///  which probes for `getCollectableReward()`. Since v0.4.0 (voucher-only staking) it compiles against the
///  current sources only, so the v0.2.4 branches document the original bug and are no longer executed.
///   - `test_v024_*`  reproduce v0.2.4 (deployed 0xa816...) bugs and assert the fix.
///   - `test_v030_*` / `test_v040_*` exercise behaviour introduced in that version.
///   - `test_known_*` document accepted limitations.
///   - `test_sound_*` document behaviour verified correct.
///  APY is in basis points since v0.4.0: APY = 1000 is the same 10% the original figures were computed with.
import {Test, console, stdError} from "forge-std/Test.sol";
import {TestToken} from "../../../shared/TestToken.sol";
import {Clock} from "../../../shared/Clock.sol";
import {VoucherHelper} from "../../../shared/VoucherHelper.sol";
import {ERC20PeriodicalStaking} from
    "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {LimitController} from "../../../../src/contracts/LimitController.sol";
import {Types} from "../../../../src/common/Types.sol";
import {Errors} from "../../../../src/common/Errors.sol";

contract SecurityRegression is VoucherHelper {
    TestToken token;
    ERC20PeriodicalStaking staking;

    address owner = address(this);
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant ONE = 1e18;
    uint256 constant APY = 1000; // bps (10%)
    uint256 constant TARGET = 1_000_000 * ONE;
    uint256 constant PERIOD_90 = 90;
    uint256 constant PERIOD_0 = 0; // indefinite

    uint256 ts;
    Clock clock = new Clock();

    function _now() internal view returns (uint256) {
        return clock.now();
    }

    function setUp() public {
        token = new TestToken(18);
        staking = new ERC20PeriodicalStaking(address(token));
        staking.addContractAdmin(admin);
        _enableVoucherStaking(staking);

        uint256[] memory empty = new uint256[](0);
        staking.addStakingPeriod(PERIOD_0, empty, empty);
        staking.addStakingPeriod(PERIOD_90, empty, empty);
        uint256[] memory apys = new uint256[](2);
        uint256[] memory targets = new uint256[](2);
        apys[0] = APY;
        apys[1] = APY;
        targets[0] = TARGET;
        targets[1] = TARGET;
        staking.pushStakingPhase(apys, targets);

        token.transfer(alice, 10_000 * ONE);
        token.transfer(bob, 10_000 * ONE);
        token.transfer(attacker, 100_000 * ONE);
        token.transfer(admin, 1_000_000 * ONE);

        vm.prank(admin);
        token.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
        vm.prank(attacker);
        token.approve(address(staking), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers
    function _isV030() internal view returns (bool ok) {
        (ok,) = address(staking).staticcall(abi.encodeWithSignature("getCollectableReward()"));
    }

    /// @dev storage-backed clock seeded from the external Clock: two `vm.warp(block.timestamp + x)` in one
    ///      test get CSE-d by via-IR (see test/shared/ClockHazard.t.sol), so never read block.timestamp here.
    function _warpBy(uint256 delta) internal {
        if (ts == 0) ts = _now();
        ts += delta;
        vm.warp(ts);
    }

    function _fund(uint256 amount) internal {
        vm.prank(admin);
        staking.provideReward(amount);
    }

    function _stake(address who, uint256 period, uint256 amount) internal returns (uint256 depositNo) {
        depositNo = _stakeV(staking, who, 0, period, amount);
    }

    function _expectStakeRevert(address who, uint256 period, uint256 amount, bytes memory err) internal {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, who, 0, period, 0, 0);
        vm.prank(who);
        vm.expectRevert(err);
        staking.stakeWithVoucher(v, sig, amount, APY);
    }

    function _status(address who, uint256 dep) internal view returns (ProgramManager.DepositStatus) {
        return staking.checkDepositStatus(who, dep);
    }

    /// @dev v0.3.0+ opt-in partial withdraw, encoded for a low-level call (originally so the file compiled
    ///      against the v0.2.4 sources).
    function _partialWithdrawCall(uint256 dep, uint256 minReward) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("withdrawDepositPartial(uint256,uint256)", dep, minReward);
    }

    function _collectAll() internal {
        if (_isV030()) {
            (, bytes memory data) = address(staking).staticcall(abi.encodeWithSignature("getCollectableReward()"));
            uint256 c = abi.decode(data, (uint256));
            if (c > 0) staking.collectReward(c);
        } else {
            staking.collectReward(staking.rewardPool());
        }
    }

    function _assertSolvent() internal {
        uint256 bal = token.balanceOf(address(staking));
        uint256 principal = staking.getTotalData(Types.DataType.STAKING);
        assertEq(bal, principal + staking.rewardPool(), "balance == active principal + rewardPool");
    }

    // =====================================================================================
    // v0.2.4: removeStakingPeriod / popStakingPhase permanently lock deposits (see README Known Issues)
    // =====================================================================================
    function test_v024_removeStakingPeriodLocksMaturedDeposit() public {
        _fund(1_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_90, 1_000 * ONE);
        _warpBy(91 days);
        staking.removeStakingPeriod(PERIOD_90);

        vm.prank(alice);
        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.claimDeposit.selector, dep));
        if (_isV030()) {
            assertTrue(ok, "v0.3.0: deposit on removed period must stay claimable");
            assertGt(token.balanceOf(alice), 10_000 * ONE, "principal + reward returned");
        } else {
            assertFalse(ok, "v0.2.4: claim underflows on zeroed STAKED / REWARD_EXPECTED cells");
            assertEq(token.balanceOf(alice), 9_000 * ONE, "v0.2.4: principal is stuck");
            console.log("v0.2.4 lockup reproduced: claim reverts after removeStakingPeriod");
        }
    }

    function test_v024_popStakingPhaseLocksIndefiniteDeposit() public {
        _fund(1_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(10 days);
        staking.popStakingPhase();

        vm.prank(alice);
        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.withdrawDeposit.selector, dep));
        if (_isV030()) assertTrue(ok, "v0.3.0: withdraw after popStakingPhase must work");
        else assertFalse(ok, "v0.2.4: withdraw underflows after popStakingPhase");
    }

    // =====================================================================================
    // v0.2.4: collectReward ignores REWARD_EXPECTED -> matured deposits unclaimable
    // =====================================================================================
    function test_v024_collectRewardStrandsMaturedPeriodicalDeposit() public {
        _fund(1_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_90, 1_000 * ONE);
        uint256 expected = staking.getTotalData(Types.DataType.REWARD_EXPECTED);

        (bool drained,) = address(staking).call(
            abi.encodeWithSelector(staking.collectReward.selector, staking.rewardPool())
        );
        _warpBy(91 days);
        if (_isV030()) {
            assertFalse(drained, "v0.3.0: cannot collect below REWARD_EXPECTED");
            assertGe(staking.rewardPool(), expected);
            vm.prank(alice);
            staking.claimDeposit(dep);
        } else {
            assertTrue(drained);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, expected, 0));
            staking.claimDeposit(dep);
            // withdrawDeposit is not allowed on READY_TO_CLAIM, so principal is stuck too
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, dep));
            staking.withdrawDeposit(dep);
        }
    }

    // =====================================================================================
    // v0.2.4: _clearPhasePeriodUserData gas is O(stakerAddressList) -> admin DoS
    // =====================================================================================
    function _seedStakers(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            address s = address(uint160(0x10000 + i));
            token.transfer(s, 100);
            vm.prank(s);
            token.approve(address(staking), 100);
            _stake(s, PERIOD_90, 100); // 100 wei = default minimumDeposit
        }
    }

    function test_v024_removeStakingPeriodGasScalesWithStakerCount() public {
        _fund(1_000 * ONE);
        assertEq(staking.minimumDeposit(), 100, "default minimumDeposit is 100 wei");

        uint256 snap = vm.snapshot();
        _seedStakers(50);
        uint256 g0 = gasleft();
        staking.removeStakingPeriod(PERIOD_0);
        uint256 gas50 = g0 - gasleft();
        vm.revertTo(snap);

        _seedStakers(400);
        g0 = gasleft();
        staking.removeStakingPeriod(PERIOD_0);
        uint256 gas400 = g0 - gasleft();

        emit log_named_uint("removeStakingPeriod gas, 50 stakers", gas50);
        emit log_named_uint("removeStakingPeriod gas, 400 stakers", gas400);
        if (_isV030()) {
            assertLt(gas400, gas50 + 10_000, "v0.3.0: gas independent of staker count");
        } else {
            uint256 perStaker = (gas400 - gas50) / 350;
            emit log_named_uint("marginal gas per staker (1 phase)", perStaker);
            emit log_named_uint("stakers to exceed 30M gas (1 phase)", 30_000_000 / perStaker);
            assertGt(perStaker, 5_000, "v0.2.4: loop is O(stakers)");
        }
    }

    // =====================================================================================
    // v0.3.0: indefinite principal is always recoverable. withdrawDeposit pays the full accrued reward or
    // reverts NotEnoughFundsInRewardPool (deposit stays open); withdrawDepositPartial(deposit, minReward)
    // is the explicit opt-in that closes it with min(accrued, collectable) reward (>= minReward).
    // =====================================================================================
    function test_v030_indefinitePrincipalRecoverableWhenRewardPoolInsufficient() public {
        _fund(1 * ONE); // tiny pool
        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(365 days); // ~100 tokens accrued at 10% APY

        (,, uint256 accrued) = staking.checkClaimableDataFor(alice);
        assertGt(accrued, staking.rewardPool(), "precondition: accrued > pool");

        if (_isV030()) {
            // claim pays the whole free pool (1 token) and leaves the remainder accruing
            vm.prank(alice);
            staking.claimDeposit(dep);
            assertEq(staking.rewardPool(), 0);
            assertEq(token.balanceOf(alice), 9_000 * ONE + 1 * ONE);
            assertEq(staking.getDeposit(alice, dep).rewardGenerated, accrued - 1 * ONE, "remainder still owed");

            // nothing collectable: single claim reverts NoRewardToClaim, batch is a silent no-op
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, dep));
            staking.claimDeposit(dep);
            vm.prank(alice);
            staking.claimAll();

            // the full withdraw refuses to forfeit the remainder and leaves the deposit open...
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued - 1 * ONE, 0));
            staking.withdrawDeposit(dep);
            assertEq(uint256(_status(alice, dep)), uint256(ProgramManager.DepositStatus.INDEFINITE));

            // ...but principal is never hostage: the opt-in partial withdraw returns it with 0 reward
            vm.prank(alice);
            (bool ok,) = address(staking).call(_partialWithdrawCall(dep, 0));
            assertTrue(ok, "withdrawDepositPartial(dep, 0) must succeed");
            assertEq(token.balanceOf(alice), 10_000 * ONE + 1 * ONE, "principal + the 1 token already paid");
            assertEq(uint256(_status(alice, dep)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        } else {
            bytes memory err =
                abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, staking.rewardPool());
            vm.prank(alice);
            vm.expectRevert(err);
            staking.withdrawDeposit(dep); // v0.2.4: PRINCIPAL withdrawal reverts
        }
    }

    function test_v030_ownerCollectCannotLockIndefinitePrincipal() public {
        _fund(10_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(30 days);
        _collectAll(); // on v0.3.0 the reserve is 0 here because indefinite accrual is not reserved
        assertEq(staking.rewardPool(), 0);

        uint256 before = token.balanceOf(alice);
        bool v030 = _isV030(); // probe before pranking: the staticcall would consume the prank
        if (v030) {
            // the full withdraw will not forfeit the accrued reward; the opt-in partial one returns principal
            uint256 accrued = staking.getDeposit(alice, dep).rewardGenerated;
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 0));
            staking.withdrawDeposit(dep);
            vm.prank(alice);
            (bool ok,) = address(staking).call(_partialWithdrawCall(dep, 0));
            assertTrue(ok, "withdrawDepositPartial(dep, 0) must succeed");
            assertEq(token.balanceOf(alice), before + 1_000 * ONE, "principal back, 0 reward");
            assertEq(uint256(_status(alice, dep)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        } else {
            vm.prank(alice);
            vm.expectRevert();
            staking.withdrawDeposit(dep);
        }
    }

    // =====================================================================================
    // v0.3.0: indefinite payouts are bounded by getCollectableReward()
    // =====================================================================================
    function test_v030_indefiniteClaimCannotDrainRewardReservedForPeriodicalDeposit() public {
        if (!_isV030()) return; // getCollectableReward() does not exist on v0.2.4
        uint256 bobReward = staking.calculateReward(1_000 * ONE, APY, PERIOD_90); // ~24.66 tokens
        _fund(bobReward + 5 * ONE); // pool covers bob's reservation plus 5 tokens of slack

        _stake(alice, PERIOD_0, 1_000 * ONE); // indefinite, unreserved
        uint256 bobDep = _stake(bob, PERIOD_90, 1_000 * ONE); // commits bobReward to REWARD_EXPECTED
        assertEq(staking.getTotalData(Types.DataType.REWARD_EXPECTED), bobReward);

        _warpBy(37 days);
        // alice's accrued indefinite reward (~10.1 tokens) exceeds the 5-token slack but not the pool.
        (,, uint256 aliceAccrued) = staking.checkClaimableDataFor(alice);
        assertGt(aliceAccrued, 5 * ONE);
        assertLt(aliceAccrued, staking.rewardPool());
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(alice), before + 5 * ONE, "only the 5-token slack is paid");
        assertEq(staking.rewardPool(), bobReward, "pool never drops below the reserved amount");
        assertEq(staking.getDeposit(alice, 0).rewardGenerated, aliceAccrued - 5 * ONE, "rest keeps accruing");

        _warpBy(54 days); // bob matures

        // bob's matured deposit is fully payable
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        staking.claimDeposit(bobDep);
        assertEq(token.balanceOf(bob), bobBefore + 1_000 * ONE + bobReward);
        assertEq(staking.rewardPool(), 0);
        assertEq(staking.getTotalData(Types.DataType.REWARD_EXPECTED), 0);
    }

    // =====================================================================================
    // LimitController semantics
    // =====================================================================================
    function test_v030_limitControllerZeroWalletLimitBlocksWallet() public {
        _fund(1_000 * ONE);
        LimitController lc = new LimitController(address(staking));
        staking.setLimitController(address(lc));
        lc.setDefaultLimit(0, PERIOD_90, 5_000 * ONE);

        // NatSpec: "0 means no staking allowed". Fixed: hasWalletLimit makes the explicit 0 authoritative.
        lc.setWalletLimit(alice, 0, PERIOD_90, 0);
        assertTrue(lc.hasWalletLimit(alice, 0, PERIOD_90));
        assertEq(lc.getAllowed(alice, 0, PERIOD_90), 0);
        _expectStakeRevert(
            alice,
            PERIOD_90,
            1_000 * ONE,
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, PERIOD_90, 1_000 * ONE, 0)
        );

        // clearing restores the default
        lc.clearWalletLimit(alice, 0, PERIOD_90);
        assertFalse(lc.hasWalletLimit(alice, 0, PERIOD_90));
        assertEq(lc.getAllowed(alice, 0, PERIOD_90), 5_000 * ONE);
        _stake(alice, PERIOD_90, 1_000 * ONE);
        assertEq(staking.checkDepositCountOfAddress(alice), 1);
    }

    function test_sound_limitControllerLimitIsConcurrentNotLifetime() public {
        LimitController lc = new LimitController(address(staking));
        staking.setLimitController(address(lc));
        lc.setDefaultLimit(0, PERIOD_0, 1_000 * ONE);

        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, PERIOD_0), 0);
        vm.prank(alice);
        staking.withdrawDeposit(dep);
        assertEq(lc.getRemaining(alice, 0, PERIOD_0), 1_000 * ONE, "limit restored after withdraw");
        _stake(alice, PERIOD_0, 1_000 * ONE);
    }

    // =====================================================================================
    // v0.4.0 regressions
    // =====================================================================================
    /// v0.3.0 treated `limitController == address(0)` as "headroom = remaining target", so one wallet could fill
    /// the whole pool. v0.4.0 refuses to stake without a controller.
    function test_v040_noLimitControllerMeansNoStaking() public {
        _fund(1_000 * ONE);
        staking.setLimitController(address(0));
        _expectStakeRevert(attacker, PERIOD_90, 100_000 * ONE, abi.encodeWithSelector(Errors.LimitControllerNotSet.selector));
        assertEq(staking.checkDepositCountOfAddress(attacker), 0);
        assertEq(token.balanceOf(attacker), 100_000 * ONE);
    }

    /// The plain v0.3.0 stake entry point is gone (no fallback either) and an unsigned voucher is refused:
    /// eligibility can only come from the backend's signature.
    function test_v040_stakeWithoutVoucherImpossible() public {
        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(staking).call(
            abi.encodeWithSignature("safeStake(uint256,uint256,uint256,uint256)", 0, PERIOD_90, 1_000 * ONE, APY)
        );
        assertFalse(ok, "safeStake must not exist");
        assertEq(ret.length, 0, "no fallback");

        Types.StakeVoucher memory v = _makeVoucher(attacker, 0, PERIOD_90, 0, 0);
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, "", 1_000 * ONE, APY);
        // self-signed with the attacker's own key
        bytes memory selfSig = _signVoucher(address(staking), v, uint256(keccak256("attacker")));
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, selfSig, 1_000 * ONE, APY);
        assertEq(staking.checkDepositCountOfAddress(attacker), 0);
    }

    // =====================================================================================
    // Known limitation: the owner can pause withdrawals and claims indefinitely (no timelock, no escape hatch)
    // =====================================================================================
    function test_known_ownerCanPauseWithdrawAndClaimIndefinitely() public {
        _fund(1_000 * ONE);
        uint256 a = _stake(alice, PERIOD_0, 1_000 * ONE);
        uint256 b = _stake(bob, PERIOD_90, 1_000 * ONE);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, false);
        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        _warpBy(365 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.WITHDRAWAL));
        staking.withdrawDeposit(a);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.CLAIM));
        staking.claimDeposit(b);
    }

    // =====================================================================================
    // claimAll silently skips deposits with nothing payable (a short pool pays the collectable part first)
    // =====================================================================================
    function test_sound_claimAllSilentNoOpWhenNothingCollectable() public {
        _fund(1 * ONE);
        _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(365 days);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        if (_isV030()) {
            assertEq(token.balanceOf(alice), before + 1 * ONE, "pays the collectable part");
            assertEq(staking.rewardPool(), 0);
            before = token.balanceOf(alice);
            vm.prank(alice);
            staking.claimAll(); // now nothing collectable: no revert, no event, no transfer
        }
        assertEq(token.balanceOf(alice), before);
    }

    // =====================================================================================
    // Default minimum deposit and bad-index views
    // =====================================================================================
    function test_sound_defaultMinimumDepositIs100Wei() public {
        _fund(1 * ONE);
        _stake(alice, PERIOD_90, 100);
        assertEq(staking.getDeposit(alice, 0).rewardGenerated, 2); // 100 wei * 10% * 90/365 = 2 wei
    }

    function test_v024_viewFunctionsPanicOnBadIndex() public {
        (bool ok, bytes memory ret) = address(staking).staticcall(
            abi.encodeWithSelector(staking.getDeposit.selector, alice, 0)
        );
        assertFalse(ok);
        if (_isV030()) {
            assertEq(bytes4(ret), Errors.DepositDoesNotExist.selector, "v0.3.0: typed error");
        } else {
            assertEq(bytes4(ret), bytes4(keccak256("Panic(uint256)")), "v0.2.4: opaque panic");
        }
    }

    // =====================================================================================
    // v0.3.0 behaviour checks (period re-add, reward reserve, ownership, claimRange, rescue)
    // =====================================================================================
    /// Re-adding a removed period with a smaller target does not underflow; STAKED carries over
    function test_v030_readdPeriodWithSmallerTargetIsSafeButHidesStaked() public {
        if (!_isV030()) return;
        _fund(1_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_90, 5_000 * ONE);
        staking.removeStakingPeriod(PERIOD_90);

        // while removed: totalDataList[STAKING] != sum of visible STAKED cells (view inconsistency)
        uint256[][] memory stakedCells = staking.getPhasePeriodDataAll(Types.PhasePeriodDataType.STAKED);
        uint256 visible;
        for (uint256 i = 0; i < stakedCells[0].length; i++) visible += stakedCells[0][i];
        assertEq(visible, 0);
        assertEq(staking.getTotalData(Types.DataType.STAKING), 5_000 * ONE);

        uint256[] memory apy = new uint256[](1);
        uint256[] memory tgt = new uint256[](1);
        apy[0] = APY;
        tgt[0] = 1_000 * ONE; // smaller than the 5_000 still staked
        staking.addStakingPeriod(PERIOD_90, apy, tgt);

        // no underflow: the reward-for-targets view saturates the over-target cell at 0
        assertEq(staking.getRewardRequiredForTargets(), 0);
        _expectStakeRevert(
            bob, PERIOD_90, 100 * ONE, abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, PERIOD_90, 1_000 * ONE)
        );

        // old deposit still exits cleanly
        vm.prank(alice);
        staking.withdrawDeposit(dep);
        assertEq(staking.getPhasePeriodData(Types.PhasePeriodDataType.STAKED, 0, PERIOD_90), 0);
    }

    /// There is NO stake-time reservation, so a stake can never be blocked by someone else occupying the free
    ///     pool with a large stake and exiting for free. A large early-exiting stake leaves every other stake,
    ///     the collect guard and the matured claims unaffected.
    function test_v030_noStakeTimeReservation_largeStakeCannotBlockOthers() public {
        if (!_isV030()) return;
        _fund(1_000 * ONE); // owner funds 1000 tokens of rewards; target is 1,000,000 tokens

        // reward fraction for 90d @10% = 2.466%; 41,000 tokens commit ~1011 tokens, more than the 1000 in the
        // pool; the stake is still accepted because the pool is never checked at stake time
        uint256 blockAmount = 41_000 * ONE;
        uint256 attDep = _stake(attacker, PERIOD_90, blockAmount);
        assertGt(
            staking.getTotalData(Types.DataType.REWARD_EXPECTED), staking.rewardPool(), "pool below REWARD_EXPECTED is allowed"
        );

        // victim stakes regardless of pool state
        uint256 aliceDep = _stake(alice, PERIOD_90, 100 * ONE);
        uint256 aliceReward = staking.calculateReward(100 * ONE, APY, PERIOD_90);

        // owner cannot collect anything promised to open deposits
        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, 1, 0));
        staking.collectReward(1);

        // attacker exits early with no reward, releasing its commitment; nothing else changes
        vm.prank(attacker);
        staking.withdrawDeposit(attDep);
        assertEq(token.balanceOf(attacker), 100_000 * ONE, "no penalty, no reward");
        assertEq(staking.getTotalData(Types.DataType.REWARD_EXPECTED), aliceReward);
        assertEq(staking.rewardPool(), 1_000 * ONE);

        // alice's matured claim is paid from the funded pool
        _warpBy(91 days);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimDeposit(aliceDep);
        assertEq(token.balanceOf(alice), before + 100 * ONE + aliceReward);
        _assertSolvent();
    }

    /// Accepted behaviour (same as v0.2.4): a matured periodical claim against a short pool reverts
    ///     NotEnoughFundsInRewardPool; nothing is lost and the claim succeeds after provideReward.
    function test_v030_maturedClaimWaitsForTopUp_noLoss() public {
        if (!_isV030()) return;
        uint256 dep = _stake(alice, PERIOD_90, 1_000 * ONE); // pool is empty
        uint256 reward = staking.calculateReward(1_000 * ONE, APY, PERIOD_90);
        assertEq(staking.rewardPool(), 0);
        assertGe(staking.getRewardPoolShortfall(), reward, "shortfall reports the existing deficit");
        _warpBy(91 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward, 0));
        staking.claimDeposit(dep);
        vm.prank(alice);
        staking.claimAll(); // batch: silent skip
        assertEq(uint256(_status(alice, dep)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));

        _fund(reward - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward, reward - 1));
        staking.claimDeposit(dep);

        _fund(1);
        vm.prank(alice);
        staking.claimDeposit(dep);
        assertEq(token.balanceOf(alice), 10_000 * ONE + reward, "principal + full reward, no loss");
        assertEq(staking.rewardPool(), 0);
        _assertSolvent();
    }

    /// Two-step ownership
    function test_v030_twoStepOwnership() public {
        if (!_isV030()) return;
        // symbols below did not exist on v0.2.4, so signatures are used
        bytes4 notPending = bytes4(keccak256("NotPendingOwner(address,address)"));
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");

        staking.transferOwnership(bob);
        assertEq(staking.contractOwner(), owner, "owner unchanged until accept");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(notPending, alice, bob));
        (bool ok,) = address(staking).call(acceptCall);
        ok;

        // owner can cancel with address(0)
        staking.transferOwnership(address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(notPending, bob, address(0)));
        (ok,) = address(staking).call(acceptCall);

        staking.transferOwnership(bob);
        vm.prank(bob);
        (ok,) = address(staking).call(acceptCall);
        assertTrue(ok);
        assertEq(staking.contractOwner(), bob);
        (, bytes memory pend) = address(staking).staticcall(abi.encodeWithSignature("pendingOwner()"));
        assertEq(abi.decode(pend, (address)), address(0));
        // old owner lost privileges
        vm.expectRevert();
        staking.setMiniumumDeposit(1);
    }

    /// Bounded claimRange and cursor advancing to `count`
    function test_v030_claimRangeAndCursorAdvancesToCount() public {
        if (!_isV030()) return;
        _fund(10_000 * ONE);
        for (uint256 i = 0; i < 4; i++) _stake(alice, PERIOD_90, 100 * ONE);
        _warpBy(91 days);

        vm.prank(alice);
        (bool ok,) = address(staking).call(abi.encodeWithSignature("claimRange(uint256,uint256)", 0, 2));
        assertTrue(ok);
        assertEq(uint256(_status(alice, 1)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(uint256(_status(alice, 2)), uint256(ProgramManager.DepositStatus.READY_TO_CLAIM));
        assertEq(staking.stakerActiveDepositStartIndex(alice), 2);

        vm.prank(alice);
        staking.claimAll();
        assertEq(staking.stakerActiveDepositStartIndex(alice), 4, "cursor == count when all closed");

        // cursor == count: claimAll() is an empty loop (no underflow) and a fresh stake lands at the cursor
        vm.prank(alice);
        (ok,) = address(staking).call(abi.encodeWithSignature("claimAll()"));
        assertTrue(ok);
        _stake(alice, PERIOD_0, 100 * ONE);
        assertEq(staking.stakerActiveDepositStartIndex(alice), 4);
        (,, uint256 indef) = staking.checkClaimableDataFor(alice);
        assertEq(indef, 0);
        _warpBy(10 days);
        (,, indef) = staking.checkClaimableDataFor(alice);
        assertGt(indef, 0, "new deposit visible from cursor");
    }

    /// rescueTokens can never touch principal or the reward pool
    function test_v030_rescueCannotTouchPrincipalOrPool() public {
        if (!_isV030()) return;
        _fund(1_000 * ONE);
        _stake(alice, PERIOD_0, 1_000 * ONE);
        token.transfer(address(staking), 7 * ONE); // accidental donation

        (bool ok,) = address(staking).call(
            abi.encodeWithSignature("rescueTokens(address,uint256)", address(token), 8 * ONE)
        );
        assertFalse(ok, "cannot exceed excess");
        (ok,) = address(staking).call(
            abi.encodeWithSignature("rescueTokens(address,uint256)", address(token), 7 * ONE)
        );
        assertTrue(ok);
        _assertSolvent();
        assertEq(staking.getTotalData(Types.DataType.STAKING), 1_000 * ONE);
        assertEq(staking.rewardPool(), 1_000 * ONE);
    }

    // =====================================================================================
    // Behaviour that is easy to misread (documented so it is not reported as a bug)
    // =====================================================================================
    /// Lowering the APY after a partial indefinite claim does not underflow or change what the deposit earns:
    /// the deposit stores its own APY, so setPhasePeriodData never touches existing deposits.
    function test_sound_apyChangeDoesNotAffectExistingIndefiniteDeposit() public {
        _fund(10_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(100 days);
        vm.prank(alice);
        staking.claimDeposit(dep);
        uint256 paidFirst = staking.getUserData(Types.DataType.CLAIM, alice);

        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, PERIOD_0, 1); // 10% -> 0.01%

        _warpBy(100 days);
        vm.prank(alice);
        staking.claimDeposit(dep);
        uint256 paidSecond = staking.getUserData(Types.DataType.CLAIM, alice) - paidFirst;
        // single-truncation math: floor(2x) - floor(x) is floor(x) or floor(x) + 1
        assertApproxEqAbs(paidSecond, paidFirst, 1, "still accrues at the ORIGINAL APY; owner cannot cap liability");
        assertEq(paidFirst + paidSecond, staking.calculateReward(1_000 * ONE, APY, 200), "exact total over 200 days");
        assertEq(staking.getDeposit(alice, dep).APY, APY);
    }

    /// Period 0 deposits are INDEFINITE, not "instantly READY_TO_CLAIM with zero reward".
    function test_sound_period0IsIndefinite() public {
        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        assertEq(uint256(_status(alice, dep)), uint256(ProgramManager.DepositStatus.INDEFINITE));
    }

    // =====================================================================================
    // Verified-sound behaviour
    // =====================================================================================
    function test_sound_targetLoweredBelowStakedDoesNotUnderflow() public {
        _fund(1_000 * ONE);
        _stake(alice, PERIOD_90, 5_000 * ONE);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, PERIOD_90, 100 * ONE);

        assertEq(staking.getRewardRequiredForTargets(), 0, "over-target cell saturates, no underflow");
        _expectStakeRevert(
            bob, PERIOD_90, 100 * ONE, abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, PERIOD_90, 100 * ONE)
        );
        vm.prank(alice);
        staking.withdrawDeposit(0);
        assertEq(token.balanceOf(alice), 10_000 * ONE);
    }

    function test_sound_indefiniteWithdrawIsClassifiedWithdrawnAndNotReclaimable() public {
        _fund(1_000 * ONE);
        uint256 dep = _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(10 days);
        vm.prank(alice);
        staking.withdrawDeposit(dep);
        assertEq(uint256(_status(alice, dep)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotClaimable.selector, dep));
        staking.claimDeposit(dep);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotWithdrawable.selector, dep));
        staking.withdrawDeposit(dep);
    }

    function test_sound_activeStartIndexNeverSkipsClaimable() public {
        _fund(10_000 * ONE);
        _stake(alice, PERIOD_0, 1_000 * ONE); // 0: indefinite, stays active
        _stake(alice, PERIOD_90, 1_000 * ONE); // 1
        _stake(alice, PERIOD_90, 1_000 * ONE); // 2
        _warpBy(91 days);

        vm.prank(alice);
        staking.claimDeposit(2); // out of order
        assertEq(staking.stakerActiveDepositStartIndex(alice), 0);
        vm.prank(alice);
        staking.claimAll(); // must still reach deposit 1
        assertEq(uint256(_status(alice, 1)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), 1_000 * ONE);

        vm.prank(alice);
        staking.withdrawDeposit(0);
        // v0.2.4 fell back to count-1 (closed deposit), v0.3.0+ advances to count
        assertEq(staking.stakerActiveDepositStartIndex(alice), _isV030() ? 3 : 2);
    }

    function test_sound_dayBoundaryCannotBeGamedByWithdrawRestake() public {
        _fund(10_000 * ONE);
        _stake(alice, PERIOD_0, 1_000 * ONE);
        _warpBy(5 days + 23 hours);
        vm.prank(alice);
        staking.withdrawDeposit(0);
        assertEq(staking.getUserData(Types.DataType.CLAIM, alice), staking.calculateReward(1_000 * ONE, APY, 5));
    }

    function test_sound_solvencyInvariantHoldsAcrossLifecycle() public {
        _fund(5_000 * ONE);
        _stake(alice, PERIOD_0, 1_000 * ONE);
        _stake(alice, PERIOD_90, 1_000 * ONE);
        _stake(bob, PERIOD_90, 2_000 * ONE);
        _assertSolvent();
        _warpBy(40 days);
        vm.prank(alice);
        staking.claimDeposit(0);
        _assertSolvent();
        vm.prank(bob);
        staking.withdrawDeposit(0);
        _assertSolvent();
        _warpBy(60 days);
        vm.prank(alice);
        staking.claimAll();
        _assertSolvent();
        _collectAll();
        _assertSolvent();
    }

    function test_sound_calculateRewardMonotonicAndRoundsDown() public {
        uint256 prev;
        for (uint256 d = 0; d < 400; d += 7) {
            uint256 r = staking.calculateReward(123_456_789 * 1e12, 7, d);
            assertGe(r, prev);
            prev = r;
        }
        // splitting a deposit never yields more than the whole (rounding favours the protocol)
        uint256 whole = staking.calculateReward(1001, APY, PERIOD_90);
        uint256 split = staking.calculateReward(500, APY, PERIOD_90) + staking.calculateReward(501, APY, PERIOD_90);
        assertGe(whole, split);
    }
}
