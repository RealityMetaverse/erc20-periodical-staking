// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AuxiliaryFunctions.sol";

contract MainManagementScenarios is AuxiliaryFunctions {
    // ======================================
    // =         Access Control Test        =
    // ======================================
    enum Action {
        PUSH_PHASE,
        ADD_PERIOD,
        POP_PHASE,
        REMOVE_PERIOD
    }

    function _performAction(Action action, address userAddress) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        if (action == Action.PUSH_PHASE) _pushStakingPhase(userAddress);
        else if (action == Action.ADD_PERIOD) _addStakingPeriod(userAddress);
        else if (action == Action.POP_PHASE) _popStakingPhase(userAddress);
        else if (action == Action.REMOVE_PERIOD) _removeStakingPeriod(userAddress);

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _checkAccesControl(address userAddress, Action action) internal {
        vm.expectRevert();
        _performAction(action, userAddress);
    }

    function test_AccessControl_RevertProgramControlAccess() external {
        for (uint256 actionNo; actionNo < 3; actionNo++) {
            for (uint256 userNo = 0; userNo < addressList.length; userNo++) {
                _checkAccesControl(addressList[userNo], Action(actionNo));
            }

            _checkAccesControl(contractAdmin, Action(actionNo));
        }
    }

    // ======================================
    // =      Program Management Test       =
    // ======================================
    function test_ProgramManagement_TransferOwnership() external {
        vm.startPrank(contractAdmin);
        vm.expectRevert();
        stakingContract.transferOwnership(userOne);
        vm.stopPrank();

        vm.startPrank(userOne);
        vm.expectRevert();
        stakingContract.transferOwnership(userTwo);
        vm.stopPrank();

        assertEq(stakingContract.contractOwner(), address(this));

        stakingContract.transferOwnership(userOne);
        assertEq(stakingContract.contractOwner(), userOne);
    }

    function test_ProgramManagement_AddRemoveAdmin() external {
        assertEq(stakingContract.contractAdmins(contractAdmin), true);

        stakingContract.removeContractAdmin(contractAdmin);
        assertEq(stakingContract.contractAdmins(contractAdmin), false);
    }

    // ======================================
    // =    Phase Period Management Test    =
    // ======================================
    function test_PhasePeriodManagement_PushPhase() external {
        uint8 x = 20;
        for (uint8 No = 0; No < x; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
    }

    function test_PhasePeriodManagement_AddPeriod() external {
        uint8 x = 20;
        for (uint8 No = 0; No < x; No++) {
            _addStakingPeriodWithTest(address(this));
        }
    }

    function test_PhasePeriodManagement_PushPopPhase() external {
        uint8 x = 20;
        uint8 y = 20;

        for (uint8 No = 0; No < x; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < x; No++) {
            _popStakingPhase(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _popStakingPhase(address(this));
        }
    }

    function test_PhasePeriodManagement_AddRemovePeriod() external {
        uint8 x = 20;
        uint8 y = 20;

        for (uint8 No = 0; No < x; No++) {
            _addStakingPeriodWithTest(address(this));
        }
        for (uint8 No = 0; No < x; No++) {
            _removeStakingPeriod(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _addStakingPeriodWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _removeStakingPeriod(address(this));
        }
    }

    function test_PhasePeriodManagement_PushPhaseAddPeriod() external {
        uint8 x = 20;
        uint8 y = 20;
        uint8 z = 20;
        uint8 a = 20;

        for (uint8 No = 0; No < x; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _addStakingPeriodWithTest(address(this));
        }
        for (uint8 No = 0; No < z; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < a; No++) {
            _addStakingPeriodWithTest(address(this));
        }
    }

    function test_PhasePeriodManagement_PushPopPhaseAddRemovePeriod() external {
        uint8 x = 20;
        uint8 y = 20;

        for (uint8 No = 0; No < x; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _addStakingPeriodWithTest(address(this));
        }
        for (uint8 No = 0; No < x; No++) {
            _popStakingPhase(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _removeStakingPeriod(address(this));
        }
    }

    // ======================================
    // =       Reward Management Test      =
    // ======================================
    function test_RewardManagement_ProvideReward() external {
        _increaseAllowance(contractAdmin, amountToProvide);

        vm.startPrank(contractAdmin);
        stakingContract.provideReward(amountToProvide);
        vm.stopPrank();
    }

    function test_RewardManagement_CollectReward() external {
        _increaseAllowance(contractAdmin, amountToProvide);

        vm.startPrank(contractAdmin);
        stakingContract.provideReward(amountToProvide);
        assertEq(stakingContract.getUserData(ProgramManager.DataType.REWARD_PROVIDED, contractAdmin), amountToProvide);
        vm.expectRevert();
        stakingContract.collectReward(amountToProvide);
        vm.stopPrank();
        stakingContract.collectReward(amountToProvide);
    }

    function test_RewardManagement_NotEnoughFundsInTheRewardPool() external {
        _increaseAllowance(address(this), amountToProvide);

        stakingContract.provideReward(amountToProvide);
        stakingContract.collectReward(amountToProvide);

        vm.expectRevert();
        stakingContract.collectReward(amountToProvide);
    }
}
