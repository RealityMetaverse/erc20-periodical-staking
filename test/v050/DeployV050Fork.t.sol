// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VoucherHelper} from "../shared/VoucherHelper.sol";
import {DeployV050, ILegacyStakingV024, ILegacyLimitControllerV024} from "../../script/DeployV050.s.sol";
import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {LimitController} from "../../src/contracts/LimitController.sol";
import {Errors} from "../../src/common/Errors.sol";
import {Types} from "../../src/common/Types.sol";

interface IVmSkip {
    function skip(bool skipTest) external;
}

/// @notice The v0.2.4 write surface this test needs to create legacy stake on a fork when no known staker exists.
interface ILegacyStakingV024Write {
    function setRequirementChecker(address) external;
    function setLimitController(address) external;
    function safeStake(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount, uint256 expectedAPY) external;
}

/// @notice Runs DeployV050 against a fork of any network with a known source contract and compares the result with
///         that network's live v0.2.4 contract.
/// @dev Opt-in: FORK_RPC_URL (any network; falls back to POLYGON_RPC_URL), optionally FORK_BLOCK and SOURCE_STAKING.
///      Without an RPC every test is skipped with a log.
contract DeployV050ForkTest is VoucherHelper {
    IVmSkip private constant VM_SKIP = IVmSkip(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant MAX_EXTRA_APY_BPS = 500;
    uint256 internal constant MAX_EXTRA_LIMIT_TOTAL = 50_000e18;
    uint256 internal constant MAX_EXTRA_LIMIT_PER_CELL = 50_000e18;
    uint256 internal constant MAX_VOUCHER_VALIDITY = 1 days;

    bool internal forkOn;
    DeployV050 internal script;
    DeployV050.OldConfig internal old;
    ERC20PeriodicalStaking internal staking;
    LimitController internal controller;
    address internal admin = makeAddr("admin");

    modifier onlyFork() {
        if (!forkOn) {
            console2.log("DeployV050ForkTest skipped: set FORK_RPC_URL (or POLYGON_RPC_URL) to run against a fork");
            VM_SKIP.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", vm.envOr("POLYGON_RPC_URL", string("")));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forkOn = true;

        script = new DeployV050();
        address source = vm.envOr("SOURCE_STAKING", script.sourceStakingFor(block.chainid));
        require(source != address(0), "no source staking contract for this chain; set SOURCE_STAKING");

        address[] memory admins = new address[](1);
        admins[0] = admin;
        DeployV050.Params memory p = DeployV050.Params({
            sourceStaking: source,
            requirementCheckerV2: script.requirementCheckerV2For(block.chainid),
            voucherSigner: _voucherSignerAddr(),
            treasury: treasury,
            maxExtraApyBps: MAX_EXTRA_APY_BPS,
            maxExtraLimitTotal: MAX_EXTRA_LIMIT_TOTAL,
            maxExtraLimitPerCell: MAX_EXTRA_LIMIT_PER_CELL,
            maxVoucherValidity: MAX_VOUCHER_VALIDITY,
            newOwner: address(0),
            admins: admins,
            openStaking: false,
            rewardTopUp: 0,
            walletLimitsFile: "",
            resumeStaking: address(0),
            resumeController: address(0),
            allowSharedRoles: false
        });
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) =
            script.deployFrom(p, new DeployV050.WalletLimitRow[](0));
        old = o;
        staking = d.staking;
        controller = d.controller;
    }

    // ======================================
    // =   Config equals the live source    =
    // ======================================
    function test_fork_configMatchesLiveSource() external onlyFork {
        ILegacyStakingV024 src = ILegacyStakingV024(old.staking);
        address srcController = src.limitController();
        console2.log("chain", block.chainid, "source", old.staking);

        assertEq(address(staking.STAKING_TOKEN()), src.STAKING_TOKEN(), "token");
        assertEq(staking.stakingPhaseCount(), src.stakingPhaseCount(), "phase count");
        assertEq(staking.currentStakingPhase(), src.currentStakingPhase(), "current phase");
        assertEq(staking.minimumDeposit(), src.minimumDeposit(), "minimum deposit");

        uint256[] memory oldPeriods = src.getStakingPeriods();
        uint256[] memory newPeriods = staking.getStakingPeriods();
        assertEq(newPeriods.length, oldPeriods.length, "period count");
        uint256 phases = src.stakingPhaseCount();
        for (uint256 ph = 0; ph < phases; ph++) {
            for (uint256 i = 0; i < oldPeriods.length; i++) {
                uint256 period = oldPeriods[i];
                assertEq(newPeriods[i], period, "period");
                assertEq(
                    staking.phasePeriodDataList(Types.PhasePeriodDataType.APY, ph, period),
                    src.getPhasePeriodData(1, ph, period) * 100,
                    "APY bps = pct * 100"
                );
                assertEq(
                    staking.phasePeriodDataList(Types.PhasePeriodDataType.STAKING_TARGET, ph, period),
                    src.getPhasePeriodData(0, ph, period),
                    "target"
                );
                uint256 expectedDefault = srcController == address(0)
                    ? 0
                    : ILegacyLimitControllerV024(srcController).defaultPhasePeriodLimit(ph, period);
                assertEq(controller.defaultPhasePeriodLimit(ph, period), expectedDefault, "controller default");
                assertEq(staking.phasePeriodDataList(Types.PhasePeriodDataType.STAKED, ph, period), 0, "staked 0");
            }
        }

        assertEq(staking.limitController(), address(controller), "limit controller");
        assertEq(address(controller.stakingContract()), address(staking), "controller.stakingContract");
        assertEq(address(controller.legacyStakingContract()), old.staking, "controller.legacy = source");
        assertFalse(staking.checkActionAvailability(Types.DataType.STAKING), "staking closed by default");
        assertTrue(staking.checkActionAvailability(Types.DataType.WITHDRAWAL), "withdrawal open");
        assertTrue(staking.checkActionAvailability(Types.DataType.CLAIM), "claim open");
        assertEq(staking.voucherSigner(), _voucherSignerAddr(), "voucher signer");
        assertEq(staking.treasury(), treasury, "treasury");
        assertEq(staking.maxExtraApyBps(), MAX_EXTRA_APY_BPS, "max extra apy");
        assertEq(staking.maxExtraLimitTotal(), MAX_EXTRA_LIMIT_TOTAL, "max extra limit");
        assertEq(staking.maxExtraLimitPerCell(), MAX_EXTRA_LIMIT_PER_CELL, "max extra limit per cell");
        assertEq(staking.maxVoucherValidity(), MAX_VOUCHER_VALIDITY, "max voucher validity");
        assertTrue(staking.contractAdmins(admin), "admin");
        assertEq(staking.contractOwner(), address(script), "owner = deployer context");
    }

    // ======================================
    // =       Legacy stake is counted      =
    // ======================================
    function test_fork_legacyStakeCountedByController() external onlyFork {
        (address wallet, uint256 period, uint256 legacyCell) = _legacyStake();
        uint256 phase = old.currentPhase;

        assertEq(staking.getUserPhasePeriodData(Types.DataType.STAKING, wallet, phase, period), 0, "new cell empty");
        assertEq(controller.getUsed(wallet, phase, period), legacyCell, "used = live source cell");
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(wallet, phase, period);
        assertEq(allowed, controller.defaultPhasePeriodLimit(phase, period), "allowed = copied default");
        assertEq(used, legacyCell, "getAllowedAndUsed.used");
        assertEq(controller.getRemaining(wallet, phase, period), used >= allowed ? 0 : allowed - used, "remaining");
        console2.log("legacy staker", wallet);
        console2.log("  period / legacy cell / remaining", period, legacyCell, controller.getRemaining(wallet, phase, period));
    }

    // ======================================
    // =      Voucher stake end-to-end      =
    // ======================================
    function test_fork_voucherStakeWithCopiedConfig() external onlyFork {
        (address wallet, uint256 period, uint256 legacyCell) = _legacyStake();
        uint256 phase = old.currentPhase;
        uint256 allowed = controller.getAllowed(wallet, phase, period);
        uint256 amount = (allowed - legacyCell) / 2;
        if (amount > 1_000e18) amount = 1_000e18;
        require(amount >= staking.minimumDeposit(), "not enough limit room for a test stake");
        uint256 extraApy = 100;
        uint256 baseBps = staking.phasePeriodDataList(Types.PhasePeriodDataType.APY, phase, period);

        deal(old.token, wallet, amount * 10);
        vm.prank(wallet);
        IERC20(old.token).approve(address(staking), type(uint256).max);

        // Closed until deliberately opened.
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, wallet, phase, period, 0, 0);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING));
        staking.stakeWithVoucher(v, sig, amount, baseBps);

        vm.prank(address(script));
        staking.changeActionAvailability(Types.DataType.STAKING, true);

        uint256 dep = _stakeVWith(staking, wallet, phase, period, amount, extraApy, 0);
        assertEq(staking.getDeposit(wallet, dep).APY, baseBps + extraApy, "deposit APY = base bps + extra");
        assertEq(staking.getDeposit(wallet, dep).amount, amount, "deposit amount");
        assertEq(staking.getUserPhasePeriodData(Types.DataType.STAKING, wallet, phase, period), amount, "new cell");
        assertEq(controller.getUsed(wallet, phase, period), legacyCell + amount, "used = source + v0.4.0");

        // The copied default, minus source + new stake, is exactly the remaining room.
        uint256 headroom = allowed - legacyCell - amount;
        (v, sig) = _prepareVoucherStake(staking, wallet, phase, period, 0, 0);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, wallet, phase, period, headroom + 1, headroom)
        );
        staking.stakeWithVoucher(v, sig, headroom + 1, baseBps);
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    /// @dev A real staker of the source with room left (Polygon), otherwise legacy stake created on the fork: the
    ///      source owner unhooks its checker/controller (fork-local) and a fresh wallet safeStakes on the source.
    function _legacyStake() internal returns (address wallet, uint256 period, uint256 cell) {
        address[] memory candidates = _knownStakers();
        for (uint256 w = 0; w < candidates.length; w++) {
            for (uint256 i = 0; i < old.periods.length; i++) {
                uint256 p = old.periods[i];
                uint256 c = ILegacyStakingV024(old.staking).getUserPhasePeriodData(0, candidates[w], old.currentPhase, p);
                if (c > 0 && controller.getAllowed(candidates[w], old.currentPhase, p) >= c + 2 * staking.minimumDeposit()) {
                    console2.log("using a real source staker");
                    return (candidates[w], p, c);
                }
            }
        }
        return _createLegacyStake();
    }

    function _createLegacyStake() internal returns (address wallet, uint256 period, uint256 cell) {
        uint256 phase = old.currentPhase;
        uint256 periodIndex = type(uint256).max;
        for (uint256 i = 0; i < old.periods.length; i++) {
            if (old.defaultLimits[phase][i] >= 4 * old.minimumDeposit) {
                periodIndex = i;
                break;
            }
        }
        require(periodIndex != type(uint256).max, "no period with a default limit to test against");
        period = old.periods[periodIndex];
        uint256 target = old.targets[phase][periodIndex];
        uint256 staked = ILegacyStakingV024(old.staking).getPhasePeriodData(2, phase, period);
        cell = old.defaultLimits[phase][periodIndex] / 4;
        if (target - staked < cell) cell = target - staked;
        require(cell >= old.minimumDeposit, "source target has no room for a legacy test stake");

        wallet = makeAddr("legacyStaker");
        vm.startPrank(old.owner);
        ILegacyStakingV024Write(old.staking).setRequirementChecker(address(0));
        ILegacyStakingV024Write(old.staking).setLimitController(address(0));
        vm.stopPrank();

        deal(old.token, wallet, cell);
        vm.startPrank(wallet);
        IERC20(old.token).approve(old.staking, cell);
        ILegacyStakingV024Write(old.staking).safeStake(phase, period, cell, old.apyPct[phase][periodIndex]);
        vm.stopPrank();
        assertEq(ILegacyStakingV024(old.staking).getUserPhasePeriodData(0, wallet, phase, period), cell, "legacy cell");
        console2.log("no known staker on this chain: created legacy stake on the fork");
    }

    function _knownStakers() internal view returns (address[] memory s) {
        if (block.chainid == 137) {
            s = new address[](3);
            s[0] = 0x47cABbA9ABf3Ff8a9dDe2Ac3675aB6E029C652c9;
            s[1] = 0x986b088F2874FeC553f05644Aa22c4b0239d54e5;
            s[2] = 0xF7E482d5e2a72CA9E1E17945192a83E81f4BfE71;
        }
    }
}
