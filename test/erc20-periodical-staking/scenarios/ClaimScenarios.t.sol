// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/ClaimFunctions.sol";
import "../../../src/common/Types.sol";
import "../../../src/common/Errors.sol";

/// @dev v0.4.0: every stake here goes through the local _stakeChecked instead of the shared
///      _stakeTokenWithAllowance. With that shared helper, this contract (even with only its original v0.3.0 tests)
///      fails to compile under via_ir with "stack too deep". _stakeChecked makes the same accounting assertions,
///      split across smaller frames.
contract ClaimScenarios is ClaimFunctions {
    // ======================================
    // =          Stake helper              =
    // ======================================

    /// @dev Stake on phase 0 through a voucher (no extras) and assert the same effects _stakeTokenWithTest checks.
    function _stakeChecked(address user, uint256 period, uint256 amount) internal {
        _increaseAllowance(user, amount);
        uint256[] memory beforeData = _getCurrentData(user, 0, period);
        uint256 depositNumber = _stakeV(stakingContract, user, 0, period, amount);
        _assertStakeAccounting(user, period, amount, beforeData);
        _assertStakedDeposit(user, period, amount, depositNumber);
    }

    function _expectedStakeReward(uint256 period, uint256 amount) internal view returns (uint256) {
        return period == 0 ? 0 : stakingContract.calculateReward(amount, _getPhasePeriodAPY(0, period), period);
    }

    function _assertStakeAccounting(address user, uint256 period, uint256 amount, uint256[] memory beforeData)
        internal
    {
        uint256 reward = _expectedStakeReward(period, amount);
        uint256[] memory afterData = _getCurrentData(user, 0, period);
        assertEq(afterData[0], beforeData[0] + amount, "total staked");
        assertEq(afterData[1], beforeData[1] - amount, "user balance");
        assertEq(afterData[2], beforeData[2] + amount, "user staked");
        assertEq(afterData[3], beforeData[3] + amount, "contract balance");
        assertEq(afterData[4], beforeData[4] + amount, "phase/period staked");
        assertEq(afterData[8], beforeData[8] + reward, "total reward expected");
        assertEq(afterData[9], beforeData[9] + reward, "user reward expected");
    }

    function _assertStakedDeposit(address user, uint256 period, uint256 amount, uint256 depositNumber) internal {
        assertEq(_getUserDepositCount(user), depositNumber + 1, "deposit count");
        ProgramManager.TokenDeposit memory d = stakingContract.getDeposit(user, depositNumber);
        assertEq(d.stakingPhase, 0);
        assertEq(d.stakingPeriod, period);
        assertEq(d.amount, amount);
        // Effective APY in bps; no voucher extra here, so it equals the base APY.
        assertEq(d.APY, _getPhasePeriodAPY(0, period));
        assertEq(d.rewardGenerated, _expectedStakeReward(period, amount));
    }

    function _fundPool() internal {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);
    }

    // ======================================
    // =          v0.3.0 scenarios          =
    // ======================================

    function test_Claim_NotOpen() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
        skip(90 days);

        stakingContract.changeActionAvailability(Types.DataType.CLAIM, false);

        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_Periodical() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
    }

    function test_Claim_PeriodicalSameDeposit() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
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

        _stakeChecked(userOne, 90, amountToStake);
        _stakeChecked(userOne, 0, amountToStake);
        skip(90 days);

        // Indefinite claim (deposit 1) finds no unreserved reward and reverts; reserve untouched.
        _claimTokenWithTest(userOne, 1, true);
        assertEq(stakingContract.rewardPool(), periodicalReward);

        // Periodical claim (deposit 0) is fully paid.
        _claimTokenWithTest(userOne, 0, false);
        assertEq(stakingContract.rewardPool(), 0);
    }

    function test_Claim_Indefinite() external {
        _fundPool();

        _stakeChecked(userOne, 0, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
    }

    function test_Claim_IndefiniteSameDeposit() external {
        _fundPool();

        _stakeChecked(userOne, 0, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, false);
        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_IndefiniteNotEnoughFundsInTheRewardPool() external {
        _addPhasesAndPeriods();

        _stakeChecked(userOne, 0, amountToStake);
        skip(90 days);

        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_IndefiniteNothingToClaim() external {
        _addPhasesAndPeriods();

        _stakeChecked(userOne, 0, amountToStake);
        _claimTokenWithTest(userOne, 0, true);
    }

    function test_Claim_ClaimAll() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
        skip(90 days);

        _stakeChecked(userOne, 0, amountToStake);
        skip(30 days);

        _stakeChecked(userOne, 180, amountToStake);
        skip(180 days);

        _claimAllWithTest(userOne, false);
    }

    // ======================================
    // =     v0.4.0: extra APY, freezing    =
    // ======================================

    function test_Claim_PeriodicalWithExtraApy_PaysEffectiveReward() external {
        _fundPool();

        uint256 baseApy = _getPhasePeriodAPY(0, 90);
        _increaseAllowance(userOne, amountToStake);
        _stakeVWith(stakingContract, userOne, 0, 90, amountToStake, 250, 0);
        skip(90 days);

        uint256 expectedReward = amountToStake * ((baseApy + 250) * 90) / 3_650_000;
        assertGt(expectedReward, stakingContract.calculateReward(amountToStake, baseApy, 90));

        uint256 balBefore = myToken.balanceOf(userOne);
        _claimTokenWithTest(userOne, 0, false);
        assertEq(myToken.balanceOf(userOne), balBefore + amountToStake + expectedReward);
        assertEq(stakingContract.getUserData(Types.DataType.CLAIM, userOne), expectedReward);
    }

    function test_Claim_FrozenDepositReverts_UntilUnfrozen() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
        skip(90 days);

        vm.prank(contractAdmin);
        stakingContract.freezeDeposit(userOne, 0);
        assertTrue(stakingContract.isDepositFrozen(userOne, 0));

        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 0));
        stakingContract.claimDeposit(0);

        // Indefinite claim path is blocked too.
        _stakeChecked(userOne, 0, amountToStake);
        skip(30 days);
        stakingContract.freezeDeposit(userOne, 1);
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, userOne, 1));
        stakingContract.claimDeposit(1);

        vm.prank(contractAdmin);
        stakingContract.unfreezeDeposit(userOne, 0);
        assertFalse(stakingContract.isDepositFrozen(userOne, 0));
        _claimTokenWithTest(userOne, 0, false);
    }

    /// @notice claimAll skips a frozen deposit instead of reverting, and the cursor stops at it.
    function test_Claim_ClaimAllSkipsFrozenDeposit() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
        _stakeChecked(userOne, 90, amountToStake * 2);
        skip(90 days);

        vm.prank(contractAdmin);
        stakingContract.freezeDeposit(userOne, 0);

        uint256 reward1 = stakingContract.getDeposit(userOne, 1).rewardGenerated;
        // Frozen principal and reward are excluded, so the view matches the claimAll payout.
        _assertClaimableFor(userOne, amountToStake * 2, reward1, 0);

        uint256 balBefore = myToken.balanceOf(userOne);
        vm.prank(userOne);
        stakingContract.claimAll();

        assertEq(myToken.balanceOf(userOne), balBefore + amountToStake * 2 + reward1);
        _assertFrozenDepositUntouched(userOne, 0);
        assertEq(stakingContract.getDeposit(userOne, 1).withdrawalDate, _now());

        vm.prank(contractAdmin);
        stakingContract.unfreezeDeposit(userOne, 0);
        vm.prank(userOne);
        stakingContract.claimAll();
        assertEq(
            myToken.balanceOf(userOne),
            balBefore + amountToStake * 3 + reward1 + stakingContract.getDeposit(userOne, 0).rewardGenerated
        );
        assertEq(stakingContract.stakerActiveDepositStartIndex(userOne), 2);
        assertEq(_getTotalRewardExpected(), 0);
    }

    /// @notice A seized deposit is closed: it cannot be claimed, only its principal went to the treasury and its
    ///         reward was never paid (the reservation stays in the pool).
    function test_Claim_SeizedDepositCannotBeClaimed() external {
        _fundPool();

        _stakeChecked(userOne, 90, amountToStake);
        skip(90 days);
        uint256 poolBefore = stakingContract.rewardPool();

        stakingContract.freezeDeposit(userOne, 0);
        stakingContract.seizeDeposit(userOne, 0);

        assertEq(myToken.balanceOf(treasury), amountToStake, "principal only");
        assertEq(stakingContract.getDeposit(userOne, 0).rewardGenerated, 0, "reward not paid");
        assertEq(stakingContract.rewardPool(), poolBefore, "pool untouched");
        assertEq(
            uint256(stakingContract.checkDepositStatus(userOne, 0)), uint256(ProgramManager.DepositStatus.SEIZED)
        );

        _claimTokenWithTest(userOne, 0, true);
        _assertClaimableFor(userOne, 0, 0, 0);
    }

    function _assertClaimableFor(address user, uint256 stake, uint256 periodical, uint256 indefinite) internal {
        (uint256 s, uint256 p, uint256 i) = stakingContract.checkClaimableDataFor(user);
        assertEq(s, stake, "claimable stake");
        assertEq(p, periodical, "claimable periodical reward");
        assertEq(i, indefinite, "claimable indefinite reward");
    }

    /// @dev A frozen, still-open deposit: not closed, still READY_TO_CLAIM, holds the claimAll cursor and its reward
    ///      reservation.
    function _assertFrozenDepositUntouched(address user, uint256 depositNo) internal {
        assertEq(stakingContract.getDeposit(user, depositNo).withdrawalDate, 0, "frozen deposit untouched");
        assertEq(
            uint256(stakingContract.checkDepositStatus(user, depositNo)),
            uint256(ProgramManager.DepositStatus.READY_TO_CLAIM)
        );
        assertEq(stakingContract.stakerActiveDepositStartIndex(user), depositNo);
        assertEq(_getTotalRewardExpectedBy(user), stakingContract.getDeposit(user, depositNo).rewardGenerated);
    }
}
