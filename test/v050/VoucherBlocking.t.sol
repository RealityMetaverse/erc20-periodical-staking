// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";
import {AccessControl} from "../../src/contracts/erc20-periodical-staking/AccessControl.sol";

/// @notice `walletBlocked`: the on-chain switch that stops a wallet staking.
///
///         This exists because a limit of 0 does NOT block. Product decision, 2026-09-18: zero keeps one meaning
///         everywhere in the LimitController -- "no normal room" -- and the voucher bonus is independent headroom
///         stacked on top of it, so a wallet on a zero limit still stakes its whole VIP budget. Blocking is now a
///         separate, explicit flag, which means the two ideas can no longer be confused for each other. Several
///         tests here pin exactly that independence, because conflating them is the mistake this split was made
///         to prevent, and it was proposed and backed out twice before it landed this way.
///
///         THE LINE THAT MATTERS: blocking stops STAKING and nothing else. A blocked wallet must always be able
///         to get its money out -- withdraw, claim, claimAll -- and must still be seizable. Blocking is not
///         freezing and it is not confiscation. A block that trapped principal would turn an operational control
///         into a way to hold user funds hostage, which is a far worse failure than the one it prevents.
///
/// @dev Never read `block.timestamp` after a warp: use `_now()` (via_ir hazard, see test/shared/Clock.sol).
///      `_baseApy()` is an external call and eats a pending prank/expectRevert -- see the note on it in V050Base.
contract VoucherBlockingTest is V050Base {
    uint256 internal constant BUDGET = 50_000 * ONE;
    uint256 internal constant AMOUNT = 1_000 * ONE;
    uint256 internal constant MIN_DEPOSIT = 100;

    // ======================================
    // =              Helpers               =
    // ======================================
    function _phase() internal view returns (uint256) {
        return staking.currentStakingPhase();
    }

    function _budgetVoucher(address wallet, uint256 period) internal returns (Types.StakeVoucher memory) {
        return _makeVoucherBudget(wallet, _phase(), period, 0, BUDGET, BUDGET);
    }

    function _stakeBonus(address wallet, uint256 period, uint256 amount) internal returns (uint256) {
        Types.StakeVoucher memory v = _budgetVoucher(wallet, period);
        bytes memory sig = signVoucher(v);
        uint256 apy = _baseApy(v.phase, period);
        vm.prank(wallet);
        return staking.stakeWithVoucher(v, sig, amount, apy);
    }

    function _expectBlocked(address wallet, uint256 period, uint256 amount) internal {
        Types.StakeVoucher memory v = _budgetVoucher(wallet, period);
        bytes memory sig = signVoucher(v);
        uint256 apy = _baseApy(v.phase, period);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(Errors.WalletBlocked.selector, wallet));
        staking.stakeWithVoucher(v, sig, amount, apy);
    }

    function block_(address wallet) internal {
        vm.prank(admin);
        staking.setWalletBlocked(wallet, true);
    }

    function unblock_(address wallet) internal {
        vm.prank(admin);
        staking.setWalletBlocked(wallet, false);
    }

    // ======================================================================
    // =                     Blocking stops staking                         =
    // ======================================================================

    /// @notice A blocked wallet cannot stake, even holding a perfectly good voucher with the whole budget unspent.
    /// @dev The voucher is valid in every other respect -- correct signer, correct wallet, in date, budget
    ///      untouched, headroom available -- so the ONLY thing refusing it is the block. Kills a check that is
    ///      present but ineffective, e.g. one that reads a stale flag or is skipped when a bonus is available.
    function test_blockedWalletCannotStake() external {
        block_(alice);
        assertTrue(staking.walletBlocked(alice));

        _expectBlocked(alice, P30, AMOUNT);
        assertEq(staking.checkDepositCountOfAddress(alice), 0, "nothing was opened");

        // Not a quirk of the bonus path: a wallet with plain base allowance is refused too.
        _expectBlocked(alice, P90, AMOUNT);
    }

    /// @notice Blocking is per wallet. It does not leak to anyone else.
    /// @dev Kills a flag stored against the wrong key, or a global pause wearing a per-wallet interface.
    function test_blockingOneWalletDoesNotAffectOthers() external {
        block_(alice);

        _expectBlocked(alice, P30, AMOUNT);
        _stakeBonus(bob, P30, AMOUNT);
        assertEq(staking.checkDepositCountOfAddress(bob), 1, "bob is unaffected");
        assertFalse(staking.walletBlocked(bob));
    }

    /// @notice Unblocking restores staking immediately, in the very next call.
    /// @dev Kills a one-way flag, and any implementation that caches the blocked set somewhere that has to be
    ///      refreshed. An operator who blocks a wallet in error must be able to undo it without a redeploy.
    function test_unblockingRestoresStakingImmediately() external {
        block_(alice);
        _expectBlocked(alice, P30, AMOUNT);

        unblock_(alice);
        assertFalse(staking.walletBlocked(alice));

        uint256 n = _stakeBonus(alice, P30, AMOUNT);
        assertEq(_deposit(alice, n).amount, AMOUNT, "staking works again");
    }

    // ======================================================================
    // =            THE ONE THAT MATTERS: money is never trapped            =
    // ======================================================================

    /// @notice A blocked wallet can still WITHDRAW, CLAIM, claimAll and be SEIZED. Blocking never traps money.
    /// @dev The highest-value test in this file. Blocking is an operational control on new staking, not a freeze
    ///      and not confiscation, so every exit must stay open. The natural implementation mistake is to gate too
    ///      much -- a modifier on the contract, or a check in a shared internal helper, instead of one check in
    ///      `stakeWithVoucher` -- and the symptom would be a user permanently unable to reach their own principal.
    ///      That is a worse outcome than the problem blocking solves, so it is asserted path by path rather than
    ///      in aggregate: every position is opened BEFORE the block, then every exit is exercised while blocked.
    function test_blockedWalletCanStillGetItsMoneyOut() external {
        // Four positions, opened while alice is free.
        uint256 toWithdraw = _stakeBonus(alice, P30, AMOUNT);
        uint256 toClaimMatured = _stakeBonus(alice, P30, AMOUNT);
        uint256 toClaimIndefinite = _stakeBonus(alice, P0, AMOUNT);
        uint256 toSeize = _stakeBonus(alice, P90, AMOUNT);

        block_(alice);
        _expectBlocked(alice, P30, MIN_DEPOSIT); // staking really is shut

        uint256 before = token.balanceOf(alice);

        // 1. Withdraw an open periodical deposit.
        vm.prank(alice);
        staking.withdrawDeposit(toWithdraw);
        assertEq(uint8(_status(alice, toWithdraw)), uint8(ProgramManager.DepositStatus.WITHDRAWN));

        // 2. Claim an INDEFINITE deposit's reward (position stays open).
        _warpDays(31);
        vm.prank(alice);
        staking.claimDeposit(toClaimIndefinite);
        assertEq(uint8(_status(alice, toClaimIndefinite)), uint8(ProgramManager.DepositStatus.INDEFINITE));

        // 3. Claim a matured periodical deposit (closes it, returns principal).
        vm.prank(alice);
        staking.claimDeposit(toClaimMatured);
        assertEq(uint8(_status(alice, toClaimMatured)), uint8(ProgramManager.DepositStatus.CLAIMED));

        assertGt(token.balanceOf(alice), before, "principal and reward actually reached the wallet");

        // 4. The batch exit works too -- a blocked wallet is not forced to close deposits one by one.
        vm.prank(alice);
        staking.claimAll();

        // 5. And the wallet is still seizable: blocking does not put it beyond enforcement.
        freeze(alice, toSeize);
        seize(alice, toSeize);
        assertEq(uint8(_status(alice, toSeize)), uint8(ProgramManager.DepositStatus.SEIZED));

        assertTrue(staking.walletBlocked(alice), "still blocked throughout");
    }

    /// @notice Blocking a wallet mid-life releases nothing and charges nothing. It is not a close.
    /// @dev Kills an implementation that treats blocking as an enforcement action on existing positions. The
    ///      bonus meter must be exactly where it was; the budget comes back when the DEPOSIT closes, not when
    ///      the wallet is blocked, or the wallet could be blocked and unblocked to mint headroom.
    function test_blockingDoesNotTouchTheBonusMeter() external {
        // Zero the base allowance first, or the fixture's 100,000 default funds the stake and the meter stays
        // at 0 -- the test would pass while measuring nothing.
        controller.setDefaultLimit(_phase(), P30, 0);
        _stakeBonus(alice, P30, AMOUNT);
        (uint256 totalBefore, uint256 cellBefore) = staking.getBonusUsage(alice, _phase(), P30);
        assertEq(totalBefore, AMOUNT, "bonus-funded, so the meter is charged");

        block_(alice);
        (uint256 totalAfter, uint256 cellAfter) = staking.getBonusUsage(alice, _phase(), P30);
        assertEq(totalAfter, totalBefore, "block released nothing");
        assertEq(cellAfter, cellBefore, "block released nothing, per cell either");

        unblock_(alice);
        (uint256 totalUnblocked,) = staking.getBonusUsage(alice, _phase(), P30);
        assertEq(totalUnblocked, totalBefore, "and unblocking granted nothing");
    }

    // ======================================================================
    // =                 The block costs the user nothing                   =
    // ======================================================================

    /// @notice A blocked attempt does not burn the wallet's nonce.
    /// @dev The proof is that the SAME signed voucher works once the block is lifted -- no re-issuance needed.
    ///      A burnt nonce would be a silent cost: the backend would have to notice and re-sign, and a wallet
    ///      blocked briefly in error would lose whatever vouchers it held at the time.
    function test_blockedAttemptDoesNotBurnTheNonce() external {
        Types.StakeVoucher memory v = _budgetVoucher(alice, P30);
        bytes memory sig = signVoucher(v);
        uint256 apy = _baseApy(v.phase, P30);

        block_(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.WalletBlocked.selector, alice));
        staking.stakeWithVoucher(v, sig, AMOUNT, apy);

        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce), "nonce survived the refusal");

        unblock_(alice);
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, AMOUNT, apy); // same voucher, same signature
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce), "burnt only by the stake that succeeded");
    }

    /// @notice The block is checked before the signature, so a blocked wallet never pays for ECDSA recovery.
    /// @dev A behavioural test of ORDERING, which is otherwise invisible. A blocked wallet submitting a garbage
    ///      signature must get WalletBlocked, not InvalidVoucherSignature: if it got the latter, the check sits
    ///      after signature verification and every refused attempt burns the recovery cost for nothing. Also
    ///      guards the other direction -- a check placed after the nonce write would still revert, but this
    ///      pins it early enough that the cheap rejection is the one that happens.
    function test_blockIsCheckedBeforeTheSignature() external {
        block_(alice);

        Types.StakeVoucher memory v = _budgetVoucher(alice, P30);
        bytes memory garbage = new bytes(65); // not a signature at all
        uint256 apy = _baseApy(v.phase, P30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.WalletBlocked.selector, alice));
        staking.stakeWithVoucher(v, garbage, AMOUNT, apy);
    }

    // ======================================================================
    // =        Blocking and a zero limit are completely independent        =
    // ======================================================================

    /// @notice All four combinations of (limit zero or not) x (blocked or not) behave independently.
    /// @dev This is the whole point of the split, written out. The wallet-ban rule was proposed, implemented,
    ///      reverted, reinstated and reverted again before landing here, each time on the question of whether a
    ///      zero limit should block. It does not. A single test covering all four corners makes a future
    ///      re-conflation fail immediately, whichever direction someone comes at it from.
    function test_zeroLimitAndBlockingAreIndependent() external {
        uint256 zeroLimitPeriod = P30;
        uint256 normalPeriod = P90;
        controller.setWalletLimit(alice, _phase(), zeroLimitPeriod, 0);
        controller.setWalletLimit(bob, _phase(), zeroLimitPeriod, 0);

        // 1. Zero limit, NOT blocked: the bonus still gets through. A zero limit is not a block.
        _stakeBonus(alice, zeroLimitPeriod, AMOUNT);
        assertEq(_cell(alice, _phase(), zeroLimitPeriod), AMOUNT, "zero limit did not stop the bonus");

        // 2. Normal limit, BLOCKED: refused. A block does not need a zero limit to bite.
        block_(alice);
        _expectBlocked(alice, normalPeriod, AMOUNT);

        // 3. Zero limit AND blocked: refused, and the reason reported is the block, not the limit.
        _expectBlocked(alice, zeroLimitPeriod, AMOUNT);

        // 4. Zero limit, block lifted: back to case 1. Neither state has contaminated the other.
        unblock_(alice);
        _stakeBonus(alice, zeroLimitPeriod, AMOUNT);
        assertEq(_cell(alice, _phase(), zeroLimitPeriod), 2 * AMOUNT);

        // And bob, on the same zero limit but never blocked, was never affected by any of it.
        _stakeBonus(bob, zeroLimitPeriod, AMOUNT);
        assertEq(_cell(bob, _phase(), zeroLimitPeriod), AMOUNT);
    }

    // ======================================================================
    // =                     Access control and the setter                  =
    // ======================================================================

    /// @notice Only admins and the owner may block. A random caller cannot.
    /// @dev Blocking is an enforcement control sitting at the same tier as freeze. If any caller could set it,
    ///      it would be a free denial of service against any wallet.
    function test_onlyAdminsCanBlock() external {
        bytes memory err =
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.ADMIN);

        vm.prank(rando);
        vm.expectRevert(err);
        staking.setWalletBlocked(alice, true);

        vm.prank(bob);
        vm.expectRevert(err);
        staking.setWalletBlocked(alice, true);

        assertFalse(staking.walletBlocked(alice), "neither attempt took effect");

        // Admin and owner both work.
        vm.prank(admin);
        staking.setWalletBlocked(alice, true);
        assertTrue(staking.walletBlocked(alice));

        staking.setWalletBlocked(alice, false); // owner, unpranked
        assertFalse(staking.walletBlocked(alice));
    }

    /// @notice The setter announces the change.
    /// @dev Blocking is invisible from the outside otherwise. Monitoring and the backend both need the event,
    ///      and support needs to be able to answer "when was this wallet blocked, and by whom".
    function test_setterEmits() external {
        vm.expectEmit(true, true, true, true, address(staking));
        emit UpdateWalletBlocked(alice, true);
        vm.prank(admin);
        staking.setWalletBlocked(alice, true);

        vm.expectEmit(true, true, true, true, address(staking));
        emit UpdateWalletBlocked(alice, false);
        vm.prank(admin);
        staking.setWalletBlocked(alice, false);
    }

    /// @notice The batch setter blocks and unblocks many wallets, and matches the single setter exactly.
    /// @dev Kills a batch that silently skips entries, stops at the first, or writes the wrong value. An
    ///      incident response blocking a list of wallets has to be able to trust that the whole list landed.
    function test_batchSetterBlocksAndUnblocksEveryone() external {
        address[] memory wallets = new address[](3);
        wallets[0] = alice;
        wallets[1] = bob;
        wallets[2] = carol;

        vm.prank(admin);
        staking.setWalletsBlocked(wallets, true);
        for (uint256 i = 0; i < wallets.length; i++) {
            assertTrue(staking.walletBlocked(wallets[i]), "every wallet in the batch is blocked");
            _expectBlocked(wallets[i], P30, AMOUNT);
        }

        // Someone outside the list is untouched.
        assertFalse(staking.walletBlocked(admin));

        vm.prank(admin);
        staking.setWalletsBlocked(wallets, false);
        for (uint256 i = 0; i < wallets.length; i++) {
            assertFalse(staking.walletBlocked(wallets[i]), "and every one is released");
            _stakeBonus(wallets[i], P30, AMOUNT);
        }
    }

    /// @notice The batch setter is admin-only too.
    /// @dev Kills the classic omission: the single setter is guarded, the batch one is forgotten.
    function test_batchSetterIsAdminOnly() external {
        address[] memory wallets = new address[](1);
        wallets[0] = alice;

        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.ADMIN)
        );
        staking.setWalletsBlocked(wallets, true);

        assertFalse(staking.walletBlocked(alice));
    }

    /// @notice A fresh deployment blocks nobody.
    /// @dev Fail-open is right here, and the opposite of `maxExtraLimitPerCell`: a default-blocked contract would
    ///      reject every staker on day one and look like a signer outage.
    function test_nobodyIsBlockedByDefault() external {
        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        assertFalse(fresh.walletBlocked(alice));
        assertFalse(fresh.walletBlocked(bob));
        assertFalse(staking.walletBlocked(rando), "and on the configured fixture too");
    }
}
