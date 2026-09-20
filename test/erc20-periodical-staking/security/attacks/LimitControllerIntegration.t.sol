// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";
import {LimitController} from "../../../../src/contracts/LimitController.sol";
import {ILimitController} from "../../../../src/interfaces/ILimitController.sol";
import {IPeriodicalStakingContract} from "../../../../src/interfaces/IPeriodicalStakingContract.sol";
import {MockLegacyStaking} from "../../../shared/mocks/MockLegacyStaking.sol";

/// @notice Controller that returns fixed (possibly hostile) figures, to attack the stake-side headroom math.
contract FixedLimitController is ILimitController {
    uint256 public allowed;
    uint256 public used;
    /// @dev setLimitController only installs a controller whose stakingContract() is the staking contract.
    IPeriodicalStakingContract public immutable stakingContract;

    constructor(address staking_) {
        stakingContract = IPeriodicalStakingContract(staking_);
    }

    function set(uint256 allowed_, uint256 used_) external {
        allowed = allowed_;
        used = used_;
    }

    function getAllowedAndUsed(address, uint256, uint256) external view returns (uint256, uint256) {
        return (allowed, used);
    }

    function getRemaining(address, uint256, uint256) external view returns (uint256) {
        return used >= allowed ? 0 : allowed - used;
    }

    function getRemainingBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (uint256[] memory)
    {
        return new uint256[](wallets.length);
    }

    function getAllowedBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (uint256[] memory)
    {
        return new uint256[](wallets.length);
    }
}

