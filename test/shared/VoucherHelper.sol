// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {Types} from "../../src/common/Types.sol";
import {OpenLimitController} from "./mocks/OpenLimitController.sol";

/// @notice Builds, signs and submits EIP-712 stake vouchers for v0.4.0 tests.
/// @dev The digest is computed locally (independent of the contract's getVoucherDigest), so a domain or
///      typehash mismatch in src shows up as InvalidVoucherSignature.
abstract contract VoucherHelper is Test {
    uint256 internal constant VOUCHER_SIGNER_KEY = 0xB0B5;
    bytes32 internal constant VOUCHER_TYPEHASH = keccak256(
        "StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimit,uint256 validUntil,uint256 nonce)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    mapping(address => uint256) internal _nextVoucherNonce;
    address internal treasury = makeAddr("treasury");

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
                VOUCHER_TYPEHASH, v.wallet, v.phase, v.period, v.extraApyBps, v.extraLimit, v.validUntil, v.nonce
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

    /// @dev validUntil = max avoids the via_ir timestamp hazard; the nonce is fresh per wallet.
    function _makeVoucher(address wallet, uint256 phase, uint256 period, uint256 extraApyBps, uint256 extraLimit)
        internal
        returns (Types.StakeVoucher memory)
    {
        return Types.StakeVoucher({
            wallet: wallet,
            phase: phase,
            period: period,
            extraApyBps: extraApyBps,
            extraLimit: extraLimit,
            validUntil: type(uint256).max,
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
        s.setMaxExtraLimit(type(uint128).max);
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
