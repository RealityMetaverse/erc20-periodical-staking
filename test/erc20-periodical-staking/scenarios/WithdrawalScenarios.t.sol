// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/WithdrawalFunctions.sol";
import "../../../src/common/Types.sol";
import "../../../src/common/Errors.sol";

contract WithdrawalScenarious is WithdrawalFunctions {
    function test_Withdrawal_Periodical() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _withdrawTokenWithTest(userOne, 0, false);
    }

    function test_Withdrawal_PeriodicalMultiple() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _withdrawTokenWithTest(userOne, 0, false);
        _withdrawTokenWithTest(userOne, 1, false);
        _withdrawTokenWithTest(userOne, 2, false);
    }

    function test_Withdrawal_PeriodicalSameDeposit() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _withdrawTokenWithTest(userOne, 0, false);
        _withdrawTokenWithTest(userOne, 0, true);
    }

    function test_Withdrawal_Indefinite() external {
        _addPhasesAndPeriods();

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _withdrawTokenWithTest(userOne, 0, false);
    }

    function test_Withdrawal_IndefiniteTimePassed() external {
        _addPhasesAndPeriods();

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _withdrawTokenWithTest(userOne, 0, false);
    }

    function test_Withdrawal_IndefiniteMultiple() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);

        skip(30 days);

        _withdrawTokenWithTest(userOne, 0, false);
        _withdrawTokenWithTest(userOne, 1, false);
        _withdrawTokenWithTest(userOne, 2, false);
    }

    function test_Withdrawal_IndefiniteSameDeposit() external {
        _addPhasesAndPeriods();

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _withdrawTokenWithTest(userOne, 0, false);
        _withdrawTokenWithTest(userOne, 0, true);
    }

    function test_Withdrawal_MultiplePhasesPeriods() external {
        _addPhasesAndPeriods();
        // Fund the pool up front so the matured periodical claims below can be paid.
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        uint256 timesStaked;
        uint256 skipDays = 5 days;

        timesStaked += _tryMultiUserMultiStake();
        skip(skipDays);

        timesStaked += _tryMultiUserMultiStake();
        skip(skipDays);

        timesStaked += _tryMultiUserMultiStake();
        skip(skipDays);

        console.log(_now());

        for (uint256 i = 0; i < timesStaked; i++) {
            for (uint256 userNo = 0; userNo < addressList.length; userNo++) {
                _withdrawTokenWithTest(addressList[userNo], i, false);
            }
        }
    }

    function test_Withdrawal_NotOpen() external {
        _addPhasesAndPeriods();
        stakingContract.changeActionAvailability(Types.DataType.WITHDRAWAL, false);

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _withdrawTokenWithTest(userOne, 0, true);
    }

    // ======================================
    // =  v0.4.0: extra APY, freeze, seize  =
    // ======================================

    function test_Withdrawal_IndefiniteWithExtraApy() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        uint256 baseApy = _getPhasePeriodAPY(0, 0);
        _increaseAllowance(userOne, amountToStake);
        _stakeVWith(stakingContract, userOne, 0, 0, amountToStake, 300, 0);
        skip(30 days);

        uint256 expectedReward = amountToStake * ((baseApy + 300) * 30) / 3_650_000;
        uint256 balBefore = myToken.balanceOf(userOne);
        _withdrawTokenWithTest(userOne, 0, false);
        assertEq(myToken.balanceOf(userOne), balBefore + amountToStake + expectedReward);
    }

    function test_Withdrawal_FrozenReverts_UntilUnfrozen() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        skip(10 days);

        address[] memory wallets = new address[](2);
        wallets[0] = userOne;
        wallets[1] = userOne;
        uint256[] memory numbers = new uint256[](2);
        numbers[0] = 0;
        numbers[1] = 1;
        vm.prank(contractAdmin);
        stakingContract.freezeDeposits(wallets, numbers);

        vm.startPrank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 0));
        stakingContract.withdrawDeposit(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 1));
        stakingContract.withdrawDeposit(1);
        vm.stopPrank();

        vm.prank(contractAdmin);
        stakingContract.unfreezeDeposits(wallets, numbers);
        _withdrawTokenWithTest(userOne, 0, false);
        _withdrawTokenWithTest(userOne, 1, false);
    }

    function test_Withdrawal_FreezeRules() external {
        _addPhasesAndPeriods();
        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);

        // Only admins (and the owner) can freeze.
        vm.prank(userTwo);
        vm.expectRevert();
        stakingContract.freezeDeposit(userOne, 0);
        assertFalse(stakingContract.isDepositFrozen(userOne, 0));

        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 0));
        stakingContract.unfreezeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 0));
        stakingContract.seizeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotExist.selector, 1));
        stakingContract.freezeDeposit(userOne, 1);

        stakingContract.freezeDeposit(userOne, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 0));
        stakingContract.freezeDeposit(userOne, 0);
        stakingContract.unfreezeDeposit(userOne, 0);

        // A closed deposit cannot be frozen.
        _withdrawTokenWithTest(userOne, 0, false);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotOpen.selector, userOne, 0));
        stakingContract.freezeDeposit(userOne, 0);
    }

    /// @notice Seizing an early periodical deposit closes it exactly like a withdrawal would, but pays the treasury.
    function test_Withdrawal_SeizeClosesDeposit() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        uint256 reward = stakingContract.getDeposit(userOne, 0).rewardGenerated;
        uint256 poolBefore = stakingContract.rewardPool();
        uint256 userBalBefore = myToken.balanceOf(userOne);

        stakingContract.freezeDeposit(userOne, 0);
        // Seize is owner only; an admin cannot.
        vm.prank(contractAdmin);
        vm.expectRevert();
        stakingContract.seizeDeposit(userOne, 0);

        stakingContract.seizeDeposit(userOne, 0);

        assertGt(reward, 0);
        assertEq(myToken.balanceOf(treasury), amountToStake, "principal only");
        assertEq(myToken.balanceOf(userOne), userBalBefore);
        assertEq(stakingContract.rewardPool(), poolBefore, "pool untouched");
        assertEq(stakingContract.getDeposit(userOne, 0).rewardGenerated, 0, "reservation released");
        assertEq(_getTotalStaked(), 0);
        assertEq(_getTotalStakedBy(userOne), 0);
        assertEq(_getPhasePeriodStakingStaked(0, 90), 0);
        assertEq(stakingContract.getUserPhasePeriodData(Types.DataType.STAKING, userOne, 0, 90), 0);
        assertEq(_getTotalRewardExpected(), 0);
        assertEq(_getTotalWithdrawnBy(userOne), amountToStake);
        assertEq(_getTotalClaimedBy(userOne), 0, "no reward booked as CLAIM");
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 1);
        assertFalse(stakingContract.isDepositFrozen(userOne, 0));
        assertEq(myToken.balanceOf(address(stakingContract)), stakingContract.rewardPool());

        _withdrawTokenWithTest(userOne, 0, true);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositNotFrozen.selector, userOne, 0));
        stakingContract.seizeDeposit(userOne, 0);
    }
}
