// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";

/// @title AccessControl
/// @notice Full matrix: every privileged function x {admin, random user, pending owner} must revert with the exact
///         UnauthorizedAccess tier; user functions must be open to everyone; ownership handover must be complete.
///         Since v0.4.0 the backend-signed voucher is the stake permission, so its authorization rules (wallet
///         binding, signer, domain, nonce, expiry, owner caps) are attacked here as well.
contract AccessControlTest is VoucherAttackBase {
    function _ownerOnlyCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](20);
        uint256[] memory three = _fill(3, 1);
        uint256[] memory two = _fill(2, 1);
        calls[0] = abi.encodeCall(staking.transferOwnership, (rando));
        calls[1] = abi.encodeCall(staking.addContractAdmin, (rando));
        calls[2] = abi.encodeCall(staking.removeContractAdmin, (admin));
        calls[3] = abi.encodeCall(staking.setMiniumumDeposit, (1));
        calls[4] = abi.encodeCall(staking.changeActionAvailability, (Types.DataType.STAKING, false));
        calls[5] = abi.encodeCall(staking.pushStakingPhase, (three, three));
        calls[6] = abi.encodeCall(staking.popStakingPhase, ());
        calls[7] = abi.encodeCall(staking.addStakingPeriod, (60, two, two));
        calls[8] = abi.encodeCall(staking.setPhasePeriodData, (Types.PhasePeriodDataType.APY, 0, P30, 1));
        calls[9] = abi.encodeCall(staking.removeStakingPeriod, (P30));
        calls[10] = abi.encodeCall(staking.changeStakingPhase, (1));
        calls[11] = abi.encodeCall(staking.seizeDeposit, (alice, 0));
        calls[12] = abi.encodeCall(staking.seizeDeposits, (_one(alice), _oneU(1)));
        calls[13] = abi.encodeCall(staking.setLimitController, (address(0)));
        calls[14] = abi.encodeCall(staking.setVoucherSigner, (address(0)));
        calls[15] = abi.encodeCall(staking.setMaxExtraApyBps, (1));
        calls[16] = abi.encodeCall(staking.setMaxExtraLimitTotal, (1));
        calls[17] = abi.encodeCall(staking.setTreasury, (rando));
        calls[18] = abi.encodeCall(staking.collectReward, (1));
        calls[19] = abi.encodeCall(staking.rescueTokens, (address(token), 1));
    }

    function _adminCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](5);
        calls[0] = abi.encodeCall(staking.freezeDeposit, (alice, 0));
        calls[1] = abi.encodeCall(staking.unfreezeDeposit, (alice, 0));
        calls[2] = abi.encodeCall(staking.freezeDeposits, (_one(alice), _oneU(0)));
        calls[3] = abi.encodeCall(staking.unfreezeDeposits, (_one(alice), _oneU(0)));
        calls[4] = abi.encodeCall(staking.provideReward, (1));
    }

    function _assertAllRevert(bytes[] memory calls, address caller, AccessControl.AccessTier tier) internal {
        bytes memory expected = _unauthorized(tier);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = _call(caller, address(staking), calls[i]);
            assertFalse(ok, string.concat("privileged call #", vm.toString(i), " succeeded for unprivileged caller"));
            assertEq(keccak256(ret), keccak256(expected), string.concat("wrong error for call #", vm.toString(i)));
        }
    }

    function _assertAllRevertUnauthorized(address caller, AccessControl.AccessTier tier) internal {
        _assertAllRevert(_ownerOnlyCalls(), caller, tier);
    }

    /// @dev Hypothesis: an admin can call some owner-only function (seize included).
    function test_matrix_admin_cannotCallOwnerFunctions() public {
        _assertAllRevertUnauthorized(admin, AccessControl.AccessTier.OWNER);
    }

    /// @dev Hypothesis: a random user can call some owner-only function.
    function test_matrix_rando_cannotCallOwnerFunctions() public {
        _assertAllRevertUnauthorized(rando, AccessControl.AccessTier.OWNER);
    }

    /// @dev Hypothesis: a random user or a depositor can freeze / unfreeze deposits or fund the pool.
    function test_matrix_nonAdmins_cannotCallAdminFunctions() public {
        _stake(alice, 0, P0, 1_000 * ONE);
        _assertAllRevert(_adminCalls(), rando, AccessControl.AccessTier.ADMIN);
        _assertAllRevert(_adminCalls(), alice, AccessControl.AccessTier.ADMIN);
        assertFalse(staking.isDepositFrozen(alice, 0));
    }

    /// @dev Hypothesis: a pending owner already has owner powers.
    function test_matrix_pendingOwner_cannotCallOwnerFunctions() public {
        staking.transferOwnership(bob);
        _assertAllRevertUnauthorized(bob, AccessControl.AccessTier.OWNER);
        // and has no admin powers either
        _assertAllRevert(_adminCalls(), bob, AccessControl.AccessTier.ADMIN);
    }

    /// @dev Hypothesis: the owner is refused by some function it should be allowed to call.
    function test_matrix_owner_canCallEverything() public {
        // seize needs two frozen deposits
        _stake(alice, 0, P0, 1_000 * ONE);
        _stake(alice, 0, P0, 1_000 * ONE);
        _freeze(alice, 0);
        _freeze(alice, 1);
        bytes[] memory calls = _ownerOnlyCalls();
        token.transfer(address(staking), 1); // so rescue(1) has excess
        for (uint256 i = 0; i < calls.length; i++) {
            if (i == 0) continue; // transferOwnership tested separately (would change pending owner)
            (bool ok, bytes memory ret) = address(staking).call(calls[i]);
            assertTrue(ok, string.concat("owner refused on call #", vm.toString(i), " ", vm.toString(ret)));
        }
        assertEq(uint256(_status(alice, 0)), uint256(ProgramManager.DepositStatus.SEIZED));
        assertEq(uint256(_status(alice, 1)), uint256(ProgramManager.DepositStatus.SEIZED));
    }

    /// @dev The owner counts as an admin: every admin-tier function works for the owner and for admins.
    function test_matrix_ownerAndAdmin_canCallAdminFunctions() public {
        _stake(alice, 0, P0, 1_000 * ONE);
        bytes[] memory calls = _adminCalls();
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = address(staking).call(calls[i]);
            assertTrue(ok, string.concat("owner refused on admin call #", vm.toString(i), " ", vm.toString(ret)));
        }
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = _call(admin, address(staking), calls[i]);
            assertTrue(ok, string.concat("admin refused on admin call #", vm.toString(i), " ", vm.toString(ret)));
        }
        assertFalse(staking.isDepositFrozen(alice, 0), "freeze/unfreeze pairs leave the deposit unfrozen");
        assertEq(_user(Types.DataType.REWARD_PROVIDED, admin), 1);
        _assertAccounting();
    }

    /// @dev provideReward: admins and owner yes, everyone else exact ADMIN error.
    function test_provideReward_tiering() public {
        vm.prank(rando);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.provideReward(1);
        vm.prank(alice);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.provideReward(1);
        vm.prank(admin);
        staking.provideReward(1);
        staking.provideReward(1);
        assertEq(_user(Types.DataType.REWARD_PROVIDED, admin), 1);
        _assertAccounting();
    }

    /// @dev acceptOwnership: only the pending owner, exact error for everyone else (including the current owner).
    function test_acceptOwnership_tiering() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, rando, address(0)));
        staking.acceptOwnership();
        staking.transferOwnership(bob);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, admin, bob));
        staking.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, owner, bob));
        staking.acceptOwnership();
        vm.prank(bob);
        staking.acceptOwnership();
        assertEq(staking.contractOwner(), bob);
    }

    /// @dev After handover the previous owner loses every privilege (and is not implicitly an admin).
    function test_afterHandover_previousOwnerPowerless() public {
        _stake(alice, 0, P0, 1_000 * ONE);
        staking.transferOwnership(bob);
        vm.prank(bob);
        staking.acceptOwnership();
        _assertAllRevertUnauthorized(owner, AccessControl.AccessTier.OWNER);
        _assertAllRevert(_adminCalls(), owner, AccessControl.AccessTier.ADMIN);
        // the new owner can freeze and seize immediately
        vm.startPrank(bob);
        staking.freezeDeposit(alice, 0);
        staking.seizeDeposit(alice, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(treasury), 1_000 * ONE);
    }

    /// @dev Hypothesis: zero-address guards on admin management and the treasury.
    function test_adminManagement_guards() public {
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        staking.addContractAdmin(address(0));
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        staking.setTreasury(address(0));
        assertEq(staking.treasury(), treasury, "a rejected treasury update must not change it");
        staking.removeContractAdmin(address(0)); // no-op allowed
        staking.removeContractAdmin(rando); // removing a non-admin is a no-op
        assertFalse(staking.contractAdmins(rando));
        staking.addContractAdmin(rando);
        assertTrue(staking.contractAdmins(rando));
        token.transfer(rando, 1);
        vm.prank(rando);
        token.approve(address(staking), 1);
        vm.prank(rando);
        staking.provideReward(1);
    }

    /// @dev User functions are callable by anyone including admins and the owner (no accidental restriction).
    function test_userFunctions_openToAll() public {
        address[3] memory callers = [admin, owner, rando];
        for (uint256 i = 0; i < callers.length; i++) {
            address c = callers[i];
            if (token.balanceOf(c) < 1_000 * ONE) token.transfer(c, 1_000 * ONE);
            vm.prank(c);
            token.approve(address(staking), type(uint256).max);
            uint256 d = _stake(c, 0, P0, 1_000 * ONE);
            vm.startPrank(c);
            staking.claimAll();
            staking.withdrawDeposit(d);
            vm.stopPrank();
            assertEq(uint256(_status(c, d)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        }
    }

    /// @dev Hypothesis: view functions are gated by access control (they must not be).
    function test_views_openToAll() public {
        _stake(alice, 0, P30, 1_000 * ONE);
        Types.StakeVoucher memory v = _makeVoucher(alice, 0, P30, 0, 0);
        vm.startPrank(rando);
        staking.getProgramData();
        _lens(staking).getProgramDataWithUserData(alice);
        staking.checkTotalClaimableData();
        staking.getCollectableReward();
        _lens(staking).getRewardPoolShortfall();
        _lens(staking).getPhasePeriodDataAll(Types.PhasePeriodDataType.STAKED);
        staking.getUserPhasePeriodData(Types.DataType.STAKING, alice, 0, P30);
        staking.isDepositFrozen(alice, 0);
        staking.isVoucherNonceUsed(alice, 0);
        staking.getVoucherDigest(v);
        staking.eip712Domain();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Voucher authorization
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: a voucher issued to alice can be used by someone else (front-run from the mempool).
    function test_voucher_boundToWallet_otherCallerRejected() public {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        uint256 apy = _apy(0, P30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherWalletMismatch.selector, alice, bob));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce), "nonce must not be burned by a rejected caller");
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        assertEq(staking.checkDepositCountOfAddress(bob), 0);
        assertEq(staking.checkDepositCountOfAddress(alice), 1);
    }

    /// @dev Hypothesis: a voucher signed by any key other than voucherSigner is accepted.
    function test_voucher_wrongSigner_rejected() public {
        Types.StakeVoucher memory v = _makeVoucher(alice, 0, P30, 0, 0);
        bytes memory sig = _signVoucher(address(staking), v, 0xBAD);
        uint256 apy = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        // garbage and empty signatures do not panic either
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, hex"deadbeef", 1_000 * ONE, apy);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, "", 1_000 * ONE, apy);
    }

    /// @dev Fuzz: altering any signed field after signing (to raise the APY, lift the limit, extend expiry,
    ///      move period or phase, or reuse a nonce) invalidates the signature.
    function testFuzz_voucher_tamperedField_rejected(uint8 field, uint256 delta) public {
        field = uint8(bound(field, 0, 6));
        delta = bound(delta, 1, 1_000);
        staking.changeStakingPhase(1);
        // This test dates its voucher a day out and then tampers the field by up to 1000 more, so it needs a
        // ceiling wider than both. Raised here, in the test, so the dependency is visible: without it the
        // stake reverts VoucherValidityTooLong and never reaches the signature check under test.
        staking.setMaxVoucherValidity(2 days);
        Types.StakeVoucher memory v = _makeVoucher(alice, 1, P30, 100, 1_000 * ONE);
        v.validUntil = _now() + 1 days;
        bytes memory sig = _signVoucher(address(staking), v, VOUCHER_SIGNER_KEY);
        if (field == 0) v.extraApyBps += delta;
        else if (field == 1) v.extraLimitTotal += delta;
        else if (field == 2) v.validUntil += delta;
        else if (field == 3) v.period = P90; // exists, so only the signature can reject it
        else if (field == 4) v.nonce += delta;
        else if (field == 5) v.extraLimitPerCell += delta;
        else v.extraApyBps -= 1; // lowering is tampering too
        uint256 apy = _apy(1, v.period);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
    }

    /// @dev Hypothesis: a used voucher can be replayed, or a rejected stake burns the nonce.
    function test_voucher_replay_rejected_failedStakeKeepsNonce() public {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        uint256 apy = _apy(0, P30);
        // first attempt fails later in the checks (below minimum): nonce stays usable
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientDeposit.selector, 99, 100));
        staking.stakeWithVoucher(v, sig, 99, apy);
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce));

        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, alice, v.nonce));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        // different amount does not help: the amount is not what makes the voucher single-use
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, alice, v.nonce));
        staking.stakeWithVoucher(v, sig, 500 * ONE, apy);
        assertEq(staking.checkDepositCountOfAddress(alice), 1);
        _assertAccounting();
    }

    /// @dev Nonces are per wallet and a bitmap: alice using nonce N does not burn N for bob, and neighbouring
    ///      bits / words are independent (nonce 255 vs 256 lands in different words).
    function test_voucher_noncesPerWalletAndBitIndependent() public {
        uint256[4] memory nonces = [uint256(255), 256, 0, type(uint256).max];
        uint256 apy = _apy(0, P0);
        for (uint256 i = 0; i < nonces.length; i++) {
            Types.StakeVoucher memory v = _makeVoucher(alice, 0, P0, 0, 0);
            v.nonce = nonces[i];
            bytes memory sig = _signVoucher(address(staking), v, VOUCHER_SIGNER_KEY);
            vm.prank(alice);
            staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
            for (uint256 j = 0; j < nonces.length; j++) {
                assertEq(staking.isVoucherNonceUsed(alice, nonces[j]), j <= i, "bitmap bit bleed");
                assertFalse(staking.isVoucherNonceUsed(bob, nonces[j]), "nonce leaked across wallets");
            }
        }
        assertFalse(staking.isVoucherNonceUsed(alice, 254));
        assertFalse(staking.isVoucherNonceUsed(alice, 257));
        assertFalse(staking.isVoucherNonceUsed(alice, 1));
        // bob can use the same nonce value
        Types.StakeVoucher memory vb = _makeVoucher(bob, 0, P0, 0, 0);
        vb.nonce = 255;
        bytes memory sigb = _signVoucher(address(staking), vb, VOUCHER_SIGNER_KEY);
        vm.prank(bob);
        staking.stakeWithVoucher(vb, sigb, 1_000 * ONE, apy);
    }

    /// @dev Hypothesis: a voucher for one staking deployment is valid on another (same signer, same chain).
    function test_voucher_crossContractReplay_rejected() public {
        ERC20PeriodicalStaking other = _deployConfigured(address(token));
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        vm.prank(alice);
        token.approve(address(other), type(uint256).max);
        uint256 apy = other.getPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        other.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        // still valid where it was issued
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
    }

    /// @dev Hypothesis: a voucher for another chain id is valid here.
    function test_voucher_otherChain_rejected() public {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        uint256 apy = _apy(0, P30);
        // read through an external call: via_ir may re-evaluate a local `block.chainid` after vm.chainId
        (,,, uint256 chain,,,) = staking.eip712Domain();
        vm.chainId(chain + 1);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        vm.chainId(chain);
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
    }

    /// @dev validUntil is inclusive: usable at exactly validUntil, rejected one second later.
    function test_voucher_expiry_inclusiveBoundary() public {
        uint256 t = _now() + 1 hours;
        Types.StakeVoucher memory v = _makeVoucher(alice, 0, P30, 0, 0);
        v.validUntil = t;
        bytes memory sig = _signVoucher(address(staking), v, VOUCHER_SIGNER_KEY);
        Types.StakeVoucher memory w = _makeVoucher(alice, 0, P30, 0, 0);
        w.validUntil = t;
        bytes memory sigW = _signVoucher(address(staking), w, VOUCHER_SIGNER_KEY);
        uint256 apy = _apy(0, P30);

        vm.warp(t + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherExpired.selector, t, t + 1));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);

        vm.warp(t);
        vm.prank(alice);
        staking.stakeWithVoucher(w, sigW, 1_000 * ONE, apy);
        assertEq(staking.checkDepositCountOfAddress(alice), 1);
    }

    /// @dev Hypothesis: a compromised / buggy signer can grant unbounded extras. The owner caps bound it even
    ///      for a validly signed voucher, and lowering a cap retroactively blocks already-issued vouchers.
    function test_voucher_extrasCappedByOwner_evenWhenValidlySigned() public {
        staking.setMaxExtraApyBps(300);
        staking.setMaxExtraLimitTotal(5_000 * ONE);
        uint256 apy = _apy(0, P30);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 301, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherExtraApyTooHigh.selector, 301, 300));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);

        (v, sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 5_000 * ONE + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherExtraLimitTotalTooHigh.selector, 5_000 * ONE + 1, 5_000 * ONE));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);

        // exactly at the caps is fine
        _stakeVWith(staking, alice, 0, P30, 1_000 * ONE, 300, 5_000 * ONE);
        assertEq(_deposit(alice, 0).APY, apy + 300);

        // issued at the cap, then the owner lowers the cap before it is used
        (v, sig) = _prepareVoucherStake(staking, alice, 0, P30, 300, 0);
        staking.setMaxExtraApyBps(299);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherExtraApyTooHigh.selector, 300, 299));
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy + 300);
        // max caps cannot be set past their storage width
        vm.expectRevert();
        staking.setMaxExtraApyBps(uint256(type(uint32).max) + 1);
        vm.expectRevert();
        staking.setMaxExtraLimitTotal(uint256(type(uint128).max) + 1);
    }

    /// @dev Rotating the signer invalidates every outstanding voucher of the old key; unsetting it stops staking
    ///      with a typed error while claims and withdrawals keep working.
    function test_voucher_signerRotationAndDisable() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        uint256 apy = _apy(0, P30);

        uint256 newKey = 0xC0FFEE;
        staking.setVoucherSigner(vm.addr(newKey));
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidVoucherSignature.selector);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        bytes memory newSig = _signVoucher(address(staking), v, newKey);
        vm.prank(alice);
        staking.stakeWithVoucher(v, newSig, 1_000 * ONE, apy);

        staking.setVoucherSigner(address(0));
        (v, sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        vm.prank(alice);
        vm.expectRevert(Errors.VoucherSignerNotSet.selector);
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, apy);
        // an attacker cannot "sign" for the zero address with an invalid signature either
        vm.prank(alice);
        vm.expectRevert(Errors.VoucherSignerNotSet.selector);
        staking.stakeWithVoucher(v, "", 1_000 * ONE, apy);

        _warpDays(3);
        _withdraw(alice, d);
        _assertAccounting();
    }
}
