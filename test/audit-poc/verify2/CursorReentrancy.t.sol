// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {VoucherAttackBase} from "../../erc20-periodical-staking/security/attacks/VoucherAttackBase.sol";
import {ReentrantERC20} from "../../shared/malicious/MaliciousTokens.sol";
import {ERC20PeriodicalStaking} from "../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Types} from "../../../src/common/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice `advanceCursor` is the only state-mutating entry point on the staking contract with NO
///         `nonReentrant` modifier and NO access control. This drives it re-entrantly from inside the staking
///         token's transfer hook, during a claim and during a withdrawal, and proves the outcome is identical
///         to the non-reentrant run.
contract CursorReentrancy is VoucherAttackBase {
    ReentrantERC20 internal rtoken;
    ERC20PeriodicalStaking internal rs;

    function setUp() public override {
        super.setUp();
        rtoken = new ReentrantERC20();
        rtoken.mint(address(this), 100_000_000 ether);
        rs = _deployConfigured(address(rtoken));
        for (uint256 i = 0; i < users.length; i++) {
            rtoken.mint(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            rtoken.approve(address(rs), type(uint256).max);
        }
    }

    function _stake(address u, uint256 period, uint256 amount) internal {
        uint256 phase = rs.currentStakingPhase();
        uint256 apy = rs.phasePeriodDataList(Types.PhasePeriodDataType.APY, phase, period);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(rs, u, phase, period, 0, 0);
        vm.prank(u);
        rs.stakeWithVoucher(v, sig, amount, apy);
    }

    /// @dev claimAll is nonReentrant, so re-entering claimAll is blocked -- but advanceCursor is NOT guarded.
    ///      Fire it from the _sendToken hook and check the payout and the final cursor are unchanged.
    function test_v2_reentrantAdvanceCursorDuringClaimAllIsHarmless() public {
        for (uint256 i = 0; i < 6; i++) {
            _stake(alice, 30, 10 ether);
        }
        _stake(alice, 90, 10 ether); // index 6: still open at day 31
        vm.warp(block.timestamp + 31 days);

        // Baseline: no hook.
        uint256 snap = vm.snapshot();
        uint256 b0 = rtoken.balanceOf(alice);
        vm.prank(alice);
        rs.claimAll();
        uint256 paidClean = rtoken.balanceOf(alice) - b0;
        uint256 cursorClean = rs.stakerActiveDepositStartIndex(alice);
        vm.revertTo(snap);

        // Same run, but the token re-enters advanceCursor(alice, 1) from inside _sendToken.
        rtoken.setHook(
            address(rs), abi.encodeWithSignature("advanceCursor(address,uint256)", alice, uint256(1)), true, false, false, 5
        );
        uint256 b1 = rtoken.balanceOf(alice);
        vm.prank(alice);
        rs.claimAll();
        uint256 paidDirty = rtoken.balanceOf(alice) - b1;

        assertTrue(rtoken.lastHookSuccess(), "the re-entrant advanceCursor must actually have executed");
        assertEq(paidDirty, paidClean, "re-entrant advanceCursor changed the payout");
        assertEq(rs.stakerActiveDepositStartIndex(alice), cursorClean, "re-entrant advanceCursor changed the cursor");
        assertEq(uint256(rs.checkDepositStatus(alice, 6)), uint256(ProgramManager.DepositStatus.TIME_LEFT));

        // The still-open deposit is claimable later and pays out.
        rtoken.clearHook();
        vm.warp(block.timestamp + 90 days);
        uint256 b2 = rtoken.balanceOf(alice);
        vm.prank(alice);
        rs.claimAll();
        assertGt(rtoken.balanceOf(alice) - b2, 10 ether, "the deposit open across the re-entrancy was lost");
    }

    /// @dev Same, on the withdrawal path (cursor update happens BEFORE _sendToken there too).
    function test_v2_reentrantAdvanceCursorDuringWithdrawIsHarmless() public {
        _stake(alice, 30, 10 ether);
        _stake(alice, 30, 10 ether);
        _stake(alice, 30, 10 ether);

        rtoken.setHook(
            address(rs), abi.encodeWithSignature("advanceCursor(address,uint256)", alice, uint256(1024)), true, false, false, 5
        );
        uint256 b = rtoken.balanceOf(alice);
        vm.prank(alice);
        rs.withdrawDeposit(0);
        assertTrue(rtoken.lastHookSuccess(), "hook did not run");
        assertEq(rtoken.balanceOf(alice) - b, 10 ether);
        assertEq(rs.stakerActiveDepositStartIndex(alice), 1, "cursor must stop at open deposit 1");
        assertEq(uint256(rs.checkDepositStatus(alice, 1)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
    }

    /// @dev Re-entering from the STAKE path (transferFrom hook), where the new deposit has not been pushed yet.
    function test_v2_reentrantAdvanceCursorDuringStakeIsHarmless() public {
        _stake(alice, 30, 10 ether);
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        rs.claimRange(0, 1);
        assertEq(rs.stakerActiveDepositStartIndex(alice), 1);

        rtoken.setHook(
            address(rs), abi.encodeWithSignature("advanceCursor(address,uint256)", alice, uint256(0)), false, true, true, 5
        );
        _stake(alice, 30, 10 ether);
        assertEq(rs.checkDepositCountOfAddress(alice), 2);
        assertEq(rs.stakerActiveDepositStartIndex(alice), 1, "cursor must not pass the freshly opened deposit");
        assertEq(uint256(rs.checkDepositStatus(alice, 1)), uint256(ProgramManager.DepositStatus.TIME_LEFT));
    }
}
