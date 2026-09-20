// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {V050Base} from "../../v050/V050Base.sol";
import {StakingLens} from "../../../src/contracts/erc20-periodical-staking/StakingLens.sol";
import {Errors} from "../../../src/common/Errors.sol";
import {Types} from "../../../src/common/Types.sol";
import {AccessControl} from "../../../src/contracts/erc20-periodical-staking/AccessControl.sol";
import {ERC20PeriodicalStaking} from "../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {LimitController} from "../../../src/contracts/LimitController.sol";

/// @notice Regression tests for the staking-contract audit findings. Each began as a PoC that passed while
///         asserting the faulty behaviour; each now asserts the FIXED behaviour (test_fixed<N>_...). #17 and #23
///         were resolved in documentation only, so their tests pin the documented behaviour.
contract StakingFindingsPoC is V050Base {
    // ------------------------------------------------------------------
    // Finding #8: a long-dated voucher used to revert today but become valid in the last maxVoucherValidity
    //             seconds before validUntil. FIXED: issuedAt is signed and the bound is validUntil - issuedAt, so
    //             it is never usable; post-dating issuedAt is rejected; bumpVoucherEpoch voids outstanding vouchers.
    // ------------------------------------------------------------------
    function test_fixed8_longDatedVoucherNeverUsable() public {
        uint256 t0 = _now();
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        v.validUntil = t0 + 365 days; // signed once, "good for a year"
        bytes memory sig = signVoucher(v);
        bytes memory err = abi.encodeWithSelector(Errors.VoucherValidityTooLong.selector, v.validUntil, t0 + 600);

        vm.prank(alice);
        vm.expectRevert(err);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, 0);

        // 365 days later minus the 600s window: the PoC's acceptance point. Same error now.
        vm.warp(v.validUntil - 600);
        vm.prank(alice);
        vm.expectRevert(err);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, 0);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
    }

    function test_fixed8_postDatedIssuedAtRejected() public {
        uint256 t0 = _now();
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        v.issuedAt = t0 + 365 days - 600; // slide the whole window forward instead
        v.validUntil = t0 + 365 days;
        bytes memory sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNotYetValid.selector, v.issuedAt, t0));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, 0);
    }

    function test_fixed8_bumpVoucherEpochVoidsOutstandingVouchers() public {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        assertEq(uint256(staking.voucherEpoch()), 0);

        vm.prank(admin);
        vm.expectRevert(); // owner only
        staking.bumpVoucherEpoch();

        vm.expectEmit(true, true, true, true, address(staking));
        emit UpdateVoucherEpoch(1);
        staking.bumpVoucherEpoch();
        assertEq(uint256(staking.voucherEpoch()), 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherEpochMismatch.selector, 0, 1));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, 0);
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce), "nonce survives");

        // A voucher signed for a FUTURE epoch is no good either.
        v.epoch = 2;
        sig = signVoucher(v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherEpochMismatch.selector, 2, 1));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, 0);

        // The backend reads voucherEpoch() and signs the current value.
        _voucherEpoch = 1;
        uint256 n = stakeFor(alice, P30, 1_000 * ONE);
        assertEq(_deposit(alice, n).amount, 1_000 * ONE);
    }

    // ------------------------------------------------------------------
    // Finding #9: walletBlocked is not a lever against a leaked signer key (the key holder signs for a fresh
    //             wallet). FIXED: an admin can now pull one lever that works -- closeStaking -- and only that one.
    // ------------------------------------------------------------------
    function test_fixed9_adminCanCloseStaking_butOnlyClose() public {
        address mallory2 = makeAddr("mallory2");
        token.transfer(mallory2, 150_000 * ONE);
        vm.prank(mallory2);
        token.approve(address(staking), type(uint256).max);

        // Attacker holds the key: max extras for a brand-new wallet that nobody has blocked.
        uint256 apy = _baseApy(0, P90) + MAX_EXTRA_APY_BPS;
        Types.StakeVoucher memory v = _makeVoucher(mallory2, 0, P90, MAX_EXTRA_APY_BPS, MAX_EXTRA_LIMIT_TOTAL);
        bytes memory sig = signVoucher(v);

        vm.prank(rando);
        vm.expectRevert();
        staking.closeStaking();

        vm.expectEmit(true, true, true, true, address(staking));
        emit UpdateActionAvailability(Types.DataType.STAKING, false); // the same event the owner path emits
        vm.prank(admin);
        staking.closeStaking();
        assertFalse(staking.checkActionAvailability(Types.DataType.STAKING));

        vm.prank(mallory2);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING));
        staking.stakeWithVoucher(v, sig, 150_000 * ONE, apy);

        // Exits are untouched, and the admin can neither reopen nor pull the owner's levers.
        assertTrue(staking.checkActionAvailability(Types.DataType.WITHDRAWAL));
        assertTrue(staking.checkActionAvailability(Types.DataType.CLAIM));
        vm.startPrank(admin);
        vm.expectRevert();
        staking.changeActionAvailability(Types.DataType.STAKING, true);
        vm.expectRevert();
        staking.setVoucherSigner(address(0));
        vm.expectRevert();
        staking.bumpVoucherEpoch();
        vm.stopPrank();

        // Reopening is the owner's call.
        staking.changeActionAvailability(Types.DataType.STAKING, true);
        assertTrue(staking.checkActionAvailability(Types.DataType.STAKING));
    }

    // ------------------------------------------------------------------
    // Finding #10: any admin could unfreeze, so an unfreeze landed before the owner's seize made it revert and
    //              the target walked away. FIXED: unfreezeDeposit / unfreezeDeposits are owner-only.
    // ------------------------------------------------------------------
    function test_fixed10_adminCannotUnfreeze_ownerSeizeLands() public {
        address rogueAdmin = makeAddr("rogueAdmin");
        staking.addContractAdmin(rogueAdmin);

        uint256 n = stakeFor(alice, P30, 10_000 * ONE);
        freeze(alice, n); // honest admin freezes

        bytes memory err =
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER);
        address[] memory ws = new address[](1);
        uint256[] memory ns = new uint256[](1);
        ws[0] = alice;
        ns[0] = n;
        vm.startPrank(rogueAdmin); // tries to front-run the owner's seize
        vm.expectRevert(err);
        staking.unfreezeDeposit(alice, n);
        vm.expectRevert(err);
        staking.unfreezeDeposits(ws, ns);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, alice, n));
        staking.withdrawDeposit(n);

        staking.seizeDeposit(alice, n);
        assertEq(token.balanceOf(treasury), 10_000 * ONE);

        // The owner can still unfreeze, single and batch.
        uint256 m = stakeFor(alice, P30, 1_000 * ONE);
        freeze(alice, m);
        staking.unfreezeDeposit(alice, m);
        freeze(alice, m);
        ns[0] = m;
        staking.unfreezeDeposits(ws, ns);
        assertFalse(staking.isDepositFrozen(alice, m));
    }

    // ------------------------------------------------------------------
    // Finding #16: setLimitController accepted any address. FIXED: a non-zero controller must answer
    //              stakingContract() with this staking contract.
    // ------------------------------------------------------------------
    function test_fixed16_setLimitControllerChecksStakingContract() public {
        ERC20PeriodicalStaking other = new ERC20PeriodicalStaking(address(token));
        LimitController foreign = new LimitController(address(other));

        vm.expectRevert(abi.encodeWithSelector(Errors.LimitControllerMismatch.selector, address(other)));
        staking.setLimitController(address(foreign));
        vm.expectRevert(); // EOA: no code
        staking.setLimitController(rando);
        vm.expectRevert(); // a contract without stakingContract()
        staking.setLimitController(address(token));
        assertEq(staking.limitController(), address(controller), "unchanged");

        // A controller actually built for this staking contract is accepted; address(0) still unsets.
        // (`foreign` can no longer be re-pointed: stakingContract is immutable, finding #16.)
        LimitController rebuilt = new LimitController(address(staking));
        staking.setLimitController(address(rebuilt));
        assertEq(staking.limitController(), address(rebuilt));
        staking.setLimitController(address(0));
        assertEq(staking.limitController(), address(0));
    }

    // ------------------------------------------------------------------
    // Finding #17: minReward is only enforced in the shortfall branch. Pool sufficient + accrued < minReward
    //              => withdrawDepositPartial succeeds and pays less than minReward.
    //              RESOLVED IN DOCS (behaviour unchanged): the NatSpec now says minReward is a floor for a
    //              REDUCED payout only. This pins the documented behaviour, both branches.
    // ------------------------------------------------------------------
    function test_fixed17_minRewardIsAShortfallFloorOnly() public {
        uint256 n = stakeFor(alice, P0, 1_000 * ONE);
        _warpDays(10);
        uint256 accrued = staking.calculateReward(1_000 * ONE, APY_P0, 10); // ~1.37 tokens
        uint256 minReward = 1_000 * ONE;
        assertLt(accrued, minReward);
        assertGt(staking.getCollectableReward(), accrued, "pool is sufficient");

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdrawDepositPartial(n, minReward); // pool covers the accrued reward: minReward not consulted
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + accrued, "paid the full accrued reward");

        // Shortfall branch: the floor IS enforced, and accepting a reduced payout forfeits the remainder.
        uint256 m = stakeFor(bob, P0, 100_000 * ONE);
        _warpDays(365);
        staking.collectReward(staking.getCollectableReward() - 10 * ONE); // leave 10 tokens free
        uint256 owed = staking.calculateReward(100_000 * ONE, APY_P0, 365);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, owed, 10 * ONE));
        staking.withdrawDepositPartial(m, 10 * ONE + 1);
        before = token.balanceOf(bob);
        vm.prank(bob);
        staking.withdrawDepositPartial(m, 10 * ONE);
        assertEq(token.balanceOf(bob) - before, 100_000 * ONE + 10 * ONE, "reduced payout; the rest is forfeited");
    }

    // ------------------------------------------------------------------
    // Finding #19: unbounded setters. FIXED: APY <= 1_000_000 bps and period <= 36_500 days wherever they enter,
    //              setMaxExtraApyBps <= 1_000_000, and the lens saturates instead of reverting.
    // ------------------------------------------------------------------
    uint256 internal constant MAX_APY = 1_000_000;
    uint256 internal constant MAX_PERIOD = 36_500;

    function _tooHigh(uint256 value, uint256 max) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Errors.ValueTooHigh.selector, value, max);
    }

    /// (a) base APY is bounded in all three entry points; the largest base + largest extra still stakes.
    function test_fixed19a_apyBoundedEverywhere() public {
        vm.expectRevert(_tooHigh(MAX_APY + 1, MAX_APY));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, MAX_APY + 1);
        vm.expectRevert(_tooHigh(type(uint32).max, MAX_APY));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, type(uint32).max);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAPY.selector, 0, 1));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 0);

        uint256[] memory apys = _fill(3, 1_000);
        apys[2] = MAX_APY + 1;
        vm.expectRevert(_tooHigh(MAX_APY + 1, MAX_APY));
        staking.pushStakingPhase(apys, _fill(3, TARGET));

        vm.expectRevert(_tooHigh(MAX_APY + 1, MAX_APY));
        staking.addStakingPeriod(180, _fill(2, MAX_APY + 1), _fill(2, TARGET));

        vm.expectRevert(_tooHigh(MAX_APY + 1, MAX_APY));
        staking.setMaxExtraApyBps(MAX_APY + 1);

        // A STAKING_TARGET is not an APY: still unbounded ("unlimited" = uint256.max).
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, type(uint256).max);

        // The extremes are accepted and a stake at base max + extra max fits the deposit's uint32 apyBps.
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, MAX_APY);
        staking.setMaxExtraApyBps(MAX_APY);
        uint256 n = stakeWith(alice, P30, 1_000 * ONE, MAX_APY, 0);
        assertEq(_deposit(alice, n).APY, 2 * MAX_APY);
    }

    /// (b) a period above 36_500 days is refused -- also when no phase exists yet -- and the largest one stakes.
    function test_fixed19b_periodBounded() public {
        vm.expectRevert(_tooHigh(13_000_000, MAX_PERIOD));
        staking.addStakingPeriod(13_000_000, _fill(2, 1_000), _fill(2, TARGET));
        vm.expectRevert(_tooHigh(MAX_PERIOD + 1, MAX_PERIOD));
        staking.addStakingPeriod(MAX_PERIOD + 1, _fill(2, 1), _fill(2, TARGET));

        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        vm.expectRevert(_tooHigh(MAX_PERIOD + 1, MAX_PERIOD));
        fresh.addStakingPeriod(MAX_PERIOD + 1, new uint256[](0), new uint256[](0));

        staking.addStakingPeriod(MAX_PERIOD, _fill(2, 1_000), _fill(2, TARGET));
        controller.setDefaultLimit(0, MAX_PERIOD, DEFAULT_LIMIT);
        uint256 n = stakeFor(alice, MAX_PERIOD, 1_000 * ONE);
        assertEq(_deposit(alice, n).stakingEndDate, _now() + MAX_PERIOD * 1 days);
    }

    /// (c) STAKING_TARGET = uint256.max ("unlimited") no longer takes the lens views down: they saturate.
    function test_fixed19c_lensSaturatesOnUnlimitedTargets() public {
        StakingLens lens = _lens(staking);
        for (uint256 phase = 0; phase < 2; phase++) {
            staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, phase, P30, type(uint256).max);
            staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, phase, P90, type(uint256).max);
        }
        // The PoC's breaking cell: 730 days at 60% APY, 6_000 * 730 > 3_650_000 => the cell's reward overflows.
        staking.addStakingPeriod(730, _fill(2, 6_000), _fill(2, type(uint256).max));
        assertEq(lens.getRewardRequiredForTargets(), type(uint256).max, "saturated, not reverted");
        assertEq(lens.getRewardPoolShortfall(), type(uint256).max - staking.getCollectableReward());

        // Every cell fits on its own but the running SUM overflows: saturates as well.
        staking.removeStakingPeriod(730);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 100_000);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 1, P30, 100_000);
        assertEq(lens.getRewardRequiredForTargets(), type(uint256).max, "sum saturated");
        lens.getRewardPoolShortfall();
    }

    // ------------------------------------------------------------------
    // Finding #23: bonus attribution is fixed at stake time. Raising the controller limit afterwards does not
    //              move already-charged bonus back to the budget, so other cells see less bonus than expected.
    //              No over-grant: the wallet-wide aggregate is exactly sum(allowed) + extraLimitTotal.
    //              RESOLVED IN DOCS (behaviour unchanged, now documented on depositBonusUsed and
    //              stakeWithVoucher). This pins it, including that the bonus frees when the deposit closes.
    // ------------------------------------------------------------------
    function test_fixed23_bonusStaysChargedAfterLimitRaise_freesOnClose() public {
        token.transfer(alice, 200_000 * ONE);
        uint256 extra = MAX_EXTRA_LIMIT_TOTAL; // 50k

        stakeWith(alice, P30, 120_000 * ONE, 0, extra); // 100k base + 20k bonus
        (uint256 usedTotal, uint256 usedCell) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, 20_000 * ONE);

        // Ops raises alice's P30 limit so the whole 120k now fits in base.
        controller.setWalletLimit(alice, 0, P30, 200_000 * ONE);
        (usedTotal, usedCell) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, 20_000 * ONE, "bonus still charged although the stake is now entirely within base");
        assertEq(usedCell, 20_000 * ONE);

        // P90: alice expects 100k base + 50k bonus, gets only 100k + 30k.
        uint256 apy = _baseApy(0, P90);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P90, 0, extra);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.StakingLimitExceeded.selector, alice, 0, P90, 150_000 * ONE, 130_000 * ONE
            )
        );
        staking.stakeWithVoucher(v, sig, 150_000 * ONE, apy);
        stakeWith(alice, P90, 130_000 * ONE, 0, extra);

        // No over-grant: the "stuck" 20k shows up as extra base room in P30 (200k - (120k - 20k) = 100k)...
        stakeWith(alice, P30, 100_000 * ONE, 0, extra);
        // ...and then everything is exhausted: 220k + 130k = 200k + 100k + 50k.
        apy = _baseApy(0, P30);
        (v, sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, extra);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 100, 0)
        );
        staking.stakeWithVoucher(v, sig, 100, apy);
        (usedTotal,) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, extra, "bonus held never exceeds the voucher budget");
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), 350_000 * ONE);

        // Closing the deposit that holds the 20k frees it.
        vm.prank(alice);
        staking.withdrawDeposit(0);
        (usedTotal, usedCell) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, extra - 20_000 * ONE, "freed when the deposit closed");
        assertEq(usedCell, 0);
    }
}
