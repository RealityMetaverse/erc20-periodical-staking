// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/LimitControllerFunctions.sol";
import "../../../src/common/Errors.sol";
import "../../../src/common/Types.sol";
import {MockLegacyStaking} from "../../shared/mocks/MockLegacyStaking.sol";
// Vendored v0.2.4 sources (never edited): a realistic legacy contract for the controller.
import {ERC20PeriodicalStaking as LegacyStaking} from
    "../security/invariants/legacy/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";

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
        _expectLimitRevert(userOne, 0, 0, stakeAmount, 0, abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, stakeAmount, limit));
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

        _expectLimitRevert(
            userOne,
            0,
            0,
            100 * myTokenDecimals,
            0,
            abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, 100 * myTokenDecimals, 0)
        );
    }

    function test_LimitController_Staking_DifferentPhasesPeriods() external {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);
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
        _expectLimitRevert(
            userOne, 0, 0, amountToStake, 0, abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, amountToStake, 0)
        );
    }

    /// @dev v0.4.0: with no controller the stake reverts (v0.3.0 skipped the limit check and let one wallet
    ///      take the whole target).
    function test_LimitController_Staking_ControllerNotSet() external {
        _addPhasesAndPeriods();
        _setLimitControllerOnStakingContract(address(0));

        _increaseAllowance(userOne, amountToStake);
        _expectLimitRevert(userOne, 0, 0, amountToStake, 0, abi.encodeWithSelector(LimitControllerNotSet.selector));
        assertEq(_getUserDepositCount(userOne), 0);
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

        _increaseAllowance(userOne, amountToStake);
        _expectLimitRevert(userOne, 0, 0, amountToStake, 0, abi.encodeWithSelector(LimitControllerNotSet.selector));

        // Re-enabling restores staking within the limit.
        _setLimitControllerOnStakingContract(address(limitController));
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, false);
        assertEq(_getRemaining(userOne, 0, 0), limit - amountToStake);
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

    // ======================================
    // =   v0.4.0: voucher extraLimit       =
    // ======================================

    function _expectLimitRevert(
        address user,
        uint256 phase,
        uint256 period,
        uint256 amount,
        uint256 extraLimit,
        bytes memory err
    ) internal {
        uint256 apy = _getPhasePeriodAPY(phase, period);
        (Types.StakeVoucher memory v, bytes memory sig) =
            _prepareVoucherStake(stakingContract, user, phase, period, 0, extraLimit);
        vm.prank(user);
        vm.expectRevert(err);
        stakingContract.stakeWithVoucher(v, sig, amount, apy);
    }

    function _installController() internal {
        _deployLimitController(address(stakingContract));
        _addPhasesAndPeriods();
        _setLimitControllerOnStakingContract(address(limitController));
    }

    /// @notice The voucher's extraLimit raises the cap for that stake only; used stake keeps counting after it.
    function test_LimitController_Staking_VoucherExtraLimitRaisesCap() external {
        _installController();
        uint256 limit = 100 * myTokenDecimals;
        uint256 extra = 50 * myTokenDecimals;
        limitController.setWalletLimit(userOne, 0, 0, limit);
        _increaseAllowance(userOne, 1000 * myTokenDecimals);

        // Over limit + extra: headroom reported includes the extra.
        _expectLimitRevert(
            userOne,
            0,
            0,
            limit + extra + 1,
            extra,
            abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, limit + extra + 1, limit + extra)
        );

        _stakeVWith(stakingContract, userOne, 0, 0, limit + extra, 0, extra);
        (uint256 allowed, uint256 used) = limitController.getAllowedAndUsed(userOne, 0, 0);
        assertEq(allowed, limit);
        assertEq(used, limit + extra);
        assertEq(_getRemaining(userOne, 0, 0), 0, "saturates at 0");

        // A later voucher with the same extra has no headroom left; one without extra neither.
        _expectLimitRevert(
            userOne, 0, 0, 1e18, extra, abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, 1e18, 0)
        );
        _expectLimitRevert(
            userOne, 0, 0, 1e18, 0, abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, 1e18, 0)
        );

        // A bigger extra gives exactly the difference.
        _stakeVWith(stakingContract, userOne, 0, 0, 10e18, 0, extra + 10e18);
        assertEq(limitController.getUsed(userOne, 0, 0), limit + extra + 10e18);
    }

    function testFuzz_LimitController_Staking_CapIsLimitPlusExtraMinusUsed(
        uint256 limit,
        uint256 extra,
        uint256 firstStake
    ) external {
        _installController();
        uint256 minDeposit = stakingContract.minimumDeposit();
        limit = bound(limit, 0, 400e18);
        extra = bound(extra, 0, 400e18);
        vm.assume(limit + extra >= 2 * minDeposit);
        firstStake = bound(firstStake, minDeposit, limit + extra - minDeposit);

        limitController.setDefaultLimit(0, 0, limit);
        _increaseAllowance(userOne, 1000e18);

        _stakeVWith(stakingContract, userOne, 0, 0, firstStake, 0, extra);

        uint256 headroom = limit + extra - firstStake;
        _expectLimitRevert(
            userOne,
            0,
            0,
            headroom + 1,
            extra,
            abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, headroom + 1, headroom)
        );
        if (headroom >= minDeposit) {
            _stakeVWith(stakingContract, userOne, 0, 0, headroom, 0, extra);
            assertEq(limitController.getUsed(userOne, 0, 0), limit + extra);
        }
    }

    /// @notice Closing a deposit frees its limit, and so does seizing it.
    function test_LimitController_WithdrawAndSeizeFreeLimit() external {
        _installController();
        uint256 limit = 100 * myTokenDecimals;
        limitController.setWalletLimit(userOne, 0, 0, limit);
        _increaseAllowance(userOne, 1000 * myTokenDecimals);

        _stakeV(stakingContract, userOne, 0, 0, limit);
        assertEq(_getRemaining(userOne, 0, 0), 0);

        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);
        assertEq(_getRemaining(userOne, 0, 0), limit);

        _stakeV(stakingContract, userOne, 0, 0, limit);
        assertEq(_getRemaining(userOne, 0, 0), 0);
        stakingContract.freezeDeposit(userOne, 1);
        stakingContract.seizeDeposit(userOne, 1);
        assertEq(_getRemaining(userOne, 0, 0), limit);
        assertEq(myToken.balanceOf(treasury), limit);

        _stakeV(stakingContract, userOne, 0, 0, limit);
        assertEq(_getRemaining(userOne, 0, 0), 0);
    }

    // ======================================
    // =   v0.4.0: legacy staking contract  =
    // ======================================

    function test_LimitController_SetLegacyStakingContract_Rules() external {
        _deployLimitController(address(stakingContract));
        MockLegacyStaking legacy = new MockLegacyStaking();

        vm.prank(userOne);
        vm.expectRevert();
        limitController.setLegacyStakingContract(address(legacy));

        vm.expectRevert(
            abi.encodeWithSelector(LimitController.SameStakingAndLegacyContract.selector, address(stakingContract))
        );
        limitController.setLegacyStakingContract(address(stakingContract));

        limitController.setLegacyStakingContract(address(legacy));
        assertEq(address(limitController.legacyStakingContract()), address(legacy));

        vm.expectRevert(abi.encodeWithSelector(LimitController.SameStakingAndLegacyContract.selector, address(legacy)));
        limitController.setStakingContract(address(legacy));

        limitController.setLegacyStakingContract(address(0));
        assertEq(address(limitController.legacyStakingContract()), address(0));
    }

    function test_LimitController_Staking_LegacyStakeCountsTowardLimit() external {
        _installController();
        MockLegacyStaking legacy = new MockLegacyStaking();
        uint256 limit = 100 * myTokenDecimals;
        limitController.setWalletLimit(userOne, 0, 0, limit);
        limitController.setLegacyStakingContract(address(legacy));

        legacy.setStaked(userOne, 0, 0, 60e18);
        // Stake in another legacy cell does not count here.
        legacy.setStaked(userOne, 0, 90, 500e18);
        legacy.setStaked(userOne, 1, 0, 500e18);

        (uint256 allowed, uint256 used) = limitController.getAllowedAndUsed(userOne, 0, 0);
        assertEq(allowed, limit);
        assertEq(used, 60e18);
        assertEq(_getRemaining(userOne, 0, 0), 40e18);

        _increaseAllowance(userOne, 1000e18);
        _expectLimitRevert(
            userOne, 0, 0, 41e18, 0, abi.encodeWithSelector(StakingLimitExceeded.selector, userOne, 0, 0, 41e18, 40e18)
        );
        _stakeV(stakingContract, userOne, 0, 0, 40e18);
        (, used) = limitController.getAllowedAndUsed(userOne, 0, 0);
        assertEq(used, limit);

        // Unsetting the legacy contract stops counting its stake.
        limitController.setLegacyStakingContract(address(0));
        assertEq(_getRemaining(userOne, 0, 0), 60e18);
    }

    /// @notice Against the real v0.2.4 code: the same phase and period are read, nothing is remapped, and unknown
    ///         or removed phases/periods read 0 without reverting.
    function test_LimitController_RealLegacyV024_SamePhasePeriodNeverReverts() external {
        LegacyStaking legacy = new LegacyStaking(address(myToken));
        uint256[] memory empty = new uint256[](0);
        legacy.addStakingPeriod(0, empty, empty);
        legacy.addStakingPeriod(90, empty, empty);
        uint256[] memory apys = new uint256[](2);
        apys[0] = 5;
        apys[1] = 10;
        uint256[] memory targets = new uint256[](2);
        targets[0] = 1_000_000e18;
        targets[1] = 1_000_000e18;
        legacy.pushStakingPhase(apys, targets);
        myToken.approve(address(legacy), 100e18);
        legacy.provideReward(100e18);

        vm.prank(userTwo);
        myToken.approve(address(legacy), 50e18);
        _legacyStake(address(legacy), userTwo, 0, 30e18, 5);
        _legacyStake(address(legacy), userTwo, 90, 20e18, 10);

        _installController();
        limitController.setLegacyStakingContract(address(legacy));
        limitController.setDefaultLimit(0, 0, 50e18);
        limitController.setDefaultLimit(0, 90, 100e18);

        assertEq(limitController.getUsed(userTwo, 0, 0), 30e18);
        assertEq(limitController.getUsed(userTwo, 0, 90), 20e18);
        // Phase beyond the legacy count, unknown period, other wallet: all 0, no revert.
        assertEq(limitController.getUsed(userTwo, 7, 0), 0);
        assertEq(limitController.getUsed(userTwo, 0, 12345), 0);
        assertEq(limitController.getUsed(userOne, 0, 0), 0);

        address[] memory wallets = new address[](3);
        wallets[0] = userTwo;
        wallets[1] = userTwo;
        wallets[2] = userTwo;
        uint256[] memory phases = new uint256[](3);
        phases[2] = 9;
        uint256[] memory periods = new uint256[](3);
        periods[1] = 90;
        uint256[] memory remaining = limitController.getRemainingBatch(wallets, phases, periods);
        assertEq(remaining[0], 20e18);
        assertEq(remaining[1], 80e18);
        assertEq(remaining[2], 0);

        // New contract stake adds to legacy stake in the same cell.
        _increaseAllowance(userTwo, 1000e18);
        _stakeV(stakingContract, userTwo, 0, 0, 20e18);
        _expectLimitRevert(
            userTwo, 0, 0, 1e18, 0, abi.encodeWithSelector(StakingLimitExceeded.selector, userTwo, 0, 0, 1e18, 0)
        );
        _stakeVWith(stakingContract, userTwo, 0, 0, 5e18, 0, 5e18);
        assertEq(limitController.getUsed(userTwo, 0, 0), 55e18);

        // Removing the period in the legacy contract must not make the controller revert.
        legacy.removeStakingPeriod(90);
        assertEq(
            limitController.getUsed(userTwo, 0, 90),
            IPeriodicalStakingContract(address(legacy)).getUserPhasePeriodData(0, userTwo, 0, 90)
        );
        remaining = limitController.getRemainingBatch(wallets, phases, periods);
        assertEq(remaining[0], 0);
        assertEq(remaining[2], 0);

        // Without the legacy contract only the new stake counts.
        limitController.setLegacyStakingContract(address(0));
        assertEq(limitController.getUsed(userTwo, 0, 0), 25e18);
        assertEq(_getRemaining(userTwo, 0, 0), 25e18);
    }

    function _legacyStake(address legacy, address wallet, uint256 period, uint256 amount, uint256 apy) internal {
        vm.prank(wallet);
        (bool ok,) = legacy.call(
            abi.encodeWithSignature("safeStake(uint256,uint256,uint256,uint256)", 0, period, amount, apy)
        );
        assertTrue(ok, "legacy safeStake");
    }
}
