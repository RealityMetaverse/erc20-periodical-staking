// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/ClaimFunctions.sol";
import "../functions/WithdrawalFunctions.sol";

/// @title PeriodRemovalRegression
/// @notice Regression suite for the v0.2.4 production incident: removing a staking period
///         (or popping a staking phase) while deposits are active on it zeroed the per-period
///         accounting and permanently locked those deposits (claim / withdraw / claimAll underflow).
/// @dev    Every test in this file MUST fail on v0.2.4 code and pass on v0.3.0.
contract PeriodRemovalRegression is ClaimFunctions, WithdrawalFunctions {
    uint256 constant PERIOD_SHORT = 7;
    uint256 constant PERIOD_LONG = 90;
    uint256 constant APY = 30;
    uint256 constant TARGET = 10_000_000 ether;
    uint256 constant STAKE_AMOUNT = 200 ether;

    /// @dev Upper bound on removeStakingPeriod gas. v0.2.4 iterated every staker x every DataType,
    ///      so 200 stakers cost multiple millions of gas. v0.3.0 only touches two config cells per phase.
    uint256 constant REMOVE_PERIOD_GAS_BOUND = 300_000;

    // ======================================
    // =          Setup Helpers             =
    // ======================================

    /// @dev 1 phase, 2 periods (7 and 90 days), reward pool funded.
    function _setupProgram() internal {
        uint256[] memory emptyAPY = new uint256[](0);
        uint256[] memory emptyTarget = new uint256[](0);
        stakingContract.addStakingPeriod(PERIOD_SHORT, emptyAPY, emptyTarget);
        stakingContract.addStakingPeriod(PERIOD_LONG, emptyAPY, emptyTarget);

        uint256[] memory apys = new uint256[](2);
        uint256[] memory targets = new uint256[](2);
        apys[0] = APY;
        apys[1] = APY;
        targets[0] = TARGET;
        targets[1] = TARGET;
        stakingContract.pushStakingPhase(apys, targets);

        _fundRewardPool(amountToProvide);
    }

    function _fundRewardPool(uint256 amount) internal {
        _increaseAllowance(contractAdmin, amount);
        vm.prank(contractAdmin);
        stakingContract.provideReward(amount);
    }

    function _stakeFor(address user, uint256 phase, uint256 period, uint256 amount) internal {
        uint256 apy = stakingContract.phasePeriodDataList(Types.PhasePeriodDataType.APY, phase, period);
        _increaseAllowance(user, amount);
        vm.prank(user);
        stakingContract.safeStake(phase, period, amount, apy);
    }

    function _stakeFor(address user, uint256 period, uint256 amount) internal {
        _stakeFor(user, 0, period, amount);
    }

    function _assertClosed(address user, uint256 depositNo) internal {
        assertEq(stakingContract.getDeposit(user, depositNo).withdrawalDate, _now());
    }

    /// @dev Asserts the aggregate accounting is internally consistent once every deposit is closed.
    function _assertAllCountersZeroed(address[] memory users) internal {
        assertEq(stakingContract.totalDataList(Types.DataType.STAKING), 0, "total STAKING");
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), 0, "total REWARD_EXPECTED");
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_SHORT), 0, "phasePeriod STAKED short");
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_LONG), 0, "phasePeriod STAKED long");

        for (uint256 i = 0; i < users.length; i++) {
            assertEq(_getTotalStakedBy(users[i]), 0, "user STAKING");
            assertEq(_getTotalRewardExpectedBy(users[i]), 0, "user REWARD_EXPECTED");
            assertEq(
                stakingContract.getUserPhasePeriodData(Types.DataType.STAKING, users[i], 0, PERIOD_SHORT),
                0,
                "userPhasePeriod STAKING"
            );
            assertEq(
                stakingContract.getUserPhasePeriodData(Types.DataType.REWARD_EXPECTED, users[i], 0, PERIOD_SHORT),
                0,
                "userPhasePeriod REWARD_EXPECTED"
            );
        }
        // Contract holds exactly the remaining reward pool.
        assertEq(myToken.balanceOf(address(stakingContract)), stakingContract.rewardPool(), "contract balance");
    }

    // ======================================
    // =    Claim after removeStakingPeriod =
    // ======================================

    function test_Claim_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 expectedReward = stakingContract.getDeposit(userOne, 0).rewardGenerated;
        uint256 balBefore = myToken.balanceOf(userOne);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        assertFalse(stakingContract.checkIfStakingPeriodExists(PERIOD_SHORT));

        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);

        _assertClosed(userOne, 0);
        assertEq(myToken.balanceOf(userOne), balBefore + STAKE_AMOUNT + expectedReward);

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    function test_Claim_MultipleUsers_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT * 2);
        _stakeFor(userThree, PERIOD_SHORT, STAKE_AMOUNT * 3);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        skip(PERIOD_SHORT * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        vm.prank(userThree);
        stakingContract.claimDeposit(0);

        _assertClosed(userOne, 0);
        _assertClosed(userTwo, 0);
        _assertClosed(userThree, 0);
        _assertAllCountersZeroed(addressList);
    }

    function test_Claim_MultipleDeposits_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        skip(PERIOD_SHORT * 1 days + 1);

        vm.startPrank(userOne);
        stakingContract.claimDeposit(0);
        stakingContract.claimDeposit(1);
        stakingContract.claimDeposit(2);
        vm.stopPrank();

        _assertClosed(userOne, 0);
        _assertClosed(userOne, 1);
        _assertClosed(userOne, 2);

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    function test_ClaimAll_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        skip(PERIOD_LONG * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimAll();

        _assertClosed(userOne, 0);
        _assertClosed(userOne, 1);
        _assertClosed(userOne, 2);

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    /// @notice Deposits on other periods must keep working; the removed-period deposit must too.
    function test_Claim_MixedPeriods_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        skip(PERIOD_LONG * 1 days + 1);

        vm.startPrank(userOne);
        stakingContract.claimDeposit(1); // long period, untouched
        stakingContract.claimDeposit(0); // removed period
        vm.stopPrank();

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    // ======================================
    // =  Withdraw after removeStakingPeriod =
    // ======================================

    function test_EarlyWithdraw_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 balBefore = myToken.balanceOf(userOne);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);

        // still TIME_LEFT
        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);

        _assertClosed(userOne, 0);
        assertEq(myToken.balanceOf(userOne), balBefore + STAKE_AMOUNT);
        assertEq(stakingContract.getDeposit(userOne, 0).rewardGenerated, 0);

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    function test_EarlyWithdraw_MultipleUsers_AfterRemoveStakingPeriod() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userThree, PERIOD_SHORT, STAKE_AMOUNT);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);

        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);
        vm.prank(userTwo);
        stakingContract.withdrawDeposit(0);
        vm.prank(userThree);
        stakingContract.withdrawDeposit(0);

        _assertAllCountersZeroed(addressList);
    }

    // ======================================
    // =        popStakingPhase             =
    // ======================================

    function test_Claim_AfterPopStakingPhase() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 expectedReward = stakingContract.getDeposit(userOne, 0).rewardGenerated;
        uint256 balBefore = myToken.balanceOf(userOne);

        stakingContract.popStakingPhase();
        assertEq(stakingContract.stakingPhaseCount(), 0);

        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);

        _assertClosed(userOne, 0);
        assertEq(myToken.balanceOf(userOne), balBefore + STAKE_AMOUNT + expectedReward);

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    function test_EarlyWithdraw_AfterPopStakingPhase() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);

        stakingContract.popStakingPhase();

        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);
        _assertClosed(userOne, 0);

        address[] memory users = new address[](1);
        users[0] = userOne;
        _assertAllCountersZeroed(users);
    }

    function test_ClaimAll_MultipleUsers_AfterPopStakingPhase() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userThree, PERIOD_LONG, STAKE_AMOUNT);

        stakingContract.popStakingPhase();
        skip(PERIOD_LONG * 1 days + 1);

        vm.prank(userOne);
        stakingContract.claimAll();
        vm.prank(userTwo);
        stakingContract.claimAll();
        vm.prank(userThree);
        stakingContract.claimAll();

        _assertClosed(userOne, 0);
        _assertClosed(userOne, 1);
        _assertClosed(userTwo, 0);
        _assertClosed(userThree, 0);
        _assertAllCountersZeroed(addressList);
    }

    // ======================================
    // =     Re-add period then stake       =
    // ======================================

    function test_ReAddPeriod_ExistingStakeCountsTowardTarget_ThenClaimBoth() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);

        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        // Tokens are genuinely still staked on (0, 7) even though the period is not configured.
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_SHORT), STAKE_AMOUNT);

        uint256[] memory apys = new uint256[](1);
        uint256[] memory targets = new uint256[](1);
        apys[0] = APY;
        targets[0] = TARGET;
        stakingContract.addStakingPeriod(PERIOD_SHORT, apys, targets);
        assertTrue(stakingContract.checkIfStakingPeriodExists(PERIOD_SHORT));

        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT);
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_SHORT), STAKE_AMOUNT * 2);

        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);

        _assertClosed(userOne, 0);
        _assertClosed(userTwo, 0);

        address[] memory users = new address[](2);
        users[0] = userOne;
        users[1] = userTwo;
        _assertAllCountersZeroed(users);
    }

    /// @notice Re-adding with a target smaller than what is already staked must reject new stakes
    ///         (the old stake still occupies the target) but must not lock the old deposit.
    function test_ReAddPeriod_TargetRespectsExistingStake() public {
        _setupProgram();
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        stakingContract.removeStakingPeriod(PERIOD_SHORT);

        uint256[] memory apys = new uint256[](1);
        uint256[] memory targets = new uint256[](1);
        apys[0] = APY;
        targets[0] = STAKE_AMOUNT + (STAKE_AMOUNT / 2); // room for only half another stake
        stakingContract.addStakingPeriod(PERIOD_SHORT, apys, targets);

        _increaseAllowance(userTwo, STAKE_AMOUNT);
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, PERIOD_SHORT, targets[0]));
        stakingContract.safeStake(0, PERIOD_SHORT, STAKE_AMOUNT, APY);

        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        _assertClosed(userOne, 0);
    }

    // ======================================
    // =          Gas bound                 =
    // ======================================

    /// @notice removeStakingPeriod gas must not scale with the number of stakers.
    function test_RemoveStakingPeriod_GasDoesNotScaleWithStakers() public {
        _setupProgram();

        uint256 stakerCount = 200;
        for (uint256 i = 0; i < stakerCount; i++) {
            address staker = address(uint160(0x10000 + i));
            myToken.transfer(staker, STAKE_AMOUNT);
            _stakeFor(staker, PERIOD_SHORT, STAKE_AMOUNT);
        }
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_SHORT), STAKE_AMOUNT * stakerCount);

        uint256 gasBefore = gasleft();
        stakingContract.removeStakingPeriod(PERIOD_SHORT);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, REMOVE_PERIOD_GAS_BOUND, "removeStakingPeriod gas scales with staker count");

        // Accounting must be untouched.
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_SHORT), STAKE_AMOUNT * stakerCount);
        assertEq(_getPhasePeriodAPY(0, PERIOD_SHORT), 0);
        assertEq(_getPhasePeriodStakingTarget(0, PERIOD_SHORT), 0);
    }

    function test_PopStakingPhase_GasDoesNotScaleWithStakers() public {
        _setupProgram();

        uint256 stakerCount = 200;
        for (uint256 i = 0; i < stakerCount; i++) {
            address staker = address(uint160(0x20000 + i));
            myToken.transfer(staker, STAKE_AMOUNT);
            _stakeFor(staker, PERIOD_SHORT, STAKE_AMOUNT);
        }

        uint256 gasBefore = gasleft();
        stakingContract.popStakingPhase();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, REMOVE_PERIOD_GAS_BOUND, "popStakingPhase gas scales with staker count");
        assertEq(_getPhasePeriodStakingStaked(0, PERIOD_SHORT), STAKE_AMOUNT * stakerCount);
    }
}
