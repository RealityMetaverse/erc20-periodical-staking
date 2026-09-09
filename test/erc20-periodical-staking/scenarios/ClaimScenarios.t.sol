pragma solidity 0.8.20;

import "../functions/ClaimFunctions.sol";
import "../../../src/common/Types.sol";

contract ClaimScenarios is ClaimFunctions {
    function test_Claim_NotOpen() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        skip(90 days);

        stakingContract.changeActionAvailability(Types.DataType.CLAIM, false);

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

    /// @dev v0.3.0: indefinite claims may only spend the unreserved portion of the pool,
    ///      so a matured periodical deposit whose reward the pool already holds is always payable. (Stakes are
    ///      not checked against the pool; a short pool makes the periodical claim wait for a top-up instead.)
    function test_Claim_PeriodicalReserveProtected_IndefiniteClaimCannotDrainIt() external {
        _addPhasesAndPeriods();

        uint256 periodicalReward = stakingContract.calculateReward(amountToStake, _getPhasePeriodAPY(0, 90), 90);
        _increaseAllowance(address(this), periodicalReward);
        stakingContract.provideReward(periodicalReward);

        _stakeTokenWithAllowance(userOne, 0, 90, amountToStake);
        _stakeTokenWithAllowance(userOne, 0, 0, amountToStake);
        skip(90 days);

        // Indefinite claim (deposit 1) finds no unreserved reward and reverts; reserve untouched.
        _claimTokenWithTest(userOne, 1, true);
        assertEq(stakingContract.rewardPool(), periodicalReward);

        // Periodical claim (deposit 0) is fully paid.
        _claimTokenWithTest(userOne, 0, false);
        assertEq(stakingContract.rewardPool(), 0);
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
