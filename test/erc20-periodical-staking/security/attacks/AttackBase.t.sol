// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestToken} from "../../../shared/TestToken.sol";
import {ERC20PeriodicalStaking} from "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {AccessControl} from "../../../../src/contracts/erc20-periodical-staking/AccessControl.sol";
import {Errors} from "../../../../src/common/Errors.sol";
import {Types} from "../../../../src/common/Types.sol";

/// @title AttackBase
/// @notice Self-contained fixture for the adversarial test suites. Written against the v0.3.0
///         behaviour. Functions that only exist in v0.3.0 are invoked through
///         low-level calls so that this suite compiles against both the v0.2.4 and the v0.3.0 sources.
/// @dev Reads block.timestamp through an external call. With `via_ir` the optimizer treats TIMESTAMP as
///      invariant inside a function, so `block.timestamp` read after `vm.warp` in the same test can be stale.
contract Clock {
    function now_() external view returns (uint256) {
        return block.timestamp;
    }
}

abstract contract AttackBase is Test {
    Clock internal clock = new Clock();

    function _now() internal view returns (uint256) {
        return clock.now_();
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 internal constant ONE = 1e18;
    uint256 internal constant P0 = 0; // indefinite
    uint256 internal constant P30 = 30;
    uint256 internal constant P90 = 90;
    uint256 internal constant TARGET = 1_000_000 * ONE;
    uint256 internal constant POOL = 3_000_000 * ONE;
    uint256 internal constant USER_FUNDS = 200_000 * ONE;

    uint256[] internal PERIODS = [P0, P30, P90];
    uint256[] internal APY_PHASE0 = [5, 10, 20];
    uint256[] internal APY_PHASE1 = [7, 14, 28];

    // Panic selector: Panic(uint256)
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;
    // OpenZeppelin ReentrancyGuard.ReentrancyGuardReentrantCall()
    bytes4 internal constant REENTRANT_CALL_SELECTOR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    // OpenZeppelin SafeERC20.SafeERC20FailedOperation(address)
    bytes4 internal constant SAFE_ERC20_FAILED_SELECTOR = bytes4(keccak256("SafeERC20FailedOperation(address)"));

    // v0.3.0-only signatures. These are called via low-level calls.
    string internal constant SIG_ACCEPT_OWNERSHIP = "acceptOwnership()";
    string internal constant SIG_PENDING_OWNER = "pendingOwner()";
    string internal constant SIG_RESCUE_TOKENS = "rescueTokens(address,uint256)";
    string internal constant SIG_CLAIM_RANGE = "claimRange(uint256,uint256)";

    // ---------------------------------------------------------------------
    // Fixture
    // ---------------------------------------------------------------------
    TestToken internal token;
    ERC20PeriodicalStaking internal staking;

    address internal owner; // == address(this)
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal rando = makeAddr("rando");

    address[] internal users;

    /// @dev every period ever added to `staking` (removed ones included) — used by the accounting checks
    uint256[] internal periodsEver;
    uint256 internal maxPhaseCountEver;

    function setUp() public virtual {
        owner = address(this);
        token = new TestToken(18);
        staking = _deployConfigured(address(token));

        users.push(alice);
        users.push(bob);
        users.push(carol);
        users.push(dave);
        for (uint256 i = 0; i < users.length; i++) {
            token.transfer(users[i], USER_FUNDS);
            vm.prank(users[i]);
            token.approve(address(staking), type(uint256).max);
        }
        token.transfer(admin, USER_FUNDS);
        vm.prank(admin);
        token.approve(address(staking), type(uint256).max);
    }

    /// @notice Deploys a staking contract on `tokenAddr`, adds periods [0,30,90] and two phases, funds the pool.
    ///         Requires this contract to hold at least POOL of `tokenAddr`.
    function _deployConfigured(address tokenAddr) internal returns (ERC20PeriodicalStaking s) {
        s = new ERC20PeriodicalStaking(tokenAddr);
        s.addContractAdmin(admin);

        uint256[] memory empty = new uint256[](0);
        for (uint256 i = 0; i < PERIODS.length; i++) {
            s.addStakingPeriod(PERIODS[i], empty, empty);
        }
        s.pushStakingPhase(APY_PHASE0, _fill(PERIODS.length, TARGET));
        s.pushStakingPhase(APY_PHASE1, _fill(PERIODS.length, TARGET));
        s.changeStakingPhase(0);

        IERC20(tokenAddr).approve(address(s), type(uint256).max);
        s.provideReward(POOL);

        if (address(staking) == address(0)) {
            // first deployment: track for accounting checks
            delete periodsEver;
            for (uint256 i = 0; i < PERIODS.length; i++) {
                periodsEver.push(PERIODS[i]);
            }
            maxPhaseCountEver = 2;
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _fill(uint256 n, uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = v;
        }
    }

    function _apy(uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.getPhasePeriodData(Types.PhasePeriodDataType.APY, phase, period);
    }

    function _target(uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.getPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, phase, period);
    }

    function _staked(uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.getPhasePeriodData(Types.PhasePeriodDataType.STAKED, phase, period);
    }

    function _total(Types.DataType dt) internal view returns (uint256) {
        return staking.totalDataList(dt);
    }

    function _user(Types.DataType dt, address u) internal view returns (uint256) {
        return staking.userDataList(dt, u);
    }

    function _upp(Types.DataType dt, address u, uint256 phase, uint256 period) internal view returns (uint256) {
        return staking.userPhasePeriodDataList(dt, phase, period, u);
    }

    function _stake(address u, uint256 phase, uint256 period, uint256 amount) internal returns (uint256 depositNo) {
        uint256 apy = _apy(phase, period);
        vm.prank(u);
        staking.safeStake(phase, period, amount, apy);
        depositNo = staking.checkDepositCountOfAddress(u) - 1;
    }

    function _withdraw(address u, uint256 depositNo) internal {
        vm.prank(u);
        staking.withdrawDeposit(depositNo);
    }

    function _claim(address u, uint256 depositNo) internal {
        vm.prank(u);
        staking.claimDeposit(depositNo);
    }

    function _claimAll(address u) internal {
        vm.prank(u);
        staking.claimAll();
    }

    function _warpDays(uint256 d) internal {
        vm.warp(_now() + d * 1 days);
    }

    function _deposit(address u, uint256 n) internal view returns (ProgramManager.TokenDeposit memory) {
        return staking.getDeposit(u, n);
    }

    function _status(address u, uint256 n) internal view returns (ProgramManager.DepositStatus) {
        return staking.checkDepositStatus(u, n);
    }

    function _trackPeriod(uint256 p) internal {
        for (uint256 i = 0; i < periodsEver.length; i++) {
            if (periodsEver[i] == p) return;
        }
        periodsEver.push(p);
    }

    function _trackPhaseCount() internal {
        uint256 c = staking.stakingPhaseCount();
        if (c > maxPhaseCountEver) maxPhaseCountEver = c;
    }

    function _pushPhase(uint256 apy, uint256 target) internal {
        uint256 n = staking.getStakingPeriods().length;
        staking.pushStakingPhase(_fill(n, apy), _fill(n, target));
        _trackPhaseCount();
    }

    function _addPeriod(uint256 period, uint256 apy, uint256 target) internal {
        uint256 n = staking.stakingPhaseCount();
        staking.addStakingPeriod(period, _fill(n, apy), _fill(n, target));
        _trackPeriod(period);
    }

    /// @dev Low-level call helper (from `from`).
    function _call(address from, address to, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = to.call(data);
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(ret, 0x20))
        }
    }

    function _isPanic(bytes memory ret) internal pure returns (bool) {
        return _selectorOf(ret) == PANIC_SELECTOR;
    }

    function _unauthorized(AccessControl.AccessTier tier) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, tier);
    }

    // ---------------------------------------------------------------------
    // Accounting invariants (the "truth" every scenario is checked against)
    // ---------------------------------------------------------------------
    function _sumUserData(Types.DataType dt) internal view returns (uint256 s) {
        for (uint256 i = 0; i < users.length; i++) {
            s += _user(dt, users[i]);
        }
    }

    function _sumStakedAllCells() internal view returns (uint256 s) {
        for (uint256 ph = 0; ph < maxPhaseCountEver; ph++) {
            for (uint256 i = 0; i < periodsEver.length; i++) {
                s += _staked(ph, periodsEver[i]);
            }
        }
    }

    function _sumUserCells(Types.DataType dt, address u) internal view returns (uint256 s) {
        for (uint256 ph = 0; ph < maxPhaseCountEver; ph++) {
            for (uint256 i = 0; i < periodsEver.length; i++) {
                s += _upp(dt, u, ph, periodsEver[i]);
            }
        }
    }

    function _openPeriodicalRewards(address u) internal view returns (uint256 s) {
        uint256 n = staking.checkDepositCountOfAddress(u);
        for (uint256 i = 0; i < n; i++) {
            ProgramManager.DepositStatus st = _status(u, i);
            if (st == ProgramManager.DepositStatus.TIME_LEFT || st == ProgramManager.DepositStatus.READY_TO_CLAIM) {
                s += _deposit(u, i).rewardGenerated;
            }
        }
    }

    /// @notice Asserts every accounting relationship that must hold for the tracked `users`.
    ///         Only valid when `users` are the only stakers in `staking`.
    function _assertAccounting() internal {
        // 1. Token conservation: contract balance == principal + reward pool
        assertEq(
            token.balanceOf(address(staking)),
            _total(Types.DataType.STAKING) + staking.rewardPool(),
            "conservation: balance != totalStaked + rewardPool"
        );

        // 2. sum over users of userDataList == totalDataList, for every DataType
        for (uint8 i = 0; i <= uint8(type(Types.DataType).max); i++) {
            Types.DataType dt = Types.DataType(i);
            uint256 expected = _sumUserData(dt);
            if (dt == Types.DataType.REWARD_PROVIDED) {
                // owner/admin provide rewards; they are not in `users`
                expected += _user(dt, owner) + _user(dt, admin);
            }
            if (dt == Types.DataType.REWARD_COLLECTED) {
                expected += _user(dt, owner);
            }
            assertEq(_total(dt), expected, string.concat("sum(userDataList) != totalDataList for dt ", vm.toString(i)));
        }

        // 3. sum over (phase, period) STAKED == totalStaked
        assertEq(_sumStakedAllCells(), _total(Types.DataType.STAKING), "sum(STAKED cells) != totalStaked");

        // 4. per user: sum over cells == user totals for STAKING / WITHDRAWAL / CLAIM / REWARD_EXPECTED
        uint256 rewardExpectedSum;
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            assertEq(_sumUserCells(Types.DataType.STAKING, u), _user(Types.DataType.STAKING, u), "user STAKING cells");
            assertEq(
                _sumUserCells(Types.DataType.WITHDRAWAL, u), _user(Types.DataType.WITHDRAWAL, u), "user WITHDRAWAL cells"
            );
            assertEq(_sumUserCells(Types.DataType.CLAIM, u), _user(Types.DataType.CLAIM, u), "user CLAIM cells");
            assertEq(
                _sumUserCells(Types.DataType.REWARD_EXPECTED, u),
                _user(Types.DataType.REWARD_EXPECTED, u),
                "user REWARD_EXPECTED cells"
            );
            // 5. REWARD_EXPECTED == sum of rewardGenerated over open periodical deposits
            uint256 open = _openPeriodicalRewards(u);
            assertEq(_user(Types.DataType.REWARD_EXPECTED, u), open, "user REWARD_EXPECTED != open periodical rewards");
            rewardExpectedSum += open;
        }
        assertEq(_total(Types.DataType.REWARD_EXPECTED), rewardExpectedSum, "total REWARD_EXPECTED != open rewards");

        // `rewardPool >= REWARD_EXPECTED` is no longer an invariant: stakes are never blocked by
        // pool state, so the pool may legitimately sit below the committed reward until the owner tops up.
        // The reserve properties are asserted per scenario (collectReward guard, indefinite payouts from the
        // free pool only) and by the ghost-based invariants in security/invariants/.
    }
}
