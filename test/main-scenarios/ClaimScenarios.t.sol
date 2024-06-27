pragma solidity 0.8.20;

import "../main-test-functions/ClaimFunctions.sol";

contract ClaimScenarios is ClaimFunctions {
    function test_Claim_NotOpen() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        skip(90 days);

        stakingContract.changeActionAvailability(ProgramManager.DataType.CLAIM, false);

        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_Periodical() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
    }

    function test_Claim_PeriodicalSameDeposit() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_PeriodicalNotEnoughFundsInTheRewardPool() external {
        _addPhasesAndPeriods();

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, true);
    }
    
    function test_Claim_Indefinite() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
    }

    function test_Claim_IndefiniteSameDeposit() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);
        
        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_IndefiniteNotEnoughFundsInTheRewardPool() external {
        _addPhasesAndPeriods();

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_IndefiniteNothingToClaim() external {
        _addPhasesAndPeriods();

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        _claimTokenWithTest(userOne, 0, true);
    }


    function test_Claim_ClaimAll() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        skip(90 days);

        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        skip(30 days);

        _stakeTokenWithAllowance(userOne, 0, 180, amountToStake);
        skip(180 days);

        _claimAllWithTest(userOne, false);
    }
}
