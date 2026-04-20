// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/LimitControllerFunctions.sol";
import "../../../src/common/Errors.sol";
import "../../../src/common/Types.sol";

contract LimitControllerScenarios is LimitControllerFunctions, Errors {
    // ======================================
    // =      Constructor Tests             =
    // ======================================

    function test_LimitController_Constructor_ValidAddress() external {
        _deployLimitController(address(stakingContract));
        assertEq(address(limitController.stakingContract()), address(stakingContract));
    }

    function test_LimitController_Constructor_ZeroAddress() external {
        vm.expectRevert(ZeroAddressProvided.selector);
        new LimitController(address(0));
    }

    // ======================================
    // =   setStakingContract Tests         =
    // ======================================

    function test_LimitController_SetStakingContract_ValidAddress() external {
        _deployLimitController(address(stakingContract));

        address newStakingContract = address(0x1234);
        vm.prank(limitController.owner());
        _setStakingContract(newStakingContract, false);

        assertEq(address(limitController.stakingContract()), newStakingContract);
    }

    function test_LimitController_SetStakingContract_ZeroAddress() external {
        _deployLimitController(address(stakingContract));

        vm.prank(limitController.owner());
        vm.expectRevert(ZeroAddressProvided.selector);
        limitController.setStakingContract(address(0));
    }

    function test_LimitController_SetStakingContract_NotOwner() external {
        _deployLimitController(address(stakingContract));

        vm.prank(userOne);
        vm.expectRevert();
        limitController.setStakingContract(address(0x1234));
    }

    // ======================================
    // =   setWalletLimit Tests             =
    // ======================================

    function test_LimitController_SetWalletLimit_Valid() external {
        _deployLimitController(address(stakingContract));
        uint256 limit = 1000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        assertEq(_getAllowed(userOne, 0, 0), limit);
    }

    function test_LimitController_SetWalletLimit_ZeroAddress() external {
        _deployLimitController(address(stakingContract));

        vm.prank(limitController.owner());
        vm.expectRevert(ZeroAddressProvided.selector);
        limitController.setWalletLimit(address(0), 0, 0, 1000 * myTokenDecimals);
    }

    function test_LimitController_SetWalletLimit_NotOwner() external {
        _deployLimitController(address(stakingContract));

        vm.prank(userOne);
        vm.expectRevert();
        limitController.setWalletLimit(userOne, 0, 0, 1000 * myTokenDecimals);
    }

    function test_LimitController_SetWalletLimit_ZeroLimit() external {
        _deployLimitController(address(stakingContract));

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, 0, false);

        assertEq(_getAllowed(userOne, 0, 0), 0);
    }

    function test_LimitController_SetWalletLimit_MultiplePhasesPeriods() external {
        _deployLimitController(address(stakingContract));
        uint256 limit1 = 1000 * myTokenDecimals;
        uint256 limit2 = 2000 * myTokenDecimals;
        uint256 limit3 = 3000 * myTokenDecimals;

        vm.startPrank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit1, false);
        _setWalletLimit(userOne, 0, 90, limit2, false);
        _setWalletLimit(userOne, 1, 0, limit3, false);
        vm.stopPrank();

        assertEq(_getAllowed(userOne, 0, 0), limit1);
        assertEq(_getAllowed(userOne, 0, 90), limit2);
        assertEq(_getAllowed(userOne, 1, 0), limit3);
    }

    function test_LimitController_SetWalletLimit_UpdateExisting() external {
        _deployLimitController(address(stakingContract));
        uint256 initialLimit = 1000 * myTokenDecimals;
        uint256 updatedLimit = 2000 * myTokenDecimals;

        vm.startPrank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, initialLimit, false);
        assertEq(_getAllowed(userOne, 0, 0), initialLimit);

        _setWalletLimit(userOne, 0, 0, updatedLimit, false);
        assertEq(_getAllowed(userOne, 0, 0), updatedLimit);
        vm.stopPrank();
    }

    // ======================================
    // =   setWalletLimits Tests            =
    // ======================================

    function test_LimitController_SetWalletLimits_Valid() external {
        _deployLimitController(address(stakingContract));
        address[] memory wallets = new address[](3);
        wallets[0] = userOne;
        wallets[1] = userTwo;
        wallets[2] = userThree;

        uint256[] memory limits = new uint256[](3);
        limits[0] = 1000 * myTokenDecimals;
        limits[1] = 2000 * myTokenDecimals;
        limits[2] = 3000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimits(wallets, 0, 0, limits, false);

        assertEq(_getAllowed(userOne, 0, 0), limits[0]);
        assertEq(_getAllowed(userTwo, 0, 0), limits[1]);
        assertEq(_getAllowed(userThree, 0, 0), limits[2]);
    }

    function test_LimitController_SetWalletLimits_LengthMismatch() external {
        _deployLimitController(address(stakingContract));
        address[] memory wallets = new address[](2);
        wallets[0] = userOne;
        wallets[1] = userTwo;

        uint256[] memory limits = new uint256[](3);
        limits[0] = 1000 * myTokenDecimals;
        limits[1] = 2000 * myTokenDecimals;
        limits[2] = 3000 * myTokenDecimals;

        vm.prank(limitController.owner());
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, wallets.length, limits.length));
        limitController.setWalletLimits(wallets, 0, 0, limits);
    }

    function test_LimitController_SetWalletLimits_ZeroAddressInArray() external {
        _deployLimitController(address(stakingContract));
        address[] memory wallets = new address[](2);
        wallets[0] = userOne;
        wallets[1] = address(0);

        uint256[] memory limits = new uint256[](2);
        limits[0] = 1000 * myTokenDecimals;
        limits[1] = 2000 * myTokenDecimals;

        vm.prank(limitController.owner());
        vm.expectRevert(ZeroAddressProvided.selector);
        limitController.setWalletLimits(wallets, 0, 0, limits);
    }

    function test_LimitController_SetWalletLimits_NotOwner() external {
        _deployLimitController(address(stakingContract));
        address[] memory wallets = new address[](1);
        wallets[0] = userOne;

        uint256[] memory limits = new uint256[](1);
        limits[0] = 1000 * myTokenDecimals;

        vm.prank(userOne);
        vm.expectRevert();
        limitController.setWalletLimits(wallets, 0, 0, limits);
    }

    // ======================================
    // =   getAllowed Tests                 =
    // ======================================

    function test_LimitController_GetAllowed_NotSet() external {
        _deployLimitController(address(stakingContract));

        assertEq(_getAllowed(userOne, 0, 0), 0);
    }

    function test_LimitController_GetAllowed_AfterSet() external {
        _deployLimitController(address(stakingContract));
        uint256 limit = 5000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        assertEq(_getAllowed(userOne, 0, 0), limit);
    }

    // ======================================
    // =   getRemaining Tests               =
    // ======================================

    function test_LimitController_GetRemaining_NoLimitSet() external {
        _deployLimitController(address(stakingContract));

        // No limit set, should return 0 (no staking allowed)
        assertEq(_getRemaining(userOne, 0, 0), 0);
    }

    function test_LimitController_GetRemaining_NoStakingYet() external {
        _deployLimitController(address(stakingContract));
        uint256 limit = 1000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // No staking yet, remaining should equal limit
        assertEq(_getRemaining(userOne, 0, 0), limit);
    }

    function test_LimitController_GetRemaining_ExceedsLimit() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 1000 * myTokenDecimals;
        uint256 stakeAmount = 1500 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // Stake more than limit (this should fail, but if it somehow happened, remaining would be 0)
        // First stake up to limit
        _increaseAllowance(userOne, limit);
        _stakeTokenWithTest(userOne, 0, 0, limit, false);

        // Try to stake more (should fail)
        _increaseAllowance(userOne, stakeAmount - limit);
        _stakeTokenWithTest(userOne, 0, 0, stakeAmount - limit, true);

        // Remaining should still be 0
        assertEq(_getRemaining(userOne, 0, 0), 0);
    }

    // ======================================
    // =   Integration Tests                =
    // ======================================

    function test_LimitController_Staking_WithinLimit() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 1000 * myTokenDecimals;
        uint256 stakeAmount = 500 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // Stake within limit should succeed
        _increaseAllowance(userOne, stakeAmount);
        _stakeTokenWithTest(userOne, 0, 0, stakeAmount, false);

        assertEq(_getRemaining(userOne, 0, 0), limit - stakeAmount);
    }

    function test_LimitController_Staking_ExceedsLimit() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 100 * myTokenDecimals;
        uint256 stakeAmount = 150 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // Stake exceeding limit should fail
        _increaseAllowance(userOne, stakeAmount);
        uint256 phasePeriodAPY = _getPhasePeriodAPY(0, 0);

        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, stakeAmount, limit));
        stakingContract.safeStake(0, 0, stakeAmount, phasePeriodAPY);
    }

    function test_LimitController_Staking_AtLimit() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 1000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // Stake exactly at limit should succeed
        _increaseAllowance(userOne, limit);
        _stakeTokenWithTest(userOne, 0, 0, limit, false);

        assertEq(_getRemaining(userOne, 0, 0), 0);
    }

    function test_LimitController_Staking_MultipleDeposits() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 100 * myTokenDecimals;
        uint256 firstStake = 30 * myTokenDecimals;
        uint256 secondStake = 40 * myTokenDecimals;
        uint256 thirdStake = 30 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // First stake
        _increaseAllowance(userOne, firstStake);
        _stakeTokenWithTest(userOne, 0, 0, firstStake, false);
        assertEq(_getRemaining(userOne, 0, 0), limit - firstStake);

        // Second stake
        _increaseAllowance(userOne, secondStake);
        _stakeTokenWithTest(userOne, 0, 0, secondStake, false);
        assertEq(_getRemaining(userOne, 0, 0), limit - firstStake - secondStake);

        // Third stake (should complete the limit)
        _increaseAllowance(userOne, thirdStake);
        _stakeTokenWithTest(userOne, 0, 0, thirdStake, false);
        assertEq(_getRemaining(userOne, 0, 0), 0);

        // Fourth stake should fail
        _increaseAllowance(userOne, 100 * myTokenDecimals);

        uint256 phasePeriodAPY = _getPhasePeriodAPY(0, 0);

        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, 100 * myTokenDecimals, 0));
        stakingContract.safeStake(0, 0, 100 * myTokenDecimals, phasePeriodAPY);
    }

    function test_LimitController_Staking_DifferentPhasesPeriods() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit1 = 100 * myTokenDecimals;
        uint256 limit2 = 200 * myTokenDecimals;
        uint256 stakeAmount1 = 50 * myTokenDecimals;
        uint256 stakeAmount2 = 100 * myTokenDecimals;

        vm.startPrank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit1, false);
        _setWalletLimit(userOne, 0, 90, limit2, false);
        vm.stopPrank();

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // Stake in phase 0, period 0
        _increaseAllowance(userOne, stakeAmount1);
        _stakeTokenWithTest(userOne, 0, 0, stakeAmount1, false);
        assertEq(_getRemaining(userOne, 0, 0), limit1 - stakeAmount1);

        // Stake in phase 0, period 90 (different limit)
        _increaseAllowance(userOne, stakeAmount2);
        _stakeTokenWithTest(userOne, 0, 90, stakeAmount2, false);
        assertEq(_getRemaining(userOne, 0, 90), limit2 - stakeAmount2);

        // Limits should be independent
        assertEq(_getRemaining(userOne, 0, 0), limit1 - stakeAmount1);
    }

    function test_LimitController_Staking_ZeroLimit() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, 0, false);

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // Staking with zero limit should fail
        _increaseAllowance(userOne, amountToStake);
        uint256 phasePeriodAPY = _getPhasePeriodAPY(0, 0);

        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, amountToStake, 0));

        stakingContract.safeStake(0, 0, amountToStake, phasePeriodAPY);
    }

    function test_LimitController_Staking_ControllerNotSet() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 1000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Don't set limit controller on staking contract

        // Staking should succeed (limit check is bypassed)
        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, false);
    }

    function test_LimitController_Staking_ControllerDisabled() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit = 1000 * myTokenDecimals;

        vm.prank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit, false);

        // Set limit controller, then disable it
        _setLimitControllerOnStakingContract(address(limitController));
        _setLimitControllerOnStakingContract(address(0));

        // Staking should succeed (limit check is bypassed)
        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, false);
    }

    function test_LimitController_Staking_MultipleUsers() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        uint256 limit1 = 1000 * myTokenDecimals;
        uint256 limit2 = 2000 * myTokenDecimals;

        vm.startPrank(limitController.owner());
        _setWalletLimit(userOne, 0, 0, limit1, false);
        _setWalletLimit(userTwo, 0, 0, limit2, false);
        vm.stopPrank();

        // Set limit controller on staking contract
        _setLimitControllerOnStakingContract(address(limitController));

        // User one stakes
        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, false);
        assertEq(_getRemaining(userOne, 0, 0), limit1 - amountToStake);

        // User two stakes (independent limit)
        _increaseAllowance(userTwo, amountToStake);
        _stakeTokenWithTest(userTwo, 0, 0, amountToStake, false);
        assertEq(_getRemaining(userTwo, 0, 0), limit2 - amountToStake);
    }
}
