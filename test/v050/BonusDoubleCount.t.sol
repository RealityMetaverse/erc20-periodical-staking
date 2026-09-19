// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";

/// @notice Bonus-funded stake must not ALSO consume the wallet's normal limit.
///
///         `LimitController.getUsed` is the wallet's whole open stake in the cell, including the part already
///         charged to the bonus meter. The first metered implementation computed
///
///             baseRoom = allowed - used
///
///         so a bonus-funded deposit filled the bonus budget AND the base allowance for as long as it stayed open,
///         and because which-deposit-used-what is fixed at stake time, closing a base-funded deposit did not hand
///         the base room back either. Single-deposit wallets never noticed; a VIP with two deposits in a cell was
///         refused stake it was entitled to. The fix takes the metered part out first:
///
///             baseUsed = used - walletBonusUsedInCell[phase][period][wallet]  // saturating; same cell as `used`
///             baseRoom = allowed - baseUsed                                       // saturating
///
///         The product standard these tests are judged against: "50k total ... for any without any issues" -- a
///         VIP holding a 50,000 budget uses that 50,000 freely, in one deposit or several, gets it back when
///         deposits close, and never exceeds allowed + 50,000 in any one cell.
///
/// @dev Every headroom claim is proved both ways: `X + 1` is refused with exactly `X` reported, and then `X` is
///      staked. Never read `block.timestamp` after a warp: use `_now()` (via_ir hazard, see test/shared/Clock.sol).
contract BonusDoubleCountTest is V050Base {
    /// @dev == MAX_EXTRA_LIMIT_TOTAL, the 50,000 in the product brief.
    uint256 internal constant BUDGET = 50_000 * ONE;
    /// @dev The contract's minimumDeposit. A 1-wei probe would trip InsufficientDeposit, a different check.
    uint256 internal constant MIN_DEPOSIT = 100;

    function setUp() public override {
        super.setUp();
        // Enough for every sequence below, including the fuzz, without ever tripping an ERC20 balance revert
        // (which would masquerade as a limit refusal).
        token.transfer(alice, 800_000 * ONE);
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    function _phase() internal view returns (uint256) {
        return staking.currentStakingPhase();
    }

    function _setAllowed(uint256 allowed) internal {
        controller.setDefaultLimit(_phase(), P30, allowed);
    }

    /// @dev Stake `amount` in P30 under a fresh 50k/50k voucher.
    function _stake(uint256 amount) internal returns (uint256 depositNumber) {
        return stakeWith(alice, P30, amount, 0, BUDGET);
    }

    function _close(uint256 depositNumber) internal {
        vm.prank(alice);
        staking.withdrawDeposit(depositNumber);
    }

    /// @dev Refuse `headroom + 1` with exactly `headroom` reported.
    function _expectHeadroom(uint256 headroom) internal {
        uint256 probe = headroom + 1 < MIN_DEPOSIT ? MIN_DEPOSIT : headroom + 1;
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, BUDGET);
        bytes memory sig = signVoucher(v);
        uint256 expectedApy = _baseApy(v.phase, P30);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, v.phase, P30, probe, headroom)
        );
        staking.stakeWithVoucher(v, sig, probe, expectedApy);
    }

    /// @dev Prove the next stake may be exactly `headroom`: one more is refused, then `headroom` lands.
    function _assertNextStakeMayBe(uint256 headroom) internal returns (uint256 depositNumber) {
        _expectHeadroom(headroom);
        uint256 before = _cell(alice, _phase(), P30);
        depositNumber = _stake(headroom);
        assertEq(_cell(alice, _phase(), P30), before + headroom, "the full headroom landed");
    }

    function _bonus() internal view returns (uint256 usedTotal, uint256 usedInCell) {
        return staking.getBonusUsage(alice, _phase(), P30);
    }

    // ======================================================================
    // =                 The four cases from the product brief              =
    // ======================================================================

    /// @notice normal 100,000 / bonus 50,000: stake 100,000, stake 50,000, close the first -> next may be 100,000.
    /// @dev Under the double count the second deposit (all bonus) also filled the base allowance, so after the
    ///      first closed baseRoom stayed 0 and only 0 was offered: the VIP could not re-use base room it had
    ///      just freed.
    function test_case1_baseThenBonus_closeBase_baseRoomComesBack() external {
        _setAllowed(100_000 * ONE);

        uint256 first = _stake(100_000 * ONE);
        (uint256 t, uint256 c) = _bonus();
        assertEq(t, 0, "inside the allowance: no bonus metered");
        assertEq(c, 0, "inside the allowance: no bonus metered (cell)");

        _stake(50_000 * ONE);
        (t, c) = _bonus();
        assertEq(t, BUDGET, "the second stake is all bonus");
        assertEq(c, BUDGET, "the second stake is all bonus (cell)");
        _expectHeadroom(0);

        _close(first);
        (t, c) = _bonus();
        assertEq(t, BUDGET, "closing the base deposit refunds no bonus");
        assertEq(c, BUDGET, "closing the base deposit refunds no bonus (cell)");

        _assertNextStakeMayBe(100_000 * ONE);
    }

    /// @notice normal 10,000 / bonus 50,000: stake 10,000, stake 50,000, close the first -> next may be 10,000.
    function test_case2_smallBaseThenBonus_closeBase_smallBaseComesBack() external {
        _setAllowed(10_000 * ONE);

        uint256 first = _stake(10_000 * ONE);
        _stake(50_000 * ONE);
        (uint256 t, uint256 c) = _bonus();
        assertEq(t, BUDGET, "50k of bonus held open");
        assertEq(c, BUDGET, "50k of bonus held open (cell)");
        _expectHeadroom(0);

        _close(first);
        _assertNextStakeMayBe(10_000 * ONE);
    }

    /// @notice normal 10,000 / bonus 50,000: stake 50,000, stake 10,000, close the 50,000 -> next may be 50,000.
    /// @dev The first deposit is 10k base + 40k bonus; the second is 10k bonus (base is full). Closing the first
    ///      releases exactly its 40k of bonus and its 10k of base, so 50k is on offer again -- 10k base + 40k
    ///      bonus -- while the second deposit's 10k of bonus stays metered.
    function test_case3_mixedThenBonus_closeMixed_fiftyComesBack() external {
        _setAllowed(10_000 * ONE);

        uint256 first = _stake(50_000 * ONE);
        (uint256 t, uint256 c) = _bonus();
        assertEq(t, 40_000 * ONE, "50k stake over a 10k allowance meters 40k");
        assertEq(c, 40_000 * ONE, "50k stake over a 10k allowance meters 40k (cell)");

        _stake(10_000 * ONE);
        (t, c) = _bonus();
        assertEq(t, BUDGET, "the second stake is all bonus: budget exhausted");
        assertEq(c, BUDGET, "the second stake is all bonus: budget exhausted (cell)");
        _expectHeadroom(0);

        _close(first);
        (t, c) = _bonus();
        assertEq(t, 10_000 * ONE, "only the closed deposit's 40k is released");
        assertEq(c, 10_000 * ONE, "only the closed deposit's 40k is released (cell)");

        _assertNextStakeMayBe(50_000 * ONE);
        (t, c) = _bonus();
        assertEq(t, BUDGET, "the 50k re-stake is 10k base + 40k bonus");
        assertEq(c, BUDGET, "the 50k re-stake is 10k base + 40k bonus (cell)");
    }

    /// @notice normal 10,000 / bonus 50,000: stake 60,000, close it -> next may be 60,000.
    function test_case4_everythingInOne_closeIt_everythingComesBack() external {
        _setAllowed(10_000 * ONE);

        uint256 n = _assertNextStakeMayBe(60_000 * ONE);
        (uint256 t, uint256 c) = _bonus();
        assertEq(t, BUDGET, "60k over a 10k allowance meters the whole budget");
        assertEq(c, BUDGET, "60k over a 10k allowance meters the whole budget (cell)");

        _close(n);
        (t, c) = _bonus();
        assertEq(t, 0, "closing releases the whole budget");
        assertEq(c, 0, "closing releases the whole budget (cell)");

        _assertNextStakeMayBe(60_000 * ONE);
    }

    // ======================================================================
    // =                        The failure the fix removes                 =
    // ======================================================================

    /// @notice The exact under-grant: with a bonus deposit open, base room must still be on offer.
    /// @dev Under the double count this stake of 100k was refused with headroom 50k (the 50k bonus deposit had
    ///      eaten half of the 100k allowance). This is the regression test for the fix itself.
    function test_bonusDepositDoesNotEatTheBaseAllowance() external {
        _setAllowed(100_000 * ONE);

        // Base is empty; this voucher stake should spend none of the bonus. Force it onto the bonus by filling
        // base first, then closing base: the bonus deposit is now the only thing open.
        uint256 base = _stake(100_000 * ONE);
        _stake(50_000 * ONE);
        _close(base);

        (uint256 t,) = _bonus();
        assertEq(t, BUDGET, "sanity: 50k of bonus held open, nothing else");
        assertEq(_cell(alice, _phase(), P30), BUDGET, "sanity: 50k open in the cell");

        // The whole base allowance is available, not allowance - 50k.
        _assertNextStakeMayBe(100_000 * ONE);
        assertEq(_cell(alice, _phase(), P30), 150_000 * ONE, "allowed + budget fully in use");
    }

    /// @notice Legacy stake is base stake: it shrinks baseRoom and is never refunded from the meter, but it does
    ///         not touch the bonus and unwinding it frees base room again.
    function test_legacyStakeIsBaseStake_shrinksAndFreesBaseRoomOnly() external {
        _setAllowed(20_000 * ONE);
        legacy.setStaked(alice, _phase(), P30, 15_000 * ONE);

        // 5k of base left, plus the whole budget.
        _assertNextStakeMayBe(5_000 * ONE + BUDGET);
        (uint256 t,) = _bonus();
        assertEq(t, BUDGET, "only the part above the legacy-shrunk base room was metered");
        _expectHeadroom(0);

        // Legacy unwinds: 15k of base room comes back, no bonus is refunded.
        legacy.setStaked(alice, _phase(), P30, 0);
        (t,) = _bonus();
        assertEq(t, BUDGET, "legacy unwind refunds no bonus");
        _assertNextStakeMayBe(15_000 * ONE);
    }

    // ======================================================================
    // =                         The safety property                        =
    // ======================================================================

    /// @notice No order of stakes and closes lets the open stake exceed allowed + extraLimitTotal, and after
    ///         every step the headroom on offer is EXACTLY allowed + budget - open (no over-grant, no under-grant).
    /// @dev Random walk of up to 16 steps over one cell: each step either stakes a random amount (which may be
    ///      refused; a refusal must be a StakingLimitExceeded reporting exactly the expected headroom) or closes
    ///      a random open deposit. Checked after every step: open <= allowed + BUDGET, the meter is <= BUDGET, the
    ///      meter never exceeds what is open, and `headroom + 1` is refused with exactly `headroom`. In a single
    ///      cell with total == perCell the fixed formula collapses to headroom = allowed + BUDGET - open, which is
    ///      precisely "50k total, usable freely, never more".
    function testFuzz_noOrderOfStakesAndClosesOverOrUnderGrants(uint256 seed, uint8 stepsRaw) external {
        uint256 steps = bound(uint256(stepsRaw), 1, 16);
        uint256[3] memory allowedChoices = [uint256(0), 10_000 * ONE, 100_000 * ONE];
        uint256 allowed = allowedChoices[seed % 3];
        _setAllowed(allowed);
        uint256 ceiling = allowed + BUDGET;

        uint256[] memory open = new uint256[](0);

        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool doClose = open.length != 0 && (r & 1) == 1;

            if (doClose) {
                uint256 idx = (r >> 8) % open.length;
                _close(open[idx]);
                open[idx] = open[open.length - 1];
                assembly {
                    mstore(open, sub(mload(open), 1))
                }
            } else {
                // Whole tokens between 1 and ceiling + 10k, so refusals are exercised too.
                uint256 amount = (((r >> 8) % (ceiling / ONE + 10_000)) + 1) * ONE;
                uint256 headroomBefore = ceiling - _cell(alice, _phase(), P30);

                Types.StakeVoucher memory v = voucherFor(alice, P30, 0, BUDGET);
                bytes memory sig = signVoucher(v);
                uint256 expectedApy = _baseApy(v.phase, P30);
                vm.prank(alice);
                try staking.stakeWithVoucher(v, sig, amount, expectedApy) returns (uint256 n) {
                    assertLe(amount, headroomBefore, "a stake above the headroom was accepted");
                    uint256[] memory grown = new uint256[](open.length + 1);
                    for (uint256 k = 0; k < open.length; k++) {
                        grown[k] = open[k];
                    }
                    grown[open.length] = n;
                    open = grown;
                } catch (bytes memory err) {
                    assertGt(amount, headroomBefore, "a stake within the headroom was refused");
                    assertEq(
                        err,
                        abi.encodeWithSelector(
                            Errors.StakingLimitExceeded.selector, alice, _phase(), P30, amount, headroomBefore
                        ),
                        "refusal must report exactly the headroom"
                    );
                }
            }

            uint256 openNow = _cell(alice, _phase(), P30);
            (uint256 t, uint256 c) = _bonus();
            assertLe(openNow, ceiling, "open stake exceeds allowed + budget");
            assertLe(t, BUDGET, "meter exceeds the budget");
            assertEq(t, c, "single cell: total and cell meters agree");
            assertLe(c, openNow, "meter exceeds what is open");
            // Base stake open (open - bonus) never exceeds the allowance.
            assertLe(openNow - c, allowed, "base stake exceeds the allowance");
            // And nothing is withheld: exactly the rest is on offer.
            _expectHeadroom(ceiling - openNow);
        }
    }
}
