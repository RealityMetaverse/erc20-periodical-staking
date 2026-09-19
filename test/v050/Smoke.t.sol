// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";

/// @notice End-to-end smoke test of the v0.4.0 fixture: voucher stake, claim, freeze + seize.
contract SmokeTest is V050Base {
    function test_smoke_voucherStake() external {
        uint256 amount = 1_000 * ONE;
        Types.StakeVoucher memory v = voucherFor(alice, P30, 25, 0);
        bytes memory sig = signVoucher(v);
        assertEq(staking.getVoucherDigest(v), _voucherDigest(address(staking), v), "digest mismatch");

        vm.prank(alice);
        uint256 n = staking.stakeWithVoucher(v, sig, amount, APY_P30 + 25);

        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, APY_P30 + 25, "effective apy");
        assertEq(d.amount, amount);
        assertEq(d.rewardGenerated, staking.calculateReward(amount, APY_P30 + 25, P30), "reward");
        assertEq(_cell(alice, 0, P30), amount, "STAKING cell");
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce), "nonce used");

        // Replay is rejected.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, alice, v.nonce));
        staking.stakeWithVoucher(v, sig, amount, 0);

        // Legacy stake in the same phase/period counts as used.
        legacy.setStaked(alice, 0, P30, 5_000 * ONE);
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, 0, P30);
        assertEq(allowed, DEFAULT_LIMIT);
        assertEq(used, 6_000 * ONE);
    }

    function test_smoke_claim() external {
        uint256 amount = 2_000 * ONE;
        uint256 n = stakeFor(bob, P30, amount);
        uint256 reward = _deposit(bob, n).rewardGenerated;
        assertGt(reward, 0);

        _warpDays(P30);
        uint256 balBefore = token.balanceOf(bob);
        vm.prank(bob);
        staking.claimDeposit(n);

        assertEq(token.balanceOf(bob) - balBefore, amount + reward, "claim payout");
        assertEq(uint256(_status(bob, n)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(_cell(bob, 0, P30), 0);
    }

    function test_smoke_freezeAndSeize() external {
        uint256 amount = 3_000 * ONE;
        uint256 n = stakeFor(carol, P90, amount);
        uint256 reward = _deposit(carol, n).rewardGenerated;

        freeze(carol, n);
        assertTrue(staking.isDepositFrozen(carol, n));

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositFrozen.selector, carol, n));
        staking.withdrawDeposit(n);

        uint256 treasuryBefore = token.balanceOf(treasury);
        seize(carol, n);

        assertGt(reward, 0);
        assertEq(token.balanceOf(treasury) - treasuryBefore, amount, "treasury received principal only");
        assertEq(_deposit(carol, n).rewardGenerated, 0, "reservation released");
        assertEq(uint256(_status(carol, n)), uint256(ProgramManager.DepositStatus.SEIZED));
        assertEq(_cell(carol, 0, P90), 0, "STAKING cell freed");
        assertEq(staking.totalDataList(Types.DataType.STAKING), 0);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        assertEq(staking.rewardPool(), POOL, "pool untouched");
        assertEq(controller.getRemaining(carol, 0, P90), DEFAULT_LIMIT, "limit freed");
        assertEq(token.balanceOf(address(staking)), staking.rewardPool(), "conservation");
    }
}
