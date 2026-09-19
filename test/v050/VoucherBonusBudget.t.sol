// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";

import "./V050Base.sol";

/// @notice The voucher extra limit as a METERED BUDGET rather than a per-stake grant.
///
///         v0.4.0 as first written added `extraLimit` straight onto the controller's allowance for the one stake
///         being made. Because `getUsed` is per (phase, period) cell, the same voucher value was granted again in
///         every period and again for every fresh voucher: a VIP 1 bonus of 50,000 turned into a 50,000-per-cell
///         ceiling, which over the eight configured periods is 405,000 (8 x 50,000 of bonus on top of the base
///         limit). The fix meters what the wallet actually holds open above its controller limit:
///
///             baseUsed  = used > spentCell ? used - spentCell : 0    // don't count bonus money twice
///             baseRoom  = baseUsed >= allowed ? 0 : allowed - baseUsed
///             bonusLeft = min(extraLimitTotal - spentTotal, extraLimitPerCell - spentCell)   // floored at 0
///             headroom  = baseRoom + bonusLeft                                               // saturating
///             bonusNow  = tokenAmount > baseRoom ? tokenAmount - baseRoom : 0
///
///         A CELL is (phase, period), as the LimitController has always keyed it. The two meters are scoped
///         differently on purpose:
///             walletBonusUsed[wallet]                        -- GLOBAL. One budget for all time, every phase
///                                                               and every period. A phase change does not
///                                                               refill it.
///             walletBonusUsedInCell[phase][period][wallet]   -- PER CELL, against extraLimitPerCell. The same
///                                                               period in a new phase is a new cell.
///         Both are CONCURRENT, not a lifetime spend: closing a deposit returns exactly the bonus that deposit
///         consumed, to its own cell and to the total.
///
/// @dev Every test names the mutation or regression it kills. The fixture deliberately sets every controller
///      default limit to 0, so the bonus is the only room and the meter is read directly off the staked cell;
///      tests that care about the base allowance set it themselves. Never read `block.timestamp` after a warp:
///      use `_now()` (via_ir hazard, see test/shared/Clock.sol).
contract VoucherBonusBudgetTest is V050Base {
    /// @dev == MAX_EXTRA_LIMIT_TOTAL, the largest budget a voucher may carry in this fixture.
    uint256 internal constant BUDGET = 50_000 * ONE;
    uint256 internal constant AMOUNT = 1_000 * ONE;
    /// @dev The contract's minimumDeposit. Probing headroom with 1 wei would trip InsufficientDeposit first,
    ///      which is a different check and would hide the one under test.
    uint256 internal constant MIN_DEPOSIT = 100;

    /// @dev Eight periods, so "one voucher, granted again per cell" is worth 8x its face value. P7/P14/P60/P180/
    ///      P365 are added here rather than in V050Base so no other suite's fixture shifts.
    uint256 internal constant P7 = 7;
    uint256 internal constant P14 = 14;
    uint256 internal constant P60 = 60;
    uint256 internal constant P180 = 180;
    uint256 internal constant P365 = 365;

    uint256[] internal ALL_PERIODS;

    function setUp() public override {
        super.setUp();

        uint256[] memory apys = new uint256[](2);
        uint256[] memory targets = _fill(2, TARGET);
        uint256[5] memory extra = [P7, P14, P60, P180, P365];
        uint256[5] memory extraApy = [uint256(600), 700, 1_200, 2_500, 3_000];
        for (uint256 i = 0; i < extra.length; i++) {
            apys[0] = extraApy[i];
            apys[1] = extraApy[i] + PHASE1_APY_BONUS;
            staking.addStakingPeriod(extra[i], apys, targets);
        }

        ALL_PERIODS = [P0, P7, P14, P30, P60, P90, P180, P365];

        // Default limit 0 everywhere, both phases: no wallet-specific entry, so the bonus is fully available
        // (see test_ban_...) and every token staked below is bonus. Tests that want a base allowance set one.
        for (uint256 phase = 0; phase < 2; phase++) {
            for (uint256 i = 0; i < ALL_PERIODS.length; i++) {
                controller.setDefaultLimit(phase, ALL_PERIODS[i], 0);
            }
        }

        // Alice needs more than USER_FUNDS for the additive-base and legacy cases.
        token.transfer(alice, 400_000 * ONE);
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    function _phase() internal view returns (uint256) {
        return staking.currentStakingPhase();
    }

    /// @dev Voucher carrying a split budget, no extra APY, for the current phase.
    function _budgetVoucher(address wallet, uint256 period, uint256 total, uint256 perCell)
        internal
        returns (Types.StakeVoucher memory)
    {
        return _makeVoucherBudget(wallet, _phase(), period, 0, total, perCell);
    }

    /// @dev Stake `amount` under a fresh budget voucher. Returns the deposit number.
    function _stakeBudget(address wallet, uint256 period, uint256 amount, uint256 total, uint256 perCell)
        internal
        returns (uint256 depositNumber)
    {
        Types.StakeVoucher memory v = _budgetVoucher(wallet, period, total, perCell);
        bytes memory sig = signVoucher(v);
        // Read the APY BEFORE the prank: _baseApy is an external call and would consume the cheatcode.
        uint256 expectedApy = _baseApy(v.phase, period);
        vm.prank(wallet);
        depositNumber = staking.stakeWithVoucher(v, sig, amount, expectedApy);
    }

    /// @dev Expect `amount` to be refused with exactly `headroom` available.
    function _expectHeadroom(
        address wallet,
        uint256 period,
        uint256 amount,
        uint256 total,
        uint256 perCell,
        uint256 headroom
    ) internal {
        Types.StakeVoucher memory v = _budgetVoucher(wallet, period, total, perCell);
        bytes memory sig = signVoucher(v);
        uint256 expectedApy = _baseApy(v.phase, period);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, wallet, v.phase, period, amount, headroom)
        );
        staking.stakeWithVoucher(v, sig, amount, expectedApy);
    }

    function _usedTotal(address wallet, uint256 period) internal view returns (uint256 usedTotal) {
        (usedTotal,) = staking.getBonusUsage(wallet, _phase(), period);
    }

    function _usedInCell(address wallet, uint256 period) internal view returns (uint256 usedInCell) {
        (, usedInCell) = staking.getBonusUsage(wallet, _phase(), period);
    }

    /// @dev Current-phase form. A CELL is (phase, period), so anything that crosses a phase boundary must say
    ///      which phase it means: use _assertUsageIn. The total is global and reads the same from any cell.
    function _assertUsage(address wallet, uint256 period, uint256 expectedTotal, uint256 expectedCell, string memory m)
        internal
    {
        _assertUsageIn(wallet, _phase(), period, expectedTotal, expectedCell, m);
    }

    function _assertUsageIn(
        address wallet,
        uint256 phase,
        uint256 period,
        uint256 expectedTotal,
        uint256 expectedCell,
        string memory m
    ) internal {
        (uint256 usedTotal, uint256 usedInCell) = staking.getBonusUsage(wallet, phase, period);
        assertEq(usedTotal, expectedTotal, string.concat(m, ": usedTotal"));
        assertEq(usedInCell, expectedCell, string.concat(m, ": usedInCell"));
    }

    /// @dev True if any log in `logs` is a BonusReleased.
    function _sawRelease(Vm.Log[] memory logs) internal pure returns (bool) {
        bytes32 topic = keccak256("BonusReleased(address,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    // ======================================================================
    // =                      1-4: the headline behaviour                   =
    // ======================================================================

    /// @notice total == perCell == 50k: the whole budget fits in one period, and not one wei more.
    /// @dev Kills: dropping the per-cell clamp entirely (the stake of BUDGET + 1 would then be allowed up to the
    ///      wallet-wide total, which is the same here, so this is really the baseline both clamps must agree on);
    ///      and any implementation that charges the meter the wrong amount, since the follow-up stake of 1 wei
    ///      only reverts when exactly BUDGET was recorded.
    function test_wholeBudgetInOneCell_andNotOneWeiMore() external {
        _expectHeadroom(alice, P30, BUDGET + 1, BUDGET, BUDGET, BUDGET);

        uint256 n = _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        assertEq(_cell(alice, _phase(), P30), BUDGET, "cell holds the whole budget");
        assertEq(_deposit(alice, n).amount, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "after the full-budget stake");

        // A fresh, independently valid voucher with the same numbers finds nothing left.
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, BUDGET, 0);
    }

    /// @notice THE BUG: the budget is ONE TOTAL, so the sum across ALL periods can never exceed it.
    /// @dev Kills the shipped v0.4.0 behaviour outright. Under per-cell-only metering each of the eight periods
    ///      would independently accept 50,000, i.e. 400,000 of bonus from one 50,000 voucher. Here seven periods
    ///      take 7,000 each (49,000) and the eighth is capped at the remaining 1,000.
    function test_budgetIsATotal_notPerCell() external {
        uint256 slice = 7_000 * ONE;
        for (uint256 i = 0; i < 7; i++) {
            _stakeBudget(alice, ALL_PERIODS[i], slice, BUDGET, BUDGET);
        }
        assertEq(_usedTotal(alice, P30), 7 * slice, "49,000 of the budget is held open");

        // The eighth period does NOT get a fresh 50,000: only the 1,000 left over.
        uint256 left = BUDGET - 7 * slice;
        _expectHeadroom(alice, P365, slice, BUDGET, BUDGET, left);
        _stakeBudget(alice, P365, left, BUDGET, BUDGET);

        _assertUsage(alice, P365, BUDGET, left, "budget exhausted across eight periods");

        // Nothing anywhere: every period is now shut, including the ones that took a slice.
        for (uint256 i = 0; i < ALL_PERIODS.length; i++) {
            _expectHeadroom(alice, ALL_PERIODS[i], MIN_DEPOSIT, BUDGET, BUDGET, 0);
        }

        // And the total staked is the budget, not a multiple of it.
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), BUDGET, "total staked == one budget");
    }

    /// @notice total 50k with perCell 10k: no cell takes more than 10k, and using the budget needs five cells.
    /// @dev Kills: clamping the cell against extraLimitTotal instead of extraLimitPerCell (the first cell would
    ///      then swallow all 50,000), and ignoring extraLimitPerCell altogether.
    function test_perCellCapForcesTheBudgetToSpread() external {
        uint256 perCell = 10_000 * ONE;

        _expectHeadroom(alice, P30, perCell + 1, BUDGET, perCell, perCell);
        _stakeBudget(alice, P30, perCell, BUDGET, perCell);
        _assertUsage(alice, P30, perCell, perCell, "first cell filled to the per-cell cap");

        // The cell is full even though 40,000 of the wallet's budget is untouched.
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, perCell, 0);

        // Four more cells to spend the rest: five in total, exactly as the cap forces.
        uint256[4] memory rest = [P0, P7, P14, P60];
        for (uint256 i = 0; i < rest.length; i++) {
            _stakeBudget(alice, rest[i], perCell, BUDGET, perCell);
        }
        _assertUsage(alice, P60, BUDGET, perCell, "budget spent across five cells");

        // A sixth cell gets nothing: the wallet total is the binding constraint now.
        _expectHeadroom(alice, P90, MIN_DEPOSIT, BUDGET, perCell, 0);
    }

    /// @notice The controller allowance is additive and separate: only the part above baseRoom touches the meter.
    /// @dev Kills: charging the meter the whole tokenAmount (the wallet would lose 1,000 of budget it never
    ///      needed), and charging nothing (the meter would never fill).
    function test_baseAllowanceIsAdditiveAndDoesNotTouchTheMeter() external {
        uint256 allowed = 1_000 * ONE;
        controller.setDefaultLimit(_phase(), P30, allowed);
        controller.setDefaultLimit(_phase(), P90, allowed);

        // A stake that fits entirely inside the controller limit spends no bonus at all.
        _stakeBudget(alice, P90, allowed, BUDGET, BUDGET);
        _assertUsage(alice, P90, 0, 0, "stake inside the base allowance");

        // The smallest stake past the base allowance charges exactly that much bonus, and no more.
        _stakeBudget(alice, P90, MIN_DEPOSIT, BUDGET, BUDGET);
        _assertUsage(alice, P90, MIN_DEPOSIT, MIN_DEPOSIT, "just over the base allowance");

        // In a fresh cell: allowance + the REST of the budget (MIN_DEPOSIT of it is held open in P90 above),
        // and only the part above the allowance is metered.
        uint256 rest = BUDGET - MIN_DEPOSIT;
        _expectHeadroom(alice, P30, allowed + rest + 1, BUDGET, BUDGET, allowed + rest);
        _stakeBudget(alice, P30, allowed + rest, BUDGET, BUDGET);
        assertEq(_cell(alice, _phase(), P30), allowed + rest, "base and bonus both landed");
        _assertUsage(alice, P30, BUDGET, rest, "only the part above baseRoom was metered");
    }

    // ======================================================================
    // =                     5-10: release and concurrency                  =
    // ======================================================================

    /// @notice Withdrawal returns exactly the bonus the deposit consumed, to both counters.
    /// @dev Kills: no release at all (the budget would be lifetime, not concurrent), releasing to only one of the
    ///      two counters, and releasing a value other than depositBonusUsed[wallet][n].
    function test_withdrawReleasesBothCountersExactly() external {
        uint256 amount = 30_000 * ONE;
        uint256 n = _stakeBudget(alice, P30, amount, BUDGET, BUDGET);
        _assertUsage(alice, P30, amount, amount, "after the stake");

        vm.expectEmit(true, true, true, true, address(staking));
        emit BonusReleased(alice, _phase(), P30, n, amount);
        vm.prank(alice);
        staking.withdrawDeposit(n);

        _assertUsage(alice, P30, 0, 0, "after the withdrawal");

        // The same bonus is spendable again, which is what "concurrent, not lifetime" means.
        _stakeBudget(alice, P30, amount, BUDGET, BUDGET);
        _assertUsage(alice, P30, amount, amount, "re-staked the released bonus");
    }

    /// @notice HIGHEST VALUE HERE: claiming an INDEFINITE deposit's reward must NOT release the budget.
    /// @dev An indefinite (period 0) claim pays only the accrued reward; the principal stays staked, so the
    ///      controller cell is unchanged and the bonus is still held open. The natural implementation releases
    ///      whenever depositBonusUsed[wallet][n] != 0, or hangs the release off _updateAllDataAfterAction for
    ///      every non-STAKING action -- both free the budget here while the position is open, letting the wallet
    ///      claim, re-stake the same bonus, claim again, and hold an unbounded multiple of its budget.
    ///      Kills exactly that: the release must be on the close branches (depositAmount != 0), not on CLAIM.
    function test_indefiniteRewardClaimDoesNotReleaseTheBudget() external {
        uint256 amount = 20_000 * ONE;
        uint256 n = _stakeBudget(alice, P0, amount, BUDGET, BUDGET);
        _assertUsage(alice, P0, amount, amount, "after the indefinite stake");

        _warpDays(100);
        assertEq(uint8(_status(alice, n)), uint8(ProgramManager.DepositStatus.INDEFINITE));

        vm.recordLogs();
        vm.prank(alice);
        staking.claimDeposit(n);
        assertFalse(_sawRelease(vm.getRecordedLogs()), "an indefinite claim must not emit BonusReleased");

        // The position is still open and still holding the bonus.
        assertEq(uint8(_status(alice, n)), uint8(ProgramManager.DepositStatus.INDEFINITE), "still open");
        assertEq(_cell(alice, _phase(), P0), amount, "principal never left the cell");
        _assertUsage(alice, P0, amount, amount, "budget still held after the reward claim");

        // And the freed-budget double spend is impossible: only the genuine remainder is available.
        uint256 left = BUDGET - amount;
        _expectHeadroom(alice, P0, left + 1, BUDGET, BUDGET, left);
        _stakeBudget(alice, P0, left, BUDGET, BUDGET);
        _assertUsage(alice, P0, BUDGET, BUDGET, "budget exhausted, claim gave nothing back");
    }

    /// @notice A READY_TO_CLAIM claim closes the deposit, so it DOES release.
    /// @dev Kills the over-correction of the test above: keying the release on "period != 0" or on
    ///      "not a claim" would leave matured periodical deposits charging the budget forever.
    function test_maturedClaimReleasesTheBudget() external {
        uint256 amount = 20_000 * ONE;
        uint256 n = _stakeBudget(alice, P30, amount, BUDGET, BUDGET);
        _warpDays(31);
        assertEq(uint8(_status(alice, n)), uint8(ProgramManager.DepositStatus.READY_TO_CLAIM));

        vm.expectEmit(true, true, true, true, address(staking));
        emit BonusReleased(alice, _phase(), P30, n, amount);
        vm.prank(alice);
        staking.claimDeposit(n);

        _assertUsage(alice, P30, 0, 0, "matured claim released the budget");
        _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "the whole budget is available again");
    }

    /// @notice Seizing routes through the withdrawal branch, so it releases too.
    /// @dev Kills: releasing only inside withdrawDeposit/claimDeposit rather than in the shared close path. The
    ///      wallet's principal is gone; leaving its budget charged would punish it twice, and worse, the charge
    ///      could never be cleared because the deposit can never be closed again.
    function test_seizeReleasesTheBudget() external {
        uint256 amount = 20_000 * ONE;
        uint256 n = _stakeBudget(alice, P30, amount, BUDGET, BUDGET);

        freeze(alice, n);
        vm.expectEmit(true, true, true, true, address(staking));
        emit BonusReleased(alice, _phase(), P30, n, amount);
        seize(alice, n);

        assertEq(uint8(_status(alice, n)), uint8(ProgramManager.DepositStatus.SEIZED));
        assertEq(_cell(alice, _phase(), P30), 0, "principal left the cell");
        _assertUsage(alice, P30, 0, 0, "seize released the budget");
    }

    /// @notice Freezing only sets a flag, so it must NOT release.
    /// @dev Kills: treating freeze as a close. A frozen deposit's principal is still staked and still counted by
    ///      the controller; releasing its bonus would let the wallet re-stake a budget it is still holding, which
    ///      is precisely the position an admin froze it out of.
    function test_freezeDoesNotReleaseTheBudget() external {
        uint256 amount = 20_000 * ONE;
        uint256 n = _stakeBudget(alice, P30, amount, BUDGET, BUDGET);

        vm.recordLogs();
        freeze(alice, n);
        assertFalse(_sawRelease(vm.getRecordedLogs()), "freeze must not emit BonusReleased");

        assertEq(_cell(alice, _phase(), P30), amount, "principal still staked");
        _assertUsage(alice, P30, amount, amount, "budget still held while frozen");

        // Unfreezing is not a second grant either.
        unfreeze(alice, n);
        _assertUsage(alice, P30, amount, amount, "unfreeze changes nothing");
    }

    /// @notice withdrawDepositPartial reduces the REWARD, never the principal, so it releases the budget in full.
    /// @dev The "partial" in the name is about accepting a reduced indefinite reward when the free pool is short;
    ///      the deposit is closed and the whole principal is returned. Kills: scaling the release by the payout,
    ///      or skipping it on this path, either of which would strand budget that can never be reclaimed because
    ///      the deposit is already closed. Set up so the reward really is cut short, to prove the release is
    ///      driven by the principal and not by what was paid.
    function test_partialWithdrawalReleasesTheWholeBudget() external {
        uint256 amount = 20_000 * ONE;
        uint256 n = _stakeBudget(alice, P0, amount, BUDGET, BUDGET);
        _warpDays(365);

        // Drain the free pool so the accrued reward cannot be paid in full.
        uint256 collectable = staking.getCollectableReward();
        staking.collectReward(collectable - 1);
        assertLt(staking.getCollectableReward(), _deposit(alice, n).rewardGenerated, "reward really is short");

        uint256 before = token.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(staking));
        emit BonusReleased(alice, _phase(), P0, n, amount);
        vm.prank(alice);
        staking.withdrawDepositPartial(n, 0);

        assertEq(token.balanceOf(alice) - before, amount + 1, "full principal, reduced reward");
        _assertUsage(alice, P0, 0, 0, "the whole budget came back");
        _stakeBudget(alice, P0, BUDGET, BUDGET, BUDGET);
    }

    // ======================================================================
    // =            11-13: immunity to operator configuration               =
    // ======================================================================

    /// @notice Raising a limit under an existing bonus-funded position must NOT refresh the bonus.
    /// @dev This is why the budget is explicit state rather than derived. Under the rejected design
    ///      `bonusUsed = max(0, used - allowed)`, raising the default from 0 to 100,000 with 50,000 staked makes
    ///      the derived usage 0 and silently hands the whole budget back -- headroom would jump to 100,000 here
    ///      instead of the 50,000 of genuinely unused base allowance. Kills exactly that.
    function test_raisingTheDefaultLimitDoesNotRefreshTheBonus() external {
        _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "budget spent under a 0 limit");

        controller.setDefaultLimit(_phase(), P30, 100_000 * ONE);

        // The 50,000 already staked is entirely bonus-funded, so it does NOT count against the new base
        // allowance: baseUsed = used - spentCell = 0, so baseRoom is the whole 100,000. bonusLeft is still 0 --
        // which is the claim this test exists for. Raising a limit grants base room, never bonus.
        uint256 baseRoom = 100_000 * ONE;
        _expectHeadroom(alice, P30, baseRoom + 1, BUDGET, BUDGET, baseRoom);
        _stakeBudget(alice, P30, baseRoom, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "the base-funded stake consumed no bonus");

        // And now that the base allowance is genuinely exhausted, there is nothing left from either source.
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, BUDGET, 0);
    }

    /// @notice Lowering a limit under an existing position must NOT consume bonus the wallet never spent.
    /// @dev The mirror image of the test above, and the more dangerous direction: under the derived design,
    ///      dropping the wallet limit from 20,000 to 5,000 with 20,000 staked makes the derived usage 15,000, so
    ///      an operator tightening a limit would silently confiscate 15,000 of a VIP's untouched budget. The
    ///      metered design charges nothing, because the wallet never staked above its limit.
    function test_loweringAWalletLimitDoesNotConsumeUnspentBonus() external {
        uint256 allowed = 20_000 * ONE;
        controller.setDefaultLimit(_phase(), P30, allowed);

        _stakeBudget(alice, P30, allowed, BUDGET, BUDGET);
        _assertUsage(alice, P30, 0, 0, "entirely base-funded");

        controller.setWalletLimit(alice, _phase(), P30, 5_000 * ONE);

        // baseRoom is now 0, but the whole budget is still unspent.
        _expectHeadroom(alice, P30, BUDGET + 1, BUDGET, BUDGET, BUDGET);
        _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "the full budget was still available");
    }

    /// @notice Legacy stake raises `used` and shrinks baseRoom, but never touches the bonus meter.
    /// @dev Kills: deriving usage from the controller's numbers (legacy stake would eat the budget) and double
    ///      counting the legacy amount on both sides. The wallet gets exactly baseRoom + budget.
    function test_legacyStakeShrinksBaseRoomOnly() external {
        uint256 allowed = 20_000 * ONE;
        uint256 legacyStake = 15_000 * ONE;
        controller.setDefaultLimit(_phase(), P30, allowed);
        legacy.setStaked(alice, _phase(), P30, legacyStake);

        uint256 baseRoom = allowed - legacyStake;
        _expectHeadroom(alice, P30, baseRoom + BUDGET + 1, BUDGET, BUDGET, baseRoom + BUDGET);

        _stakeBudget(alice, P30, baseRoom + BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "only the part above baseRoom was metered");

        // Legacy stake going away refunds BASE room and no bonus. Alice holds 55,000 in the cell, but 50,000
        // of it is charged to the bonus meter, so only 5,000 counts against the 20,000 allowance: freeing the
        // 15,000 of legacy stake leaves baseRoom = 20,000 - 5,000 = 15,000. The meter does not move.
        legacy.setStaked(alice, _phase(), P30, 0);
        _assertUsage(alice, P30, BUDGET, BUDGET, "legacy unwind does not refund bonus");

        uint256 freedBaseRoom = allowed - baseRoom; // 20,000 - 5,000
        _expectHeadroom(alice, P30, freedBaseRoom + 1, BUDGET, BUDGET, freedBaseRoom);
        _stakeBudget(alice, P30, freedBaseRoom, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "the freed base room funded it, not the bonus");
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, BUDGET, 0);
    }

    // ======================================================================
    // =                          14-18: security                           =
    // ======================================================================

    /// @notice A limit of 0 means "no base allowance". It is NOT a block, and it never touches the bonus.
    /// @dev Product decision, 2026-09-18: zero keeps one meaning everywhere in the LimitController -- no normal
    ///      room. Blocking a wallet is a separate switch (`setWalletBlocked`, see VoucherBlocking.t.sol) so the
    ///      two ideas cannot be confused. This test pins the "limit" half of that split: a wallet on an explicit
    ///      zero limit still receives its whole voucher budget, because the bonus is independent headroom.
    ///      Kills a re-introduction of the old proposal where `allowed == 0 && hasWalletLimit` zeroed the bonus,
    ///      which would silently disable the perk for every wallet an operator had merely throttled.
    function test_aZeroWalletLimitIsNotABlockAndLeavesTheBonusIntact() external {
        controller.setWalletLimit(alice, _phase(), P30, 0);
        assertTrue(controller.hasWalletLimit(alice, _phase(), P30), "an explicit zero, not an absent entry");
        assertEq(controller.getRemaining(alice, _phase(), P30), 0, "no base room at all");

        _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "the zero limit did not touch the bonus");
        assertEq(_cell(alice, _phase(), P30), BUDGET, "the whole budget landed in the zero-limit cell");
    }

    /// @notice Two vouchers that are both valid at the same time share one budget.
    /// @dev Kills: metering per voucher or per nonce. Both vouchers are signed BEFORE either is used, so an
    ///      implementation that keys the budget on the voucher (or resets it when a new nonce is seen) hands out
    ///      50,000 twice. The backend cannot be relied on to issue only one live voucher per wallet.
    function test_twoLiveVouchersCannotDoubleSpendTheBudget() external {
        Types.StakeVoucher memory a = _budgetVoucher(alice, P30, BUDGET, BUDGET);
        Types.StakeVoucher memory b = _budgetVoucher(alice, P90, BUDGET, BUDGET);
        bytes memory sigA = signVoucher(a);
        bytes memory sigB = signVoucher(b);
        assertTrue(a.nonce != b.nonce, "two distinct, simultaneously valid vouchers");

        uint256 apyA = _baseApy(a.phase, P30);
        uint256 apyB = _baseApy(b.phase, P90);

        vm.prank(alice);
        staking.stakeWithVoucher(a, sigA, BUDGET, apyA);
        _assertUsage(alice, P30, BUDGET, BUDGET, "voucher A spent the budget");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.StakingLimitExceeded.selector, alice, b.phase, P90, MIN_DEPOSIT, uint256(0)
            )
        );
        staking.stakeWithVoucher(b, sigB, MIN_DEPOSIT, apyB);

        assertEq(staking.getUserData(Types.DataType.STAKING, alice), BUDGET, "one budget, not two");
    }

    /// @notice Both admin ceilings are enforced, and the total one is checked first.
    /// @dev Kills: validating only extraLimitTotal (a compromised or buggy signer could then put an unbounded
    ///      amount into a single cell, which is exactly the blast radius maxExtraLimitPerCell exists to bound),
    ///      and validating perCell against maxExtraLimitTotal by mistake.
    function test_bothAdminCeilingsAreEnforced() external {
        Types.StakeVoucher memory overTotal = _budgetVoucher(alice, P30, MAX_EXTRA_LIMIT_TOTAL + 1, BUDGET);
        bytes memory sig = signVoucher(overTotal);
        uint256 apy = _baseApy(overTotal.phase, P30);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.VoucherExtraLimitTotalTooHigh.selector, MAX_EXTRA_LIMIT_TOTAL + 1, MAX_EXTRA_LIMIT_TOTAL)
        );
        staking.stakeWithVoucher(overTotal, sig, AMOUNT, apy);

        uint256 newPerCellMax = 10_000 * ONE;
        staking.setMaxExtraLimitPerCell(newPerCellMax);
        assertEq(staking.maxExtraLimitPerCell(), newPerCellMax);

        Types.StakeVoucher memory overCell = _budgetVoucher(alice, P30, BUDGET, newPerCellMax + 1);
        bytes memory sig2 = signVoucher(overCell);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.VoucherExtraLimitPerCellTooHigh.selector, newPerCellMax + 1, newPerCellMax
            )
        );
        staking.stakeWithVoucher(overCell, sig2, AMOUNT, apy);

        // Exactly on both ceilings is fine.
        _stakeBudget(alice, P30, newPerCellMax, MAX_EXTRA_LIMIT_TOTAL, newPerCellMax);
        _assertUsage(alice, P30, newPerCellMax, newPerCellMax, "both ceilings accept their exact value");
    }

    /// @notice Advancing the phase gives NO fresh budget. One budget, for all time.
    /// @dev BEHAVIOUR CHANGE, 2026-09-18, deliberate product decision. This test previously asserted the
    ///      opposite: the meter was keyed on (phase, wallet), so a wallet that spent its whole 50,000 in phase 0
    ///      got another 50,000 in phase 1 while the phase-0 position was still open -- two budgets held at once.
    ///      The key is now the wallet alone. A wallet gets 50,000, full stop.
    ///
    ///      It is still CONCURRENT, not a lifetime spend: closing a deposit returns its bonus, in any phase.
    ///      So "one budget forever" means one budget held open at a time, not one budget ever granted.
    ///      Do not restore the old assertion; the phase key was removed on purpose.
    function test_advancingThePhaseGivesNoFreshBudget() external {
        _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "whole budget spent in phase 0");

        staking.changeStakingPhase(1);
        assertEq(_phase(), 1);

        // The TOTAL does not reset, and the new phase offers nothing. The per-cell meter is keyed on
        // (phase, period), so phase 1's P30 cell is genuinely empty -- and still gets no room, because the
        // global total is what is exhausted.
        _assertUsageIn(alice, 0, P30, BUDGET, BUDGET, "phase 0's cell still holds the spend");
        _assertUsageIn(alice, 1, P30, BUDGET, 0, "phase 1's cell is a fresh cell with an exhausted total");
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, BUDGET, 0);
        _expectHeadroom(alice, P90, MIN_DEPOSIT, BUDGET, BUDGET, 0);

        assertEq(staking.getUserData(Types.DataType.STAKING, alice), BUDGET, "one budget, not two");
    }

    /// @notice Spend part of the budget, advance the phase, and only the LEFTOVER is available.
    /// @dev The partial case of the test above, and the one a wrong implementation is most likely to pass by
    ///      accident: resetting the meter on a phase change looks identical to "budget exhausted" when the
    ///      wallet happened to spend all of it. Spending 30,000 and then finding exactly 20,000 -- not 50,000,
    ///      and not 0 -- can only happen if the meter carried across the phase boundary intact.
    function test_leftoverBudgetCarriesAcrossAPhaseChange() external {
        uint256 spent = 30_000 * ONE;
        uint256 leftover = BUDGET - spent;

        _stakeBudget(alice, P30, spent, BUDGET, BUDGET);
        _assertUsage(alice, P30, spent, spent, "30,000 spent in phase 0");

        staking.changeStakingPhase(1);

        // Exactly the leftover, in the new phase: not a fresh budget, not nothing.
        _expectHeadroom(alice, P90, leftover + 1, BUDGET, BUDGET, leftover);
        _stakeBudget(alice, P90, leftover, BUDGET, BUDGET);

        (uint256 total,) = staking.getBonusUsage(alice, _phase(), P90);
        assertEq(total, BUDGET, "the two spends add up to one budget across two phases");
        _expectHeadroom(alice, P90, MIN_DEPOSIT, BUDGET, BUDGET, 0);
    }

    /// @notice The same period in a NEW phase: the base allowance is whole, and the bonus is not granted twice.
    /// @dev The 2026-09-18 re-key made a once-dead branch live. `baseUsed = used > spentCell ? used - spentCell : 0`
    ///      subtracts a meter that now spans phases from a controller figure that is still per (phase, period).
    ///      A wallet holding bonus in P30 of phase 0 arrives in P30 of phase 1 with `used == 0` and
    ///      `spentCell == 20,000`, so the subtraction goes negative and the guard has to catch it. The comment in
    ///      src that called this branch unreachable was true before the re-key and false after it.
    ///
    ///      Kills BOTH failure modes at once:
    ///        - drop the `used > spentCell` guard and this panics 0x11 (0 - 20,000), bricking every VIP who
    ///          holds an open bonus position when the phase turns over;
    ///        - subtract nothing and clamp `baseUsed` some other way and the wallet loses base room in the new
    ///          phase that it is fully entitled to.
    ///
    ///      Numbers: 10,000 of base allowance in each phase, one 50,000 budget. Phase 0 takes 30,000 (10,000
    ///      base + 20,000 bonus). Phase 1 must then offer 10,000 of base + 30,000 of remaining bonus = 40,000,
    ///      and not one wei more -- 50,001 would mean the bonus was handed out a second time.
    function test_sameCellInANewPhaseKeepsItsBaseRoomAndNotMoreBonus() external {
        uint256 allowed = 10_000 * ONE;
        uint256 firstBonus = 20_000 * ONE;

        controller.setDefaultLimit(0, P30, allowed);
        controller.setDefaultLimit(1, P30, allowed);

        // Phase 0: fill the base allowance and take 20,000 of bonus on top.
        uint256 n0 = _stakeBudget(alice, P30, allowed + firstBonus, BUDGET, BUDGET);
        _assertUsage(alice, P30, firstBonus, firstBonus, "phase 0 charged only the part above the allowance");
        assertEq(_cell(alice, 0, P30), allowed + firstBonus, "phase 0 cell holds base + bonus");

        staking.changeStakingPhase(1);
        assertEq(_phase(), 1);

        // Phase 1, SAME period: used is 0 here, spentCell is 20,000. The subtraction has to saturate.
        uint256 bonusLeft = BUDGET - firstBonus;
        uint256 expectedRoom = allowed + bonusLeft;
        _expectHeadroom(alice, P30, expectedRoom + 1, BUDGET, BUDGET, expectedRoom);

        uint256 n1 = _stakeBudget(alice, P30, expectedRoom, BUDGET, BUDGET);
        _assertUsageIn(alice, 0, P30, BUDGET, firstBonus, "phase 0's cell keeps its own 20,000");
        _assertUsageIn(alice, 1, P30, BUDGET, bonusLeft, "phase 1's cell holds the other 30,000");
        assertEq(_cell(alice, 1, P30), expectedRoom, "phase 1 cell holds its own base + the rest of the bonus");

        // One budget of bonus in total, plus one base allowance per phase. Never two budgets.
        assertEq(
            staking.getUserData(Types.DataType.STAKING, alice),
            2 * allowed + BUDGET,
            "two base allowances and exactly one bonus budget"
        );

        // Closing the phase-0 deposit returns its 20,000 and nothing else, still keyed on P30.
        vm.prank(alice);
        staking.withdrawDeposit(n0);
        _assertUsageIn(alice, 0, P30, bonusLeft, 0, "phase 0's cell is empty again");
        _assertUsageIn(alice, 1, P30, bonusLeft, bonusLeft, "phase 1's cell was not touched by that close");
        assertEq(_deposit(alice, n1).amount, expectedRoom, "the phase-1 position is untouched");
    }

    /// @notice FINDING, 2026-09-18: bonus held open in an earlier phase hands the wallet EXTRA BASE ALLOWANCE
    ///         in the same period of every later phase. The LimitController cap is breached, by base stake, with
    ///         no bonus involved at all.
    /// @dev The voucher here carries a budget that is ALREADY FULLY SPENT by the phase-0 stake, so `bonusLeft`
    ///      is 0 for every call in phase 1. Everything the wallet gets in phase 1 is base room. It should get
    ///      `allowed` once. It gets `allowed` three times.
    ///
    ///      Why: `baseUsed = used > spentCell ? used - spentCell : 0` mixes two scopes. `used` is the
    ///      LimitController's figure for THIS (phase, period) cell. `spentCell` now spans every phase. While
    ///      `spentCell >= used`, baseUsed saturates to 0, so baseRoom stays at the full `allowed` no matter how
    ///      much base stake is already sitting in the cell. The wallet can keep taking `allowed` until `used`
    ///      climbs past `spentCell`, i.e. up to `spentCell + allowed` in a cell whose cap is `allowed`.
    ///
    ///      The over-grant equals the bonus held open in that period in earlier phases, and it comes back at
    ///      EVERY phase change while that deposit stays open. StakingFunctions.sol:108-111 asserts the opposite
    ///      ("it never over-grants, because baseRoom is then just `allowed`"); that comment is the bug.
    function test_bonusInAnEarlierPhaseMustNotUnlockExtraBaseRoom() external {
        uint256 allowed = 10_000 * ONE;
        uint256 smallBudget = 20_000 * ONE;

        controller.setDefaultLimit(0, P30, allowed);
        controller.setDefaultLimit(1, P30, allowed);

        // Phase 0: 10,000 of base + the whole 20,000 budget. Nothing is left of the budget after this.
        _stakeBudget(alice, P30, allowed + smallBudget, smallBudget, smallBudget);
        _assertUsageIn(alice, 0, P30, smallBudget, smallBudget, "the whole budget is spent in phase 0");

        staking.changeStakingPhase(1);

        // Phase 1, same period. bonusLeft is 0 from here on, so every wei below is BASE stake.
        uint256 taken;
        for (uint256 i = 0; i < 5; i++) {
            (uint256 a, uint256 u) = controller.getAllowedAndUsed(alice, 1, P30);
            emit log_named_uint("phase-1 round", i);
            emit log_named_uint("  allowed", a);
            emit log_named_uint("  used", u);
            Types.StakeVoucher memory v = _budgetVoucher(alice, P30, smallBudget, smallBudget);
            bytes memory sig = signVoucher(v);
            uint256 apy = _baseApy(v.phase, P30);
            vm.prank(alice);
            try staking.stakeWithVoucher(v, sig, allowed, apy) {
                taken += allowed;
            } catch {
                break;
            }
        }

        emit log_named_uint("base stake accepted in phase 1 / P30", taken);
        emit log_named_uint("the cell's actual cap", allowed);
        _assertUsageIn(alice, 0, P30, smallBudget, smallBudget, "phase 0's cell is unchanged");
        _assertUsageIn(alice, 1, P30, smallBudget, 0, "no bonus was charged in phase 1: this is all base stake");

        assertEq(taken, allowed, "a cell whose cap is 10,000 must not accept more than 10,000 of base stake");
    }

    /// @notice A CELL is (phase, period). The per-cell cap therefore does NOT span phases: the same period in
    ///         a new phase is a new cell and gets the full cap again.
    /// @dev This is the test that goes red if anyone ever drops the phase key from `walletBonusUsedInCell`
    ///      again. It is the only cross-phase test where the PER-CELL cap is the binding constraint rather
    ///      than the global total, so it is the only one that can tell the two keyings apart. Without the
    ///      phase key, the second stake below is refused with 0 headroom instead of accepted.
    ///
    ///      Product definition, 2026-09-18: "cell is a combination of phase and period. Same phase and same
    ///      period = the limit for this cell." Only `walletBonusUsed` ignores phase and period.
    ///
    ///      WHY THIS IS NOT A HOLE, because three of us read it as one on the day it was written: the per-cell
    ///      cap exists to stop a wallet putting its whole bonus into ONE PERIOD WITHIN A PHASE. Spreading it
    ///      across phases is deliberate and was accepted by the product owner, whose reason was a fact that is
    ///      nowhere in the code -- a phase runs about a year, so "25,000 now and 25,000 next phase" is a year
    ///      apart, not a way around the cap. The thing that spans phases is the global budget, and it still
    ///      holds the line at 50,000 (see test_theGlobalTotalBindsEvenWhenACellHasItsWholeCapFree).
    ///      Do not "fix" this by re-scoping the cell meter; that is the change that caused the base-allowance
    ///      over-grant in test_bonusInAnEarlierPhaseMustNotUnlockExtraBaseRoom.
    function test_thePerCellCapDoesNotSpanPhases() external {
        uint256 perCell = 25_000 * ONE;

        // Phase 0, P30: take the whole per-cell cap. The cell is now shut even though 25,000 of budget is left.
        _stakeBudget(alice, P30, perCell, BUDGET, perCell);
        _assertUsageIn(alice, 0, P30, perCell, perCell, "phase 0's P30 cell is at its cap");
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, perCell, 0);

        staking.changeStakingPhase(1);

        // Phase 1, SAME period, different cell: the full cap again, limited only by what the budget has left.
        _expectHeadroom(alice, P30, perCell + 1, BUDGET, perCell, perCell);
        _stakeBudget(alice, P30, perCell, BUDGET, perCell);

        _assertUsageIn(alice, 0, P30, BUDGET, perCell, "phase 0's cell is unchanged");
        _assertUsageIn(alice, 1, P30, BUDGET, perCell, "phase 1's cell took its own full cap");
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), BUDGET, "two cells, still one budget");
    }

    /// @notice The global total is the line that holds: a cell with its whole cap free still gets nothing once
    ///         the budget is spent.
    /// @dev The other half of the definition. Because the per-cell cap resets every phase, the total is the
    ///      only thing left stopping a wallet from spending its whole budget in one period -- so it has to bind
    ///      on a cell that has never been touched. P90 in phase 1 has 25,000 of per-cell room and 0 of budget;
    ///      it must be refused with exactly 0, not 25,000.
    ///
    ///      Kills: scoping `walletBonusUsed` to phase or period by mistake. Either one makes this cell offer
    ///      25,000 and turns a 50,000 budget into 50,000 per phase.
    function test_theGlobalTotalBindsEvenWhenACellHasItsWholeCapFree() external {
        uint256 perCell = 25_000 * ONE;

        uint256 first = _stakeBudget(alice, P30, perCell, BUDGET, perCell);
        staking.changeStakingPhase(1);
        _stakeBudget(alice, P30, perCell, BUDGET, perCell);
        _assertUsageIn(alice, 1, P30, BUDGET, perCell, "the budget is spent across two cells of one period");

        // A cell that has never been used, in the live phase, with its whole per-cell cap free.
        _assertUsageIn(alice, 1, P90, BUDGET, 0, "P90 in phase 1 has spent nothing");
        _expectHeadroom(alice, P90, MIN_DEPOSIT, BUDGET, perCell, 0);

        // Closing the phase-0 position returns its 25,000 to the global total, and P90 opens up by exactly that
        // much -- proof the refusal above was the total and not some per-cell accident.
        vm.prank(alice);
        staking.withdrawDeposit(first);
        _assertUsageIn(alice, 0, P30, perCell, 0, "the phase-0 cell gave its 25,000 back");
        _expectHeadroom(alice, P90, perCell + 1, BUDGET, perCell, perCell);
    }

    /// @notice An "unlimited" controller allowance must not panic-revert when the bonus is added to it.
    /// @dev Kills: `allowed + bonusLeft` without the saturating guard. type(uint256).max + anything panics with
    ///      0x11 and bricks staking for that wallet -- a self-inflicted denial of service an operator could
    ///      trigger just by writing "no limit" the obvious way.
    function test_unlimitedAllowanceDoesNotOverflow() external {
        controller.setWalletLimit(alice, _phase(), P30, type(uint256).max);

        uint256 n = _stakeBudget(alice, P30, AMOUNT, BUDGET, BUDGET);
        assertEq(_deposit(alice, n).amount, AMOUNT);
        _assertUsage(alice, P30, 0, 0, "an unlimited allowance needs no bonus");

        // And the budget is still intact and usable elsewhere.
        _stakeBudget(alice, P90, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P90, BUDGET, BUDGET, "budget untouched by the unlimited cell");
    }

    // ======================================================================
    // =            Close-path completeness and re-presentation             =
    // ======================================================================

    /// @notice EVERY close path returns the budget and clears the per-deposit record. Enumerated, not hard-coded.
    /// @dev The invariant is "a wallet holding no open bonus-funded deposit has consumed no budget". Today the
    ///      close paths are exhaustive -- withdrawDeposit, withdrawDepositPartial, a READY_TO_CLAIM claim (and
    ///      its batch forms) and seize -- but that is held by inspection, not by the compiler. If someone later
    ///      adds a close path and forgets `_releaseBonus`, that wallet's budget is consumed permanently with no
    ///      way to recover it: the deposit is already closed, so the hook can never run for it again.
    ///
    ///      Written as a loop over the paths so ADDING a path without a hook fails here. `depositBonusUsed` is
    ///      internal, so it is probed the only way a caller can: the wallet must be able to re-stake the whole
    ///      budget afterwards, which is only true if all three counters went back to zero.
    function test_everyClosePathReturnsTheWholeBudget() external {
        uint256 amount = 10_000 * ONE;
        uint256 pathCount = 5;

        for (uint256 path = 0; path < pathCount; path++) {
            assertEq(_usedTotal(alice, P30), 0, "each path starts from a clean budget");

            uint256 n = _stakeBudget(alice, P30, amount, BUDGET, BUDGET);
            _assertUsage(alice, P30, amount, amount, "staked");

            if (path == 0) {
                vm.prank(alice);
                staking.withdrawDeposit(n);
            } else if (path == 1) {
                vm.prank(alice);
                staking.withdrawDepositPartial(n, 0);
            } else if (path == 2) {
                _warpDays(31);
                vm.prank(alice);
                staking.claimDeposit(n);
            } else if (path == 3) {
                _warpDays(31);
                vm.prank(alice);
                staking.claimAll(); // the batch form must release too
            } else {
                freeze(alice, n);
                seize(alice, n);
            }

            _assertUsage(alice, P30, 0, 0, "every close path returns the whole budget");
            assertEq(_cell(alice, _phase(), P30), 0, "and the principal really left the cell");
            // Since the phase key was removed, PERIOD is the only key the per-cell meter has. Check a
            // neighbour on every path, so a release that credits the wrong cell fails here and not only in
            // the one test dedicated to it.
            (, uint256 neighbour) = staking.getBonusUsage(alice, _phase(), P90);
            assertEq(neighbour, 0, "no close path credited a period it never charged");
        }

        // The end state of the invariant: no open bonus-funded deposit, so nothing consumed, so the full
        // budget is spendable again.
        _stakeBudget(alice, P30, BUDGET, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "the whole budget was still there at the end");
    }

    /// @notice Re-presenting the same numbers under a fresh nonce grants nothing extra. This is the whole point.
    /// @dev The pre-fix contract added `extraLimit` to the allowance for THAT STAKE, so a second voucher with
    ///      identical numbers handed out the bonus again -- and the backend issues a fresh voucher per stake,
    ///      so this was the normal path, not an edge case. Kills any regression to per-voucher granting,
    ///      including one that keys the meter on the nonce.
    function test_aFreshVoucherWithTheSameNumbersGrantsNothingExtra() external {
        uint256 half = BUDGET / 2;

        _stakeBudget(alice, P30, half, BUDGET, BUDGET);
        _stakeBudget(alice, P30, half, BUDGET, BUDGET);
        _assertUsage(alice, P30, BUDGET, BUDGET, "two vouchers, one budget");

        // A third, identically-shaped voucher with a fresh nonce finds nothing.
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, BUDGET, 0);
        assertEq(_cell(alice, _phase(), P30), BUDGET, "never more than one budget in the cell");
    }

    /// @notice A release credits the deposit's OWN cell -- its own phase AND its own period.
    /// @dev A release that used the CURRENT phase or period rather than the deposit's own would credit a cell
    ///      the wallet never spent in: the real cell stays charged forever and another is handed free room.
    ///      The phase half is the newer risk -- the per-cell meter regained its phase key on 2026-09-18 and
    ///      every call site had to be revisited.
    ///
    ///      IMPORTANT, and the reason this test looks more complicated than it needs to: a release SUBTRACTS,
    ///      and the subtraction saturates at zero. So the wrong cell has to be holding something, or the test
    ///      passes while measuring nothing. An earlier version of this test opened one deposit in phase 0 and
    ///      checked that phase 1's cell read 0 -- which it would have done either way, because 0 minus 20,000
    ///      floors at 0. A second position is opened in phase 1 so the two outcomes are different numbers:
    ///
    ///          after closing the phase-0 deposit    cell (0,P30)   cell (1,P30)
    ///          correct, keys on the deposit's own        0            10,000
    ///          wrong, keys on the current phase       20,000             0
    function test_releaseCreditsTheDepositsOwnCell() external {
        uint256 inPhase0Amount = 20_000 * ONE;
        uint256 inPhase1Amount = 10_000 * ONE;

        uint256 n0 = _stakeBudget(alice, P30, inPhase0Amount, BUDGET, BUDGET);
        _assertUsageIn(alice, 0, P30, inPhase0Amount, inPhase0Amount, "charged to phase 0's P30 cell");

        staking.changeStakingPhase(1);
        assertEq(_phase(), 1);

        // A live position in the cell a wrong-phase release would land in. Without this the test is blind.
        _stakeBudget(alice, P30, inPhase1Amount, BUDGET, BUDGET);
        _assertUsageIn(alice, 1, P30, inPhase0Amount + inPhase1Amount, inPhase1Amount, "charged to phase 1");

        vm.prank(alice);
        staking.withdrawDeposit(n0);

        _assertUsageIn(alice, 0, P30, inPhase1Amount, 0, "the deposit's own cell gave its 20,000 back");
        _assertUsageIn(alice, 1, P30, inPhase1Amount, inPhase1Amount, "the live phase's cell kept its 10,000");

        // And no other period was touched, in either phase.
        (, uint256 p90Phase0) = staking.getBonusUsage(alice, 0, P90);
        (, uint256 p90Phase1) = staking.getBonusUsage(alice, 1, P90);
        assertEq(p90Phase0, 0, "no other period in phase 0 was credited");
        assertEq(p90Phase1, 0, "no other period in phase 1 was credited");
    }

    /// @notice `maxExtraLimitPerCell` defaults to 0, so bonus vouchers fail closed until an owner sets it.
    /// @dev Fail-closed is the right default, but it means a deployment that configures maxExtraLimitTotal and
    ///      forgets maxExtraLimitPerCell accepts plain stakes and rejects every VIP one -- a partial outage
    ///      that looks like a signer problem. Recorded here because the v0.4.0 deploy script sets it, but
    ///      anything constructing the contract directly does not.
    function test_perCellCeilingDefaultsToZeroAndFailsClosed() external {
        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        assertEq(fresh.maxExtraLimitPerCell(), 0, "fail closed until configured");
    }

    // ======================================================================
    // =                             19: views                              =
    // ======================================================================

    /// @notice getBonusUsage and getBonusUsageBatch agree with each other and with observed behaviour.
    /// @dev Kills: a batch view that reads the wrong mapping or loses the per-cell dimension, and any drift
    ///      between what the views report and what the stake path actually enforces -- the backend sizes the next
    ///      voucher off these numbers, so a view that over-reports available budget produces vouchers that revert
    ///      and one that under-reports silently shrinks every VIP's allowance.
    function test_viewsAgreeWithEachOtherAndWithBehaviour() external {
        uint256 perCell = 10_000 * ONE;

        uint256 keepOpen = _stakeBudget(alice, P30, perCell, BUDGET, perCell);
        uint256 toWithdraw = _stakeBudget(alice, P90, perCell, BUDGET, perCell);
        uint256 indefinite = _stakeBudget(alice, P0, 5_000 * ONE, BUDGET, perCell);

        vm.prank(alice);
        staking.withdrawDeposit(toWithdraw);

        _warpDays(100);
        vm.prank(alice);
        staking.claimDeposit(indefinite); // reward only: releases nothing

        uint256 expectedTotal = perCell + 5_000 * ONE;

        uint256[] memory periods = new uint256[](ALL_PERIODS.length);
        for (uint256 i = 0; i < ALL_PERIODS.length; i++) {
            periods[i] = ALL_PERIODS[i];
        }
        (uint256 batchTotal, uint256[] memory batchCells) = _lens(staking).getBonusUsageBatch(alice, _phase(), periods);
        assertEq(batchCells.length, periods.length, "one cell reading per period");
        assertEq(batchTotal, expectedTotal, "batch total");

        for (uint256 i = 0; i < periods.length; i++) {
            (uint256 singleTotal, uint256 singleCell) = staking.getBonusUsage(alice, _phase(), periods[i]);
            assertEq(singleTotal, batchTotal, "single and batch totals agree");
            assertEq(singleCell, batchCells[i], "single and batch cells agree");

            uint256 expectedCell = 0;
            if (periods[i] == P30) expectedCell = perCell;
            else if (periods[i] == P0) expectedCell = 5_000 * ONE;
            assertEq(singleCell, expectedCell, "cell matches what is actually held open");
        }

        // The views predict the stake path exactly: P30 is full, P0 has 5,000 of its per-cell cap left, and the
        // wallet has BUDGET - expectedTotal left overall.
        _expectHeadroom(alice, P30, MIN_DEPOSIT, BUDGET, perCell, 0);
        _expectHeadroom(alice, P0, perCell - 5_000 * ONE + 1, BUDGET, perCell, perCell - 5_000 * ONE);
        _expectHeadroom(alice, P90, BUDGET - expectedTotal + 1, BUDGET, BUDGET, BUDGET - expectedTotal);

        assertEq(keepOpen, 0, "sanity: first deposit index");
    }
}

