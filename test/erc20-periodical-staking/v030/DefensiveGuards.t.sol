// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";

/// @title Defensive admin/view guards
contract DefensiveGuardsTest is V030Base {
    function test_PopStakingPhase_RevertsWhenNoPhases() public {
        assertEq(stakingContract.stakingPhaseCount(), 0);
        vm.expectRevert(Errors.NoStakingPhasesAddedYet.selector);
        stakingContract.popStakingPhase();

        // Still works normally once a phase exists, and reverts again once emptied.
        _setupProgram(false);
        stakingContract.popStakingPhase();
        vm.expectRevert(Errors.NoStakingPhasesAddedYet.selector);
        stakingContract.popStakingPhase();
    }

    function test_GetDeposit_RevertsOnMissingDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        stakingContract.getDeposit(userOne, 0);

        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        stakingContract.getDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 1));
        stakingContract.getDeposit(userOne, 1);
    }

    function test_CheckDepositStatus_RevertsOnMissingDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 7));
        stakingContract.checkDepositStatus(userOne, 7);
    }

    function test_GetDepositsInRangeBy_Validation() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);

        _lens(stakingContract);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 2, 1));
        _lens(stakingContract).getDepositsInRangeBy(userOne, 2, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 3));
        _lens(stakingContract).getDepositsInRangeBy(userOne, 0, 3);

        ProgramManager.TokenDeposit[] memory all = _lens(stakingContract).getDepositsInRangeBy(userOne, 0, 2);
        assertEq(all.length, 2);
        assertEq(all[0].stakingPeriod, PERIOD_SHORT);
        assertEq(all[1].stakingPeriod, PERIOD_LONG);

        ProgramManager.TokenDeposit[] memory none = _lens(stakingContract).getDepositsInRangeBy(userOne, 1, 1);
        assertEq(none.length, 0);

        ProgramManager.TokenDeposit[] memory last = _lens(stakingContract).getDepositsInRangeBy(userOne, 1, 2);
        assertEq(last.length, 1);
        assertEq(last[0].stakingPeriod, PERIOD_LONG);
    }

    function test_CollectReward_RejectsZero() public {
        _setupProgram(true);
        vm.expectRevert(Errors.ZeroAmountProvided.selector);
        stakingContract.collectReward(0);
    }

    function test_ProvideReward_RejectsZero() public {
        vm.expectRevert(Errors.ZeroAmountProvided.selector);
        stakingContract.provideReward(0);
    }

    function test_CollectReward_RecordsRewardCollected() public {
        _setupProgram(true);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_PROVIDED), amountToProvide);
        assertEq(stakingContract.userDataList(Types.DataType.REWARD_PROVIDED, contractAdmin), amountToProvide);

        uint256 half = amountToProvide / 2;
        vm.expectEmit(true, false, false, true, address(stakingContract));
        emit CollectReward(address(this), half);
        stakingContract.collectReward(half);

        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_COLLECTED), half);
        assertEq(stakingContract.userDataList(Types.DataType.REWARD_COLLECTED, address(this)), half);
        assertEq(stakingContract.rewardPool(), amountToProvide - half);
        // Symmetry: provided - collected == pool when nothing has been paid out.
        assertEq(
            stakingContract.totalDataList(Types.DataType.REWARD_PROVIDED)
                - stakingContract.totalDataList(Types.DataType.REWARD_COLLECTED),
            stakingContract.rewardPool()
        );
    }

    function test_RemoveStakingPeriod_UnknownPeriodReverts() public {
        _setupProgram(false);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, 365));
        stakingContract.removeStakingPeriod(365);
    }

    // ======================================
    // =     Freeze / seize guards (v0.4.0)  =
    // ======================================

    function _pair(address w, uint256 n) internal pure returns (address[] memory ws, uint256[] memory ns) {
        ws = new address[](1);
        ns = new uint256[](1);
        ws[0] = w;
        ns[0] = n;
    }

    function test_Enforcement_MissingDepositReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        stakingContract.isDepositFrozen(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        stakingContract.freezeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        stakingContract.unfreezeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 0));
        stakingContract.seizeDeposit(userOne, 0);
    }

    function test_Freeze_OnlyOpenDeposits_NoDoubleFreeze_SeizeNeedsFrozen() public {
        _setupProgram(true);
        _stakeFor(userOne, 0, STAKE_AMOUNT); // 0: closed below
        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, userOne, 0));
        stakingContract.freezeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 0));
        stakingContract.unfreezeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 0));
        stakingContract.seizeDeposit(userOne, 0);

        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT); // 1: open
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 1));
        stakingContract.seizeDeposit(userOne, 1);

        vm.expectEmit(true, true, true, true, address(stakingContract));
        emit FreezeDeposit(userOne, 1, contractAdmin);
        vm.prank(contractAdmin);
        stakingContract.freezeDeposit(userOne, 1);
        assertTrue(stakingContract.isDepositFrozen(userOne, 1));
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 1));
        stakingContract.freezeDeposit(userOne, 1);

        vm.expectEmit(true, true, true, true, address(stakingContract));
        emit UnfreezeDeposit(userOne, 1, address(this));
        stakingContract.unfreezeDeposit(userOne, 1);
        assertFalse(stakingContract.isDepositFrozen(userOne, 1));

        // Seized deposits are final: not freezable, not seizable again.
        stakingContract.freezeDeposit(userOne, 1);
        stakingContract.seizeDeposit(userOne, 1);
        assertEq(
            uint256(stakingContract.checkDepositStatus(userOne, 1)), uint256(ProgramManager.DepositStatus.SEIZED)
        );
        assertFalse(stakingContract.isDepositFrozen(userOne, 1));
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, userOne, 1));
        stakingContract.freezeDeposit(userOne, 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 1));
        stakingContract.seizeDeposit(userOne, 1);
    }

    /// @notice A frozen deposit blocks every individual user exit; batch claims skip it; unfreezing restores it.
    function test_Frozen_BlocksUserExits_UnfreezeRestores() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT); // 0
        _stakeFor(userOne, 0, STAKE_AMOUNT); // 1
        skip(8 days);

        address[] memory ws = new address[](2);
        uint256[] memory ns = new uint256[](2);
        ws[0] = userOne;
        ws[1] = userOne;
        ns[0] = 0;
        ns[1] = 1;
        vm.prank(contractAdmin);
        stakingContract.freezeDeposits(ws, ns);

        vm.startPrank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 0));
        stakingContract.claimDeposit(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 1));
        stakingContract.claimDeposit(1);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 1));
        stakingContract.withdrawDeposit(1);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 1));
        stakingContract.withdrawDepositPartial(1, 0);
        uint256 before = myToken.balanceOf(userOne);
        stakingContract.claimAll();
        vm.stopPrank();
        assertEq(myToken.balanceOf(userOne), before, "claimAll skipped both frozen deposits");
        (uint256 s, uint256 p, uint256 i) = stakingContract.checkClaimableDataFor(userOne);
        assertEq(s + p + i, 0);

        vm.prank(contractAdmin);
        stakingContract.unfreezeDeposits(ws, ns);
        vm.prank(userOne);
        stakingContract.claimAll();
        assertEq(
            myToken.balanceOf(userOne) - before,
            STAKE_AMOUNT + _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT) + _periodicalReward(STAKE_AMOUNT, 8)
        );
    }

    function test_Enforcement_AccessControl() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        (address[] memory ws, uint256[] memory ns) = _pair(userOne, 0);

        bytes memory notAdmin =
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.ADMIN);
        bytes memory notOwner =
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER);

        vm.startPrank(userOne);
        vm.expectRevert(notAdmin);
        stakingContract.freezeDeposit(userOne, 0);
        vm.expectRevert(notAdmin);
        stakingContract.freezeDeposits(ws, ns);
        vm.stopPrank();

        vm.prank(contractAdmin);
        stakingContract.freezeDeposit(userOne, 0);

        vm.startPrank(userOne);
        vm.expectRevert(notAdmin);
        stakingContract.unfreezeDeposit(userOne, 0);
        vm.expectRevert(notAdmin);
        stakingContract.unfreezeDeposits(ws, ns);
        vm.expectRevert(notOwner);
        stakingContract.seizeDeposit(userOne, 0);
        vm.stopPrank();

        // Admins may freeze but never seize.
        vm.startPrank(contractAdmin);
        vm.expectRevert(notOwner);
        stakingContract.seizeDeposit(userOne, 0);
        vm.expectRevert(notOwner);
        stakingContract.seizeDeposits(ws, ns);
        vm.stopPrank();
        assertTrue(stakingContract.isDepositFrozen(userOne, 0));
    }

    function test_Enforcement_BatchLengthMismatchAndAtomicity() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT);

        address[] memory ws = new address[](2);
        uint256[] memory one = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        stakingContract.freezeDeposits(ws, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        stakingContract.unfreezeDeposits(ws, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        stakingContract.seizeDeposits(ws, one);

        // One bad entry (userTwo has no deposit 5) reverts the whole batch: userOne stays unfrozen.
        uint256[] memory ns = new uint256[](2);
        ws[0] = userOne;
        ws[1] = userTwo;
        ns[1] = 5;
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 5));
        stakingContract.freezeDeposits(ws, ns);
        assertFalse(stakingContract.isDepositFrozen(userOne, 0));
    }

    function test_SetTreasury_RejectsZero() public {
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        stakingContract.setTreasury(address(0));
        assertEq(stakingContract.treasury(), treasury);
    }
}
