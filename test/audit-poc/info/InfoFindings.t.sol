// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V050Base} from "../../v050/V050Base.sol";
import {TestToken} from "../../shared/TestToken.sol";
import {ERC20PeriodicalStaking} from "../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {Types} from "../../../src/common/Types.sol";
import {Errors} from "../../../src/common/Errors.sol";
import {ProgramManager} from "../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";

/// @notice Regression tests for informational findings #33, #34, #36, #37, #38. Each began as a PoC that passed
///         while demonstrating the finding; each now asserts the FIXED behaviour, or -- where the owner decided
///         to keep the behaviour and document it (#34, #36b, #37a, #38) -- pins what is documented.
contract InfoFindingsPoC is V050Base {
    /// Finding #34 (+ #33b): popStakingPhase on the CURRENT phase moves currentStakingPhase back, re-opening
    /// staking on the previous phase. Behaviour kept (documented with a NatSpec warning); FIXED #33b: it is no
    /// longer silent -- ChangeStakingPhase(previous) is emitted after RemoveStakingPhase.
    function test_fixed34_popCurrentPhase_emitsChangeStakingPhase() public {
        staking.changeStakingPhase(1);
        assertEq(staking.currentStakingPhase(), 1);

        vm.recordLogs();
        staking.popStakingPhase();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(staking.currentStakingPhase(), 0, "current phase rolled back");
        assertEq(logs.length, 2, "two logs");
        assertEq(logs[0].topics[0], keccak256("RemoveStakingPhase(uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(1)));
        assertEq(logs[1].topics[0], keccak256("ChangeStakingPhase(uint256)"));
        assertEq(logs[1].topics[1], bytes32(uint256(0)), "announces the phase that is current again");

        // Documented consequence: phase 0 accepts new stakes again.
        uint256 d = stakeFor(alice, P30, 1_000 * ONE);
        assertEq(_deposit(alice, d).stakingPhase, 0);
    }

    /// #33b, the other branch: popping a phase that is NOT current leaves currentStakingPhase alone and emits no
    /// ChangeStakingPhase. Same when the only phase is popped (current stays 0).
    function test_fixed33_popNonCurrentPhase_noChangeEvent() public {
        vm.recordLogs();
        staking.popStakingPhase(); // pops phase 1 while phase 0 is current
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("RemoveStakingPhase(uint256)"));
        assertEq(staking.currentStakingPhase(), 0);

        vm.recordLogs();
        staking.popStakingPhase(); // pops phase 0, the only one left
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(staking.currentStakingPhase(), 0);
    }

    /// Finding #36a: setTreasury(address(this)) was accepted, so seized principal never left the contract, stopped
    /// being reserved, and the owner could take it with rescueTokens. FIXED: rejected.
    function test_fixed36_treasurySelfRejected() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTreasury.selector));
        staking.setTreasury(address(staking));
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddressProvided.selector));
        staking.setTreasury(address(0));
        assertEq(staking.treasury(), treasury, "unchanged");

        // Seized principal leaves the contract and is never rescuable.
        uint256 amount = 10_000 * ONE;
        uint256 d = stakeFor(alice, P30, amount);
        freezeAndSeize(alice, d);
        assertEq(token.balanceOf(treasury), amount);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, amount, 0));
        staking.rescueTokens(address(token), amount);
    }

    /// Finding #36b: a treasury the token refuses to pay (blacklist) makes every seize revert. Behaviour kept and
    /// documented on setTreasury / seizeDeposit; this pins that it is recoverable and the deposit stays frozen.
    function test_fixed36_blacklistedTreasury_seizeRevertsUntilTreasuryChanged() public {
        uint256 d = stakeFor(alice, P30, 10_000 * ONE);
        freeze(alice, d);
        // forge-std 1.2.0 (vendored under OZ, finding #40) has no vm.mockCallRevert: call the cheatcode raw.
        (bool ok,) = address(vm).call(
            abi.encodeWithSignature(
                "mockCallRevert(address,bytes,bytes)",
                address(token),
                abi.encodeWithSelector(IERC20.transfer.selector, treasury, 10_000 * ONE),
                bytes("blacklisted")
            )
        );
        assertTrue(ok);
        vm.expectRevert();
        staking.seizeDeposit(alice, d);
        vm.clearMockedCalls();
        assertTrue(staking.isDepositFrozen(alice, d), "still frozen, nothing lost");

        // Recoverable: point treasury elsewhere and seize again.
        staking.setTreasury(carol);
        staking.seizeDeposit(alice, d);
    }

    /// Finding #37a: a seize raises the wallet's WITHDRAWAL counters although the treasury received the funds.
    /// Behaviour kept and documented (_seize / seizeDeposit NatSpec): indexers key on SeizeDeposit / SEIZED.
    function test_fixed37a_seizeBooksAsWithdrawal_distinguishableByEventAndStatus() public {
        uint256 amount = 10_000 * ONE;
        uint256 d = stakeFor(alice, P30, amount);
        uint256 aliceBal = token.balanceOf(alice);
        freeze(alice, d);
        vm.expectEmit(true, true, true, true, address(staking));
        emit SeizeDeposit(alice, d, treasury, amount);
        seize(alice, d);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.SEIZED));

        assertEq(staking.getUserData(Types.DataType.WITHDRAWAL, alice), amount, "user WITHDRAWAL counter rose");
        assertEq(staking.getTotalData(Types.DataType.WITHDRAWAL), amount, "total WITHDRAWAL counter rose");
        assertEq(token.balanceOf(alice), aliceBal, "alice received nothing");
        assertEq(token.balanceOf(treasury), amount);
    }

    /// Finding #37b: empty freeze / unfreeze / seize / block batches succeeded silently. FIXED: EmptyBatch.
    function test_fixed37b_emptyBatchesRevert() public {
        address[] memory w = new address[](0);
        uint256[] memory n = new uint256[](0);
        bytes memory err = abi.encodeWithSelector(Errors.EmptyBatch.selector);
        vm.startPrank(admin);
        vm.expectRevert(err);
        staking.freezeDeposits(w, n);
        vm.expectRevert(err);
        staking.setWalletsBlocked(w, true);
        vm.stopPrank();
        vm.expectRevert(err);
        staking.unfreezeDeposits(w, n);
        vm.expectRevert(err);
        staking.seizeDeposits(w, n);

        // A length mismatch is now reported as a mismatch whichever array is the short one: the length check
        // runs before the empty check, so `(0 wallets, 1 deposit)` names the real problem instead of "empty".
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 0, 1));
        staking.seizeDeposits(w, new uint256[](1));
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 1, 0));
        staking.seizeDeposits(new address[](1), n);
    }

    /// Finding #38: the misspelled setMiniumumDeposit selector is kept on purpose (v0.2.4 tooling / ABI
    /// compatibility, now said so in its NatSpec). FIXED #33a: the constructor emits
    /// TransferOwnership(address(0), deployer), with both addresses indexed.
    function test_fixed33_constructorEmitsTransferOwnership_fixed38_typoSelectorKept() public {
        vm.recordLogs();
        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "#33a: exactly the ownership event");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3, "from and to are indexed");
        assertEq(logs[0].topics[0], keccak256("TransferOwnership(address,address)"));
        assertEq(logs[0].topics[1], bytes32(0), "from = address(0)");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))), "to = deployer");
        assertEq(fresh.currentStakingPhase(), 0);
        assertEq(fresh.minimumDeposit(), 100);
        assertEq(fresh.contractOwner(), address(this));
        // typo'd selector is the live ABI
        assertEq(fresh.setMiniumumDeposit.selector, bytes4(keccak256("setMiniumumDeposit(uint256)")));
        (bool ok,) = address(fresh).call(abi.encodeWithSignature("setMinimumDeposit(uint256)", 1e18));
        assertFalse(ok, "correctly spelled setter does not exist");
    }
}
