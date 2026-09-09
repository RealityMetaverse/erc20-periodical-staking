// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";

/// @dev Exposes the internal indefinite-reward calculation so the saturating branch can be unit tested.
///      The public API pins each deposit's APY at stake time, so accrued < rewardGenerated is not reachable
///      through safeStake/claim; the harness tests the guard directly.
contract RewardMathHarness is ERC20PeriodicalStaking {
    constructor(address token) ERC20PeriodicalStaking(token) {}

    function indefiniteReward(TokenDeposit memory d) external view returns (uint256) {
        return _calculateIndefiniteDepositReward(d);
    }
}

/// @title Indefinite reward math is saturating
contract SaturatingRewardMathTest is V030Base {
    RewardMathHarness harness;

    function _deposit(uint256 amount, uint256 apy, uint256 startDate, uint256 rewardGenerated)
        internal
        pure
        returns (ProgramManager.TokenDeposit memory)
    {
        return ProgramManager.TokenDeposit(0, 0, startDate, 0, 0, amount, apy, rewardGenerated);
    }

    function _harness() internal {
        harness = new RewardMathHarness(address(myToken));
    }

    function test_ReturnsZeroWhenAlreadyPaidExceedsAccrued() public {
        _harness();
        vm.warp(1_000_000);
        uint256 start = _now() - 10 days;
        uint256 accrued = harness.calculateReward(STAKE_AMOUNT, APY, 10);

        // rewardGenerated larger than accrued (e.g. paid at a higher rate earlier): must be 0, not underflow.
        assertEq(harness.indefiniteReward(_deposit(STAKE_AMOUNT, APY, start, accrued + 1)), 0);
        assertEq(harness.indefiniteReward(_deposit(STAKE_AMOUNT, APY, start, accrued * 3)), 0);
        assertEq(harness.indefiniteReward(_deposit(STAKE_AMOUNT, APY, start, type(uint256).max)), 0);
    }

    function test_ExactDifferenceWhenAccruedExceedsPaid() public {
        _harness();
        vm.warp(1_000_000);
        uint256 start = _now() - 10 days;
        uint256 accrued = harness.calculateReward(STAKE_AMOUNT, APY, 10);

        assertEq(harness.indefiniteReward(_deposit(STAKE_AMOUNT, APY, start, 0)), accrued);
        assertEq(harness.indefiniteReward(_deposit(STAKE_AMOUNT, APY, start, accrued / 2)), accrued - accrued / 2);
        assertEq(harness.indefiniteReward(_deposit(STAKE_AMOUNT, APY, start, accrued)), 0);
    }

    function testFuzz_NeverReverts(uint128 amount, uint16 apy, uint32 daysPassed, uint256 rewardGenerated)
        public
    {
        _harness();
        vm.warp(uint256(daysPassed) * 1 days + 1);
        uint256 start = _now() - uint256(daysPassed) * 1 days;
        uint256 accrued = harness.calculateReward(amount, apy, daysPassed);

        uint256 got = harness.indefiniteReward(_deposit(amount, apy, start, rewardGenerated));
        if (rewardGenerated >= accrued) assertEq(got, 0);
        else assertEq(got, accrued - rewardGenerated);
    }

    /// @notice End-to-end: an indefinite deposit claimed repeatedly never reverts and never over-pays.
    function test_IndefiniteRepeatedClaims_Consistent() public {
        _setupProgram(true);
        _stakeFor(userOne, 0, STAKE_AMOUNT);

        uint256 paid;
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 days);
            uint256 before = myToken.balanceOf(userOne);
            vm.prank(userOne);
            stakingContract.claimDeposit(0);
            paid += myToken.balanceOf(userOne) - before;
        }
        assertEq(paid, stakingContract.calculateReward(STAKE_AMOUNT, APY, 50));
        assertEq(stakingContract.getDeposit(userOne, 0).rewardGenerated, 0); // nothing further claimable right now

        // Same block: nothing to claim, explicit error (not an underflow).
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoRewardToClaim.selector, 0));
        stakingContract.claimDeposit(0);
    }
}
