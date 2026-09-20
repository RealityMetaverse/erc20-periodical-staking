// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {V050Base} from "../../v050/V050Base.sol";
import {Types} from "../../../src/common/Types.sol";
import {ProgramManager} from "../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Errors} from "../../../src/common/Errors.sol";
import {AccessControl} from "../../../src/contracts/erc20-periodical-staking/AccessControl.sol";

/// @dev ERC-1271 signer that accepts EVERYTHING. If the staking contract still used SignatureChecker this
///      would let any garbage signature through.
contract AlwaysValid1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice Adversarial verification of the v0.5.0 audit fixes. Written by a reviewer who did not write them.
contract AdvVerify is V050Base, Errors {
    // secp256k1 order
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // ==================================================================
    // #39 signature handling
    // ==================================================================

    /// @dev Malleated (high-s) counterpart of a valid signature must NOT be accepted.
    function test_adv39_highSMalleabilityRejected() public {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes32 digest = _voucherDigest(address(staking), v);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(VOUCHER_SIGNER_KEY, digest);

        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlipped = vv == 27 ? 28 : 27;
        bytes memory malleated = abi.encodePacked(r, sHigh, vFlipped);

        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidVoucherSignature.selector));
        staking.stakeWithVoucher(v, malleated, 1e18, apy);
    }

    /// @dev Every malformed shape must surface as InvalidVoucherSignature, never an ECDSA library error.
    function test_adv39_malformedSignaturesRevertInvalidVoucherSignature() public {
        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);

        bytes[4] memory bad = [
            bytes(""),
            new bytes(64),
            new bytes(65), // all-zero 65 bytes -> v = 0
            new bytes(100)
        ];

        for (uint256 i = 0; i < bad.length; i++) {
            Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(InvalidVoucherSignature.selector));
            staking.stakeWithVoucher(v, bad[i], 1e18, apy);
        }
    }

    /// @dev A contract (ERC-1271) signer that accepts everything must still be rejected.
    function test_adv39_erc1271SignerGenuinelyRejected() public {
        AlwaysValid1271 c = new AlwaysValid1271();
        staking.setVoucherSigner(address(c));

        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v); // "valid" for the old EOA, and 1271 would accept anything anyway

        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidVoucherSignature.selector));
        staking.stakeWithVoucher(v, sig, 1e18, apy);
    }

    /// @dev Signer address(0) must be caught BEFORE recovery, so a failed recovery (address(0)) can never match.
    function test_adv39_zeroSignerCaughtBeforeRecovery() public {
        staking.setVoucherSigner(address(0));
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VoucherSignerNotSet.selector));
        staking.stakeWithVoucher(v, new bytes(65), 1e18, apy);
    }

    // ==================================================================
    // #8 voucher shape / epoch
    // ==================================================================

    /// @dev Recompute the EIP-712 type string from the struct definition and compare to the deployed constant.
    function test_adv8_typehashMatchesStructFieldOrder() public {
        bytes32 recomputed = keccak256(
            abi.encodePacked(
                "StakeVoucher(",
                "address wallet,",
                "uint256 phase,",
                "uint256 period,",
                "uint256 extraApyBps,",
                "uint256 extraLimitTotal,",
                "uint256 extraLimitPerCell,",
                "uint256 issuedAt,",
                "uint256 validUntil,",
                "uint256 epoch,",
                "uint256 nonce)"
            )
        );
        assertEq(recomputed, staking.VOUCHER_TYPEHASH(), "typehash != struct field order/types");
        assertEq(recomputed, VOUCHER_TYPEHASH, "helper typehash drifted");
    }

    /// @dev voucher.epoch is uint256, storage is uint64. 2**64 + current must NOT false-match.
    function test_adv8_epochAboveUint64MaxCannotWrap() public {
        staking.bumpVoucherEpoch();
        assertEq(staking.voucherEpoch(), 1);

        uint256 wrapped = uint256(type(uint64).max) + 2; // == 2**64 + 1, low 64 bits == 1
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        v.epoch = wrapped;
        bytes memory sig = signVoucher(v);

        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VoucherEpochMismatch.selector, wrapped, uint256(1)));
        staking.stakeWithVoucher(v, sig, 1e18, apy);
    }

    /// @dev validUntil < issuedAt must never be usable.
    function test_adv8_validUntilBeforeIssuedAtUnusable() public {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        v.issuedAt = _now();
        v.validUntil = _now() - 1;
        bytes memory sig = signVoucher(v);

        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);
        uint256 t = _now();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VoucherExpired.selector, v.validUntil, t));
        staking.stakeWithVoucher(v, sig, 1e18, apy);
    }

    /// @dev issuedAt + maxVoucherValidity cannot overflow: issuedAt is bounded by now.
    function test_adv8_hugeIssuedAtRejectedNotOverflowed() public {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        v.issuedAt = type(uint256).max;
        v.validUntil = type(uint256).max;
        bytes memory sig = signVoucher(v);

        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);
        uint256 t = _now();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VoucherNotYetValid.selector, type(uint256).max, t));
        staking.stakeWithVoucher(v, sig, 1e18, apy);
    }

    /// @dev The original #8 bug: a voucher signed today with validUntil years out must never become usable,
    ///      not now and not one second before it expires.
    function test_adv8_longDatedVoucherNeverBecomesUsable() public {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        v.issuedAt = _now();
        v.validUntil = _now() + 3650 days;
        bytes memory sig = signVoucher(v);
        uint256 apy = _baseApy(staking.currentStakingPhase(), P30);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(VoucherValidityTooLong.selector, v.validUntil, v.issuedAt + VOUCHER_LIFETIME)
        );
        staking.stakeWithVoucher(v, sig, 1e18, apy);

        // ... and still not just before it expires.
        vm.warp(v.validUntil - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(VoucherValidityTooLong.selector, v.validUntil, v.issuedAt + VOUCHER_LIFETIME)
        );
        staking.stakeWithVoucher(v, sig, 1e18, apy);
    }

    // ==================================================================
    // #9 / #10 privilege
    // ==================================================================

    /// @dev No admin-reachable path may re-open staking or clear FLAG_FROZEN.
    function test_adv910_adminCannotReopenStakingNorUnfreeze() public {
        vm.prank(admin);
        staking.closeStaking();
        assertFalse(staking.checkActionAvailability(Types.DataType.STAKING));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER));
        staking.changeActionAvailability(Types.DataType.STAKING, true);

        // owner re-opens, stake, freeze, then admin tries every unfreeze path
        staking.changeActionAvailability(Types.DataType.STAKING, true);
        uint256 d = stakeFor(alice, P30, 1e18);
        freeze(alice, d);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER));
        staking.unfreezeDeposit(alice, d);

        address[] memory ws = new address[](1);
        uint256[] memory ds = new uint256[](1);
        ws[0] = alice;
        ds[0] = d;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER));
        staking.unfreezeDeposits(ws, ds);

        assertTrue(staking.isDepositFrozen(alice, d));
    }

    // ==================================================================
    // #33/#37 empty batches
    // ==================================================================

    function test_adv37_everyBatchEntryPointRejectsEmptyInput() public {
        address[] memory ws = new address[](0);
        uint256[] memory ds = new uint256[](0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EmptyBatch.selector));
        staking.freezeDeposits(ws, ds);

        vm.expectRevert(abi.encodeWithSelector(EmptyBatch.selector));
        staking.unfreezeDeposits(ws, ds);

        vm.expectRevert(abi.encodeWithSelector(EmptyBatch.selector));
        staking.seizeDeposits(ws, ds);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EmptyBatch.selector));
        staking.setWalletsBlocked(ws, true);
    }

    // ==================================================================
    // #16 limit controller
    // ==================================================================

    function test_adv16_eoaControllerRevertsAndZeroStillAllowed() public {
        vm.expectRevert(); // extcodesize check: reverts without data
        staking.setLimitController(makeAddr("not-a-contract"));

        staking.setLimitController(address(0));
        assertEq(staking.limitController(), address(0));
    }

    // ==================================================================
    // #18 lagging cursor -- the risky one
    // ==================================================================

    /// @dev Force the cursor to lag behind the real frontier, then prove claimAll neither double-pays the
    ///      already-closed deposits it now rescans nor skips the open one behind them.
    function test_adv18_laggingCursorNoDoubleClaimNoSkip() public {
        uint256 n = 260; // > MAX_CURSOR_SCAN (256)
        for (uint256 i = 0; i < n + 1; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);

        // Close 0..259 in one call -> one cursor update, capped at 256.
        vm.prank(alice);
        staking.claimRange(0, n);

        uint256 cursor = staking.stakerActiveDepositStartIndex(alice);
        assertEq(cursor, 256, "cursor should have stopped at the MAX_CURSOR_SCAN cap");
        // Deposits 256..259 are closed but sit at/after the cursor: the cursor LAGS.
        for (uint256 i = 256; i < n; i++) {
            assertEq(
                uint256(_status(alice, i)), uint256(ProgramManager.DepositStatus.CLAIMED), "256..259 must be closed"
            );
        }

        // What the lens/read path reports with a lagging cursor must equal exactly deposit #260.
        ProgramManager.TokenDeposit memory last = _deposit(alice, n);
        (uint256 cs, uint256 cpr, uint256 cir) = staking.checkClaimableDataFor(alice);
        assertEq(cs, last.amount, "lagging cursor inflated claimable principal");
        assertEq(cpr, last.rewardGenerated, "lagging cursor inflated claimable reward");
        assertEq(cir, 0);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        uint256 paid = token.balanceOf(alice) - balBefore;

        assertEq(paid, last.amount + last.rewardGenerated, "double-claim or skip across the lagging cursor");
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.CLAIMED));
        // Cursor caught up in one further call (261 <= 256 + 256).
        assertEq(staking.stakerActiveDepositStartIndex(alice), n + 1, "cursor stuck");

        (cs, cpr, cir) = staking.checkClaimableDataFor(alice);
        assertEq(cs + cpr + cir, 0, "nothing should remain claimable");
    }

    /// @dev Same lagging cursor, but one survivor is withdrawn and another is frozen+seized.
    function test_adv18_laggingCursorWithdrawAndSeizeStayConsistent() public {
        uint256 n = 258;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        stakeFor(alice, P0, 1e18); // index n   -> INDEFINITE, withdrawable
        stakeFor(alice, P0, 1e18); // index n+1 -> INDEFINITE, seizable
        _warpDays(31);

        vm.prank(alice);
        staking.claimRange(0, n); // closes 0..257, cursor capped at 256
        assertEq(staking.stakerActiveDepositStartIndex(alice), 256, "cursor should lag");

        freeze(alice, n + 1);
        uint256 treasBefore = token.balanceOf(treasury);
        seize(alice, n + 1);
        assertEq(token.balanceOf(treasury) - treasBefore, 1e18, "seize principal wrong");
        assertEq(uint256(_status(alice, n + 1)), uint256(ProgramManager.DepositStatus.SEIZED));

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdrawDeposit(n);
        assertGe(token.balanceOf(alice) - balBefore, 1e18, "withdraw principal wrong");
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.WITHDRAWN));

        assertLe(staking.stakerActiveDepositStartIndex(alice), staking.checkDepositCountOfAddress(alice), "cursor past count");
        assertEq(_cell(alice, staking.currentStakingPhase(), P30), 0, "P30 STAKED cell not released");
        assertEq(_cell(alice, staking.currentStakingPhase(), P0), 0, "P0 STAKED cell not released");
        (uint256 cs, uint256 cpr, uint256 cir) = staking.checkClaimableDataFor(alice);
        assertEq(cs + cpr + cir, 0, "stale claimable after lagging-cursor close");
    }

    /// @dev With every deposit closed, nothing re-runs the scan (claimAll pays 0 -> no cursor update), so the
    ///      cursor stays behind and every later reader rescans the closed tail. FIXED (#18): the permissionless
    ///      advanceCursor pays it down without closing anything, and read gas drops.
    function test_adv18_stuckCursorIsRecoverableViaAdvanceCursor() public {
        uint256 n = 600;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);

        vm.prank(alice);
        staking.claimRange(0, n);
        assertEq(staking.stakerActiveDepositStartIndex(alice), 256, "first scan capped at 256");

        // Nothing left to claim -> claimAll transfers nothing -> the close paths never advance it again.
        vm.prank(alice);
        staking.claimAll();
        assertEq(staking.stakerActiveDepositStartIndex(alice), 256, "close paths cannot advance it any more");

        uint256 g0 = gasleft();
        (uint256 s0, uint256 p0, uint256 i0) = staking.checkClaimableDataFor(alice);
        uint256 usedStale = g0 - gasleft();
        assertGt(usedStale, 250_000, "the stale tail is rescanned before the fix-up");

        // Anyone -- here an unrelated third party -- can pay the cursor down. Nothing else changes.
        vm.prank(rando);
        uint256 newIndex = staking.advanceCursor(alice, 0); // 0 => MAX_CURSOR_ADVANCE (1024)
        assertEq(newIndex, n, "cursor must catch up to the closed frontier in one 1024-step call");
        assertEq(staking.stakerActiveDepositStartIndex(alice), n);

        // Reads are cheap again, and report exactly the same thing.
        uint256 g1 = gasleft();
        (uint256 s1, uint256 p1, uint256 i1) = staking.checkClaimableDataFor(alice);
        uint256 usedFresh = g1 - gasleft();
        assertLt(usedFresh, usedStale / 10, "read gas must collapse once the cursor is current");
        assertEq(s0 + p0 + i0, 0);
        assertEq(s1 + p1 + i1, 0);

        // Idempotent: a second call finds nothing to skip.
        assertEq(staking.advanceCursor(alice, 0), n);
    }

    /// @dev advanceCursor is bounded, respects its maxSteps, and can never move past an OPEN deposit --
    ///      it is maintenance only, so it must not touch balances, counters or deposit state.
    function test_adv18_advanceCursorIsBoundedAndStopsAtOpenDeposits() public {
        for (uint256 i = 0; i < 10; i++) {
            stakeFor(alice, P30, 1e18);
        }
        stakeFor(alice, P0, 1e18); // index 10 -> INDEFINITE, stays open forever
        for (uint256 i = 0; i < 5; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);

        vm.prank(alice);
        staking.claimRange(0, 10); // closes 0..9; cursor lands on 10 already

        // Force the cursor back to 0 is not possible, so re-verify from a fresh wallet instead: here just
        // check the bound and the open-deposit stop from where it is.
        assertEq(staking.stakerActiveDepositStartIndex(alice), 10, "cursor stopped at the open INDEFINITE one");
        assertEq(staking.advanceCursor(alice, 1024), 10, "must never step past an open deposit");

        uint256 stakedBefore = staking.getUserData(Types.DataType.STAKING, alice);
        uint256 balBefore = token.balanceOf(alice);
        staking.advanceCursor(alice, 5);
        assertEq(staking.getUserData(Types.DataType.STAKING, alice), stakedBefore, "must not move principal");
        assertEq(token.balanceOf(alice), balBefore, "must not pay anything out");
        assertEq(uint256(_status(alice, 10)), uint256(ProgramManager.DepositStatus.INDEFINITE), "state untouched");

        // A wallet with no deposits at all is a no-op, not a revert.
        assertEq(staking.advanceCursor(rando, 1), 0);
    }

    /// @dev maxSteps is honoured below the cap: a 64-step call moves the cursor by exactly 64.
    function test_adv18_advanceCursorHonoursMaxSteps() public {
        uint256 n = 400;
        for (uint256 i = 0; i < n; i++) {
            stakeFor(alice, P30, 1e18);
        }
        _warpDays(31);
        vm.prank(alice);
        staking.claimRange(0, n);
        assertEq(staking.stakerActiveDepositStartIndex(alice), 256);

        assertEq(staking.advanceCursor(alice, 64), 256 + 64, "exactly 64 steps");
        assertEq(staking.advanceCursor(alice, 1024), n, "then the rest, clamped at the frontier");
    }
}