/// @title LimitControllerIntegration
/// @notice Wallet-limit semantics (especially the "0 means default" ambiguity), limit changes after deposits,
///         batch validation, controllers pointed at the wrong staking contract, the voucher's extraLimit, legacy
///         stake counting, and hostile controller figures.
contract LimitControllerIntegrationTest is VoucherAttackBase {
    LimitController internal lc;

    function setUp() public override {
        super.setUp();
        lc = new LimitController(address(staking));
        staking.setLimitController(address(lc));
        // default: 10k per wallet per cell
        for (uint256 ph = 0; ph < 2; ph++) {
            for (uint256 i = 0; i < PERIODS.length; i++) {
                lc.setDefaultLimit(ph, PERIODS[i], 10_000 * ONE);
            }
        }
    }

    function _limitErr(address w, uint256 phase, uint256 period, uint256 requested, uint256 headroom)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, w, phase, period, requested, headroom);
    }

    /// @dev Hypothesis: a wallet explicitly limited to 0 ("0 means no staking allowed" per NatSpec) can still stake
    ///      because getAllowed falls back to the default when the wallet limit is 0.
    function test_walletLimitZero_blocksWallet() public {
        lc.setWalletLimit(alice, 0, P30, 0);
        assertEq(lc.getAllowed(alice, 0, P30), 0, "explicit 0 wallet limit must mean 0");
        _expectStakeRevert(alice, 0, P30, 1_000 * ONE, _apy(0, P30), _limitErr(alice, 0, P30, 1_000 * ONE, 0));
    }

    /// @dev Hypothesis: with default 0 and no wallet limit, staking is blocked with exact figures.
    function test_defaultZero_noWalletLimit_blocked() public {
        lc.setDefaultLimit(0, P90, 0);
        _expectStakeRevert(alice, 0, P90, 1_000 * ONE, _apy(0, P90), _limitErr(alice, 0, P90, 1_000 * ONE, 0));
        lc.setWalletLimit(alice, 0, P90, 500 * ONE);
        _expectStakeRevert(
            alice, 0, P90, 1_000 * ONE, _apy(0, P90), _limitErr(alice, 0, P90, 1_000 * ONE, 500 * ONE)
        );
        _stake(alice, 0, P90, 500 * ONE);
    }

    /// @dev Hypothesis: lowering a limit below the staked amount underflows getRemaining / the stake headroom, or
    ///      blocks closing. The saturation is still asserted; what changed is that a voucher bonus is NOT
    ///      cancelled by the overshoot -- an operator tightening a limit must not confiscate unspent budget.
    // BEHAVIOUR CHANGE, 2026-09-18, v0.4.0 bonus-budget rework: the voucher bonus is INDEPENDENT headroom on top
    // of the base allowance, not something an overshoot eats into. Previously a wallet whose stake already sat
    // above its controller limit arrived with part of its VIP perk silently spent -- on day one, for exactly the
    // users most likely to be VIPs. Do not restore the old `allowed + extra - used` assertions.
    function test_limitLoweredBelowStaked_noUnderflow_closingWorks() public {
        uint256 d = _stake(alice, 0, P30, 8_000 * ONE);
        lc.setWalletLimit(alice, 0, P30, 5_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 0);
        (uint256 allowed, uint256 used) = lc.getAllowedAndUsed(alice, 0, P30);
        assertEq(allowed, 5_000 * ONE);
        assertEq(used, 8_000 * ONE);
        uint256 apy = _apy(0, P30);
        _expectStakeRevert(alice, 0, P30, 100, apy, _limitErr(alice, 0, P30, 100, 0));

        // A voucher bonus survives the tightening in full: base room is 0, the 2,000 budget is untouched.
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 2_000 * ONE);
        vm.prank(alice);
        vm.expectRevert(_limitErr(alice, 0, P30, 2_000 * ONE + 1, 2_000 * ONE));
        staking.stakeWithVoucher(v, sig, 2_000 * ONE + 1, apy);

        _warpDays(30);
        _claim(alice, d);
        assertEq(lc.getRemaining(alice, 0, P30), 5_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: raising the limit after a deposit does not open new headroom.
    function test_limitRaised_afterDeposit_allowsExactlyMore() public {
        _stake(alice, 0, P30, 10_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 0);
        lc.setWalletLimit(alice, 0, P30, 12_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 2_000 * ONE);
        _expectStakeRevert(
            alice, 0, P30, 2_000 * ONE + 1, _apy(0, P30), _limitErr(alice, 0, P30, 2_000 * ONE + 1, 2_000 * ONE)
        );
        _stake(alice, 0, P30, 2_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 0);
    }

    /// @dev Hypothesis: the voucher's extraLimit leaks into later stakes, or is measured against the base limit
    ///      instead of total usage. It is per-stake headroom on top of (allowed - used), never stored.
    function test_voucherExtraLimit_exactHeadroom_perStakeOnly() public {
        uint256 apy = _apy(0, P30);
        _stake(alice, 0, P30, 10_000 * ONE); // default limit exhausted

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 3_000 * ONE);
        vm.prank(alice);
        vm.expectRevert(_limitErr(alice, 0, P30, 3_000 * ONE + 1, 3_000 * ONE));
        staking.stakeWithVoucher(v, sig, 3_000 * ONE + 1, apy);
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 3_000 * ONE, apy);

        // not persistent: a plain voucher has no headroom left
        _expectStakeRevert(alice, 0, P30, 100, apy, _limitErr(alice, 0, P30, 100, 0));

        // a later extra is measured against total usage (13k): 10k + 5k - 13k = 2k
        (v, sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 5_000 * ONE);
        vm.prank(alice);
        vm.expectRevert(_limitErr(alice, 0, P30, 2_000 * ONE + 1, 2_000 * ONE));
        staking.stakeWithVoucher(v, sig, 2_000 * ONE + 1, apy);

        // the controller views never include voucher extras
        assertEq(lc.getRemaining(alice, 0, P30), 0);
        (, uint256[][] memory rem) = _lens(staking).getPhasePeriodUserData(alice);
        assertEq(rem[0][1], 0);
        _assertAccounting();
    }

    /// @dev Fuzz: for any wallet limit, voucher bonus and legacy stake, a stake is accepted iff
    ///      amount <= max(0, limit - legacyStake) + extra, and the revert reports exactly that headroom.
    // BEHAVIOUR CHANGE, 2026-09-18, v0.4.0 bonus-budget rework: the voucher bonus is INDEPENDENT headroom on top
    // of the base allowance, not something an overshoot eats into. Previously a wallet whose stake already sat
    // above its controller limit arrived with part of its VIP perk silently spent -- on day one, for exactly the
    // users most likely to be VIPs. Do not restore the old `allowed + extra - used` assertions.
    function testFuzz_headroom_baseRoomPlusBonus(uint256 limit, uint256 extra, uint256 legacyAmt, uint256 amount)
        public
    {
        limit = bound(limit, 0, 100_000 * ONE);
        extra = bound(extra, 0, 50_000 * ONE);
        legacyAmt = bound(legacyAmt, 0, 150_000 * ONE);
        amount = bound(amount, 100, 50_000 * ONE);

        MockLegacyStaking legacy = new MockLegacyStaking();
        lc.setLegacyStakingContract(address(legacy));
        legacy.setStaked(alice, 0, P0, legacyAmt);
        lc.setWalletLimit(alice, 0, P0, limit);

        uint256 baseRoom = legacyAmt >= limit ? 0 : limit - legacyAmt;
        uint256 headroom = baseRoom + extra;
        uint256 apy = _apy(0, P0);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P0, 0, extra);

        if (amount > headroom) {
            vm.prank(alice);
            vm.expectRevert(_limitErr(alice, 0, P0, amount, headroom));
            staking.stakeWithVoucher(v, sig, amount, apy);
            assertEq(_upp(Types.DataType.STAKING, alice, 0, P0), 0);
        } else {
            vm.prank(alice);
            staking.stakeWithVoucher(v, sig, amount, apy);
            assertEq(_upp(Types.DataType.STAKING, alice, 0, P0), amount);
            (, uint256 used) = lc.getAllowedAndUsed(alice, 0, P0);
            assertEq(used, legacyAmt + amount, "used = new contract + legacy");
        }
    }

    /// @dev Hypothesis: legacy stake is remapped to other phases/periods, leaks between cells, or an unknown
    ///      legacy phase/period reverts. It counts only in the SAME (phase, period) and unknown cells read 0.
    function test_legacyStake_sameCellOnly_unknownCellsNeverRevert() public {
        MockLegacyStaking legacy = new MockLegacyStaking();
        lc.setLegacyStakingContract(address(legacy));
        legacy.setStaked(alice, 0, P30, 8_000 * ONE);
        legacy.setStaked(alice, 7, 365, 1_000_000 * ONE); // a phase/period the new contract never had

        _expectStakeRevert(
            alice, 0, P30, 2_000 * ONE + 1, _apy(0, P30), _limitErr(alice, 0, P30, 2_000 * ONE + 1, 2_000 * ONE)
        );
        _stake(alice, 0, P30, 2_000 * ONE);
        _stake(alice, 0, P90, 10_000 * ONE); // other period untouched by legacy
        staking.changeStakingPhase(1);
        _stake(alice, 1, P30, 10_000 * ONE); // other phase untouched by legacy

        (uint256 allowed, uint256 used) = lc.getAllowedAndUsed(alice, 7, 365);
        assertEq(allowed, 0);
        assertEq(used, 1_000_000 * ONE);
        (allowed, used) = lc.getAllowedAndUsed(bob, 99, 12345);
        assertEq(allowed + used, 0, "unknown cell reads 0 in both contracts");

        (, uint256[][] memory rem) = _lens(staking).getPhasePeriodUserData(alice);
        assertEq(rem[0][1], 0, "phase 0 / P30 full (8k legacy + 2k new)");
        assertEq(rem[0][0], 10_000 * ONE, "phase 0 / P0 untouched");
        assertEq(rem[1][1], 0);

        vm.expectRevert(abi.encodeWithSelector(LimitController.SameStakingAndLegacyContract.selector, address(staking)));
        lc.setLegacyStakingContract(address(staking));

        lc.setLegacyStakingContract(address(0));
        assertEq(lc.getRemaining(alice, 0, P30), 8_000 * ONE, "without legacy only the new 2k counts");
        _assertAccounting();
    }

    /// @dev Hypothesis: batch length mismatches are silently accepted somewhere.
    function test_batchLengthMismatch_exactErrors() public {
        address[] memory w = new address[](2);
        uint256[] memory one = new uint256[](1);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.getRemainingBatch(w, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.getRemainingBatch(w, two, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.getAllowedBatch(w, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.setWalletLimits(w, 0, P30, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.setDefaultLimits(two, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.setDefaultLimits(two, two, one);
        // staking side batch getter
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        staking.getUserPhasePeriodDataBatch(Types.DataType.STAKING, w, one, two);
        // only STAKING is tracked per cell; other types are refused rather than silently reading 0
        vm.expectRevert(Errors.InvalidDataType.selector);
        staking.getUserPhasePeriodDataBatch(Types.DataType.CLAIM, w, two, two);
        vm.expectRevert(Errors.InvalidDataType.selector);
        staking.getUserPhasePeriodData(Types.DataType.WITHDRAWAL, alice, 0, P30);
    }

    /// @dev Hypothesis: a controller pointed at the wrong staking contract lets a wallet exceed its limit.
    ///      Finding #16: that state is now unreachable for an INSTALLED controller -- stakingContract is
    ///      immutable, so a mismatched controller can only be built, never made out of a matching one, and
    ///      setLimitController refuses to install it. Swapping in a correctly-built replacement must
    ///      immediately account for what is already staked.
    function test_controllerPointingAtWrongStaking_cannotBeInstalledAndSwapKeepsEnforcement() public {
        ERC20PeriodicalStaking other = new ERC20PeriodicalStaking(address(token));
        LimitController wrong = new LimitController(address(other));

        // A controller built for another staking contract cannot be installed at all.
        vm.expectRevert(abi.encodeWithSelector(Errors.LimitControllerMismatch.selector, address(other)));
        staking.setLimitController(address(wrong));
        // ...and it can never become a matching one: there is no setter.
        (bool ok,) =
            address(wrong).call(abi.encodeWithSignature("setStakingContract(address)", address(staking)));
        assertFalse(ok, "setStakingContract must no longer exist");
        assertEq(address(wrong.stakingContract()), address(other));

        // The installed controller keeps enforcing across a swap to a fresh, correctly-built one.
        _stake(alice, 0, P30, 10_000 * ONE);
        LimitController replacement = new LimitController(address(staking));
        replacement.setDefaultLimit(0, P30, 10_000 * ONE);
        staking.setLimitController(address(replacement));
        assertEq(replacement.getRemaining(alice, 0, P30), 0, "existing stake must count for the replacement");
        _expectStakeRevert(alice, 0, P30, 100, _apy(0, P30), _limitErr(alice, 0, P30, 100, 0));

        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        new LimitController(address(0));
    }

    /// @dev Hypothesis: a limit on one (phase, period) leaks into another cell.
    function test_limitIsPerCell() public {
        lc.setWalletLimit(alice, 0, P30, 1);
        _expectStakeRevert(alice, 0, P30, 1_000 * ONE, _apy(0, P30), _limitErr(alice, 0, P30, 1_000 * ONE, 1));
        _stake(alice, 0, P90, 1_000 * ONE);
        _stake(alice, 0, P0, 1_000 * ONE);
        staking.changeStakingPhase(1);
        _stake(alice, 1, P30, 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a generous wallet limit bypasses the period target (or vice versa). Both must be enforced.
    function test_limitAndTarget_bothEnforced() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, 5_000 * ONE);
        lc.setWalletLimit(alice, 0, P30, 100_000 * ONE);
        _expectStakeRevert(
            alice,
            0,
            P30,
            6_000 * ONE,
            _apy(0, P30),
            abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P30, 5_000 * ONE)
        );
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, TARGET);
        lc.setWalletLimit(alice, 0, P30, 5_000 * ONE);
        _expectStakeRevert(
            alice, 0, P30, 6_000 * ONE, _apy(0, P30), _limitErr(alice, 0, P30, 6_000 * ONE, 5_000 * ONE)
        );
        _stake(alice, 0, P30, 5_000 * ONE);
    }

    /// @dev Documented semantics: the limit is on live stake, not lifetime; withdraw frees headroom.
    function test_limitIsLiveStake_withdrawFreesHeadroom() public {
        uint256 d = _stake(alice, 0, P0, 10_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P0), 0);
        _withdraw(alice, d);
        assertEq(lc.getRemaining(alice, 0, P0), 10_000 * ONE);
        _stake(alice, 0, P0, 10_000 * ONE);
        assertEq(_user(Types.DataType.STAKING, alice), 10_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: freezing frees the limit (letting a frozen wallet stake around it), or seizing leaves the
    ///      seized amount counted forever. Frozen stake still counts; a seize frees it like any close.
    function test_limitCountsFrozenStake_seizeFreesHeadroom() public {
        uint256 d = _stake(alice, 0, P0, 10_000 * ONE);
        _freeze(alice, d);
        assertEq(lc.getRemaining(alice, 0, P0), 0, "frozen stake still counts");
        _expectStakeRevert(alice, 0, P0, 100, _apy(0, P0), _limitErr(alice, 0, P0, 100, 0));
        _seize(alice, d);
        assertEq(lc.getRemaining(alice, 0, P0), 10_000 * ONE, "seized stake no longer counts");
        // whether a seized wallet may stake again is the backend's call (it issues the vouchers)
        _stake(alice, 0, P0, 10_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: getPhasePeriodUserData disagrees with the controller's per-cell answers.
    function test_userDataView_matchesController() public {
        lc.setWalletLimit(alice, 0, P90, 3_000 * ONE);
        _stake(alice, 0, P90, 1_000 * ONE);
        _stake(alice, 0, P30, 4_000 * ONE);
        (uint256[][] memory limits, uint256[][] memory rem) = _lens(staking).getPhasePeriodUserData(alice);
        for (uint256 ph = 0; ph < 2; ph++) {
            for (uint256 i = 0; i < PERIODS.length; i++) {
                assertEq(limits[ph][i], lc.getAllowed(alice, ph, PERIODS[i]));
                assertEq(rem[ph][i], lc.getRemaining(alice, ph, PERIODS[i]));
            }
        }
        assertEq(rem[0][2], 2_000 * ONE);
        assertEq(rem[0][1], 6_000 * ONE);
    }

    /// @dev v0.3.0 fell back to target-based headroom with no controller, handing one wallet the whole pool.
    ///      v0.4.0: no controller => no staking (typed error), the view is zero-filled, exits are unaffected.
    function test_controllerUnset_noWholePoolFallback() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        staking.setLimitController(address(0));
        _expectStakeRevert(
            bob, 0, P30, TARGET / 2, _apy(0, P30), abi.encodeWithSelector(Errors.LimitControllerNotSet.selector)
        );
        (uint256[][] memory limits, uint256[][] memory rem) = _lens(staking).getPhasePeriodUserData(alice);
        assertEq(limits[0][1], 0);
        assertEq(rem[0][1], 0);
        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: hostile controller figures (max allowed, max used, baseRoom + bonus overflowing) make the
    ///      stake-side headroom math wrap or panic. It must saturate: headroom caps at max, base room floors at 0.
    // BEHAVIOUR CHANGE, 2026-09-18, v0.4.0 bonus-budget rework: the voucher bonus is INDEPENDENT headroom on top
    // of the base allowance, not something an overshoot eats into. Previously a wallet whose stake already sat
    // above its controller limit arrived with part of its VIP perk silently spent -- on day one, for exactly the
    // users most likely to be VIPs. Do not restore the old `allowed + extra - used` assertions.
    function test_hostileControllerFigures_overflowSafe() public {
        FixedLimitController f = new FixedLimitController(address(staking));
        staking.setLimitController(address(f));
        uint256 apy = _apy(0, P0);
        uint256 bigExtra = type(uint128).max;

        f.set(type(uint256).max, 0);
        _stakeVWith(staking, alice, 0, P0, 1_000 * ONE, 0, bigExtra); // allowed + extra would overflow
        f.set(type(uint256).max - 1, 0);
        _stakeVWith(staking, alice, 0, P0, 1_000 * ONE, 0, bigExtra);

        // allowed == used == max: base room saturates to 0 (no underflow). With NO bonus there is no headroom.
        f.set(type(uint256).max, type(uint256).max);
        _expectStakeRevert(alice, 0, P0, 1_000 * ONE, apy, _limitErr(alice, 0, P0, 1_000 * ONE, 0));

        // Same figures WITH a bonus: the bonus is independent of the overshoot, so it is the whole headroom, and
        // `baseRoom + bonusLeft` must saturate rather than wrap.
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P0, 0, bigExtra);
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        (uint256 spentTotal,) = staking.getBonusUsage(alice, 0, P0);
        assertEq(spentTotal, 1_000 * ONE, "the whole stake came out of the bonus");

        f.set(0, type(uint256).max);
        _expectStakeRevert(alice, 0, P0, 1_000 * ONE, apy, _limitErr(alice, 0, P0, 1_000 * ONE, 0));

        // Ordinary small figures, on a FRESH wallet. Bob has to be used here rather than alice: since the
        // 2026-09-18 two-meter fix, `baseUsed` is `used - walletBonusUsedInCell[phase][period][wallet]`, and
        // alice is holding 1,000 RMV of bonus in this very cell from the stake above. The fake controller
        // reports used == 3 while 1,000 RMV is really staked, so the subtraction saturates to 0 and baseRoom
        // becomes the whole `allowed`. That is a lying controller meeting a real meter -- a different thing
        // from the overflow safety this test is named for. Bob's meter is 0, so `allowed - used` is the answer.
        f.set(5, 3);
        _expectStakeRevert(bob, 0, P0, 100, apy, _limitErr(bob, 0, P0, 100, 2));
        assertEq(staking.checkDepositCountOfAddress(alice), 3);
        _assertAccounting();
    }

    /// @dev Fuzz: remaining never exceeds allowed and never underflows for any (limit, staked) pair.
    function testFuzz_remaining_neverExceedsAllowed(uint256 walletLimit, uint256 defaultLimit, uint256 stakeAmt)
        public
    {
        walletLimit = bound(walletLimit, 0, 50_000 * ONE);
        defaultLimit = bound(defaultLimit, 0, 50_000 * ONE);
        stakeAmt = bound(stakeAmt, 100, 50_000 * ONE);
        lc.setDefaultLimit(0, P0, defaultLimit);
        lc.setWalletLimit(alice, 0, P0, walletLimit);
        uint256 allowed = lc.getAllowed(alice, 0, P0);
        uint256 remaining = lc.getRemaining(alice, 0, P0);
        assertEq(remaining, allowed);
        bool ok = _tryStake(alice, 0, P0, stakeAmt);
        assertEq(ok, stakeAmt <= remaining, "stake acceptance must match remaining");
        uint256 after_ = lc.getRemaining(alice, 0, P0);
        assertLe(after_, allowed);
        if (ok) assertEq(after_, allowed - stakeAmt);
    }

    /// @dev Hypothesis: the controller's owner (not the staking owner) is a separate trust root; the staking
    ///      owner cannot change limits, the controller owner cannot touch staking.
    function test_separateOwners_noCrossPrivilege() public {
        LimitController lc2 = new LimitController(address(staking));
        vm.prank(bob);
        vm.expectRevert();
        lc2.setDefaultLimit(0, P30, 1);
        vm.prank(bob);
        vm.expectRevert();
        lc2.setLegacyStakingContract(address(0));
        // controller address has no staking privileges
        vm.prank(address(lc2));
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setLimitController(address(0));
    }
}
