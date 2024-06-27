// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../AuxiliaryFunctions.sol";

contract StakingScenarious is AuxiliaryFunctions {
    function test_Staking_BeforeLaunch() external {
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);
    }

    function test_Staking_NoAllowance() external {
        _addPhasesAndPeriods();

        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);
    }

    function test_Staking_IncreasedAllowance() external {
        _addPhasesAndPeriods();

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, false);
    }

    function test_Staking_MultiplePools() external {
        _tryMultiUserMultiStake();
    }

    function test_Staking_InsufficentDeposit() external {
        _addPhasesAndPeriods();

        _increaseAllowance(userOne, 1);
        _stakeTokenWithTest(userOne, 0, 0, 1, true);
    }

    function test_Staking_AmountExceedsTarget() external {
        _addPhasesAndPeriods();
        _stakeTokenWithAllowance(userThree, 0, 0, _getPhasePeriodStakingTarget(0, 0));

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0 + _refPeriodModifier, amountToStake, false);
    }

    function test_Staking_NotOpen() external {
        _addPhasesAndPeriods();
        stakingContract.changeActionAvailability(ProgramManager.DataType.STAKING, false);

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);
    }
}
