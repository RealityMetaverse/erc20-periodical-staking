// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice ERC-1271 smart-contract signer: accepts digests signed by its EOA key holder.
contract ContractSigner is IERC1271 {
    address public immutable keyHolder;

    constructor(address keyHolder_) {
        keyHolder = keyHolder_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == keyHolder) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @notice ERC-1271 signer that always answers with a wrong magic value.
contract RejectingContractSigner is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @notice Exhaustive tests of the stakeWithVoucher authorisation path.
contract VoucherTest is V050Base {
    uint256 internal constant AMOUNT = 1_000 * ONE;
    uint256 internal constant OTHER_KEY = 0xBAD;
    uint256 internal constant ROTATED_KEY = 0xC0FFEE;

    function setUp() public override {
        super.setUp();
        // Move away from timestamp 1 so "validUntil = now - 1" is meaningful.
        vm.warp(1_700_000_000);
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    /// @dev A validUntil that is "comfortably in the future" but still inside the contract's
    ///      `maxVoucherValidity` ceiling. Replaces the old `type(uint256).max`, which no real signer can
    ///      produce and which now reverts VoucherValidityTooLong. Read through Clock, not block.timestamp,
    ///      so it is correct after a warp.
    function _far() internal view returns (uint256) {
        return _now() + VOUCHER_LIFETIME;
    }

    /// @dev Single-extraLimit form: budget and per-cell allowance are the same value.
    function _v(address wallet, uint256 phase, uint256 period, uint256 extraApy, uint256 extraLimit, uint256 until, uint256 nonce)
        internal
        pure
        returns (Types.StakeVoucher memory)
    {
        return _vb(wallet, phase, period, extraApy, extraLimit, extraLimit, until, nonce);
    }

    function _vb(
        address wallet,
        uint256 phase,
        uint256 period,
        uint256 extraApy,
        uint256 extraLimitTotal,
        uint256 extraLimitPerCell,
        uint256 until,
        uint256 nonce
    ) internal pure returns (Types.StakeVoucher memory) {
        return Types.StakeVoucher({
            wallet: wallet,
            phase: phase,
            period: period,
            extraApyBps: extraApy,
            extraLimitTotal: extraLimitTotal,
            extraLimitPerCell: extraLimitPerCell,
            validUntil: until,
            nonce: nonce
        });
    }

    /// @notice EIP-712 digest written from scratch, as an off-chain signer (backend) would compute it.
    function _offchainDigest(uint256 chainId, address verifyingContract, Types.StakeVoucher memory v)
        internal
        pure
        returns (bytes32)
    {
        bytes32 typeHash = keccak256(
            bytes(
                "StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimitTotal,uint256 extraLimitPerCell,uint256 validUntil,uint256 nonce)"
            )
        );
        bytes32 domainTypeHash =
            keccak256(bytes("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                domainTypeHash,
                keccak256(bytes("ERC20PeriodicalStaking")),
                keccak256(bytes("1")),
                chainId,
                verifyingContract
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                bytes32(uint256(uint160(v.wallet))),
                v.phase,
                v.period,
                v.extraApyBps,
                v.extraLimitTotal,
                v.extraLimitPerCell,
                v.validUntil,
                v.nonce
            )
        );
        return keccak256(bytes.concat(hex"1901", domainSeparator, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v8, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v8);
    }

    function _stakeRaw(address wallet, Types.StakeVoucher memory v, bytes memory sig, uint256 amount, uint256 expected)
        internal
        returns (uint256)
    {
        vm.prank(wallet);
        return staking.stakeWithVoucher(v, sig, amount, expected);
    }

    function _expectStakeRevert(
        address wallet,
        Types.StakeVoucher memory v,
        bytes memory sig,
        uint256 amount,
        uint256 expected,
        bytes memory err
    ) internal {
        vm.prank(wallet);
        vm.expectRevert(err);
        staking.stakeWithVoucher(v, sig, amount, expected);
        assertFalse(staking.isVoucherNonceUsed(v.wallet, v.nonce), "failed stake must not consume the nonce");
    }

    // ======================================
    // =            Valid stake             =
    // ======================================
    function test_validStake_recordsDepositNonceAndEvent() external {
        Types.StakeVoucher memory v = voucherFor(alice, P90, 150, 5_000 * ONE);
        bytes memory sig = signVoucher(v);
        uint256 effective = APY_P90 + 150;
        uint256 balBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(staking));
        emit Stake(alice, 0, P90, effective, 150, AMOUNT, 0, v.nonce);
        uint256 n = _stakeRaw(alice, v, sig, AMOUNT, effective);

        assertEq(n, 0, "first deposit number");
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.stakingPhase, 0);
        assertEq(d.stakingPeriod, P90);
        assertEq(d.amount, AMOUNT);
        assertEq(d.APY, effective, "effective bps recorded");
        assertEq(d.stakingEndDate, d.stakingStartDate + P90 * 1 days);
        assertEq(d.rewardGenerated, staking.calculateReward(AMOUNT, effective, P90));
        assertEq(balBefore - token.balanceOf(alice), AMOUNT, "tokens pulled");
        assertEq(_cell(alice, 0, P90), AMOUNT);
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce));
        assertFalse(staking.isVoucherNonceUsed(alice, v.nonce + 1));
        assertFalse(staking.isVoucherNonceUsed(bob, v.nonce), "nonce space is per wallet");
    }

    function test_validStake_sameNonceDifferentWallets() external {
        Types.StakeVoucher memory va = _v(alice, 0, P30, 0, 0, _far(), 7);
        Types.StakeVoucher memory vb = _v(bob, 0, P30, 0, 0, _far(), 7);
        _stakeRaw(alice, va, signVoucher(va), AMOUNT, APY_P30);
        _stakeRaw(bob, vb, signVoucher(vb), AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, 7));
        assertTrue(staking.isVoucherNonceUsed(bob, 7));
    }

    function test_validStake_indefinitePeriod() external {
        uint256 n = stakeWith(alice, P0, AMOUNT, 42, 0);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, APY_P0 + 42);
        assertEq(d.stakingEndDate, 0);
        assertEq(uint256(_status(alice, n)), uint256(ProgramManager.DepositStatus.INDEFINITE));
    }

    // ======================================
    // =            Signatures              =
    // ======================================
    function test_wrongSigner_reverts() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = _signVoucher(address(staking), v, OTHER_KEY);
        _expectStakeRevert(alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector));
    }

    function testFuzz_wrongSigner_reverts(uint256 key) external {
        key = bound(key, 1, 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140);
        vm.assume(key != VOUCHER_SIGNER_KEY);
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = _signVoucher(address(staking), v, key);
        _expectStakeRevert(alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector));
    }

    function test_malformedSignatures_revertInvalid() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory good = signVoucher(v);
        bytes memory err = abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector);

        _expectStakeRevert(alice, v, "", AMOUNT, 0, err);
        _expectStakeRevert(alice, v, new bytes(65), AMOUNT, 0, err);

        bytes memory truncated = new bytes(64);
        for (uint256 i = 0; i < 64; i++) truncated[i] = good[i];
        _expectStakeRevert(alice, v, truncated, AMOUNT, 0, err);

        bytes memory flipped = bytes.concat(good);
        flipped[10] = bytes1(uint8(flipped[10]) ^ 0x01);
        _expectStakeRevert(alice, v, flipped, AMOUNT, 0, err);

        // The untouched signature still works afterwards.
        _stakeRaw(alice, v, good, AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce));
    }

    function test_erc1271ContractSigner_accepted() external {
        address keyHolder = vm.addr(ROTATED_KEY);
        ContractSigner wallet = new ContractSigner(keyHolder);
        staking.setVoucherSigner(address(wallet));

        Types.StakeVoucher memory v = voucherFor(alice, P30, 10, 0);
        bytes memory sig = _signVoucher(address(staking), v, ROTATED_KEY);
        uint256 n = _stakeRaw(alice, v, sig, AMOUNT, APY_P30 + 10);
        assertEq(_deposit(alice, n).APY, APY_P30 + 10);
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce));

        // A signature the contract wallet rejects (the original EOA signer's key) fails.
        Types.StakeVoucher memory v2 = voucherFor(alice, P30, 0, 0);
        _expectStakeRevert(
            alice,
            v2,
            signVoucher(v2),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );
    }

    function test_erc1271WrongMagic_reverts() external {
        staking.setVoucherSigner(address(new RejectingContractSigner()));
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        _expectStakeRevert(
            alice, v, signVoucher(v), AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );
    }

    function test_signerRotation_invalidatesOldVouchers() external {
        Types.StakeVoucher memory oldV = voucherFor(alice, P30, 0, 0);
        bytes memory oldSig = signVoucher(oldV);

        staking.setVoucherSigner(vm.addr(ROTATED_KEY));
        _expectStakeRevert(
            alice, oldV, oldSig, AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );

        Types.StakeVoucher memory newV = voucherFor(alice, P30, 0, 0);
        _stakeRaw(alice, newV, _signVoucher(address(staking), newV, ROTATED_KEY), AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, newV.nonce));

        // Rotating back revives the unused old voucher (the nonce was never consumed).
        staking.setVoucherSigner(_voucherSignerAddr());
        _stakeRaw(alice, oldV, oldSig, AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, oldV.nonce));
    }

    // ======================================
    // =        Wallet / expiry / nonce     =
    // ======================================
    function test_walletMismatch_reverts() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        _expectStakeRevert(
            bob, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.VoucherWalletMismatch.selector, alice, bob)
        );
        // Checked before the signature: even a garbage signature reports the mismatch.
        _expectStakeRevert(
            bob, v, "", AMOUNT, 0, abi.encodeWithSelector(Errors.VoucherWalletMismatch.selector, alice, bob)
        );
    }

    function testFuzz_walletMismatch_reverts(address caller) external {
        vm.assume(caller != alice);
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        _expectStakeRevert(
            caller,
            v,
            signVoucher(v),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.VoucherWalletMismatch.selector, alice, caller)
        );
    }

    function test_expiry_inclusiveBoundary() external {
        uint256 t = _now();
        Types.StakeVoucher memory expired = _v(alice, 0, P30, 0, 0, t - 1, 0);
        _expectStakeRevert(
            alice,
            expired,
            signVoucher(expired),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.VoucherExpired.selector, t - 1, t)
        );

        Types.StakeVoucher memory lastSecond = _v(alice, 0, P30, 0, 0, t, 1);
        _stakeRaw(alice, lastSecond, signVoucher(lastSecond), AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, 1));
    }

    function testFuzz_expiry_afterWarp(uint256 lifetime, uint256 lateBy) external {
        lifetime = bound(lifetime, 0, 365 days);
        lateBy = bound(lateBy, 1, 365 days);
        uint256 until = _now() + lifetime;
        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, until, 3);
        bytes memory sig = signVoucher(v);

        vm.warp(until + lateBy);
        uint256 t = _now();
        _expectStakeRevert(
            alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.VoucherExpired.selector, until, t)
        );
    }

    function test_replayedNonce_reverts() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        _stakeRaw(alice, v, sig, AMOUNT, APY_P30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, alice, v.nonce));
        staking.stakeWithVoucher(v, sig, AMOUNT, APY_P30);

        // A differently-shaped voucher with the same nonce is also rejected (nonce, not signature, is single-use).
        Types.StakeVoucher memory other = _v(alice, 0, P90, 5, 1, _far(), v.nonce);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, alice, v.nonce));
        staking.stakeWithVoucher(other, signVoucher(other), AMOUNT, 0);

        assertEq(staking.checkDepositCountOfAddress(alice), 1, "only one deposit");
    }

    function test_nonceBitmap_acrossWords() external {
        uint256[7] memory nonces = [uint256(0), 255, 256, 511, 512, 1 << 200, type(uint256).max];
        for (uint256 i = 0; i < nonces.length; i++) {
            Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), nonces[i]);
            _stakeRaw(alice, v, signVoucher(v), 100 * ONE, APY_P30);
        }
        for (uint256 i = 0; i < nonces.length; i++) {
            assertTrue(staking.isVoucherNonceUsed(alice, nonces[i]), "used nonce");
        }
        uint256[8] memory untouched = [uint256(1), 254, 257, 510, 513, (1 << 200) + 1, (1 << 200) - 1, type(uint256).max - 1];
        for (uint256 i = 0; i < untouched.length; i++) {
            assertFalse(staking.isVoucherNonceUsed(alice, untouched[i]), "neighbour nonce untouched");
        }
        // Word boundary replays are still rejected.
        Types.StakeVoucher memory replay = _v(alice, 0, P30, 0, 0, _far(), 256);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, alice, 256));
        staking.stakeWithVoucher(replay, signVoucher(replay), 100 * ONE, 0);
    }

    function testFuzz_nonceBitmap_onlyExactBit(uint256 nonce, uint256 probe) external {
        vm.assume(probe != nonce);
        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), nonce);
        _stakeRaw(alice, v, signVoucher(v), AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, nonce));
        assertFalse(staking.isVoucherNonceUsed(alice, probe));
        assertFalse(staking.isVoucherNonceUsed(bob, nonce));
    }

    // ======================================
    // =          Tampered fields           =
    // ======================================
    function testFuzz_tamperedField_reverts(uint8 field) external {
        field = uint8(bound(field, 0, 7));
        Types.StakeVoucher memory v = _v(alice, 0, P30, 100, 1_000 * ONE, _far(), 11);
        bytes memory sig = signVoucher(v);
        address caller = alice;

        if (field == 0) {
            v.wallet = bob; // bob submits alice's signature with his own address
            caller = bob;
        } else if (field == 1) {
            v.phase = 1;
        } else if (field == 2) {
            v.period = P90;
        } else if (field == 3) {
            v.extraApyBps = 101;
        } else if (field == 4) {
            v.extraLimitTotal = 1_000 * ONE + 1;
        } else if (field == 5) {
            v.extraLimitPerCell = 1_000 * ONE + 1;
        } else if (field == 6) {
            v.validUntil = _far() - 1;
        } else {
            v.nonce = 12;
        }

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector));
        staking.stakeWithVoucher(v, sig, AMOUNT, 0);
        assertEq(staking.checkDepositCountOfAddress(caller), 0);
    }

    /// @notice Explicit per-field coverage (the fuzz above may not hit all eight).
    function test_tamperedField_eachField() external {
        bytes memory err = abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector);
        Types.StakeVoucher memory base = _v(alice, 0, P30, 100, 1_000 * ONE, _far(), 11);
        bytes memory sig = signVoucher(base);

        Types.StakeVoucher memory t = base;
        t = _v(bob, 0, P30, 100, 1_000 * ONE, _far(), 11);
        _expectStakeRevert(bob, t, sig, AMOUNT, 0, err);
        t = _v(alice, 1, P30, 100, 1_000 * ONE, _far(), 11);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);
        t = _v(alice, 0, P90, 100, 1_000 * ONE, _far(), 11);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);
        t = _v(alice, 0, P30, 0, 1_000 * ONE, _far(), 11);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);
        t = _v(alice, 0, P30, 100, 50_000 * ONE, _far(), 11);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);
        t = _vb(alice, 0, P30, 100, 1_000 * ONE, 50_000 * ONE, _far(), 11);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);
        t = _v(alice, 0, P30, 100, 1_000 * ONE, _far() - 1, 11);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);
        t = _v(alice, 0, P30, 100, 1_000 * ONE, _far(), 0);
        _expectStakeRevert(alice, t, sig, AMOUNT, 0, err);

        _stakeRaw(alice, base, sig, AMOUNT, APY_P30 + 100);
        assertEq(staking.checkDepositCountOfAddress(alice), 1);
    }

    // ======================================
    // =      Voucher's phase and period    =
    // ======================================
    function test_voucherUsesItsPhaseAndPeriod() external {
        uint256 n = stakeWith(alice, P90, AMOUNT, 0, 0);
        assertEq(_deposit(alice, n).stakingPeriod, P90);
        assertEq(_cell(alice, 0, P90), AMOUNT);
        assertEq(_cell(alice, 0, P30), 0);
        assertEq(_cell(alice, 1, P90), 0);
    }

    function test_voucherForOtherPhase_revertsUntilPhaseSwitch() external {
        Types.StakeVoucher memory v = _v(alice, 1, P30, 0, 0, _far(), 0);
        bytes memory sig = signVoucher(v);
        _expectStakeRevert(
            alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.IncorrectStakingPhase.selector, 1, 0)
        );

        staking.changeStakingPhase(1);
        uint256 n = _stakeRaw(alice, v, sig, AMOUNT, APY_P30 + PHASE1_APY_BONUS);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.stakingPhase, 1);
        assertEq(d.APY, APY_P30 + PHASE1_APY_BONUS, "phase-1 base APY used");
        assertEq(_cell(alice, 1, P30), AMOUNT);

        // A phase-0 voucher is now stale.
        Types.StakeVoucher memory stale = _v(alice, 0, P30, 0, 0, _far(), 1);
        _expectStakeRevert(
            alice,
            stale,
            signVoucher(stale),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.IncorrectStakingPhase.selector, 0, 1)
        );
    }

    function testFuzz_voucherForNonCurrentPhase_reverts(uint256 phase) external {
        vm.assume(phase != 0);
        Types.StakeVoucher memory v = _v(alice, phase, P30, 0, 0, _far(), 0);
        _expectStakeRevert(
            alice,
            v,
            signVoucher(v),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.IncorrectStakingPhase.selector, phase, 0)
        );
    }

    function test_allPhasesPopped_revertsPhaseDoesNotExist() external {
        staking.popStakingPhase();
        staking.popStakingPhase();
        assertEq(staking.stakingPhaseCount(), 0);
        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), 0);
        _expectStakeRevert(
            alice, v, signVoucher(v), AMOUNT, 0, abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 0)
        );
    }

    function testFuzz_voucherForUnknownPeriod_reverts(uint256 period) external {
        vm.assume(period != P0 && period != P30 && period != P90);
        Types.StakeVoucher memory v = _v(alice, 0, period, 0, 0, _far(), 0);
        _expectStakeRevert(
            alice,
            v,
            signVoucher(v),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, period)
        );
    }

    /// @notice Regression for the APY-cell existence check: removing a period invalidates vouchers for it in every
    ///         phase, and re-adding it makes them valid again.
    function test_removedPeriod_revertsAndReAddRestores() external {
        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), 0);
        bytes memory sig = signVoucher(v);

        staking.removeStakingPeriod(P30);
        assertEq(_baseApy(0, P30), 0);
        assertEq(_baseApy(1, P30), 0);
        _expectStakeRevert(
            alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, P30)
        );

        uint256[] memory apys = new uint256[](2);
        apys[0] = 777;
        apys[1] = 888;
        staking.addStakingPeriod(P30, apys, _fill(2, TARGET));
        uint256 n = _stakeRaw(alice, v, sig, AMOUNT, 777);
        assertEq(_deposit(alice, n).APY, 777);
    }

    // ======================================
    // =       Missing configuration        =
    // ======================================
    function test_noSigner_reverts() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        staking.setVoucherSigner(address(0));
        _expectStakeRevert(alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.VoucherSignerNotSet.selector));

        // A signature "from" address(0) (invalid bytes) cannot sneak through either.
        _expectStakeRevert(alice, v, new bytes(65), AMOUNT, 0, abi.encodeWithSelector(Errors.VoucherSignerNotSet.selector));
    }

    function test_noController_reverts() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        staking.setLimitController(address(0));
        _expectStakeRevert(alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.LimitControllerNotSet.selector));
        assertEq(staking.totalDataList(Types.DataType.STAKING), 0);

        staking.setLimitController(address(controller));
        _stakeRaw(alice, v, sig, AMOUNT, APY_P30);
        assertEq(staking.totalDataList(Types.DataType.STAKING), AMOUNT);
    }

    function test_noSignerAndNoController_signerErrorFirst() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        staking.setVoucherSigner(address(0));
        staking.setLimitController(address(0));
        _expectStakeRevert(alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.VoucherSignerNotSet.selector));
    }

    function test_freshContract_stakeRevertsUntilConfigured() external {
        ERC20PeriodicalStaking fresh = new ERC20PeriodicalStaking(address(token));
        uint256[] memory one = new uint256[](1);
        one[0] = 1_000;
        fresh.addStakingPeriod(P30, new uint256[](0), new uint256[](0));
        fresh.pushStakingPhase(one, _fill(1, TARGET));

        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), 0);
        bytes memory sig = _signVoucher(address(fresh), v, VOUCHER_SIGNER_KEY);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.VoucherSignerNotSet.selector));
        fresh.stakeWithVoucher(v, sig, AMOUNT, 0);

        fresh.setVoucherSigner(_voucherSignerAddr());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LimitControllerNotSet.selector));
        fresh.stakeWithVoucher(v, sig, AMOUNT, 0);
    }

    function test_stakingClosed_revertsAndReopens() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);

        staking.changeActionAvailability(Types.DataType.STAKING, false);
        assertFalse(staking.checkActionAvailability(Types.DataType.STAKING));
        _expectStakeRevert(
            alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING)
        );
        // Closed staking is checked first, even with no signer configured.
        staking.setVoucherSigner(address(0));
        _expectStakeRevert(
            alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING)
        );
        staking.setVoucherSigner(_voucherSignerAddr());

        // Closing withdrawal/claim does not affect staking.
        staking.changeActionAvailability(Types.DataType.STAKING, true);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, false);
        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        _stakeRaw(alice, v, sig, AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, v.nonce));
    }

    // ======================================
    // =      Extras and voucher bounds     =
    // ======================================
    function test_extraApy_boundByMax() external {
        Types.StakeVoucher memory over = voucherFor(alice, P30, MAX_EXTRA_APY_BPS + 1, 0);
        _expectStakeRevert(
            alice,
            over,
            signVoucher(over),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.VoucherExtraApyTooHigh.selector, MAX_EXTRA_APY_BPS + 1, MAX_EXTRA_APY_BPS)
        );
        uint256 n = stakeWith(alice, P30, AMOUNT, MAX_EXTRA_APY_BPS, 0);
        assertEq(_deposit(alice, n).APY, APY_P30 + MAX_EXTRA_APY_BPS);
    }

    function test_extraLimit_boundByMaxAndAddsHeadroom() external {
        Types.StakeVoucher memory over = voucherFor(alice, P30, 0, MAX_EXTRA_LIMIT_TOTAL + 1);
        _expectStakeRevert(
            alice,
            over,
            signVoucher(over),
            AMOUNT,
            0,
            abi.encodeWithSelector(Errors.VoucherExtraLimitTotalTooHigh.selector, MAX_EXTRA_LIMIT_TOTAL + 1, MAX_EXTRA_LIMIT_TOTAL)
        );

        uint256 extra = 10_000 * ONE;
        Types.StakeVoucher memory tooMuch = voucherFor(alice, P30, 0, extra);
        _expectStakeRevert(
            alice,
            tooMuch,
            signVoucher(tooMuch),
            DEFAULT_LIMIT + extra + 1,
            0,
            abi.encodeWithSelector(
                Errors.StakingLimitExceeded.selector, alice, 0, P30, DEFAULT_LIMIT + extra + 1, DEFAULT_LIMIT + extra
            )
        );
        stakeWith(alice, P30, DEFAULT_LIMIT + extra, 0, extra);
        assertEq(_cell(alice, 0, P30), DEFAULT_LIMIT + extra);

        // The extra is per voucher: a new voucher without it has no headroom left.
        Types.StakeVoucher memory plain = voucherFor(alice, P30, 0, 0);
        _expectStakeRevert(
            alice,
            plain,
            signVoucher(plain),
            100,
            0,
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 100, 0)
        );
    }

    // ======================================
    // =       expectedApyBps (floor)       =
    // ======================================
    function testFuzz_expectedApyFloor(uint256 extraApy, uint256 expected) external {
        extraApy = bound(extraApy, 0, MAX_EXTRA_APY_BPS);
        uint256 effective = APY_P30 + extraApy;
        expected = bound(expected, 0, effective + 10_000);
        Types.StakeVoucher memory v = voucherFor(alice, P30, extraApy, 0);
        bytes memory sig = signVoucher(v);

        if (expected > effective) {
            _expectStakeRevert(
                alice,
                v,
                sig,
                AMOUNT,
                expected,
                abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, P30, effective, expected)
            );
        } else {
            uint256 n = _stakeRaw(alice, v, sig, AMOUNT, expected);
            assertEq(_deposit(alice, n).APY, effective, "effective APY, not expected, is recorded");
        }
    }

    function test_expectedApyFloor_boundaries() external {
        uint256 effective = APY_P30 + 25;
        Types.StakeVoucher memory v = voucherFor(alice, P30, 25, 0);
        bytes memory sig = signVoucher(v);
        _expectStakeRevert(
            alice,
            v,
            sig,
            AMOUNT,
            effective + 1,
            abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, P30, effective, effective + 1)
        );
        _stakeRaw(alice, v, sig, AMOUNT, effective); // equal passes

        Types.StakeVoucher memory v2 = voucherFor(alice, P30, 25, 0);
        _stakeRaw(alice, v2, signVoucher(v2), AMOUNT, 0); // lower passes
        assertEq(staking.checkDepositCountOfAddress(alice), 2);
    }

    /// @notice Front-running guard: the owner lowers the base APY between voucher issuance and inclusion.
    function test_expectedApyFloor_frontRunLowerReverts_higherPasses() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 50, 0);
        bytes memory sig = signVoucher(v);
        uint256 expected = APY_P30 + 50;

        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, APY_P30 - 1);
        _expectStakeRevert(
            alice,
            v,
            sig,
            AMOUNT,
            expected,
            abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, P30, expected - 1, expected)
        );

        staking.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, P30, APY_P30 + 300);
        uint256 n = _stakeRaw(alice, v, sig, AMOUNT, expected);
        ProgramManager.TokenDeposit memory d = _deposit(alice, n);
        assertEq(d.APY, APY_P30 + 350, "higher APY accepted and recorded");
        assertEq(d.rewardGenerated, staking.calculateReward(AMOUNT, APY_P30 + 350, P30));
    }

    // ======================================
    // =              EIP-712               =
    // ======================================
    function test_eip712_domainAndTypehash() external {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt,) =
            staking.eip712Domain();
        assertEq(fields, hex"0f", "name, version, chainId, verifyingContract");
        assertEq(name, "ERC20PeriodicalStaking");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(staking));
        assertEq(salt, bytes32(0));
        assertEq(
            staking.VOUCHER_TYPEHASH(),
            keccak256(
                "StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimitTotal,uint256 extraLimitPerCell,uint256 validUntil,uint256 nonce)"
            )
        );
    }

    function test_eip712_digestKnownVector() external {
        vm.chainId(137);
        ERC20PeriodicalStaking s = new ERC20PeriodicalStaking(address(token));
        Types.StakeVoucher memory v = _v(alice, 1, 90, 225, 5_000 * ONE, 1_800_000_000, 42);
        assertEq(s.getVoucherDigest(v), _offchainDigest(137, address(s), v), "polygon digest");
    }

    function testFuzz_eip712_digestMatchesOffchain(
        address wallet,
        uint256 phase,
        uint256 period,
        uint256 extraApy,
        uint256 extraLimit,
        uint256 until,
        uint256 nonce
    ) external {
        Types.StakeVoucher memory v = _v(wallet, phase, period, extraApy, extraLimit, until, nonce);
        bytes32 expected = _offchainDigest(block.chainid, address(staking), v);
        assertEq(staking.getVoucherDigest(v), expected, "contract digest");
        assertEq(_voucherDigest(address(staking), v), expected, "helper digest");
    }

    function test_eip712_offchainSignatureStakes() external {
        Types.StakeVoucher memory v = _v(alice, 0, P90, 1, 1, _far(), 999);
        bytes memory sig = _sign(VOUCHER_SIGNER_KEY, _offchainDigest(block.chainid, address(staking), v));
        uint256 n = _stakeRaw(alice, v, sig, AMOUNT, APY_P90 + 1);
        assertEq(_deposit(alice, n).APY, APY_P90 + 1);
    }

    function test_eip712_crossContractReplayRejected() external {
        address otherContract = makeAddr("otherStakingDeployment");
        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), 0);
        bytes memory sig = _sign(VOUCHER_SIGNER_KEY, _offchainDigest(block.chainid, otherContract, v));
        _expectStakeRevert(alice, v, sig, AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector));
    }

    function test_eip712_crossChainReplayRejected() external {
        uint256 originalChain = block.chainid;
        Types.StakeVoucher memory v = _v(alice, 0, P30, 0, 0, _far(), 0);
        bytes memory otherChainSig = _sign(VOUCHER_SIGNER_KEY, _offchainDigest(originalChain + 1, address(staking), v));
        _expectStakeRevert(
            alice, v, otherChainSig, AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );

        // After a fork to a new chain id, signatures for the old chain stop working.
        bytes memory thisChainSig = _sign(VOUCHER_SIGNER_KEY, _offchainDigest(originalChain, address(staking), v));
        vm.chainId(originalChain + 1);
        _expectStakeRevert(
            alice, v, thisChainSig, AMOUNT, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );
        vm.prank(alice);
        staking.stakeWithVoucher(v, otherChainSig, AMOUNT, APY_P30);
        assertTrue(staking.isVoucherNonceUsed(alice, 0));
    }
}
