// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";

/// @title AccessControl
/// @notice Full matrix: every privileged function x {admin, random user, pending owner} must revert with the exact
///         UnauthorizedAccess tier; user functions must be open to everyone; ownership handover must be complete.
contract AccessControlTest is AttackBase {
    function _ownerOnlyCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](18);
        uint256[] memory three = _fill(3, 1);
        uint256[] memory two = _fill(2, 1);
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
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
        calls[11] = abi.encodeCall(staking.setWhitelistEnabled, (true));
        calls[12] = abi.encodeCall(staking.setWhitelistAddress, (alice, true));
        calls[13] = abi.encodeCall(staking.setWhitelistAddresses, (addrs, true));
        calls[14] = abi.encodeCall(staking.setLimitController, (address(0)));
        calls[15] = abi.encodeCall(staking.setRequirementChecker, (address(0)));
        calls[16] = abi.encodeCall(staking.collectReward, (1));
        calls[17] = abi.encodeCall(staking.rescueTokens, (address(token), 1));
    }

    function _assertAllRevertUnauthorized(address caller, AccessControl.AccessTier tier) internal {
        bytes[] memory calls = _ownerOnlyCalls();
        bytes memory expected = _unauthorized(tier);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = _call(caller, address(staking), calls[i]);
            assertFalse(ok, string.concat("owner-only call #", vm.toString(i), " succeeded for non-owner"));
            assertEq(keccak256(ret), keccak256(expected), string.concat("wrong error for call #", vm.toString(i)));
        }
    }

    /// @dev Hypothesis: an admin can call some owner-only function.
    function test_matrix_admin_cannotCallOwnerFunctions() public {
        _assertAllRevertUnauthorized(admin, AccessControl.AccessTier.OWNER);
    }

    /// @dev Hypothesis: a random user can call some owner-only function.
    function test_matrix_rando_cannotCallOwnerFunctions() public {
        _assertAllRevertUnauthorized(rando, AccessControl.AccessTier.OWNER);
    }

    /// @dev Hypothesis: a pending owner already has owner powers.
    function test_matrix_pendingOwner_cannotCallOwnerFunctions() public {
        staking.transferOwnership(bob);
        _assertAllRevertUnauthorized(bob, AccessControl.AccessTier.OWNER);
        // and cannot provide rewards as an admin either
        vm.prank(bob);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.provideReward(1);
    }

    /// @dev Hypothesis: the owner is refused by some function it should be allowed to call.
    function test_matrix_owner_canCallEverything() public {
        bytes[] memory calls = _ownerOnlyCalls();
        token.transfer(address(staking), 1); // so rescue(1) has excess
        for (uint256 i = 0; i < calls.length; i++) {
            if (i == 0) continue; // transferOwnership tested separately (would change pending owner)
            (bool ok, bytes memory ret) = address(staking).call(calls[i]);
            assertTrue(ok, string.concat("owner refused on call #", vm.toString(i), " ", vm.toString(ret)));
        }
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
        staking.transferOwnership(bob);
        vm.prank(bob);
        staking.acceptOwnership();
        _assertAllRevertUnauthorized(owner, AccessControl.AccessTier.OWNER);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.ADMIN));
        staking.provideReward(1);
    }

    /// @dev Hypothesis: zero-address guards on admin management.
    function test_adminManagement_guards() public {
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        staking.addContractAdmin(address(0));
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
            vm.startPrank(c);
            token.approve(address(staking), type(uint256).max);
            uint256 apy = _apy(0, P0);
            staking.safeStake(0, P0, 1_000 * ONE, apy);
            uint256 d = staking.checkDepositCountOfAddress(c) - 1;
            staking.claimAll();
            staking.withdrawDeposit(d);
            vm.stopPrank();
        }
    }

    /// @dev Hypothesis: view functions are gated by access control (they must not be).
    function test_views_openToAll() public {
        vm.startPrank(rando);
        staking.getProgramData();
        staking.getProgramDataWithUserData(alice);
        staking.checkTotalClaimableData();
        staking.getCollectableReward();
        staking.getPhasePeriodDataAll(Types.PhasePeriodDataType.STAKED);
        staking.checkIfUserExceedsLimit(alice, 0, P30, 1);
        staking.checkIfUserMeetsRequirements(alice, 0, P30);
        vm.stopPrank();
    }
}
