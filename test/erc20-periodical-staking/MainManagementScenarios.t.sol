// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AuxiliaryFunctions.sol";
import "../../src/common/Types.sol";

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

    function _performAction(Action action, address userAddress, bool ifRevertExpected) internal {
        if (action == Action.PUSH_PHASE) _pushStakingPhase(userAddress, ifRevertExpected);
        else if (action == Action.ADD_PERIOD) _addStakingPeriod(userAddress, ifRevertExpected);
        else if (action == Action.POP_PHASE) _popStakingPhase(userAddress, ifRevertExpected);
        else if (action == Action.REMOVE_PERIOD) _removeStakingPeriod(userAddress, ifRevertExpected);
    }

    function _checkAccesControl(address userAddress, Action action) internal {
        _performAction(action, userAddress, true);
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

        // v0.3.0: two-step ownership. Proposing does not move ownership.
        stakingContract.transferOwnership(userOne);
        assertEq(stakingContract.contractOwner(), address(this));
        assertEq(stakingContract.pendingOwner(), userOne);

        vm.startPrank(userTwo);
        vm.expectRevert();
        stakingContract.acceptOwnership();
        vm.stopPrank();

        vm.prank(userOne);
        stakingContract.acceptOwnership();
        assertEq(stakingContract.contractOwner(), userOne);
        assertEq(stakingContract.pendingOwner(), address(0));
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
            _popStakingPhase(address(this), false);
        }
        for (uint8 No = 0; No < y; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _popStakingPhase(address(this), false);
        }
    }

    function test_PhasePeriodManagement_AddRemovePeriod() external {
        uint8 x = 20;
        uint8 y = 20;

        for (uint8 No = 0; No < x; No++) {
            _addStakingPeriodWithTest(address(this));
        }
        for (uint8 No = 0; No < x; No++) {
            _removeStakingPeriod(address(this), false);
        }
        for (uint8 No = 0; No < y; No++) {
            _addStakingPeriodWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _removeStakingPeriod(address(this), false);
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
            _popStakingPhase(address(this), false);
        }
        for (uint8 No = 0; No < y; No++) {
            _removeStakingPeriod(address(this), false);
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
        assertEq(stakingContract.getUserData(Types.DataType.REWARD_PROVIDED, contractAdmin), amountToProvide);
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

    // ======================================
    // =       Whitelist Management Test    =
    // ======================================
    function test_WhitelistManagement_AccessControl() external {
        // Non-owner should not be able to change whitelist settings
        vm.startPrank(userOne);
        vm.expectRevert();
        stakingContract.setWhitelistEnabled(true);
        vm.expectRevert();
        stakingContract.setWhitelistAddress(userOne, true);
        vm.expectRevert();
        address[] memory addrs = new address[](1);
        addrs[0] = userOne;
        stakingContract.setWhitelistAddresses(addrs, true);
        vm.stopPrank();
    }

    function test_WhitelistManagement_SingleAndBatch() external {
        // Initially whitelist is disabled
        assertEq(stakingContract.whitelistEnabled(), false);

        // Enable whitelist
        stakingContract.setWhitelistEnabled(true);
        assertEq(stakingContract.whitelistEnabled(), true);

        // Single address update
        assertEq(stakingContract.isWhitelisted(userOne), false);
        stakingContract.setWhitelistAddress(userOne, true);
        assertEq(stakingContract.isWhitelisted(userOne), true);

        // Batch update for userTwo and userThree
        address[] memory addrs = new address[](2);
        addrs[0] = userTwo;
        addrs[1] = userThree;
        stakingContract.setWhitelistAddresses(addrs, true);
        assertEq(stakingContract.isWhitelisted(userTwo), true);
        assertEq(stakingContract.isWhitelisted(userThree), true);

        // Batch removal
        stakingContract.setWhitelistAddresses(addrs, false);
        assertEq(stakingContract.isWhitelisted(userTwo), false);
        assertEq(stakingContract.isWhitelisted(userThree), false);
    }
}
