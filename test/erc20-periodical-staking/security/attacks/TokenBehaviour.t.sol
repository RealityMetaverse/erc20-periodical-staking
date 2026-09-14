// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    FeeOnTransferToken,
    FalseReturningToken,
    ShortTransferToken,
    NoReturnToken,
    PlainToken
} from "../../../shared/malicious/MaliciousTokens.sol";

/// @title TokenBehaviour
/// @notice Non-standard tokens must be rejected, SafeERC20 must catch `false` returns (on stake, withdraw and
///         seize), allowance edges must be exact, and rescueTokens must never reach principal or the reward pool.
contract TokenBehaviourTest is VoucherAttackBase {
    /// @dev Deploys a bare staking contract on `t` with periods [0,30,90], one phase and voucher staking enabled;
    ///      no pool.
    function _bare(address t) internal returns (ERC20PeriodicalStaking s) {
        s = new ERC20PeriodicalStaking(t);
        _enableVoucherStaking(s);
        uint256[] memory empty = new uint256[](0);
        for (uint256 i = 0; i < PERIODS.length; i++) {
            s.addStakingPeriod(PERIODS[i], empty, empty);
        }
        s.pushStakingPhase(APY_PHASE0, _fill(PERIODS.length, TARGET));
    }

    /// @dev a fee-on-transfer token must be rejected on stake with the observed delta, and the voucher stays unused.
    function test_feeOnTransfer_stakeReverts() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100); // 1%
        ERC20PeriodicalStaking s = _bare(address(fee));
        fee.mint(alice, 10_000 * ONE);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(s, alice, 0, P0, 0, 0);
        vm.startPrank(alice);
        fee.approve(address(s), type(uint256).max);
        uint256 amt = 1_000 * ONE;
        vm.expectRevert(abi.encodeWithSelector(Errors.UnexpectedTokenAmount.selector, amt, amt - amt / 100));
        s.stakeWithVoucher(v, sig, amt, APY_PHASE0[0]);
        vm.stopPrank();
        assertEq(s.checkDepositCountOfAddress(alice), 0);
        assertEq(fee.balanceOf(address(s)), 0);
        assertFalse(s.isVoucherNonceUsed(alice, v.nonce));
    }

    /// @dev provideReward through a fee token is rejected as well (pool must equal real balance).
    function test_feeOnTransfer_provideRewardReverts() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(50);
        ERC20PeriodicalStaking s = _bare(address(fee));
        fee.mint(address(this), 10_000 * ONE);
        fee.approve(address(s), type(uint256).max);
        uint256 amt = 1_000 * ONE;
        vm.expectRevert(abi.encodeWithSelector(Errors.UnexpectedTokenAmount.selector, amt, amt - amt * 50 / 10_000));
        s.provideReward(amt);
        assertEq(s.rewardPool(), 0);
    }

    /// @dev a token that moves only half the amount but returns true is rejected.
    function test_shortTransfer_stakeReverts() public {
        ShortTransferToken st = new ShortTransferToken();
        ERC20PeriodicalStaking s = _bare(address(st));
        st.mint(alice, 10_000 * ONE);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(s, alice, 0, P0, 0, 0);
        vm.startPrank(alice);
        st.approve(address(s), type(uint256).max);
        uint256 amt = 1_000 * ONE;
        vm.expectRevert(abi.encodeWithSelector(Errors.UnexpectedTokenAmount.selector, amt, amt / 2));
        s.stakeWithVoucher(v, sig, amt, APY_PHASE0[0]);
        vm.stopPrank();
        assertEq(st.balanceOf(address(s)), 0, "no tokens must be stuck after a failed stake");
    }

    /// @dev Hypothesis: a token returning false on transferFrom lets a stake through without moving tokens.
    function test_falseReturn_transferFrom_stakeReverts() public {
        FalseReturningToken ft = new FalseReturningToken();
        ERC20PeriodicalStaking s = _bare(address(ft));
        ft.mint(alice, 10_000 * ONE);
        ft.setFail(false, true);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(s, alice, 0, P0, 0, 0);
        vm.startPrank(alice);
        ft.approve(address(s), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SAFE_ERC20_FAILED_SELECTOR, address(ft)));
        s.stakeWithVoucher(v, sig, 1_000 * ONE, APY_PHASE0[0]);
        vm.stopPrank();
        assertEq(s.checkDepositCountOfAddress(alice), 0);
    }

    /// @dev Hypothesis: a token returning false on transfer lets a withdraw close the deposit without paying.
    function test_falseReturn_transfer_withdrawRevertsAtomically() public {
        FalseReturningToken ft = new FalseReturningToken();
        ERC20PeriodicalStaking s = _bare(address(ft));
        ft.mint(alice, 10_000 * ONE);
        vm.prank(alice);
        ft.approve(address(s), type(uint256).max);
        _stakeV(s, alice, 0, P0, 1_000 * ONE);
        ft.setFail(true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SAFE_ERC20_FAILED_SELECTOR, address(ft)));
        s.withdrawDeposit(0);
        assertEq(uint256(s.checkDepositStatus(alice, 0)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        assertEq(s.totalDataList(Types.DataType.STAKING), 1_000 * ONE);
        ft.setFail(false, false);
        vm.prank(alice);
        s.withdrawDeposit(0);
        assertEq(ft.balanceOf(alice), 10_000 * ONE);
    }

    /// @dev Hypothesis: a token returning false on the treasury payout lets seize close the deposit without
    ///      moving the principal (it would vanish from accounting while staying in the contract).
    function test_falseReturn_transfer_seizeRevertsAtomically() public {
        FalseReturningToken ft = new FalseReturningToken();
        ERC20PeriodicalStaking s = _bare(address(ft));
        ft.mint(alice, 10_000 * ONE);
        vm.prank(alice);
        ft.approve(address(s), type(uint256).max);
        _stakeV(s, alice, 0, P0, 1_000 * ONE);
        s.freezeDeposit(alice, 0);

        ft.setFail(true, false);
        vm.expectRevert(abi.encodeWithSelector(SAFE_ERC20_FAILED_SELECTOR, address(ft)));
        s.seizeDeposit(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(SAFE_ERC20_FAILED_SELECTOR, address(ft)));
        s.seizeDeposits(_one(alice), _oneU(0));
        assertTrue(s.isDepositFrozen(alice, 0), "still frozen, not seized");
        assertEq(uint256(s.checkDepositStatus(alice, 0)), uint256(ProgramManager.DepositStatus.INDEFINITE));
        assertEq(s.totalDataList(Types.DataType.STAKING), 1_000 * ONE);
        assertEq(s.getUserPhasePeriodData(Types.DataType.STAKING, alice, 0, P0), 1_000 * ONE, "limit cell untouched");

        ft.setFail(false, false);
        s.seizeDeposit(alice, 0);
        assertEq(ft.balanceOf(treasury), 1_000 * ONE);
        assertEq(ft.balanceOf(address(s)), s.totalDataList(Types.DataType.STAKING) + s.rewardPool());
    }

    /// @dev Hypothesis: a USDT-style token without return values is rejected by SafeERC20.
    function test_noReturnToken_works() public {
        NoReturnToken nrt = new NoReturnToken();
        ERC20PeriodicalStaking s = _bare(address(nrt));
        nrt.mint(alice, 10_000 * ONE);
        nrt.mint(address(this), POOL);
        nrt.approve(address(s), POOL);
        s.provideReward(POOL);
        vm.prank(alice);
        nrt.approve(address(s), type(uint256).max);
        _stakeV(s, alice, 0, P30, 1_000 * ONE);
        _warpDays(30);
        vm.prank(alice);
        s.claimDeposit(0);
        assertEq(nrt.balanceOf(alice), 10_000 * ONE + s.calculateReward(1_000 * ONE, APY_PHASE0[1], P30));
        assertEq(nrt.balanceOf(address(s)), s.totalDataList(Types.DataType.STAKING) + s.rewardPool());
    }

    /// @dev Hypothesis: a zero-amount stake creates an empty deposit (index bloat) or bypasses the minimum.
    function test_zeroAmountStake_rejected() public {
        uint256 minDeposit = staking.minimumDeposit();
        _expectStakeRevert(
            alice, 0, P0, 0, _apy(0, P0), abi.encodeWithSelector(Errors.InsufficientDeposit.selector, 0, minDeposit)
        );
        _expectStakeRevert(alice, 0, P0, 99, _apy(0, P0), abi.encodeWithSelector(Errors.InsufficientDeposit.selector, 99, 100));
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
    }

    /// @dev Hypothesis: allowance exactly equal to the amount is rejected / amount-1 accepted (off-by-one).
    ///      The failed attempt must not burn the voucher: the same voucher succeeds once allowance is fixed.
    function test_allowanceBoundary_exact() public {
        uint256 amt = 1_000 * ONE;
        uint256 apy = _apy(0, P0);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P0, 0, 0);
        vm.startPrank(alice);
        token.approve(address(staking), amt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(staking), amt - 1, amt)
        );
        staking.stakeWithVoucher(v, sig, amt, apy);
        token.approve(address(staking), amt);
        staking.stakeWithVoucher(v, sig, amt, apy);
        vm.stopPrank();
        assertEq(token.allowance(alice, address(staking)), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: insufficient balance with enough allowance leaves a half-written deposit.
    function test_insufficientBalance_atomic() public {
        uint256 amt = USER_FUNDS + 1;
        _expectStakeRevert(
            alice,
            0,
            P0,
            amt,
            _apy(0, P0),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, USER_FUNDS, amt)
        );
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
        assertEq(_total(Types.DataType.STAKING), 0);
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // rescueTokens
    // ---------------------------------------------------------------------

    /// @dev the owner cannot rescue a single wei of principal or reward pool.
    function test_rescueTokens_cannotTouchPrincipalOrPool() public {
        _stake(alice, 0, P0, 10_000 * ONE);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 1, 0));
        staking.rescueTokens(address(token), 1);
        // draining the pool first does not help
        staking.collectReward(staking.getCollectableReward());
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 1, 0));
        staking.rescueTokens(address(token), 1);
        assertEq(token.balanceOf(address(staking)), 10_000 * ONE);
    }

    /// @dev Hypothesis: seizing books the principal out without sending it, leaving a rescuable "excess".
    function test_rescueTokens_afterSeize_noExcessCreated() public {
        _stake(alice, 0, P30, 10_000 * ONE);
        _stake(bob, 0, P0, 5_000 * ONE);
        _freeze(alice, 0);
        _seize(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 1, 0));
        staking.rescueTokens(address(token), 1);
        assertEq(token.balanceOf(address(staking)), _total(Types.DataType.STAKING) + staking.rewardPool());
    }

    /// @dev only the donated excess of STAKING_TOKEN is rescuable, exactly.
    function test_rescueTokens_excessOnly_exact() public {
        _stake(alice, 0, P30, 10_000 * ONE);
        token.transfer(address(staking), 777); // accidental donation
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 778, 777));
        staking.rescueTokens(address(token), 778);
        uint256 before = token.balanceOf(owner);
        staking.rescueTokens(address(token), 777);
        assertEq(token.balanceOf(owner) - before, 777);
        assertEq(staking.rewardPool(), POOL, "rescue must not touch rewardPool accounting");
        _assertAccounting();
        _warpDays(30);
        _claim(alice, 0);
        _assertAccounting();
    }

    /// @dev foreign tokens can be rescued in full; zero address / zero amount rejected.
    function test_rescueTokens_foreignToken_full_andGuards() public {
        PlainToken p = new PlainToken();
        p.mint(address(staking), 5_000 * ONE);
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        staking.rescueTokens(address(0), 1);
        vm.expectRevert(Errors.ZeroAmountProvided.selector);
        staking.rescueTokens(address(p), 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 5_000 * ONE + 1, 5_000 * ONE));
        staking.rescueTokens(address(p), 5_000 * ONE + 1);
        staking.rescueTokens(address(p), 5_000 * ONE);
        assertEq(p.balanceOf(owner), 5_000 * ONE);
        assertEq(p.balanceOf(address(staking)), 0);
    }

    /// @dev Hypothesis: a direct donation inflates rewardPool or changes what users are paid.
    function test_directDonation_doesNotInflateRewardPool() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 reward = _deposit(alice, d).rewardGenerated;
        uint256 pool = staking.rewardPool();
        token.transfer(address(staking), 1_000 * ONE);
        assertEq(staking.rewardPool(), pool);
        assertEq(staking.getCollectableReward(), pool - reward);
        _warpDays(30);
        uint256 before = token.balanceOf(alice);
        _claim(alice, d);
        assertEq(token.balanceOf(alice) - before, 1_000 * ONE + reward);
        assertEq(token.balanceOf(address(staking)), staking.rewardPool() + 1_000 * ONE);
    }

    /// @dev Hypothesis: rescueTokens is callable by admins or users.
    function test_rescueTokens_onlyOwner() public {
        token.transfer(address(staking), 100);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.rescueTokens(address(token), 100);
        vm.prank(alice);
        vm.expectRevert(_unauthorized(AccessControl.AccessTier.OWNER));
        staking.rescueTokens(address(token), 100);
    }
}
