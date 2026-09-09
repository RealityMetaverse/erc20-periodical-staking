// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";

/// @title Reward-pool accounting at stake, claim and collectReward
/// @dev There is no stake-time pool check. The guarantees are: the owner can never collect reward
///      promised to open periodical deposits, indefinite payouts come from the free pool only, and a matured
///      periodical claim against a short pool reverts NotEnoughFundsInRewardPool until a top-up (no loss).
contract RewardSolvencyTest is V030Base {
    /// @notice a periodical stake is accepted against an EMPTY pool. Its reward is committed to
    ///         REWARD_EXPECTED, nothing is collectable, and getRewardPoolShortfall() reports the deficit.
    function test_PeriodicalStake_SucceedsWhenPoolEmpty() public {
        _setupProgram(false);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);

        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), reward);
        assertEq(stakingContract.rewardPool(), 0, "no stake-time pool check");
        assertEq(stakingContract.getCollectableReward(), 0);
        assertEq(
            stakingContract.getRewardPoolShortfall(),
            stakingContract.getRewardRequiredForTargets() + reward,
            "shortfall = required for open targets + existing deficit"
        );

        // Indefinite stakes are accepted as well and reserve nothing.
        _stakeFor(userTwo, 0, STAKE_AMOUNT);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), reward);
    }

    /// @notice the pool never blocks a stake. Two deposits against a pool that covers only one:
    ///         the first matured claim is paid, the second reverts NotEnoughFundsInRewardPool until a top-up,
    ///         after which it is paid in full (no loss).
    function test_PeriodicalStake_NotBlockedByPool_ClaimWaitsForTopUp() public {
        _setupProgram(false);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);
        _fundRewardPool(reward);

        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), reward * 2);
        assertEq(stakingContract.rewardPool(), reward, "pool may sit below REWARD_EXPECTED");
        assertEq(stakingContract.getCollectableReward(), 0);

        // The owner cannot take anything while the pool is short.
        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, 1, 0));
        stakingContract.collectReward(1);

        skip(PERIOD_SHORT * 1 days + 1);
        uint256 before = myToken.balanceOf(userOne);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        assertEq(myToken.balanceOf(userOne), before + STAKE_AMOUNT + reward);
        assertEq(stakingContract.rewardPool(), 0);

        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, reward, 0));
        stakingContract.claimDeposit(0);
        // Batch claim skips it silently; the deposit stays READY_TO_CLAIM.
        vm.prank(userTwo);
        stakingContract.claimAll();
        assertEq(
            uint256(stakingContract.checkDepositStatus(userTwo, 0)),
            uint256(ProgramManager.DepositStatus.READY_TO_CLAIM)
        );
        assertEq(stakingContract.getRewardPoolShortfall(), stakingContract.getRewardRequiredForTargets() + reward);

        _fundRewardPool(reward);
        before = myToken.balanceOf(userTwo);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(myToken.balanceOf(userTwo), before + STAKE_AMOUNT + reward, "no loss after top-up");
        assertEq(stakingContract.rewardPool(), 0);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
    }

    /// @notice with the pool already short, collectReward reverts RewardPoolBelowReserved for any
    ///         amount; a partial top-up that still leaves it short is equally locked.
    function test_CollectReward_RevertsWhenPoolAlreadyShort() public {
        _setupProgram(false);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, 1, 0));
        stakingContract.collectReward(1);

        _fundRewardPool(reward / 2);
        assertEq(stakingContract.getCollectableReward(), 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, reward / 2, 0));
        stakingContract.collectReward(reward / 2);

        // Once the pool covers the commitment, only the surplus is collectable.
        _fundRewardPool(reward - reward / 2 + 3);
        assertEq(stakingContract.getCollectableReward(), 3);
        stakingContract.collectReward(3);
        assertEq(stakingContract.rewardPool(), reward);
        _assertPoolCoversReserve();
    }

    /// @notice getRewardPoolShortfall() also counts the deficit of already-open deposits
    ///         (`REWARD_EXPECTED - rewardPool` when the pool is short).
    function test_Shortfall_IncludesExistingDeficit() public {
        _setupProgram(false);
        uint256 target = 2_000 ether;
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, 0, target);
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, PERIOD_SHORT, target);
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, PERIOD_LONG, target);

        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        uint256 deficit = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        uint256 required =
            _periodicalReward(target, PERIOD_SHORT) + _periodicalReward(target - STAKE_AMOUNT, PERIOD_LONG);
        assertEq(stakingContract.getRewardRequiredForTargets(), required);
        assertEq(stakingContract.getRewardPoolShortfall(), required + deficit, "open deposit's deficit is counted");

        // Funding part of the deficit reduces the shortfall one-for-one.
        _fundRewardPool(deficit / 2);
        assertEq(stakingContract.getRewardPoolShortfall(), required + deficit - deficit / 2);

        // Covering the deficit exactly: shortfall == required, nothing collectable.
        _fundRewardPool(deficit - deficit / 2);
        assertEq(stakingContract.getCollectableReward(), 0);
        assertEq(stakingContract.getRewardPoolShortfall(), required);

        // Over-funding beyond required floors at 0.
        _fundRewardPool(required + 1);
        assertEq(stakingContract.getRewardPoolShortfall(), 0);
    }

    function test_IndefiniteStake_NotReserved() public {
        _setupProgram(false);
        _stakeFor(userOne, 0, STAKE_AMOUNT);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(stakingContract.rewardPool(), 0);
    }

    function test_StakedDepositAlwaysClaimable_AfterOwnerCollects() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);

        // Owner takes everything that is not reserved.
        stakingContract.collectReward(stakingContract.getCollectableReward());
        assertEq(stakingContract.rewardPool(), reward);

        skip(PERIOD_SHORT * 1 days + 1);
        uint256 before = myToken.balanceOf(userOne);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        assertEq(myToken.balanceOf(userOne), before + STAKE_AMOUNT + reward);
        assertEq(stakingContract.rewardPool(), 0);
    }

    function test_CollectReward_CannotBreachReserve() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);
        uint256 collectable = amountToProvide - reward;
        assertEq(stakingContract.getCollectableReward(), collectable);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, collectable + 1, collectable)
        );
        stakingContract.collectReward(collectable + 1);

        uint256 before = myToken.balanceOf(address(this));
        stakingContract.collectReward(collectable);
        assertEq(myToken.balanceOf(address(this)), before + collectable);
        assertEq(stakingContract.rewardPool(), reward);
        assertEq(stakingContract.getCollectableReward(), 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, 1, 0));
        stakingContract.collectReward(1);
    }

    function test_CollectReward_ReserveReleasedAfterWithdrawAndClaim() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);
        assertEq(stakingContract.getCollectableReward(), amountToProvide - 2 * reward);

        // Early withdrawal forfeits reward -> reserve shrinks.
        vm.prank(userOne);
        stakingContract.withdrawDeposit(0);
        assertEq(stakingContract.getCollectableReward(), amountToProvide - reward);

        // Claim pays reward from pool -> reserve and pool shrink together.
        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.getCollectableReward(), amountToProvide - reward);
        assertEq(stakingContract.rewardPool(), amountToProvide - reward);

        stakingContract.collectReward(amountToProvide - reward);
        assertEq(stakingContract.rewardPool(), 0);
    }

    /// @notice indefinite rewards are not reserved at stake time and are paid only from the unreserved
    ///         portion of the pool (`min(accrued, collectable)`): an indefinite claim can never eat into
    ///         REWARD_EXPECTED. With zero collectable the claim reverts NoRewardToClaim / is skipped in batch.
    function test_IndefiniteClaim_CannotBreachReserve() public {
        _setupProgram(false);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        _fundRewardPool(reward); // pool == reserve exactly once userOne stakes

        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);
        assertEq(stakingContract.getCollectableReward(), 0);
        _assertPoolCoversReserve();

        skip(30 days);
        uint256 indefiniteReward = _periodicalReward(STAKE_AMOUNT, 30);
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, 0));
        stakingContract.claimDeposit(0);

        // Batch claim skips it silently, reserve untouched.
        vm.prank(userTwo);
        stakingContract.claimAll();
        assertEq(stakingContract.rewardPool(), reward);
        _assertPoolCoversReserve();

        // A partial top-up pays exactly the collectable part; the rest keeps accruing on the deposit.
        _fundRewardPool(indefiniteReward - 1);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.rewardPool(), reward, "reserve intact after partial claim");
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, 1, "1 wei still owed");
        _assertPoolCoversReserve();

        // Topping up the last wei lets the remainder be claimed.
        _fundRewardPool(1);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.rewardPool(), reward);
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, 0);
        _assertPoolCoversReserve();

        // Periodical deposit is still fully payable.
        skip(60 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.rewardPool(), 0);
        _assertPoolCoversReserve();
    }

    /// @notice an indefinite claim is capped at getCollectableReward(); the reserve is never touched and
    ///         the Claim event reports the amount actually paid.
    function test_IndefiniteClaim_CappedAtCollectable_ReserveIntact() public {
        _setupProgram(false);
        uint256 reserved = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        uint256 free = 7 wei;
        _fundRewardPool(reserved + free);

        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT * 10);
        assertEq(stakingContract.getCollectableReward(), free);

        skip(30 days);
        uint256 accrued = _periodicalReward(STAKE_AMOUNT * 10, 30);
        assertGt(accrued, free);

        uint256 before = myToken.balanceOf(userTwo);
        vm.prank(userTwo);
        vm.expectEmit(true, true, false, true);
        emit Claim(userTwo, 0, 0, free);
        stakingContract.claimDeposit(0);

        assertEq(myToken.balanceOf(userTwo), before + free);
        assertEq(stakingContract.rewardPool(), reserved, "reserve untouched");
        assertEq(stakingContract.getCollectableReward(), 0);
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, accrued - free, "remainder still accrues");
        assertEq(stakingContract.userDataList(Types.DataType.CLAIM, userTwo), free);
        assertEq(uint256(stakingContract.checkDepositStatus(userTwo, 0)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        _assertPoolCoversReserve();

        // Nothing collectable left: second claim reverts, batch claim is a no-op.
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, 0));
        stakingContract.claimDeposit(0);
        vm.prank(userTwo);
        stakingContract.claimAll();
        assertEq(stakingContract.rewardPool(), reserved);
        _assertPoolCoversReserve();
    }

    /// @notice with zero collectable, `withdrawDeposit` refuses to close an indefinite deposit whose accrued
    ///         reward cannot be paid (the deposit stays open and keeps accruing), while the explicit opt-in
    ///         `withdrawDepositPartial(deposit, 0)` returns principal with 0 reward and the Withdraw event
    ///         carries the actual (0) reward.
    function test_IndefiniteWithdraw_EmptyCollectable_PrincipalOnly() public {
        _setupProgram(false);
        uint256 reserved = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        _fundRewardPool(reserved);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);
        assertEq(stakingContract.getCollectableReward(), 0);

        skip(45 days);
        uint256 accrued = stakingContract.getDeposit(userTwo, 0).rewardGenerated;
        assertGt(accrued, 0, "reward accrued but unpayable");

        // Full withdraw refuses to forfeit the accrued reward.
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 0));
        stakingContract.withdrawDeposit(0);
        assertEq(uint256(stakingContract.checkDepositStatus(userTwo, 0)), uint256(ProgramManager.DepositStatus.INDEFINITE));

        // Opt-in partial withdraw: principal back, 0 reward, reserve untouched.
        uint256 before = myToken.balanceOf(userTwo);
        vm.prank(userTwo);
        vm.expectEmit(true, true, false, true);
        emit Withdraw(userTwo, 0, STAKE_AMOUNT, 0);
        stakingContract.withdrawDepositPartial(0, 0);

        assertEq(myToken.balanceOf(userTwo), before + STAKE_AMOUNT);
        assertEq(stakingContract.rewardPool(), reserved, "reserve intact");
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, 0);
        assertEq(uint256(stakingContract.checkDepositStatus(userTwo, 0)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        assertEq(stakingContract.userDataList(Types.DataType.STAKING, userTwo), 0);
        _assertPoolCoversReserve();

        // Pool fully empty (no reserve at all): same split, full withdraw reverts, partial pays principal.
        skip(PERIOD_LONG * 1 days);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.rewardPool(), 0);
        _stakeFor(userThree, 0, STAKE_AMOUNT);
        skip(20 days);
        accrued = stakingContract.getDeposit(userThree, 0).rewardGenerated;
        vm.prank(userThree);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 0));
        stakingContract.withdrawDeposit(0);
        before = myToken.balanceOf(userThree);
        vm.prank(userThree);
        stakingContract.withdrawDepositPartial(0, 0);
        assertEq(myToken.balanceOf(userThree), before + STAKE_AMOUNT);
        _assertPoolCoversReserve();
    }

    /// @notice the unpaid remainder of an indefinite reward keeps accruing and becomes claimable after a
    ///         later top-up, as long as the deposit is still open.
    function test_IndefiniteClaim_RemainderClaimableAfterTopUp() public {
        _setupProgram(false);
        uint256 reserved = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        _fundRewardPool(reserved);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);

        skip(10 days);
        uint256 accrued10 = _periodicalReward(STAKE_AMOUNT, 10);
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, 0));
        stakingContract.claimDeposit(0);

        // Top up half of what is owed: half is paid, half remains.
        _fundRewardPool(accrued10 / 2);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, accrued10 - accrued10 / 2);
        _assertPoolCoversReserve();

        // More time passes; total owed is accrued over 20 days minus what was paid.
        skip(10 days);
        uint256 owed = _periodicalReward(STAKE_AMOUNT, 20) - accrued10 / 2;
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, owed);

        // Generous top-up: everything owed is paid, surplus stays collectable.
        _fundRewardPool(owed + 100);
        uint256 before = myToken.balanceOf(userTwo);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(myToken.balanceOf(userTwo), before + owed);
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, 0);
        assertEq(stakingContract.getCollectableReward(), 100);
        assertEq(stakingContract.rewardPool(), reserved + 100);
        _assertPoolCoversReserve();

        // Lifetime accounting: user CLAIM total == accrued over 20 days.
        assertEq(stakingContract.userDataList(Types.DataType.CLAIM, userTwo), _periodicalReward(STAKE_AMOUNT, 20));
    }

    /// @notice READY_TO_CLAIM claims succeed even after indefinite claims and the owner drained every
    ///         free wei of the pool, because neither path can touch the part of the pool that backs
    ///         REWARD_EXPECTED (the pool was funded before the stakes, so it covers them).
    function test_PeriodicalClaim_AlwaysPayable_AfterIndefiniteClaimsDrainFreePool() public {
        _setupProgram(false);
        uint256 reservedShort = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);
        uint256 reservedLong = _periodicalReward(STAKE_AMOUNT * 3, PERIOD_LONG);
        uint256 free = _periodicalReward(STAKE_AMOUNT * 50, 3); // roughly what the indefinite whale accrues in 3 days
        _fundRewardPool(reservedShort + reservedLong + free);

        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_LONG, STAKE_AMOUNT * 3);
        _stakeFor(userThree, 0, STAKE_AMOUNT * 50); // indefinite whale
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), reservedShort + reservedLong);
        assertEq(stakingContract.getCollectableReward(), free);

        // The whale claims repeatedly until the free pool is gone.
        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userThree);
        stakingContract.claimDeposit(0);
        assertEq(stakingContract.getCollectableReward(), 0, "free pool drained by indefinite claim");
        assertGt(stakingContract.getDeposit(userThree, 0).rewardGenerated, 0, "whale still owed");
        _assertPoolCoversReserve();

        // Owner cannot collect anything either.
        vm.expectRevert(abi.encodeWithSelector(Errors.RewardPoolBelowReserved.selector, 1, 0));
        stakingContract.collectReward(1);

        // Matured periodical deposit: full principal + reserved reward.
        uint256 before = myToken.balanceOf(userOne);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        assertEq(myToken.balanceOf(userOne), before + STAKE_AMOUNT + reservedShort);
        assertEq(stakingContract.rewardPool(), reservedLong);
        _assertPoolCoversReserve();

        // Whale keeps draining; the long deposit's reserve survives it and is paid at maturity.
        skip(PERIOD_LONG * 1 days);
        vm.prank(userThree);
        stakingContract.claimAll(); // nothing collectable -> silent no-op
        assertEq(stakingContract.rewardPool(), reservedLong);
        before = myToken.balanceOf(userTwo);
        vm.prank(userTwo);
        stakingContract.claimDeposit(0);
        assertEq(myToken.balanceOf(userTwo), before + STAKE_AMOUNT * 3 + reservedLong);
        assertEq(stakingContract.rewardPool(), 0);
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        _assertPoolCoversReserve();
    }

    /// @notice getRewardRequiredForTargets() sums calculateReward(target - staked, apy, period) over every
    ///         configured periodical cell (period 0 excluded); getRewardPoolShortfall() nets it against the
    ///         collectable pool.
    function test_Views_RewardRequiredForTargets_And_Shortfall() public {
        _setupProgram(false);
        // Shrink the targets so the full requirement fits the admin's funding balance.
        uint256 target = 2_000 ether;
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, 0, target);
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, PERIOD_SHORT, target);
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, PERIOD_LONG, target);
        uint256 needShort = _periodicalReward(target, PERIOD_SHORT);
        uint256 needLong = _periodicalReward(target, PERIOD_LONG);
        uint256 required = needShort + needLong;

        assertEq(stakingContract.getRewardRequiredForTargets(), required, "empty program: full targets");
        assertEq(stakingContract.getRewardPoolShortfall(), required, "nothing funded: shortfall == required");

        // Funding reduces the shortfall one-for-one; over-funding floors it at 0.
        _fundRewardPool(needShort);
        assertEq(stakingContract.getRewardPoolShortfall(), needLong);
        _fundRewardPool(needLong + 1);
        assertEq(stakingContract.getRewardPoolShortfall(), 0);
        assertEq(stakingContract.getRewardRequiredForTargets(), required, "funding does not change requirement");

        // A periodical stake shrinks the remaining target and reserves its reward: both sides move together.
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        uint256 stakeReward = _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT);
        assertEq(
            stakingContract.getRewardRequiredForTargets(),
            _periodicalReward(target - STAKE_AMOUNT, PERIOD_SHORT) + needLong
        );
        assertEq(stakingContract.getCollectableReward(), required + 1 - stakeReward);
        assertEq(stakingContract.getRewardPoolShortfall(), 0);

        // Indefinite stakes are not part of the requirement.
        _stakeFor(userTwo, 0, STAKE_AMOUNT * 5);
        assertEq(
            stakingContract.getRewardRequiredForTargets(),
            _periodicalReward(target - STAKE_AMOUNT, PERIOD_SHORT) + needLong
        );

        // Owner collecting the free pool re-opens the shortfall.
        stakingContract.collectReward(stakingContract.getCollectableReward());
        assertEq(
            stakingContract.getRewardPoolShortfall(),
            _periodicalReward(target - STAKE_AMOUNT, PERIOD_SHORT) + needLong
        );

        // A cell at or above target contributes 0; a removed period is no longer counted.
        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, PERIOD_SHORT, STAKE_AMOUNT / 2);
        assertEq(stakingContract.getRewardRequiredForTargets(), needLong);
        stakingContract.removeStakingPeriod(PERIOD_LONG);
        assertEq(stakingContract.getRewardRequiredForTargets(), 0);
        assertEq(stakingContract.getRewardPoolShortfall(), 0);

        // No phases at all: 0.
        stakingContract.popStakingPhase();
        assertEq(stakingContract.getRewardRequiredForTargets(), 0);
    }

    /// @notice Indefinite principal is never locked: when the free pool cannot cover the accrued reward,
    ///         `withdrawDepositPartial` pays whatever unreserved reward exists (possibly 0) and closes the
    ///         deposit, as long as the caller's `minReward` floor is met.
    function test_IndefiniteWithdraw_PrincipalRecoverable_WhenPoolCannotPay() public {
        _setupProgram(false);
        uint256 reward = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        _fundRewardPool(reward + 5); // 5 wei unreserved

        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);
        skip(30 days);
        uint256 accrued = stakingContract.getDeposit(userTwo, 0).rewardGenerated;
        assertGt(accrued, stakingContract.getCollectableReward());

        // The full withdraw refuses; the partial one with a floor of exactly the free pool pays it.
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 5));
        stakingContract.withdrawDeposit(0);

        uint256 before = myToken.balanceOf(userTwo);
        vm.prank(userTwo);
        stakingContract.withdrawDepositPartial(0, 5);

        assertEq(myToken.balanceOf(userTwo), before + STAKE_AMOUNT + 5);
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, 5);
        assertEq(stakingContract.rewardPool(), reward); // reserve intact
        assertEq(uint256(stakingContract.checkDepositStatus(userTwo, 0)), uint256(ProgramManager.DepositStatus.WITHDRAWN));

        // With zero unreserved reward a floor of 0 still closes the deposit and pays principal only.
        _stakeFor(userThree, 0, STAKE_AMOUNT);
        skip(10 days);
        before = myToken.balanceOf(userThree);
        vm.prank(userThree);
        stakingContract.withdrawDepositPartial(0, 0);
        assertEq(myToken.balanceOf(userThree), before + STAKE_AMOUNT);
        assertEq(stakingContract.rewardPool(), reward);
    }

    /// @notice A short free pool never silently forfeits indefinite reward: `withdrawDeposit` reverts
    ///         `NotEnoughFundsInRewardPool(accrued, collectable)` and leaves the deposit open; only
    ///         `withdrawDepositPartial` with a floor at or below the free pool closes it with the reduced
    ///         reward. Once the free pool covers the accrued reward again, `withdrawDeposit` pays in full.
    function test_IndefiniteWithdraw_ShortPool_RevertsUnlessPartialOptIn() public {
        _setupProgram(false);
        uint256 reserved = _periodicalReward(STAKE_AMOUNT, PERIOD_LONG);
        _fundRewardPool(reserved + 5); // 5 wei unreserved

        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);
        assertEq(stakingContract.getCollectableReward(), 5);

        skip(30 days);
        uint256 accrued = stakingContract.getDeposit(userTwo, 0).rewardGenerated;
        assertGt(accrued, 5);

        // (1) The full withdraw reverts and changes nothing.
        uint256 userBefore = myToken.balanceOf(userTwo);
        uint256 contractBefore = myToken.balanceOf(address(stakingContract));
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 5));
        stakingContract.withdrawDeposit(0);
        assertEq(uint256(stakingContract.checkDepositStatus(userTwo, 0)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        assertEq(myToken.balanceOf(userTwo), userBefore);
        assertEq(myToken.balanceOf(address(stakingContract)), contractBefore);
        assertEq(stakingContract.rewardPool(), reserved + 5);
        assertEq(stakingContract.getDeposit(userTwo, 0).rewardGenerated, accrued, "still accruing");

        // (2) A floor above the free pool is refused with the same error.
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 5));
        stakingContract.withdrawDepositPartial(0, 6);

        // (3) A floor equal to the free pool closes the deposit with the reduced reward.
        vm.prank(userTwo);
        vm.expectEmit(true, true, false, true);
        emit Withdraw(userTwo, 0, STAKE_AMOUNT, 5);
        stakingContract.withdrawDepositPartial(0, 5);
        assertEq(myToken.balanceOf(userTwo), userBefore + STAKE_AMOUNT + 5);
        assertEq(uint256(stakingContract.checkDepositStatus(userTwo, 0)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        assertEq(stakingContract.rewardPool(), reserved, "reserve intact, free pool spent");
        _assertPoolCoversReserve();

        // (4) A fresh indefinite deposit whose free pool is later consumed by someone else's large
        //     periodical reservation: the full withdraw waits until that reservation is released.
        _stakeFor(userThree, 0, STAKE_AMOUNT);
        uint256 free = _periodicalReward(STAKE_AMOUNT, 30);
        _fundRewardPool(free);
        assertEq(stakingContract.getCollectableReward(), free);
        _stakeFor(userOne, PERIOD_LONG, STAKE_AMOUNT * 100); // reserve now exceeds the pool
        assertEq(stakingContract.getCollectableReward(), 0);

        skip(30 days);
        accrued = stakingContract.getDeposit(userThree, 0).rewardGenerated;
        assertEq(accrued, free);
        vm.prank(userThree);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 0));
        stakingContract.withdrawDeposit(0);
        assertEq(uint256(stakingContract.checkDepositStatus(userThree, 0)), uint256(ProgramManager.DepositStatus.INDEFINITE));

        // The large periodical deposit exits early, releasing its reservation.
        vm.prank(userOne);
        stakingContract.withdrawDeposit(1);
        assertEq(stakingContract.getCollectableReward(), free);

        userBefore = myToken.balanceOf(userThree);
        vm.prank(userThree);
        vm.expectEmit(true, true, false, true);
        emit Withdraw(userThree, 0, STAKE_AMOUNT, accrued);
        stakingContract.withdrawDeposit(0);
        assertEq(myToken.balanceOf(userThree), userBefore + STAKE_AMOUNT + accrued, "full accrued reward paid");
        assertEq(uint256(stakingContract.checkDepositStatus(userThree, 0)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        assertEq(stakingContract.rewardPool(), reserved);
        _assertPoolCoversReserve();
    }

    function test_RewardPool_NeverBelowReserve_AcrossActions() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, PERIOD_LONG, STAKE_AMOUNT * 3);
        _stakeFor(userThree, PERIOD_SHORT, STAKE_AMOUNT / 2);
        _assertPoolCoversReserve();

        stakingContract.collectReward(stakingContract.getCollectableReward());
        _assertPoolCoversReserve();

        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        _assertPoolCoversReserve();

        vm.prank(userTwo);
        stakingContract.withdrawDeposit(0);
        _assertPoolCoversReserve();

        vm.prank(userThree);
        stakingContract.claimAll();
        _assertPoolCoversReserve();
        assertEq(stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
    }

    /// @dev Scenario assertion, NOT a contract invariant: every test that calls this funded
    ///      the pool before staking, so `rewardPool >= REWARD_EXPECTED` must survive collectReward and
    ///      indefinite payouts (they only ever spend the free part of the pool).
    function _assertPoolCoversReserve() internal {
        assertGe(stakingContract.rewardPool(), stakingContract.totalDataList(Types.DataType.REWARD_EXPECTED));
        assertGe(
            myToken.balanceOf(address(stakingContract)),
            stakingContract.totalDataList(Types.DataType.STAKING) + stakingContract.rewardPool()
        );
    }
}