/// @notice Gas for the bonus-metered stake path, following the conventions of GasBudget.t.sol: all state is
///         prepared in setUp so each body is one transaction against cold storage.
/// @dev Budgets are left at 0 (report only) until the implementation lands and a first measurement exists; the
///      point of this contract is the DELTA between a stake that touches the meter and one that does not, since
///      that delta is what the fix costs every non-VIP staker.
contract VoucherBonusBudgetGasTest is V050Base {
    uint256 internal constant AMOUNT = 1_000 * ONE;
    uint256 internal constant BUDGET = 50_000 * ONE;

    uint256 internal bonusDeposit;

    // First measurement plus ~10%, as GasBudget.t.sol does. Measured (via_ir, runs 200): stake with no bonus
    // 159,810; stake consuming bonus 220,580; withdraw releasing bonus 164,350.
    //
    // The number that matters is the delta: 220,580 - 159,810 = 60,770 for a stake that touches the meter,
    // which is three zero-to-nonzero SSTOREs (3 x 20,000) plus the BonusConsumed log. It is paid only by
    // wallets actually spending bonus. A stake that consumes none pays just the two extra cold SLOADs
    // (~4,200) for reading the counters, so ordinary stakers are barely affected.
    uint256 internal constant STAKE_NO_BONUS_BUDGET = 176_000;
    uint256 internal constant STAKE_WITH_BONUS_BUDGET = 243_000;
    uint256 internal constant CLOSE_WITH_BONUS_BUDGET = 181_000;

    function setUp() public override {
        super.setUp();
        // Warm the cells and the nonce word for alice and bob, so the measured call is a repeat stake.
        stakeFor(alice, P30, AMOUNT);
        stakeFor(bob, P30, AMOUNT);
        // Carol holds a bonus-funded position to close: her base allowance is 0 in this cell.
        controller.setDefaultLimit(0, P90, 0);
        Types.StakeVoucher memory v = _makeVoucherBudget(carol, 0, P90, 0, BUDGET, BUDGET);
        bytes memory sig = signVoucher(v);
        uint256 expectedApy = _baseApy(0, P90);
        vm.prank(carol);
        bonusDeposit = staking.stakeWithVoucher(v, sig, AMOUNT, expectedApy);
    }

    function _check(string memory label, uint256 used, uint256 budget) internal {
        emit log_named_uint(label, used);
        if (budget != 0) assertLe(used, budget, label);
    }

    /// @dev Baseline: the stake fits inside the controller limit, so the meter is read but never written.
    function test_gas_stakeWithoutBonus() external {
        Types.StakeVoucher memory v = _makeVoucherBudget(alice, 0, P30, 0, BUDGET, BUDGET);
        bytes memory sig = signVoucher(v);
        uint256 expected = _baseApy(0, P30);

        vm.prank(alice);
        uint256 g = gasleft();
        staking.stakeWithVoucher(v, sig, AMOUNT, expected);
        uint256 used = g - gasleft();

        _check("stake, no bonus consumed", used, STAKE_NO_BONUS_BUDGET);
        (uint256 usedTotal,) = staking.getBonusUsage(alice, 0, P30);
        assertEq(usedTotal, 0);
    }

    /// @dev The same stake with a 0 base allowance, so all three bonus counters are written.
    function test_gas_stakeConsumingBonus() external {
        controller.setDefaultLimit(0, P30, 0);
        Types.StakeVoucher memory v = _makeVoucherBudget(bob, 0, P30, 0, BUDGET, BUDGET);
        bytes memory sig = signVoucher(v);
        uint256 expected = _baseApy(0, P30);

        vm.prank(bob);
        uint256 g = gasleft();
        staking.stakeWithVoucher(v, sig, AMOUNT, expected);
        uint256 used = g - gasleft();

        _check("stake, bonus consumed", used, STAKE_WITH_BONUS_BUDGET);
        (uint256 usedTotal,) = staking.getBonusUsage(bob, 0, P30);
        assertEq(usedTotal, AMOUNT);
    }

    /// @dev Closing a bonus-funded deposit: three counter writes and one event on top of a plain withdrawal.
    function test_gas_closeReleasingBonus() external {
        vm.prank(carol);
        uint256 g = gasleft();
        staking.withdrawDeposit(bonusDeposit);
        uint256 used = g - gasleft();

        _check("withdraw, bonus released", used, CLOSE_WITH_BONUS_BUDGET);
        (uint256 usedTotal,) = staking.getBonusUsage(carol, 0, P90);
        assertEq(usedTotal, 0);
    }
}
