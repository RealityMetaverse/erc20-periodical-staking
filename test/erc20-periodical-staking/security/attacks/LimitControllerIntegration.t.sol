// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";
import {LimitController} from "../../../../src/contracts/LimitController.sol";

/// @title LimitControllerIntegration
/// @notice Wallet-limit semantics (especially the "0 means default" ambiguity), limit changes after deposits,
///         batch validation, and controllers pointed at the wrong staking contract.
contract LimitControllerIntegrationTest is AttackBase {
    LimitController internal lc;

    function setUp() public override {
        super.setUp();
        lc = new LimitController(address(staking));
        staking.setLimitController(address(lc));
        // default: 10k per wallet per cell
        for (uint256 ph = 0; ph < 2; ph++) {
            for (uint256 i = 0; i < PERIODS.length; i++) {
                lc.setDefaultLimit(ph, PERIODS[i], 10_000 * ONE);
            }
        }
    }

    /// @dev Hypothesis: a wallet explicitly limited to 0 ("0 means no staking allowed" per NatSpec) can still stake
    ///      because getAllowed falls back to the default when the wallet limit is 0.
    function test_walletLimitZero_blocksWallet() public {
        lc.setWalletLimit(alice, 0, P30, 0);
        assertEq(lc.getAllowed(alice, 0, P30), 0, "explicit 0 wallet limit must mean 0");
        uint256 h1 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 1_000 * ONE, 0));
        staking.safeStake(0, P30, 1_000 * ONE, h1);
    }

    /// @dev Hypothesis: with default 0 and no wallet limit, staking is blocked with exact figures.
    function test_defaultZero_noWalletLimit_blocked() public {
        lc.setDefaultLimit(0, P90, 0);
        uint256 h2 = _apy(0, P90);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P90, 1_000 * ONE, 0));
        staking.safeStake(0, P90, 1_000 * ONE, h2);
        lc.setWalletLimit(alice, 0, P90, 500 * ONE);
        uint256 h3 = _apy(0, P90);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P90, 1_000 * ONE, 500 * ONE)
        );
        staking.safeStake(0, P90, 1_000 * ONE, h3);
        _stake(alice, 0, P90, 500 * ONE);
    }

    /// @dev Hypothesis: lowering a limit below the staked amount underflows getRemaining or blocks closing.
    function test_limitLoweredBelowStaked_noUnderflow_closingWorks() public {
        uint256 d = _stake(alice, 0, P30, 8_000 * ONE);
        lc.setWalletLimit(alice, 0, P30, 5_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 0);
        (bool exceeds, uint256 rem) = staking.checkIfUserExceedsLimit(alice, 0, P30, 1);
        assertTrue(exceeds);
        assertEq(rem, 0);
        uint256 h4 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 100, 0));
        staking.safeStake(0, P30, 100, h4);
        _warpDays(30);
        _claim(alice, d);
        assertEq(lc.getRemaining(alice, 0, P30), 5_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: raising the limit after a deposit does not open new headroom.
    function test_limitRaised_afterDeposit_allowsExactlyMore() public {
        _stake(alice, 0, P30, 10_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 0);
        lc.setWalletLimit(alice, 0, P30, 12_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 2_000 * ONE);
        uint256 h5 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 2_000 * ONE + 1, 2_000 * ONE)
        );
        staking.safeStake(0, P30, 2_000 * ONE + 1, h5);
        _stake(alice, 0, P30, 2_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P30), 0);
    }

    /// @dev Hypothesis: batch length mismatches are silently accepted somewhere.
    function test_batchLengthMismatch_exactErrors() public {
        address[] memory w = new address[](2);
        uint256[] memory one = new uint256[](1);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.getRemainingBatch(w, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.getRemainingBatch(w, two, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.getAllowedBatch(w, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.setWalletLimits(w, 0, P30, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.setDefaultLimits(two, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        lc.setDefaultLimits(two, two, one);
        // staking side batch getter
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        staking.getUserPhasePeriodDataBatch(Types.DataType.STAKING, w, one, two);
    }

    /// @dev Hypothesis: a controller pointed at the wrong staking contract lets a wallet exceed its limit,
    ///      and re-pointing it must immediately account for what is already staked.
    function test_controllerPointingAtWrongStaking_fixRestoresEnforcement() public {
        ERC20PeriodicalStaking other = new ERC20PeriodicalStaking(address(token));
        lc.setStakingContract(address(other));
        _stake(alice, 0, P30, 10_000 * ONE);
        // misconfigured controller believes alice has nothing staked
        assertEq(lc.getRemaining(alice, 0, P30), 10_000 * ONE);
        lc.setStakingContract(address(staking));
        assertEq(lc.getRemaining(alice, 0, P30), 0, "after fix, existing stake must count");
        uint256 h6 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 100, 0));
        staking.safeStake(0, P30, 100, h6);
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        lc.setStakingContract(address(0));
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        new LimitController(address(0));
    }

    /// @dev Hypothesis: a limit on one (phase, period) leaks into another cell.
    function test_limitIsPerCell() public {
        lc.setWalletLimit(alice, 0, P30, 1);
        uint256 h7 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 1_000 * ONE, 1));
        staking.safeStake(0, P30, 1_000 * ONE, h7);
        _stake(alice, 0, P90, 1_000 * ONE);
        _stake(alice, 0, P0, 1_000 * ONE);
        staking.changeStakingPhase(1);
        _stake(alice, 1, P30, 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a generous wallet limit bypasses the period target (or vice versa). Both must be enforced.
    function test_limitAndTarget_bothEnforced() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, 5_000 * ONE);
        lc.setWalletLimit(alice, 0, P30, 100_000 * ONE);
        uint256 h8 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P30, 5_000 * ONE));
        staking.safeStake(0, P30, 6_000 * ONE, h8);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, TARGET);
        lc.setWalletLimit(alice, 0, P30, 5_000 * ONE);
        uint256 h9 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 6_000 * ONE, 5_000 * ONE)
        );
        staking.safeStake(0, P30, 6_000 * ONE, h9);
        _stake(alice, 0, P30, 5_000 * ONE);
    }

    /// @dev Documented semantics: the limit is on live stake, not lifetime; withdraw frees headroom.
    function test_limitIsLiveStake_withdrawFreesHeadroom() public {
        uint256 d = _stake(alice, 0, P0, 10_000 * ONE);
        assertEq(lc.getRemaining(alice, 0, P0), 0);
        _withdraw(alice, d);
        assertEq(lc.getRemaining(alice, 0, P0), 10_000 * ONE);
        _stake(alice, 0, P0, 10_000 * ONE);
        assertEq(_user(Types.DataType.STAKING, alice), 10_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: getPhasePeriodUserData disagrees with the controller's per-cell answers.
    function test_userDataView_matchesController() public {
        lc.setWalletLimit(alice, 0, P90, 3_000 * ONE);
        _stake(alice, 0, P90, 1_000 * ONE);
        _stake(alice, 0, P30, 4_000 * ONE);
        (uint256[][] memory limits, uint256[][] memory rem, bool[][] memory elig) = staking.getPhasePeriodUserData(alice);
        for (uint256 ph = 0; ph < 2; ph++) {
            for (uint256 i = 0; i < PERIODS.length; i++) {
                assertEq(limits[ph][i], lc.getAllowed(alice, ph, PERIODS[i]));
                assertEq(rem[ph][i], lc.getRemaining(alice, ph, PERIODS[i]));
                assertTrue(elig[ph][i]);
            }
        }
        assertEq(rem[0][2], 2_000 * ONE);
        assertEq(rem[0][1], 6_000 * ONE);
    }

    /// @dev Hypothesis: with the controller unset, the view falls back to target-based headroom.
    function test_controllerUnset_fallsBackToTarget() public {
        staking.setLimitController(address(0));
        _stake(alice, 0, P30, 1_000 * ONE);
        (uint256[][] memory limits, uint256[][] memory rem,) = staking.getPhasePeriodUserData(alice);
        assertEq(limits[0][1], type(uint256).max);
        assertEq(rem[0][1], TARGET - 1_000 * ONE);
        (, uint256 r) = staking.checkIfUserExceedsLimit(alice, 0, P30, 1);
        assertEq(r, TARGET - 1_000 * ONE);
    }

    /// @dev Fuzz: remaining never exceeds allowed and never underflows for any (limit, staked) pair.
    function testFuzz_remaining_neverExceedsAllowed(uint256 walletLimit, uint256 defaultLimit, uint256 stakeAmt)
        public
    {
        walletLimit = bound(walletLimit, 0, 50_000 * ONE);
        defaultLimit = bound(defaultLimit, 0, 50_000 * ONE);
        stakeAmt = bound(stakeAmt, 100, 50_000 * ONE);
        lc.setDefaultLimit(0, P0, defaultLimit);
        lc.setWalletLimit(alice, 0, P0, walletLimit);
        uint256 allowed = lc.getAllowed(alice, 0, P0);
        uint256 remaining = lc.getRemaining(alice, 0, P0);
        assertEq(remaining, allowed);
        uint256 apy = _apy(0, P0);
        vm.prank(alice);
        (bool ok,) = address(staking).call(abi.encodeCall(staking.safeStake, (0, P0, stakeAmt, apy)));
        assertEq(ok, stakeAmt <= remaining, "stake acceptance must match remaining");
        uint256 after_ = lc.getRemaining(alice, 0, P0);
        assertLe(after_, allowed);
        if (ok) assertEq(after_, allowed - stakeAmt);
    }

    /// @dev Hypothesis: the controller's owner (not the staking owner) is a separate trust root; the staking
    ///      owner cannot change limits, the controller owner cannot touch staking.
    function test_separateOwners_noCrossPrivilege() public {
        LimitController lc2 = new LimitController(address(staking));
        vm.prank(bob);
        vm.expectRevert();
        lc2.setDefaultLimit(0, P30, 1);
        // controller address has no staking privileges
        vm.prank(address(lc2));
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.setLimitController(address(0));
    }
}
