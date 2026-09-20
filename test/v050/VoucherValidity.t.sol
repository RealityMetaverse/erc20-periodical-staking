// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";
import {AccessControl} from "../../src/contracts/erc20-periodical-staking/AccessControl.sol";

/// @notice `maxVoucherValidity`: an on-chain ceiling on a voucher's SIGNED LIFETIME, validUntil - issuedAt.
///
///         Both ends are signed (audit finding #8 added `issuedAt`), so the bound is on the voucher itself, not
///         on the moment it is presented:
///             issuedAt   >  now                        -> VoucherNotYetValid   (post-dating is rejected)
///             validUntil <  now                        -> VoucherExpired
///             validUntil >  issuedAt + ceiling         -> VoucherValidityTooLong
///             otherwise                                -> accepted
///         Before #8 the bound was relative to NOW, so a voucher signed "good for a year" reverted today but
///         became usable in the last `ceiling` seconds before its validUntil. It is now never usable.
///         This bounds vouchers the backend signed honestly. It does not contain a leaked signer key -- the key
///         holder signs fresh short-lived vouchers -- which is what bumpVoucherEpoch / setVoucherSigner /
///         closeStaking are for.
///
/// @dev The contract's constructor default is 1800 seconds, matching the maximum the backend's
///      `validity_seconds` can be configured to, so the default can never reject a voucher the real signer is
///      capable of producing. V050Base sets it explicitly anyway.
contract VoucherValidityTest is V050Base {
    uint256 internal constant AMOUNT = 1_000 * ONE;
    uint256 internal constant CEILING = VOUCHER_LIFETIME; // what V050Base.setUp configured

    function setUp() public override {
        super.setUp();
        // Away from timestamp 1 so "now - 1" is a meaningful validUntil.
        vm.warp(1_700_000_000);
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    /// @dev Issued now.
    function _voucherUntil(address wallet, uint256 until, uint256 nonce)
        internal
        view
        returns (Types.StakeVoucher memory)
    {
        return _voucherIssued(wallet, _now(), until, nonce);
    }

    function _voucherIssued(address wallet, uint256 issuedAt, uint256 until, uint256 nonce)
        internal
        pure
        returns (Types.StakeVoucher memory)
    {
        return Types.StakeVoucher({
            wallet: wallet,
            phase: 0,
            period: P30,
            extraApyBps: 0,
            extraLimitTotal: 0,
            extraLimitPerCell: 0,
            issuedAt: issuedAt,
            validUntil: until,
            epoch: 0,
            nonce: nonce
        });
    }

    function _stake(Types.StakeVoucher memory v) internal returns (uint256) {
        bytes memory sig = signVoucher(v);
        uint256 apy = _baseApy(0, P30);
        vm.prank(v.wallet);
        return staking.stakeWithVoucher(v, sig, AMOUNT, apy);
    }

    function _expectStakeRevert(Types.StakeVoucher memory v, bytes memory err) internal {
        bytes memory sig = signVoucher(v);
        uint256 apy = _baseApy(0, P30);
        vm.prank(v.wallet);
        vm.expectRevert(err);
        staking.stakeWithVoucher(v, sig, AMOUNT, apy);
    }

    // ======================================================================
    // =                        The ceiling itself                          =
    // ======================================================================

    /// @notice A voucher inside the ceiling stakes normally, right up to the last permitted second.
    /// @dev Kills an off-by-one that would reject the exact ceiling. The backend issues at its configured
    ///      window, so if `now + ceiling` were rejected, every voucher issued at the maximum window would fail
    ///      and the outage would look like a signing bug.
    function test_withinCeilingStakesNormally() external {
        uint256 n = _stake(_voucherUntil(alice, _now() + CEILING - 1, 0));
        assertEq(_deposit(alice, n).amount, AMOUNT);

        // Exactly on the ceiling is accepted.
        uint256 n2 = _stake(_voucherUntil(alice, _now() + CEILING, 1));
        assertEq(_deposit(alice, n2).amount, AMOUNT);
    }

    /// @notice One second past the ceiling reverts, and the nonce is NOT burned.
    /// @dev Two mutations killed. First, dropping or inverting the bound. Second, and more subtly, moving the
    ///      nonce write above the validity check: a rejected voucher must remain usable, otherwise anyone who
    ///      could get a wallet to submit one over-dated voucher would permanently burn that nonce. The proof is
    ///      that raising the ceiling makes the SAME signed voucher work -- no re-issuance needed.
    function test_beyondCeilingReverts_andKeepsTheNonce() external {
        uint256 tooFar = _now() + CEILING + 1;
        Types.StakeVoucher memory v = _voucherUntil(alice, tooFar, 7);

        _expectStakeRevert(
            v, abi.encodeWithSelector(Errors.VoucherValidityTooLong.selector, tooFar, _now() + CEILING)
        );
        assertFalse(staking.isVoucherNonceUsed(alice, 7), "a rejected voucher must not burn its nonce");
        assertEq(staking.checkDepositCountOfAddress(alice), 0);

        // Same voucher, same signature, wider ceiling: it works. The nonce really did survive.
        staking.setMaxVoucherValidity(CEILING + 1);
        _stake(v);
        assertTrue(staking.isVoucherNonceUsed(alice, 7), "nonce burned only on the successful stake");
    }

    /// @notice The ceiling is measured from the SIGNED issuedAt, so ageing a voucher never changes the verdict.
    /// @dev A voucher issued at the full ceiling and presented with one second left on it must still pass: its
    ///      lifetime is exactly the ceiling whenever it is presented. Kills an implementation that compares the
    ///      ceiling against `now` on top of issuedAt, which would make every voucher unusable as it aged and
    ///      stop the backend using its own window as the ceiling.
    function test_ceilingIsRelativeToIssuance_agedVoucherStillGood() external {
        uint256 until = _now() + CEILING;
        Types.StakeVoucher memory v = _voucherUntil(alice, until, 3);
        bytes memory sig = signVoucher(v);

        // Age it until only one second remains.
        vm.warp(until - 1);
        assertEq(_now(), until - 1, "warped to the last usable second");

        uint256 apy = _baseApy(0, P30);
        vm.prank(alice);
        uint256 n = staking.stakeWithVoucher(v, sig, AMOUNT, apy);
        assertEq(_deposit(alice, n).amount, AMOUNT, "an aged voucher with time left is still good");
    }

    /// @notice Finding #8 regression: a long-dated voucher is NEVER usable, not even at the end of its life.
    /// @dev With the old now-relative bound this exact voucher reverted today and was accepted 365 days later,
    ///      inside the last CEILING seconds before validUntil.
    function test_longDatedVoucherNeverBecomesUsable() external {
        uint256 t0 = _now();
        Types.StakeVoucher memory v = _voucherIssued(alice, t0, t0 + 365 days, 40);
        bytes memory err = abi.encodeWithSelector(Errors.VoucherValidityTooLong.selector, v.validUntil, t0 + CEILING);

        _expectStakeRevert(v, err);
        vm.warp(v.validUntil - CEILING);
        _expectStakeRevert(v, err);
        vm.warp(v.validUntil);
        _expectStakeRevert(v, err);
        assertFalse(staking.isVoucherNonceUsed(alice, 40));
    }

    /// @notice Post-dating issuedAt to slide the window forward is rejected, and the nonce survives.
    /// @dev Without this check a signer could write issuedAt = validUntil - ceiling for any validUntil and get
    ///      the old sliding-window behaviour straight back. Exactly `now` is accepted.
    function test_postDatedVoucherReverts() external {
        uint256 t = _now();
        Types.StakeVoucher memory v = _voucherIssued(alice, t + 1, t + CEILING, 41);
        _expectStakeRevert(v, abi.encodeWithSelector(Errors.VoucherNotYetValid.selector, t + 1, t));
        assertFalse(staking.isVoucherNonceUsed(alice, 41));

        vm.warp(t + 1);
        _stake(v);
    }

    /// @notice The two errors bracket the window and do not shadow each other at either boundary.
    /// @dev With a finite ceiling, VoucherExpired and VoucherValidityTooLong sit at opposite ends of the same
    ///      sliding window, and a test that used an unreachable validUntil could now pass for the wrong reason.
    ///      This pins all four cases around the two edges in one place: too old, exactly old enough, exactly
    ///      far enough, too far. Kills a reordering of the two checks, which would report "expired" for an
    ///      over-dated voucher (and vice versa) and send whoever debugs it in the wrong direction.
    function test_expiredAndTooLongDoNotShadowEachOther() external {
        uint256 t = _now();

        // One second in the past: expired, NOT "too long".
        _expectStakeRevert(
            _voucherIssued(alice, t - CEILING, t - 1, 10),
            abi.encodeWithSelector(Errors.VoucherExpired.selector, t - 1, t)
        );

        // Exactly now: the last instant a voucher is still valid. Accepted (expiry is inclusive).
        _stake(_voucherUntil(alice, t, 11));

        // Exactly the ceiling: accepted.
        _stake(_voucherUntil(alice, t + CEILING, 12));

        // One past the ceiling: too long, NOT "expired".
        _expectStakeRevert(
            _voucherUntil(alice, t + CEILING + 1, 13),
            abi.encodeWithSelector(Errors.VoucherValidityTooLong.selector, t + CEILING + 1, t + CEILING)
        );

        assertEq(staking.checkDepositCountOfAddress(alice), 2, "only the two in-window vouchers staked");
    }

    /// @notice Tightening the ceiling invalidates already-signed long-dated vouchers immediately.
    /// @dev This is the incident-response property: on a suspected key leak an operator lowers the ceiling and
    ///      every outstanding voucher dated beyond the new value stops working at once, without a redeploy and
    ///      without touching the signer. Kills any implementation that snapshots the ceiling per voucher.
    function test_loweringTheCeilingInvalidatesOutstandingVouchers() external {
        uint256 until = _now() + CEILING;
        Types.StakeVoucher memory v = _voucherUntil(alice, until, 20);
        bytes memory sig = signVoucher(v);

        staking.setMaxVoucherValidity(60);

        // Resolve both external reads BEFORE the cheatcodes: _baseApy and _now() are calls, and either one
        // between vm.prank and the staked call would consume the prank.
        uint256 apy = _baseApy(0, P30);
        uint256 newMax = _now() + 60;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherValidityTooLong.selector, until, newMax));
        staking.stakeWithVoucher(v, sig, AMOUNT, apy);

        assertFalse(staking.isVoucherNonceUsed(alice, 20), "still not burned");
    }

    // ======================================================================
    // =                        The setter                                  =
    // ======================================================================

    /// @notice The ceiling has no off switch: 0 reverts rather than disabling the check.
    /// @dev 0 does not mean "unlimited", it means "reject every voucher", so accepting it would be a foot-gun
    ///      in both directions -- an operator typing 0 for "no limit" would halt staking instead. Kills a
    ///      well-meaning change that treats 0 as a sentinel for disabled.
    function test_setterRejectsZero() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmountProvided.selector));
        staking.setMaxVoucherValidity(0);
        assertEq(staking.maxVoucherValidity(), CEILING, "unchanged after the rejected call");
    }

    /// @notice Only the owner may move the ceiling. Not admins.
    /// @dev It is a security parameter, so it sits at the owner tier, not the admin tier that can freeze
    ///      deposits. Kills a downgrade to onlyAdmins, which would let any compromised admin key widen the very
    ///      window this check exists to bound.
    function test_setterIsOwnerOnly() external {
        bytes memory err =
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER);

        vm.prank(admin);
        vm.expectRevert(err);
        staking.setMaxVoucherValidity(1 days);

        vm.prank(rando);
        vm.expectRevert(err);
        staking.setMaxVoucherValidity(1 days);

        assertEq(staking.maxVoucherValidity(), CEILING, "unchanged by either attempt");
    }

    /// @notice The setter writes the value and announces it.
    /// @dev Kills a silent setter: the backend and monitoring both need to see the ceiling move, since every
    ///      voucher it issues has to fit inside it.
    function test_setterUpdatesAndEmits() external {
        vm.expectEmit(true, true, true, true, address(staking));
        emit UpdateMaxVoucherValidity(2 hours);
        staking.setMaxVoucherValidity(2 hours);
        assertEq(staking.maxVoucherValidity(), 2 hours);

        _stake(_voucherUntil(alice, _now() + 2 hours, 30));
    }

    /// @notice A fresh deployment is born with a usable ceiling, not a bricked one.
    /// @dev Regression test for a real bug: `maxVoucherValidity` had no constructor default, so it was 0 on
    ///      deploy -- and 0 is exactly the value the setter refuses, because it rejects every voucher. A
    ///      contract must never start in a state its own setter forbids. The default also has to be at least
    ///      the backend's maximum configurable `validity_seconds` (1800), or a correctly-issued voucher would
    ///      bounce off a contract nobody had configured yet.
    function test_freshDeploymentHasAUsableDefaultCeiling() external {
        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        assertGe(fresh.maxVoucherValidity(), 1800, "default covers the backend's widest issuance window");
        assertTrue(fresh.maxVoucherValidity() != 0, "never born in the state the setter refuses");
    }
}
