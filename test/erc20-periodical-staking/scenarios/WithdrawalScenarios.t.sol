// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/WithdrawalFunctions.sol";
import "../../../src/common/Types.sol";

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
}
