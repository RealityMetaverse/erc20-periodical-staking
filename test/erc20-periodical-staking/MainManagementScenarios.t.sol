// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AuxiliaryFunctions.sol";
import "../../src/common/Types.sol";
import "../../src/common/Errors.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
    // =  Voucher, Limit & Treasury Config  =
    // ======================================
    // v0.4.0: the whitelist tests were removed together with the whitelist; these cover its replacement settings.
    function test_VoucherConfig_OnlyOwner() external {
        address[2] memory callers = [userOne, contractAdmin];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert();
            stakingContract.setVoucherSigner(userOne);
            vm.expectRevert();
            stakingContract.setMaxExtraApyBps(1);
            vm.expectRevert();
            stakingContract.setMaxExtraLimit(1);
            vm.expectRevert();
            stakingContract.setTreasury(userOne);
            vm.expectRevert();
            stakingContract.setLimitController(address(0));
            vm.stopPrank();
        }

        assertEq(stakingContract.voucherSigner(), _voucherSignerAddr());
        assertEq(stakingContract.treasury(), treasury);
        assertTrue(stakingContract.limitController() != address(0));
    }

    function test_VoucherConfig_OwnerSetters() external {
        stakingContract.setVoucherSigner(userTwo);
        assertEq(stakingContract.voucherSigner(), userTwo);
        // address(0) is allowed: it disables staking.
        stakingContract.setVoucherSigner(address(0));
        assertEq(stakingContract.voucherSigner(), address(0));

        stakingContract.setMaxExtraApyBps(250);
        assertEq(stakingContract.maxExtraApyBps(), 250);
        stakingContract.setMaxExtraApyBps(type(uint32).max);
        assertEq(stakingContract.maxExtraApyBps(), type(uint32).max);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, 1 << 32));
        stakingContract.setMaxExtraApyBps(1 << 32);

        stakingContract.setMaxExtraLimit(5e18);
        assertEq(stakingContract.maxExtraLimit(), 5e18);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, 1 << 128));
        stakingContract.setMaxExtraLimit(1 << 128);

        stakingContract.setTreasury(userThree);
        assertEq(stakingContract.treasury(), userThree);
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        stakingContract.setTreasury(address(0));
        assertEq(stakingContract.treasury(), userThree);

        stakingContract.setLimitController(address(0));
        assertEq(stakingContract.limitController(), address(0));
    }

    function test_ProgramManagement_MinimumDeposit() external {
        assertEq(stakingContract.minimumDeposit(), 100);
        stakingContract.setMiniumumDeposit(_defaultMinimumDeposit);
        assertEq(stakingContract.minimumDeposit(), _defaultMinimumDeposit);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMinimumDeposit.selector, 0, 1));
        stakingContract.setMiniumumDeposit(0);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, 1 << 128));
        stakingContract.setMiniumumDeposit(1 << 128);
        assertEq(stakingContract.minimumDeposit(), _defaultMinimumDeposit);
    }

    /// @notice Only STAKING, WITHDRAWAL and CLAIM have an availability switch.
    function test_ProgramManagement_ActionAvailability() external {
        Types.DataType[3] memory actions = [Types.DataType.STAKING, Types.DataType.WITHDRAWAL, Types.DataType.CLAIM];
        for (uint256 i = 0; i < actions.length; i++) {
            assertTrue(stakingContract.checkActionAvailability(actions[i]));
            stakingContract.changeActionAvailability(actions[i], false);
            assertFalse(stakingContract.checkActionAvailability(actions[i]));
            for (uint256 j = 0; j < actions.length; j++) {
                if (j > i) assertTrue(stakingContract.checkActionAvailability(actions[j]));
            }
        }
        stakingContract.changeActionAvailability(Types.DataType.CLAIM, true);
        assertTrue(stakingContract.checkActionAvailability(Types.DataType.CLAIM));

        assertFalse(stakingContract.checkActionAvailability(Types.DataType.REWARD_PROVIDED));
        vm.expectRevert(Errors.InvalidDataType.selector);
        stakingContract.changeActionAvailability(Types.DataType.REWARD_PROVIDED, true);
        vm.expectRevert(Errors.InvalidDataType.selector);
        stakingContract.changeActionAvailability(Types.DataType.REWARD_EXPECTED, true);
    }
}
