// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {V050Base} from "../../v050/V050Base.sol";
import {Types} from "../../../src/common/Types.sol";
import {Errors} from "../../../src/common/Errors.sol";
import {LimitController} from "../../../src/contracts/LimitController.sol";
import {ERC20PeriodicalStaking} from "../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {StakingLens} from "../../../src/contracts/erc20-periodical-staking/StakingLens.sol";

/// @notice Second adversarial batch: events, treasury, controller-mismatch durability, APY/period bounds.
contract AdvVerify2 is V050Base, Errors {
    // ---------------- #16 ----------------

    /// @dev FIXED (#16): the stakingContract() check is no longer a snapshot. LimitController.stakingContract
    ///      is immutable and the setter is gone, so an installed controller can never be repointed at another
    ///      staking contract behind the staking contract's back. The pairing holds for the controller's life.
    function test_adv16_mismatchCheckIsNowAPermanentInvariant() public {
        ERC20PeriodicalStaking other = new ERC20PeriodicalStaking(address(token));

        assertEq(staking.limitController(), address(controller));
        assertEq(address(controller.stakingContract()), address(staking));

        // The controller owner (this test) tries to repoint it. The function does not exist any more.
        (bool ok,) = address(controller).call(
            abi.encodeWithSignature("setStakingContract(address)", address(other))
        );
        assertFalse(ok, "setStakingContract must be gone from the ABI");

        // Still paired with this staking contract, and still enforcing against it.
        assertEq(address(controller.stakingContract()), address(staking), "pairing must be permanent");
        assertEq(staking.limitController(), address(controller));

        uint256 d = stakeFor(alice, P30, 1e18);
        assertEq(_deposit(alice, d).amount, 1e18);
        assertEq(controller.getUsed(alice, 0, P30), 1e18, "`used` must come from THIS staking contract");
    }

    /// @dev A second controller built for this staking contract is still installable (swapping controllers is
    ///      legitimate), but one built for anything else is rejected and can never be converted.
    function test_adv16_onlyAControllerBuiltForThisStakingIsAccepted() public {
        LimitController sibling = new LimitController(address(staking));
        staking.setLimitController(address(sibling));
        assertEq(staking.limitController(), address(sibling));

        ERC20PeriodicalStaking other = new ERC20PeriodicalStaking(address(token));
        LimitController foreign = new LimitController(address(other));
        vm.expectRevert(abi.encodeWithSelector(LimitControllerMismatch.selector, address(other)));
        staking.setLimitController(address(foreign));

        (bool ok,) = address(foreign).call(
            abi.encodeWithSignature("setStakingContract(address)", address(staking))
        );
        assertFalse(ok, "a foreign controller can never be converted into a matching one");
    }

    // ---------------- #34 ----------------

    function test_adv34_treasuryRejectsSelfAndZero() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidTreasury.selector));
        staking.setTreasury(address(staking));

        vm.expectRevert(abi.encodeWithSelector(ZeroAddressProvided.selector));
        staking.setTreasury(address(0));

        // The lens, another contract, and an EOA are all still accepted (no allow-listing).
        staking.setTreasury(address(_lens(staking)));
        assertEq(staking.treasury(), address(_lens(staking)));
    }

    // ---------------- #33 / #36 ----------------

    function test_adv33_constructorEmitsTransferOwnershipFromZero() public {
        vm.expectEmit(true, true, false, false);
        emit TransferOwnership(address(0), address(this));
        new ERC20PeriodicalStaking(address(token));
    }

    function test_adv36_popStakingPhaseEmitsChangeStakingPhase() public {
        staking.changeStakingPhase(1);
        assertEq(staking.currentStakingPhase(), 1);

        vm.expectEmit(false, false, false, true);
        emit RemoveStakingPhase(1);
        vm.expectEmit(false, false, false, true);
        emit ChangeStakingPhase(0);
        staking.popStakingPhase();

        assertEq(staking.currentStakingPhase(), 0);
        assertEq(staking.stakingPhaseCount(), 1);
    }

    /// @dev Popping a non-current phase must NOT emit ChangeStakingPhase.
    function test_adv36_popNonCurrentPhaseDoesNotEmitChange() public {
        assertEq(staking.currentStakingPhase(), 0);
        vm.recordLogs();
        staking.popStakingPhase(); // pops phase 1, current is 0
        assertEq(staking.currentStakingPhase(), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 changeTopic = keccak256("ChangeStakingPhase(uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != changeTopic, "ChangeStakingPhase emitted for a non-current pop");
        }
    }

    // ---------------- #19 ----------------

    /// @dev Every configuration entry point that carries an APY or a period must be bounded.
    function test_adv19_allApyAndPeriodEntryPointsBounded() public {
        uint256 tooBigApy = 1_000_001;
        uint256 tooBigPeriod = 36_501;

        // setPhasePeriodData(APY)
        vm.expectRevert(abi.encodeWithSelector(ValueTooHigh.selector, tooBigApy, uint256(1_000_000)));
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, tooBigApy);

        // setMaxExtraApyBps
        vm.expectRevert(abi.encodeWithSelector(ValueTooHigh.selector, tooBigApy, uint256(1_000_000)));
        staking.setMaxExtraApyBps(tooBigApy);

        // pushStakingPhase
        uint256[] memory apys = _fill(3, tooBigApy);
        uint256[] memory targets = _fill(3, TARGET);
        vm.expectRevert(abi.encodeWithSelector(ValueTooHigh.selector, tooBigApy, uint256(1_000_000)));
        staking.pushStakingPhase(apys, targets);

        // addStakingPeriod: period bound
        uint256[] memory a2 = _fill(2, uint256(500));
        uint256[] memory t2 = _fill(2, TARGET);
        vm.expectRevert(abi.encodeWithSelector(ValueTooHigh.selector, tooBigPeriod, uint256(36_500)));
        staking.addStakingPeriod(tooBigPeriod, a2, t2);

        // addStakingPeriod: APY bound
        uint256[] memory a3 = _fill(2, tooBigApy);
        vm.expectRevert(abi.encodeWithSelector(ValueTooHigh.selector, tooBigApy, uint256(1_000_000)));
        staking.addStakingPeriod(180, a3, t2);
    }

    /// @dev Max base + max extra must fit the deposit's uint32 apyBps and actually stake.
    function test_adv19_maxBaseAndMaxExtraApyStakeFits() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, 1_000_000);
        staking.setMaxExtraApyBps(1_000_000);
        // Pool cannot pay this, but stake time never checks the pool.
        uint256 d = stakeWith(alice, P30, 1e18, 1_000_000, 0);
        assertEq(_deposit(alice, d).APY, 2_000_000, "base + extra must survive the uint32 cast");
    }

    /// @dev The lens must saturate, never revert, on an "unlimited" target.
    function test_adv19_lensSaturatesNeverReverts() public {
        StakingLens lens = _lens(staking);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P30, type(uint256).max);
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P90, type(uint256).max);

        // At production APYs an "unlimited" target does NOT overflow, so the view returns a huge FINITE
        // number, not type(uint256).max. The NatSpec on getRewardRequiredForTargets now says exactly that:
        // never-reverting is the property; saturation to type(uint256).max only happens when a cell's own
        // reward computation overflows (apyBps * days > 3_650_000).
        uint256 finite = lens.getRewardRequiredForTargets();
        assertLt(finite, type(uint256).max, "NatSpec says this reads as type(uint256).max; it does not");
        assertGt(finite, 1e70);
        assertGt(lens.getRewardPoolShortfall(), 0);

        // Only a genuinely overflowing cell (apyBps * days > 3_650_000) trips the catch.
        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P90, 1_000_000);
        assertEq(lens.getRewardRequiredForTargets(), type(uint256).max, "catch-all saturation failed");
        assertGt(lens.getRewardPoolShortfall(), 0);
    }

    // ---------------- #9 ----------------

    function test_adv9_closeStakingEmitsAndIsIdempotentAndBypassesNothing() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateActionAvailability(Types.DataType.STAKING, false);
        vm.prank(admin);
        staking.closeStaking();

        // Withdraw and claim untouched.
        assertTrue(staking.checkActionAvailability(Types.DataType.WITHDRAWAL));
        assertTrue(staking.checkActionAvailability(Types.DataType.CLAIM));

        // Idempotent.
        vm.prank(admin);
        staking.closeStaking();
        assertFalse(staking.checkActionAvailability(Types.DataType.STAKING));

        // A non-admin cannot call it.
        vm.prank(rando);
        vm.expectRevert();
        staking.closeStaking();
    }
}
