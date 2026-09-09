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

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 2, 1));
        stakingContract.getDepositsInRangeBy(userOne, 2, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRange.selector, 0, 3));
        stakingContract.getDepositsInRangeBy(userOne, 0, 3);

        ProgramManager.TokenDeposit[] memory all = stakingContract.getDepositsInRangeBy(userOne, 0, 2);
        assertEq(all.length, 2);
        assertEq(all[0].stakingPeriod, PERIOD_SHORT);
        assertEq(all[1].stakingPeriod, PERIOD_LONG);

        ProgramManager.TokenDeposit[] memory none = stakingContract.getDepositsInRangeBy(userOne, 1, 1);
        assertEq(none.length, 0);

        ProgramManager.TokenDeposit[] memory last = stakingContract.getDepositsInRangeBy(userOne, 1, 2);
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
}
