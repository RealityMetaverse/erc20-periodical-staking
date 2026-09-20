// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployV050} from "../../script/DeployV050.s.sol";
import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {LimitController} from "../../src/contracts/LimitController.sol";
import {Errors} from "../../src/common/Errors.sol";
import {Types} from "../../src/common/Types.sol";
import {TestToken} from "../shared/TestToken.sol";

// Vendored pre-fix v0.2.4 sources (never edited): the real shape of the contract DeployV050 copies FROM.
import {ERC20PeriodicalStaking as LegacyV024} from
    "../erc20-periodical-staking/security/invariants/legacy/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";

/// @notice Drives script/DeployV050.s.sol's `deployFrom()` against a locally deployed v0.2.4 "source", with no
///         fork and no RPC, so the deployment path is covered by the default `forge test` run.
/// @dev The fork tests (DeployV050Fork.t.sol) check the script against the REAL Polygon/Amoy contracts and are
///      skipped without an RPC; these tests check the parts that do not need one -- the preflight's bounds, the
///      two-step ownership hand-off on BOTH contracts, the opt-in reward funding and its resume guard, and the
///      idempotence of a resumed run.
///
///      NOT covered here: `run()` and its environment parsing. Driving it needs `vm.setEnv`, whose effect is
///      process-global and therefore visible to every other test contract executing at the same time --
///      DeployV050Fork.t.sol reads SOURCE_STAKING and FORK_BLOCK from exactly that environment. The env plumbing
///      is exercised by the deploy-v050.sh wrapper instead; everything below calls `deployFrom()` with an
///      explicit Params struct, which is the same code path minus `paramsFromEnv()`.
contract DeployV050LocalTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant TARGET = 1_000_000 * ONE;
    uint256 internal constant DEFAULT_LIMIT = 100_000 * ONE;
    uint256 internal constant MAX_EXTRA_APY_BPS = 2_000;
    uint256 internal constant MAX_EXTRA_LIMIT_TOTAL = 50_000 * ONE;
    uint256 internal constant MAX_EXTRA_LIMIT_PER_CELL = 50_000 * ONE;
    uint256 internal constant MAX_VOUCHER_VALIDITY = 1_800;

    /// @dev v0.2.4 stores APY as WHOLE PERCENT; v0.5.0 stores bps. The script multiplies by this.
    uint256 internal constant PCT_TO_BPS = 100;
    /// @dev Mirrors of the staking contract's config-time bounds (AdministrativeFunctions, internal there).
    uint256 internal constant MAX_APY_BPS = 1_000_000;
    uint256 internal constant MAX_PERIOD_DAYS = 36_500;

    DeployV050 internal deployScript;
    TestToken internal token;
    LegacyV024 internal source;
    LimitController internal sourceController;

    address internal voucherSigner = makeAddr("voucherSigner");
    address internal treasury = makeAddr("treasury");
    address internal newOwner = makeAddr("newOwner");
    address internal adminA = makeAddr("adminA");
    address internal adminB = makeAddr("adminB");

    uint256[] internal PERIODS = [uint256(0), 30, 90];
    /// @dev Whole percent, per phase, per period.
    uint256[3] internal PHASE0_PCT = [uint256(5), 10, 20];
    uint256[3] internal PHASE1_PCT = [uint256(6), 12, 24];

    function setUp() public {
        token = new TestToken(18);
        deployScript = new DeployV050();
        source = _newSource();
        sourceController = _newSourceController(source, 2, PERIODS);
    }

    // ======================================
    // =              Fixtures              =
    // ======================================

    /// @dev A v0.2.4 contract shaped like the ones on chain: 3 periods, 2 phases, current phase 1.
    function _newSource() internal returns (LegacyV024 s) {
        s = new LegacyV024(address(token));
        uint256[] memory empty = new uint256[](0);
        for (uint256 i = 0; i < PERIODS.length; ++i) {
            s.addStakingPeriod(PERIODS[i], empty, empty);
        }
        s.pushStakingPhase(_pcts(PHASE0_PCT), _fill(3, TARGET));
        s.pushStakingPhase(_pcts(PHASE1_PCT), _fill(3, TARGET));
        s.changeStakingPhase(1);
        s.setMiniumumDeposit(500 * ONE);
    }

    /// @dev The source's own LimitController. v0.2.4 pointed at a controller of this shape; the script reads its
    ///      defaults for every (phase, period) of the source's config and copies them to the new one.
    function _newSourceController(LegacyV024 s, uint256 phaseCount, uint256[] memory periods)
        internal
        returns (LimitController c)
    {
        c = new LimitController(address(s));
        _sourceControllers[address(s)] = c;
        for (uint256 ph = 0; ph < phaseCount; ++ph) {
            for (uint256 i = 0; i < periods.length; ++i) {
                // Distinct per cell, so a copy that crosses wires cannot pass by accident.
                c.setDefaultLimit(ph, periods[i], DEFAULT_LIMIT + (ph + 1) * (i + 1) * ONE);
            }
        }
        s.setLimitController(address(c));
    }

    function _params() internal view returns (DeployV050.Params memory p) {
        address[] memory admins = new address[](2);
        admins[0] = adminA;
        admins[1] = adminB;
        p = DeployV050.Params({
            sourceStaking: address(source),
            requirementCheckerV2: address(0),
            voucherSigner: voucherSigner,
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
    }

    function _noRows() internal pure returns (DeployV050.WalletLimitRow[] memory) {
        return new DeployV050.WalletLimitRow[](0);
    }

    function _deploy(DeployV050.Params memory p)
        internal
        returns (DeployV050.OldConfig memory o, DeployV050.Deployment memory d)
    {
        (o, d) = deployScript.deployFrom(p, _noRows());
    }

    function _fill(uint256 n, uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = v;
        }
    }

    function _pcts(uint256[3] memory src) internal pure returns (uint256[] memory a) {
        a = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            a[i] = src[i];
        }
    }

    // ======================================
    // =        (a) Happy path              =
    // ======================================

    /// @notice A fresh deployment reproduces the source's whole program, and the script's own self-check passes
    ///         when re-run standalone against the deployed contracts.
    function test_deployFrom_copiesTheSourceProgram() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = _deploy(p);

        ERC20PeriodicalStaking s = d.staking;
        LimitController c = d.controller;

        // Wiring: new staking <-> new controller, and the controller points back at the SOURCE as legacy, which
        // is what makes the source's existing stake count against the new limits.
        assertEq(address(s.STAKING_TOKEN()), address(token), "token");
        assertEq(s.limitController(), address(c), "staking.limitController");
        assertEq(address(c.stakingContract()), address(s), "controller.stakingContract");
        assertEq(address(c.legacyStakingContract()), address(source), "controller.legacyStakingContract");

        // Settings taken from Params.
        assertEq(s.voucherSigner(), voucherSigner, "voucherSigner");
        assertEq(s.treasury(), treasury, "treasury");
        assertEq(s.maxExtraApyBps(), MAX_EXTRA_APY_BPS, "maxExtraApyBps");
        assertEq(s.maxExtraLimitTotal(), MAX_EXTRA_LIMIT_TOTAL, "maxExtraLimitTotal");
        assertEq(s.maxExtraLimitPerCell(), MAX_EXTRA_LIMIT_PER_CELL, "maxExtraLimitPerCell");
        assertEq(s.maxVoucherValidity(), MAX_VOUCHER_VALIDITY, "maxVoucherValidity");
        assertTrue(s.contractAdmins(adminA), "adminA");
        assertTrue(s.contractAdmins(adminB), "adminB");

        // Program copied from the source.
        assertEq(s.stakingPhaseCount(), o.phaseCount, "phase count");
        assertEq(s.stakingPhaseCount(), 2, "phase count is the fixture's");
        assertEq(s.currentStakingPhase(), o.currentPhase, "current phase");
        assertEq(s.currentStakingPhase(), 1, "current phase is the fixture's");
        assertEq(s.minimumDeposit(), o.minimumDeposit, "minimum deposit");
        assertEq(s.minimumDeposit(), 500 * ONE, "minimum deposit is the fixture's");

        uint256[] memory newPeriods = s.getStakingPeriods();
        assertEq(newPeriods.length, PERIODS.length, "period count");
        for (uint256 i = 0; i < PERIODS.length; ++i) {
            assertEq(newPeriods[i], PERIODS[i], "period list");
        }

        // APY converts percent -> bps; targets and controller defaults are copied verbatim.
        for (uint256 ph = 0; ph < 2; ++ph) {
            for (uint256 i = 0; i < PERIODS.length; ++i) {
                uint256 period = PERIODS[i];
                uint256 expectedPct = ph == 0 ? PHASE0_PCT[i] : PHASE1_PCT[i];
                assertEq(
                    s.phasePeriodDataList(Types.PhasePeriodDataType.APY, ph, period),
                    expectedPct * PCT_TO_BPS,
                    "APY bps"
                );
                assertEq(
                    s.phasePeriodDataList(Types.PhasePeriodDataType.STAKING_TARGET, ph, period), TARGET, "target"
                );
                assertEq(
                    c.defaultPhasePeriodLimit(ph, period),
                    DEFAULT_LIMIT + (ph + 1) * (i + 1) * ONE,
                    "default limit"
                );
            }
        }

        // Staking stays CLOSED (openStaking = false) while withdrawal and claim are open, so the new contract
        // cannot take deposits before somebody deliberately opens it.
        assertFalse(s.checkActionAvailability(Types.DataType.STAKING), "staking must stay closed");
        assertTrue(s.checkActionAvailability(Types.DataType.WITHDRAWAL), "withdrawal open");
        assertTrue(s.checkActionAvailability(Types.DataType.CLAIM), "claim open");

        // No funding was asked for, so none happened.
        assertEq(s.rewardPool(), 0, "reward pool untouched");

        // The self-check is run inside deployFrom; re-running it standalone must also pass.
        deployScript.verifyDeployment(o, p, _noRows(), d, address(deployScript));
    }

    /// @notice openStaking = true is honoured (the one setting the script is allowed to flip on).
    function test_deployFrom_openStakingTrue() public {
        DeployV050.Params memory p = _params();
        p.openStaking = true;
        (, DeployV050.Deployment memory d) = _deploy(p);
        assertTrue(d.staking.checkActionAvailability(Types.DataType.STAKING), "staking open");
    }

    // ======================================
    // =      (b) Two-step ownership        =
    // ======================================

    /// @notice A non-zero NEW_OWNER only NOMINATES on both contracts. This is the finding the two-step change
    ///         was made for: the deployer stays in control until NEW_OWNER proves it can transact, so a mistyped
    ///         address costs nothing instead of permanently bricking the staking contract and its limits.
    function test_deployFrom_newOwnerIsOnlyNominatedOnBothContracts() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (, DeployV050.Deployment memory d) = _deploy(p);

        ERC20PeriodicalStaking s = d.staking;
        LimitController c = d.controller;

        // Neither contract has changed hands.
        assertEq(s.contractOwner(), address(deployScript), "staking still owned by the deployer");
        assertEq(c.owner(), address(deployScript), "controller still owned by the deployer");
        assertEq(s.pendingOwner(), newOwner, "staking pendingOwner nominated");
        assertEq(c.pendingOwner(), newOwner, "controller pendingOwner nominated");

        // The nominee cannot act yet on either contract.
        vm.prank(newOwner);
        vm.expectRevert();
        s.setTreasury(newOwner);
        vm.prank(newOwner);
        vm.expectRevert();
        c.setDefaultLimit(0, 0, 1);
    }

    /// @notice The hand-off completes only when NEW_OWNER accepts on BOTH contracts. Accepting on one leaves the
    ///         other with the deployer, which is exactly why the script prints two manual acceptOwnership steps.
    function test_acceptOwnership_completesOnBothContracts() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (, DeployV050.Deployment memory d) = _deploy(p);

        ERC20PeriodicalStaking s = d.staking;
        LimitController c = d.controller;

        // Accept on the staking contract only.
        vm.prank(newOwner);
        s.acceptOwnership();
        assertEq(s.contractOwner(), newOwner, "staking owner moved");
        assertEq(s.pendingOwner(), address(0), "staking pendingOwner cleared");
        assertEq(c.owner(), address(deployScript), "controller NOT moved by the staking acceptance");
        assertEq(c.pendingOwner(), newOwner, "controller still pending");

        // Then on the controller.
        vm.prank(newOwner);
        c.acceptOwnership();
        assertEq(c.owner(), newOwner, "controller owner moved");
        assertEq(c.pendingOwner(), address(0), "controller pendingOwner cleared");

        // The new owner governs both.
        vm.prank(newOwner);
        s.setTreasury(treasury);
        vm.prank(newOwner);
        c.setDefaultLimit(0, 0, 123);
        assertEq(c.defaultPhasePeriodLimit(0, 0), 123, "new owner can write");

        // And the deployer no longer does.
        vm.prank(address(deployScript));
        vm.expectRevert();
        c.setDefaultLimit(0, 0, 456);
    }

    /// @notice Somebody other than the nominee cannot accept either contract.
    function test_acceptOwnership_onlyTheNominee() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (, DeployV050.Deployment memory d) = _deploy(p);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        d.staking.acceptOwnership();
        vm.prank(stranger);
        vm.expectRevert();
        d.controller.acceptOwnership();

        assertEq(d.staking.contractOwner(), address(deployScript), "staking unchanged");
        assertEq(d.controller.owner(), address(deployScript), "controller unchanged");
    }

    // ======================================
    // =       (c) Reward top-up            =
    // ======================================

    /// @notice REWARD_TOP_UP funds the pool from the deployer's own balance (approve + provideReward).
    function test_deployFrom_rewardTopUpFundsThePool() public {
        uint256 topUp = 10_000 * ONE;
        token.transfer(address(deployScript), topUp);

        DeployV050.Params memory p = _params();
        p.rewardTopUp = topUp;
        (, DeployV050.Deployment memory d) = _deploy(p);

        assertEq(d.staking.rewardPool(), topUp, "pool funded");
        assertEq(token.balanceOf(address(d.staking)), topUp, "tokens moved to the staking contract");
        assertEq(token.balanceOf(address(deployScript)), 0, "deployer paid for it");
    }

    /// @notice The preflight refuses a top-up the deployer cannot pay, before anything is deployed.
    function test_deployFrom_rewardTopUpAboveBalanceIsRejected() public {
        DeployV050.Params memory p = _params();
        p.rewardTopUp = 1;
        vm.expectRevert(bytes("DeployV050: deployer balance below REWARD_TOP_UP"));
        _deploy(p);
    }

    /// @notice A resume must never fund twice. With a pool that is already non-empty the top-up is skipped, so
    ///         re-running a broadcast that died after provideReward cannot double the rewards on offer.
    function test_resume_rewardTopUpIsSkippedWhenThePoolIsNotEmpty() public {
        uint256 topUp = 10_000 * ONE;
        // Twice the top-up, so the second run's balance preflight passes and only the pool guard can stop it.
        token.transfer(address(deployScript), topUp * 2);

        DeployV050.Params memory p = _params();
        p.rewardTopUp = topUp;
        (, DeployV050.Deployment memory d) = _deploy(p);
        assertEq(d.staking.rewardPool(), topUp, "funded once");

        uint256 balanceAfterFirst = token.balanceOf(address(deployScript));

        p.resumeStaking = address(d.staking);
        p.resumeController = address(d.controller);
        (, DeployV050.Deployment memory d2) = _deploy(p);

        assertEq(address(d2.staking), address(d.staking), "same staking contract reused");
        assertEq(d2.staking.rewardPool(), topUp, "pool NOT funded a second time");
        assertEq(token.balanceOf(address(deployScript)), balanceAfterFirst, "deployer paid nothing more");
    }

    // ======================================
    // =      (d) Resume idempotence        =
    // ======================================

    /// @notice Resuming a finished deployment writes nothing at all. Asserted on the contracts' own events: any
    ///         setter the script re-ran would emit from the staking contract or the controller.
    function test_resume_onFinishedDeploymentWritesNothing() public {
        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory d) = _deploy(p);

        bytes32 before = _fingerprint(d);

        p.resumeStaking = address(d.staking);
        p.resumeController = address(d.controller);

        vm.recordLogs();
        (, DeployV050.Deployment memory d2) = _deploy(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 writes;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(d.staking) || logs[i].emitter == address(d.controller)) ++writes;
        }
        assertEq(writes, 0, "a resume of a finished deployment must emit nothing from either contract");

        assertEq(address(d2.staking), address(d.staking), "no new staking contract");
        assertEq(address(d2.controller), address(d.controller), "no new controller");
        assertEq(_fingerprint(d2), before, "state unchanged");
    }

    /// @notice The real resume case: a run that died after the contracts existed but before the program was
    ///         fully configured. The second run adds exactly the missing periods and phases (_addMissingPeriods
    ///         then _pushMissingPhases), and a third run adds nothing.
    function test_resume_completesAPartialConfiguration() public {
        // A smaller source first: periods [0, 30], one phase. Deploying from it stands in for the state a
        // broadcast leaves behind when it dies partway through the program setup.
        LegacyV024 small = new LegacyV024(address(token));
        uint256[] memory empty = new uint256[](0);
        small.addStakingPeriod(0, empty, empty);
        small.addStakingPeriod(30, empty, empty);
        uint256[] memory pct = new uint256[](2);
        pct[0] = 5;
        pct[1] = 10;
        small.pushStakingPhase(pct, _fill(2, TARGET));
        uint256[] memory smallPeriods = new uint256[](2);
        smallPeriods[0] = 0;
        smallPeriods[1] = 30;
        _newSourceController(small, 1, smallPeriods);

        DeployV050.Params memory p = _params();
        p.sourceStaking = address(small);
        (, DeployV050.Deployment memory d) = _deploy(p);
        assertEq(d.staking.stakingPhaseCount(), 1, "one phase so far");
        assertEq(d.staking.getStakingPeriods().length, 2, "two periods so far");

        // The source gains a period and a phase (what the dead run had not copied yet).
        uint256[] memory onePhase = new uint256[](1);
        onePhase[0] = 20;
        small.addStakingPeriod(90, onePhase, _fill(1, TARGET));
        uint256[] memory threePct = new uint256[](3);
        threePct[0] = 6;
        threePct[1] = 12;
        threePct[2] = 24;
        small.pushStakingPhase(threePct, _fill(3, TARGET));
        // The source's controller gains defaults for the new cells too.
        sourceControllerOf(small).setDefaultLimit(0, 90, DEFAULT_LIMIT);
        for (uint256 i = 0; i < 3; ++i) {
            sourceControllerOf(small).setDefaultLimit(1, PERIODS[i], DEFAULT_LIMIT + (i + 1) * ONE);
        }

        // Resume: only the missing pieces are added, and the full self-check still runs inside deployFrom.
        p.resumeStaking = address(d.staking);
        p.resumeController = address(d.controller);
        (, DeployV050.Deployment memory d2) = _deploy(p);

        assertEq(address(d2.staking), address(d.staking), "reused, not redeployed");
        assertEq(d2.staking.stakingPhaseCount(), 2, "phase added");
        assertEq(d2.staking.getStakingPeriods().length, 3, "period added");
        assertTrue(d2.staking.checkIfStakingPeriodExists(90), "period 90 present");
        // Period 90 was added while one phase existed, then phase 1 filled the rest: both orders converge.
        assertEq(
            d2.staking.phasePeriodDataList(Types.PhasePeriodDataType.APY, 0, 90), 20 * PCT_TO_BPS, "phase 0 / 90"
        );
        assertEq(
            d2.staking.phasePeriodDataList(Types.PhasePeriodDataType.APY, 1, 90), 24 * PCT_TO_BPS, "phase 1 / 90"
        );
        assertEq(d2.controller.defaultPhasePeriodLimit(0, 90), DEFAULT_LIMIT, "new default copied");

        // A third run is a no-op.
        bytes32 before = _fingerprint(d2);
        vm.recordLogs();
        (, DeployV050.Deployment memory d3) = _deploy(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 writes;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(d.staking) || logs[i].emitter == address(d.controller)) ++writes;
        }
        assertEq(writes, 0, "the completed configuration must not be rewritten");
        assertEq(_fingerprint(d3), before, "state unchanged");
    }

    /// @notice A resume the deployer does not own is refused: the "skip what is already done" guards would
    ///         otherwise read, and then try to write, a stranger's contract.
    function test_resume_rejectsAContractTheDeployerDoesNotOwn() public {
        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory d) = _deploy(p);

        // Hand the staking contract to somebody else.
        vm.prank(address(deployScript));
        d.staking.transferOwnership(newOwner);
        vm.prank(newOwner);
        d.staking.acceptOwnership();

        p.resumeStaking = address(d.staking);
        vm.expectRevert(bytes("DeployV050: RESUME_STAKING is not owned by the deployer"));
        _deploy(p);
    }

    /// @notice RESUME_CONTROLLER must be the controller of RESUME_STAKING, not some other deployment's.
    function test_resume_rejectsAControllerBuiltForAnotherStakingContract() public {
        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory a) = _deploy(p);
        (, DeployV050.Deployment memory b) = _deploy(p);

        p.resumeStaking = address(a.staking);
        p.resumeController = address(b.controller); // belongs to deployment b
        vm.expectRevert(bytes("DeployV050: RESUME_CONTROLLER was built for another staking contract"));
        _deploy(p);
    }

    // ======================================
    // =   (e) Preflight rejects bad input  =
    // ======================================

    /// @notice An APY above the contract's config-time ceiling is caught by the preflight, with a message that
    ///         names the variable, BEFORE anything is deployed. Without it the run dies inside pushStakingPhase
    ///         with a bare ValueTooHigh, halfway through a broadcast.
    function test_preflight_rejectsSourceApyAboveTheContractCeiling() public {
        // MAX_APY_BPS / 100 = 10_000 percent is the highest the new contract accepts.
        LegacyV024 bad = new LegacyV024(address(token));
        uint256[] memory empty = new uint256[](0);
        bad.addStakingPeriod(30, empty, empty);
        uint256[] memory pct = new uint256[](1);
        pct[0] = MAX_APY_BPS / PCT_TO_BPS + 1; // 10_001 percent
        bad.pushStakingPhase(pct, _fill(1, TARGET));
        _newSourceController(bad, 1, _one(30));

        DeployV050.Params memory p = _params();
        p.sourceStaking = address(bad);
        vm.expectRevert(bytes("DeployV050: source APY pct * 100 exceeds 1000000 bps (v0.5.0 rejects it)"));
        _deploy(p);
    }

    /// @notice Same for a staking period longer than the contract's ceiling. v0.2.4 had no such bound, so a
    ///         source really can hold one.
    function test_preflight_rejectsSourcePeriodAboveTheContractCeiling() public {
        LegacyV024 bad = new LegacyV024(address(token));
        uint256[] memory empty = new uint256[](0);
        bad.addStakingPeriod(MAX_PERIOD_DAYS + 1, empty, empty);
        uint256[] memory pct = new uint256[](1);
        pct[0] = 10;
        bad.pushStakingPhase(pct, _fill(1, TARGET));
        _newSourceController(bad, 1, _one(MAX_PERIOD_DAYS + 1));

        DeployV050.Params memory p = _params();
        p.sourceStaking = address(bad);
        vm.expectRevert(bytes("DeployV050: source period exceeds 36500 days (v0.5.0 rejects it)"));
        _deploy(p);
    }

    /// @notice MAX_EXTRA_APY_BPS is checked against the same ceiling.
    function test_preflight_rejectsMaxExtraApyAboveTheContractCeiling() public {
        DeployV050.Params memory p = _params();
        p.maxExtraApyBps = MAX_APY_BPS + 1;
        vm.expectRevert(bytes("DeployV050: MAX_EXTRA_APY_BPS exceeds 1000000 bps (v0.5.0 rejects it)"));
        _deploy(p);
    }

    /// @notice The bound the preflight mirrors is real: without the preflight, this is the error an operator
    ///         would get instead -- from inside a broadcast, with no indication of which setting caused it.
    function test_contractItselfRejectsTheSameValues() public {
        ERC20PeriodicalStaking s = new ERC20PeriodicalStaking(address(token));
        vm.expectRevert(abi.encodeWithSelector(Errors.ValueTooHigh.selector, MAX_APY_BPS + 1, MAX_APY_BPS));
        s.setMaxExtraApyBps(MAX_APY_BPS + 1);

        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ValueTooHigh.selector, MAX_PERIOD_DAYS + 1, MAX_PERIOD_DAYS)
        );
        s.addStakingPeriod(MAX_PERIOD_DAYS + 1, empty, empty);
    }

    /// @notice A zero per-cell ceiling with a non-zero budget would disable the voucher bonus entirely: every
    ///         voucher carrying one reverts. Caught before the deployment, not by users at the first stake.
    function test_preflight_rejectsZeroPerCellCeilingWithANonZeroBudget() public {
        DeployV050.Params memory p = _params();
        p.maxExtraLimitPerCell = 0;
        vm.expectRevert(
            bytes("DeployV050: MAX_EXTRA_LIMIT_PER_CELL is 0 while MAX_EXTRA_LIMIT_TOTAL is not, bonus would be disabled")
        );
        _deploy(p);
    }

    /// @notice MAX_VOUCHER_VALIDITY = 0 would revert every stake, and reads like "disabled" when it is the
    ///         opposite. Rejected up front.
    function test_preflight_rejectsZeroVoucherValidity() public {
        DeployV050.Params memory p = _params();
        p.maxVoucherValidity = 0;
        vm.expectRevert(bytes("DeployV050: MAX_VOUCHER_VALIDITY must be non-zero"));
        _deploy(p);
    }

    // ======================================
    // =      Role distinctness (#32)       =
    // ======================================

    /// @notice One address per role. A voucher signer that is also the owner turns a leaked backend signing key
    ///         into an ownership problem, so the preflight fails instead of deploying.
    function test_preflight_rejectsSharedRoles() public {
        DeployV050.Params memory p = _params();
        p.voucherSigner = treasury;
        vm.expectRevert(
            bytes("DeployV050: VOUCHER_SIGNER equals TREASURY (one address per role; ALLOW_SHARED_ROLES=true overrides)")
        );
        _deploy(p);
    }

    /// @notice A treasury that is the staking token would strand every seized deposit inside the token contract.
    function test_preflight_rejectsTreasuryEqualToTheToken() public {
        DeployV050.Params memory p = _params();
        p.treasury = address(token);
        vm.expectRevert(
            bytes(
                "DeployV050: TREASURY equals the staking token (one address per role; ALLOW_SHARED_ROLES=true overrides)"
            )
        );
        _deploy(p);
    }

    /// @notice ALLOW_SHARED_ROLES=true downgrades the clash to a warning, which is what a testnet wants.
    function test_allowSharedRoles_downgradesTheClashToAWarning() public {
        DeployV050.Params memory p = _params();
        p.voucherSigner = treasury;
        p.allowSharedRoles = true;
        (, DeployV050.Deployment memory d) = _deploy(p);
        assertEq(d.staking.voucherSigner(), treasury, "deployed with the shared role");
    }

    // ======================================
    // =           Source guards            =
    // ======================================

    /// @notice The script refuses a source that is not a v0.2.4 contract: a v0.3.0+ one has pendingOwner(), and
    ///         a v0.4.0+ one already stores bps, so the percent -> bps conversion would multiply by 100 twice.
    function test_readOldConfig_rejectsANonV024Source() public {
        ERC20PeriodicalStaking notLegacy = new ERC20PeriodicalStaking(address(token));
        vm.expectRevert(bytes("DeployV050: source is not a v0.2.4 ERC20PeriodicalStaking"));
        deployScript.readOldConfig(address(notLegacy));
    }

    function test_readOldConfig_rejectsAnAddressWithNoCode() public {
        vm.expectRevert(bytes("DeployV050: source staking contract has no code on this chain"));
        deployScript.readOldConfig(makeAddr("nothing"));
    }

    /// @notice The per-chain source table is the fallback when SOURCE_STAKING is unset. An unknown chain has
    ///         none, which is why resolveSourceStaking() insists on the variable there.
    function test_sourceStakingFor_knownChainsOnly() public {
        assertEq(deployScript.sourceStakingFor(137), 0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F, "polygon");
        assertEq(deployScript.sourceStakingFor(80002), 0x0d8ab209583050A9959322229A7c314c66e40E6f, "amoy");
        assertEq(deployScript.sourceStakingFor(1), address(0), "unknown chain has no entry");
        assertEq(deployScript.requirementCheckerV2For(137), 0x716ff1f64cC2B7c96ba9DDADfc08bB703F8bcA59, "rcv2 polygon");
        assertEq(deployScript.requirementCheckerV2For(1), address(0), "rcv2 unknown chain");
    }

    // ======================================
    // =              Helpers               =
    // ======================================

    mapping(address => LimitController) internal _sourceControllers;

    function sourceControllerOf(LegacyV024 s) internal view returns (LimitController) {
        return _sourceControllers[address(s)];
    }

    /// @dev A cheap digest of everything a resume could have rewritten.
    function _fingerprint(DeployV050.Deployment memory d) internal view returns (bytes32) {
        ERC20PeriodicalStaking s = d.staking;
        LimitController c = d.controller;
        uint256[] memory periods = s.getStakingPeriods();
        uint256 phases = s.stakingPhaseCount();

        // Encoded in chunks: one abi.encode with this many live locals is a stack-too-deep hazard.
        bytes memory blob = abi.encode(
            s.limitController(), s.voucherSigner(), s.treasury(), s.contractOwner(), s.pendingOwner()
        );
        blob = abi.encode(
            blob, s.maxExtraApyBps(), s.maxExtraLimitTotal(), s.maxExtraLimitPerCell(), s.maxVoucherValidity()
        );
        blob = abi.encode(blob, phases, s.currentStakingPhase(), s.minimumDeposit(), s.rewardPool(), periods);
        blob = abi.encode(
            blob,
            address(c.stakingContract()),
            address(c.legacyStakingContract()),
            c.owner(),
            c.pendingOwner()
        );
        for (uint256 ph = 0; ph < phases; ++ph) {
            for (uint256 i = 0; i < periods.length; ++i) {
                blob = abi.encode(
                    blob,
                    s.phasePeriodDataList(Types.PhasePeriodDataType.APY, ph, periods[i]),
                    s.phasePeriodDataList(Types.PhasePeriodDataType.STAKING_TARGET, ph, periods[i]),
                    c.defaultPhasePeriodLimit(ph, periods[i])
                );
            }
        }
        return keccak256(blob);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }
}
