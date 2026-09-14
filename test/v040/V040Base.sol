// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {TestToken} from "../shared/TestToken.sol";
import {Clock} from "../shared/Clock.sol";
import {VoucherHelper} from "../shared/VoucherHelper.sol";
import {MockLegacyStaking} from "../shared/mocks/MockLegacyStaking.sol";

import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {LimitController} from "../../src/contracts/LimitController.sol";
import {Errors} from "../../src/common/Errors.sol";
import {Events} from "../../src/common/Events.sol";
import {Types} from "../../src/common/Types.sol";

/// @notice Fixture for the v0.4.0 suites: real LimitController with a mock legacy staking contract, voucher
///         signer, treasury, funded pool, 2 phases x periods [0, 30, 90].
/// @dev Inherits Events so tests can `emit` inside vm.expectEmit. Never read `block.timestamp` after a warp in a
///      test body (via_ir hazard): use `_now()`.
abstract contract V040Base is VoucherHelper, Events {
    Clock internal clock = new Clock();

    uint256 internal constant ONE = 1e18;
    uint256 internal constant P0 = 0;
    uint256 internal constant P30 = 30;
    uint256 internal constant P90 = 90;
    // bps, per period [0, 30, 90]
    uint256 internal constant APY_P0 = 500;
    uint256 internal constant APY_P30 = 1_000;
    uint256 internal constant APY_P90 = 2_000;
    uint256 internal constant PHASE1_APY_BONUS = 200;

    uint256 internal constant TARGET = 1_000_000 * ONE;
    uint256 internal constant POOL = 500_000 * ONE;
    uint256 internal constant USER_FUNDS = 200_000 * ONE;
    uint256 internal constant DEFAULT_LIMIT = 100_000 * ONE;
    uint256 internal constant MAX_EXTRA_APY_BPS = 2_000;
    uint256 internal constant MAX_EXTRA_LIMIT = 50_000 * ONE;

    TestToken internal token;
    ERC20PeriodicalStaking internal staking;
    LimitController internal controller;
    MockLegacyStaking internal legacy;

    address internal owner; // == address(this)
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal rando = makeAddr("rando");

    uint256[] internal PERIODS = [P0, P30, P90];

    function setUp() public virtual {
        owner = address(this);
        token = new TestToken(18);
        staking = new ERC20PeriodicalStaking(address(token));
        staking.addContractAdmin(admin);

        uint256[] memory empty = new uint256[](0);
        for (uint256 i = 0; i < PERIODS.length; i++) {
            staking.addStakingPeriod(PERIODS[i], empty, empty);
        }
        uint256[] memory apys = new uint256[](3);
        apys[0] = APY_P0;
        apys[1] = APY_P30;
        apys[2] = APY_P90;
        staking.pushStakingPhase(apys, _fill(3, TARGET));
        for (uint256 i = 0; i < 3; i++) {
            apys[i] += PHASE1_APY_BONUS;
        }
        staking.pushStakingPhase(apys, _fill(3, TARGET));

        legacy = new MockLegacyStaking();
        controller = new LimitController(address(staking));
        controller.setLegacyStakingContract(address(legacy));
        for (uint256 phase = 0; phase < 2; phase++) {
            for (uint256 i = 0; i < PERIODS.length; i++) {
                controller.setDefaultLimit(phase, PERIODS[i], DEFAULT_LIMIT);
            }
        }

        staking.setVoucherSigner(_voucherSignerAddr());
        staking.setMaxExtraApyBps(MAX_EXTRA_APY_BPS);
        staking.setMaxExtraLimit(MAX_EXTRA_LIMIT);
        staking.setTreasury(treasury);
        staking.setLimitController(address(controller));

        token.approve(address(staking), type(uint256).max);
        staking.provideReward(POOL);

        address[4] memory funded = [alice, bob, carol, admin];
        for (uint256 i = 0; i < funded.length; i++) {
            token.transfer(funded[i], USER_FUNDS);
            vm.prank(funded[i]);
            token.approve(address(staking), type(uint256).max);
        }
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    function _now() internal view returns (uint256) {
        return clock.now();
    }

    function _warpDays(uint256 d) internal {
        vm.warp(_now() + d * 1 days);
    }

    function _fill(uint256 n, uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = v;
        }
    }

    function _baseApy(uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.phasePeriodDataList(Types.PhasePeriodDataType.APY, phase, period);
    }

    /// @notice Signature by the configured voucher signer.
    function signVoucher(Types.StakeVoucher memory v) internal view returns (bytes memory) {
        return _signVoucher(address(staking), v, VOUCHER_SIGNER_KEY);
    }

    /// @notice Fresh voucher for the current phase.
    function voucherFor(address wallet, uint256 period, uint256 extraApyBps, uint256 extraLimit)
        internal
        returns (Types.StakeVoucher memory)
    {
        return _makeVoucher(wallet, staking.currentStakingPhase(), period, extraApyBps, extraLimit);
    }

    /// @notice Stake through a signed voucher for the current phase; expectedApyBps = base + extra.
    function stakeWith(address wallet, uint256 period, uint256 amount, uint256 extraApyBps, uint256 extraLimit)
        internal
        returns (uint256 depositNumber)
    {
        return _stakeVWith(staking, wallet, staking.currentStakingPhase(), period, amount, extraApyBps, extraLimit);
    }

    function stakeFor(address wallet, uint256 period, uint256 amount) internal returns (uint256) {
        return stakeWith(wallet, period, amount, 0, 0);
    }

    function freezeAs(address by, address wallet, uint256 depositNumber) internal {
        vm.prank(by);
        staking.freezeDeposit(wallet, depositNumber);
    }

    function freeze(address wallet, uint256 depositNumber) internal {
        freezeAs(admin, wallet, depositNumber);
    }

    function unfreeze(address wallet, uint256 depositNumber) internal {
        vm.prank(admin);
        staking.unfreezeDeposit(wallet, depositNumber);
    }

    /// @notice Owner seize (this contract is the owner).
    function seize(address wallet, uint256 depositNumber) internal {
        staking.seizeDeposit(wallet, depositNumber);
    }

    function freezeAndSeize(address wallet, uint256 depositNumber) internal {
        freeze(wallet, depositNumber);
        seize(wallet, depositNumber);
    }

    function _deposit(address wallet, uint256 n) internal view returns (ProgramManager.TokenDeposit memory) {
        return staking.getDeposit(wallet, n);
    }

    function _status(address wallet, uint256 n) internal view returns (ProgramManager.DepositStatus) {
        return staking.checkDepositStatus(wallet, n);
    }

    function _cell(address wallet, uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.getUserPhasePeriodData(Types.DataType.STAKING, wallet, phase, period);
    }
}
