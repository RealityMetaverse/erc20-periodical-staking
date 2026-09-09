// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";

/// @title Two-step ownership transfer
contract TwoStepOwnershipTest is V030Base {
    function test_Propose_DoesNotMoveOwnership() public {
        vm.expectEmit(true, true, false, true, address(stakingContract));
        emit OwnershipTransferStarted(address(this), userOne);
        stakingContract.transferOwnership(userOne);

        assertEq(stakingContract.contractOwner(), address(this));
        assertEq(stakingContract.pendingOwner(), userOne);
    }

    function test_PendingOwner_CannotActBeforeAccepting() public {
        stakingContract.transferOwnership(userOne);

        vm.startPrank(userOne);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER)
        );
        stakingContract.setMiniumumDeposit(1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER)
        );
        stakingContract.transferOwnership(userTwo);

        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.ADMIN)
        );
        stakingContract.provideReward(1);
        vm.stopPrank();
    }

    function test_NonPendingOwner_CannotAccept() public {
        stakingContract.transferOwnership(userOne);

        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, userTwo, userOne));
        stakingContract.acceptOwnership();

        // Current owner cannot accept on behalf of the proposal either.
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, address(this), userOne));
        stakingContract.acceptOwnership();
    }

    function test_Accept_WithoutProposal_Reverts() public {
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, userOne, address(0)));
        stakingContract.acceptOwnership();
    }

    function test_Accept_MovesOwnership_AndOldOwnerLosesAccess() public {
        stakingContract.transferOwnership(userOne);

        vm.expectEmit(false, false, false, true, address(stakingContract));
        emit TransferOwnership(address(this), userOne);
        vm.prank(userOne);
        stakingContract.acceptOwnership();

        assertEq(stakingContract.contractOwner(), userOne);
        assertEq(stakingContract.pendingOwner(), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER)
        );
        stakingContract.setMiniumumDeposit(1 ether);

        vm.prank(userOne);
        stakingContract.setMiniumumDeposit(1 ether);
        assertEq(stakingContract.minimumDeposit(), 1 ether);

        // Cannot accept twice.
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, userOne, address(0)));
        stakingContract.acceptOwnership();
    }

    function test_Cancel_ByProposingZeroAddress() public {
        stakingContract.transferOwnership(userOne);
        stakingContract.transferOwnership(address(0));
        assertEq(stakingContract.pendingOwner(), address(0));

        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, userOne, address(0)));
        stakingContract.acceptOwnership();
        assertEq(stakingContract.contractOwner(), address(this));
    }

    function test_Reproposal_OverridesPrevious() public {
        stakingContract.transferOwnership(userOne);
        stakingContract.transferOwnership(userTwo);

        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingOwner.selector, userOne, userTwo));
        stakingContract.acceptOwnership();

        vm.prank(userTwo);
        stakingContract.acceptOwnership();
        assertEq(stakingContract.contractOwner(), userTwo);
    }

    function test_NonOwner_CannotPropose() public {
        vm.prank(contractAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER)
        );
        stakingContract.transferOwnership(userOne);
    }
}
