// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {V050Base} from "../../v050/V050Base.sol";
import {ERC20PeriodicalStaking} from "../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {LimitController} from "../../../src/contracts/LimitController.sol";
import {Types} from "../../../src/common/Types.sol";

/// @notice Audit finding #32: test gaps. (a) controller swap / repoint while bonus is held open, (b) phase pop and
///         period removal with bonus-funded deposits open, (d) the uint128 / uint32 ceilings of two setters.
contract TestGaps32 is V050Base {
    uint256 internal constant EXTRA = MAX_EXTRA_LIMIT_TOTAL; // 50k

    function _assertNoBonus(address wallet, uint256 phase, uint256 period) internal {
        (uint256 usedTotal, uint256 usedInCell) = staking.getBonusUsage(wallet, phase, period);
        assertEq(usedTotal, 0, "total bonus back to 0");
        assertEq(usedInCell, 0, "cell bonus back to 0");
    }

    // ------------------------------------------------------------------
    // (a) The bonus meters live in the staking contract, not in the controller, so swapping to a second REAL
    //     LimitController -- and even repointing that controller at another staking contract for a while, which
    //     makes `used` read 0 below the cell meter -- must neither underflow nor strand budget.
    // ------------------------------------------------------------------
    function test_gap32a_controllerSwapAndRepointWhileBonusOpen() public {
        token.transfer(alice, 200_000 * ONE);

        uint256 d0 = stakeWith(alice, P30, 120_000 * ONE, 0, EXTRA); // 100k base + 20k bonus
        (uint256 usedTotal, uint256 usedCell) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, 20_000 * ONE);
        assertEq(usedCell, 20_000 * ONE);

        // Swap to a second real controller with the same defaults.
        LimitController second = new LimitController(address(staking));
        for (uint256 i = 0; i < PERIODS.length; i++) {
            second.setDefaultLimit(0, PERIODS[i], DEFAULT_LIMIT);
        }
        staking.setLimitController(address(second));
        assertEq(second.getRemaining(alice, 0, P30), 0, "the new controller sees the existing stake");

        // Stake more through the new controller: 100k base + the remaining 30k of bonus.
        uint256 d1 = stakeWith(alice, P90, 130_000 * ONE, 0, EXTRA);
        (usedTotal, usedCell) = staking.getBonusUsage(alice, 0, P90);
        assertEq(usedTotal, EXTRA);
        assertEq(usedCell, 30_000 * ONE);

        // A controller that reports `used` = 0 for alice while the P30 cell meter holds 20k: `used - spentCell`
        // has to saturate, not underflow. Up to v0.5.0 this was reachable by repointing the INSTALLED
        // controller at another staking contract; LimitController.stakingContract is immutable now (finding
        // #16), so the same reading is injected directly instead.
        vm.mockCall(
            address(second),
            abi.encodeWithSelector(LimitController.getAllowedAndUsed.selector, alice, uint256(0), P30),
            abi.encode(DEFAULT_LIMIT, uint256(0))
        );
        uint256 d2 = stakeWith(alice, P30, 10_000 * ONE, 0, EXTRA); // base only: the budget is exhausted
        (usedTotal, usedCell) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, EXTRA, "no bonus charged by the base-only stake");
        assertEq(usedCell, 20_000 * ONE);
        vm.clearMockedCalls();

        // Close everything, in an order that releases the larger bonus first.
        vm.startPrank(alice);
        staking.withdrawDeposit(d1);
        staking.withdrawDeposit(d2);
        staking.withdrawDeposit(d0);
        vm.stopPrank();

        _assertNoBonus(alice, 0, P30);
        _assertNoBonus(alice, 0, P90);
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), 0);
        assertEq(_cell(alice, 0, P30), 0);
        assertEq(_cell(alice, 0, P90), 0);
        assertEq(second.getRemaining(alice, 0, P30), DEFAULT_LIMIT, "base room fully restored");

        // And the budget is whole again: the full 150k fits once more.
        stakeWith(alice, P30, 150_000 * ONE, 0, EXTRA);
    }

    // ------------------------------------------------------------------
    // (b) popStakingPhase / removeStakingPeriod delete configuration only. Bonus-funded deposits opened on the
    //     removed phase / period must still close (claim and withdraw) and release their bonus to the right cell.
    // ------------------------------------------------------------------
    function test_gap32b_popPhaseAndRemovePeriodWithBonusDepositsOpen() public {
        token.transfer(alice, 100_000 * ONE);

        uint256 d0 = stakeWith(alice, P90, 110_000 * ONE, 0, EXTRA); // cell (0, 90): 10k bonus
        staking.changeStakingPhase(1);
        uint256 d1 = stakeWith(alice, P30, 120_000 * ONE, 0, EXTRA); // cell (1, 30): 20k bonus
        (uint256 usedTotal,) = staking.getBonusUsage(alice, 1, P30);
        assertEq(usedTotal, 30_000 * ONE);

        staking.popStakingPhase(); // removes phase 1, current rolls back to 0
        staking.removeStakingPeriod(P90);
        assertEq(staking.currentStakingPhase(), 0);

        // Removal touched no meter.
        uint256 usedCell;
        (usedTotal, usedCell) = staking.getBonusUsage(alice, 1, P30);
        assertEq(usedTotal, 30_000 * ONE);
        assertEq(usedCell, 20_000 * ONE);
        (, usedCell) = staking.getBonusUsage(alice, 0, P90);
        assertEq(usedCell, 10_000 * ONE);

        // Close the deposit on the removed PHASE by claiming it at maturity...
        _warpDays(30);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimDeposit(d1);
        uint256 reward = staking.calculateReward(120_000 * ONE, APY_P30 + PHASE1_APY_BONUS, 30);
        assertEq(token.balanceOf(alice) - before, 120_000 * ONE + reward);
        _assertCellBonus(alice, 1, P30, 10_000 * ONE, 0);

        // ...and the one on the removed PERIOD by withdrawing it early.
        vm.prank(alice);
        staking.withdrawDeposit(d0);
        _assertNoBonus(alice, 0, P90);
        _assertNoBonus(alice, 1, P30);

        assertEq(staking.getUserData(Types.DataType.STAKING, alice), 0);
        assertEq(staking.getTotalData(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(staking.phasePeriodDataList(Types.PhasePeriodDataType.STAKED, 1, P30), 0);
        assertEq(staking.phasePeriodDataList(Types.PhasePeriodDataType.STAKED, 0, P90), 0);

        // The whole budget is usable again on what is still configured.
        stakeWith(alice, P30, 150_000 * ONE, 0, EXTRA);
    }

    function _assertCellBonus(address wallet, uint256 phase, uint256 period, uint256 total, uint256 cell) internal {
        (uint256 usedTotal, uint256 usedInCell) = staking.getBonusUsage(wallet, phase, period);
        assertEq(usedTotal, total);
        assertEq(usedInCell, cell);
    }

    // ------------------------------------------------------------------
    // (d) Ceilings of the two packed setters: one past the type's max reverts with SafeCast's typed error and
    //     leaves the value alone; the max itself is accepted.
    // ------------------------------------------------------------------
    function test_gap32d_setMaxExtraLimitPerCell_aboveUint128Reverts() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooBig));
        staking.setMaxExtraLimitPerCell(tooBig);
        assertEq(staking.maxExtraLimitPerCell(), MAX_EXTRA_LIMIT_PER_CELL, "unchanged");

        staking.setMaxExtraLimitPerCell(type(uint128).max);
        assertEq(staking.maxExtraLimitPerCell(), type(uint128).max);
        assertEq(staking.maxVoucherValidity(), VOUCHER_LIFETIME, "slot neighbour untouched");
    }

    function test_gap32d_setMaxVoucherValidity_aboveUint32Reverts() public {
        uint256 tooBig = uint256(type(uint32).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, tooBig));
        staking.setMaxVoucherValidity(tooBig);
        assertEq(staking.maxVoucherValidity(), VOUCHER_LIFETIME, "unchanged");

        staking.setMaxVoucherValidity(type(uint32).max);
        assertEq(staking.maxVoucherValidity(), type(uint32).max);
        assertEq(staking.maxExtraLimitPerCell(), MAX_EXTRA_LIMIT_PER_CELL, "slot neighbour untouched");
    }
}
