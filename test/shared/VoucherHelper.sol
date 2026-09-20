// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {StakingLens} from "../../src/contracts/erc20-periodical-staking/StakingLens.sol";
import {Types} from "../../src/common/Types.sol";
import {Clock} from "./Clock.sol";
import {OpenLimitController} from "./mocks/OpenLimitController.sol";

/// @notice Builds, signs and submits EIP-712 stake vouchers for v0.4.0 tests.
/// @dev The digest is computed locally (independent of the contract's getVoucherDigest), so a domain or
///      typehash mismatch in src shows up as InvalidVoucherSignature.
abstract contract VoucherHelper is Test {
    uint256 internal constant VOUCHER_SIGNER_KEY = 0xB0B5;
    bytes32 internal constant VOUCHER_TYPEHASH = keccak256(
        "StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimitTotal,uint256 extraLimitPerCell,uint256 issuedAt,uint256 validUntil,uint256 epoch,uint256 nonce)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Lifetime every helper-built voucher gets, in seconds. Deliberately inside the contract's 1800s
    ///      constructor default for `maxVoucherValidity`, so every fixture works without calling the setter,
    ///      AND deliberately equal to the backend's own default `validity_seconds` (600) so the suite signs
    ///      vouchers shaped like the ones production actually issues. The old value here was
    ///      `type(uint256).max`, which no real signer can produce -- those tests were passing on input that
    ///      could never reach the contract. A test that needs a longer-dated voucher raises the ceiling itself
    ///      with `setMaxVoucherValidity`, in its own body, so the dependency is visible where it matters.
    uint256 internal constant VOUCHER_LIFETIME = 600;

    /// @dev This repo's forge-std predates vm.getBlockTimestamp(), so the live time comes from Clock.
    Clock internal _voucherClock = new Clock();

    mapping(address => uint256) internal _nextVoucherNonce;
    /// @dev Epoch every helper-built voucher is signed for. 0 matches a fresh contract; a test that calls
    ///      bumpVoucherEpoch sets this to the new value itself, so the dependency is visible in its body.
    uint256 internal _voucherEpoch;
    mapping(address => StakingLens) private _lensOf;
    address internal treasury = makeAddr("treasury");

    /// @dev The bundled read views (getDepositsInRangeBy, getProgramDataWithUserData, ...) live in StakingLens
    ///      since v0.5.0. One lens per staking contract, deployed on first use. A test that checks a revert
    ///      calls `_lens(s);` BEFORE vm.expectRevert, so the deployment is not the call being checked.
    function _lens(ERC20PeriodicalStaking s) internal returns (StakingLens l) {
        l = _lensOf[address(s)];
        if (address(l) == address(0)) {
            l = new StakingLens(s);
            _lensOf[address(s)] = l;
        }
    }

    function _voucherSignerAddr() internal pure returns (address) {
        return vm.addr(VOUCHER_SIGNER_KEY);
    }

    function _voucherDigest(address staking, Types.StakeVoucher memory v) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256("ERC20PeriodicalStaking"), keccak256("1"), block.chainid, staking
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                VOUCHER_TYPEHASH,
                v.wallet,
                v.phase,
                v.period,
                v.extraApyBps,
                v.extraLimitTotal,
                v.extraLimitPerCell,
                v.issuedAt,
                v.validUntil,
                v.epoch,
                v.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signVoucher(address staking, Types.StakeVoucher memory v, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v8, bytes32 r, bytes32 s) = vm.sign(key, _voucherDigest(staking, v));
        return abi.encodePacked(r, s, v8);
    }

    /// @dev issuedAt is the live time and validUntil = issuedAt + VOUCHER_LIFETIME. The time is read through
    ///      Clock rather than `block.timestamp`: with via_ir the Yul optimizer may CSE two timestamp reads in one test body, so a voucher built after a warp would carry the
    ///      pre-warp time. The external call is an optimization barrier. The nonce is fresh per wallet.
    ///      Single-`extraLimit` form: the wallet's total budget and the per-cell allowance are both that value,
    ///      which is the v0.3.0-shaped grant ("this much bonus, usable anywhere"). Use _makeVoucherBudget to split.
    function _makeVoucher(address wallet, uint256 phase, uint256 period, uint256 extraApyBps, uint256 extraLimit)
        internal
        returns (Types.StakeVoucher memory)
    {
        return _makeVoucherBudget(wallet, phase, period, extraApyBps, extraLimit, extraLimit);
    }

    /// @dev Full form: `extraLimitTotal` is the wallet's bonus budget for the phase, `extraLimitPerCell` the most
    ///      of it usable in any single (phase, period) cell.
    function _makeVoucherBudget(
        address wallet,
        uint256 phase,
        uint256 period,
        uint256 extraApyBps,
        uint256 extraLimitTotal,
        uint256 extraLimitPerCell
    ) internal returns (Types.StakeVoucher memory) {
        uint256 issuedAt = _voucherClock.now();
        return Types.StakeVoucher({
            wallet: wallet,
            phase: phase,
            period: period,
            extraApyBps: extraApyBps,
            extraLimitTotal: extraLimitTotal,
            extraLimitPerCell: extraLimitPerCell,
            issuedAt: issuedAt,
            validUntil: issuedAt + VOUCHER_LIFETIME,
            epoch: _voucherEpoch,
            nonce: _nextVoucherNonce[wallet]++
        });
    }

    /// @dev For revert tests: prepare, then vm.prank + vm.expectRevert + stakeWithVoucher.
    function _prepareVoucherStake(
        ERC20PeriodicalStaking s,
        address wallet,
        uint256 phase,
        uint256 period,
        uint256 extraApyBps,
        uint256 extraLimit
    ) internal returns (Types.StakeVoucher memory v, bytes memory sig) {
        v = _makeVoucher(wallet, phase, period, extraApyBps, extraLimit);
        sig = _signVoucher(address(s), v, VOUCHER_SIGNER_KEY);
    }

    /// @dev No prank inside: the caller must already be the owner. Installs a permissive controller.
    function _enableVoucherStaking(ERC20PeriodicalStaking s) internal returns (OpenLimitController c) {
        c = new OpenLimitController(address(s));
        s.setVoucherSigner(_voucherSignerAddr());
        s.setMaxExtraApyBps(10_000);
        s.setMaxExtraLimitTotal(type(uint128).max);
        s.setMaxExtraLimitPerCell(type(uint128).max);
        s.setMaxVoucherValidity(VOUCHER_LIFETIME);
        s.setTreasury(treasury);
        s.setLimitController(address(c));
    }

    function _stakeV(ERC20PeriodicalStaking s, address wallet, uint256 phase, uint256 period, uint256 amount)
        internal
        returns (uint256 depositNumber)
    {
        return _stakeVWith(s, wallet, phase, period, amount, 0, 0);
    }

    function _stakeVWith(
        ERC20PeriodicalStaking s,
        address wallet,
        uint256 phase,
        uint256 period,
        uint256 amount,
        uint256 extraApyBps,
        uint256 extraLimit
    ) internal returns (uint256 depositNumber) {
        uint256 expected = s.phasePeriodDataList(Types.PhasePeriodDataType.APY, phase, period) + extraApyBps;
        (Types.StakeVoucher memory v, bytes memory sig) =
            _prepareVoucherStake(s, wallet, phase, period, extraApyBps, extraLimit);
        vm.prank(wallet);
        depositNumber = s.stakeWithVoucher(v, sig, amount, expected);
    }
}
