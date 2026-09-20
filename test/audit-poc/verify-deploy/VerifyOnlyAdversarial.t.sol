// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployV050} from "../../../script/DeployV050.s.sol";
import {ERC20PeriodicalStaking} from "../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {LimitController} from "../../../src/contracts/LimitController.sol";
import {Types} from "../../../src/common/Types.sol";
import {TestToken} from "../../shared/TestToken.sol";

import {ERC20PeriodicalStaking as LegacyV024} from
    "../../erc20-periodical-staking/security/invariants/legacy/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";

/// @notice ADVERSARIAL verification of the v0.5.0 audit fixes. Written by a reviewer who did not write the
///         fixes: everything here tries to make a "closed" finding fail.
///
///         Covers the gaps left by test/v050/DeployV050Local.t.sol:
///          - verifyOnly() / VERIFY_ONLY (finding #13) had NO test at all;
///          - _applyWalletLimits (the rows path of deployFrom) had NO test at all;
///          - the role clashes _preflightRoles does NOT check.
contract VerifyOnlyAdversarialTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant TARGET = 1_000_000 * ONE;
    uint256 internal constant DEFAULT_LIMIT = 100_000 * ONE;

    DeployV050 internal deployScript;
    TestToken internal token;
    LegacyV024 internal source;
    LimitController internal sourceController;

    address internal voucherSigner = makeAddr("voucherSigner");
    address internal treasury = makeAddr("treasury");
    address internal newOwner = makeAddr("newOwner");
    address internal attacker = makeAddr("attacker");
    address internal adminA = makeAddr("adminA");

    uint256[] internal PERIODS = [uint256(0), 30];

    function setUp() public {
        token = new TestToken(18);
        deployScript = new DeployV050();
        source = new LegacyV024(address(token));
        uint256[] memory empty = new uint256[](0);
        source.addStakingPeriod(0, empty, empty);
        source.addStakingPeriod(30, empty, empty);
        uint256[] memory pct = new uint256[](2);
        pct[0] = 5;
        pct[1] = 10;
        source.pushStakingPhase(pct, _fill(2, TARGET));
        source.setMiniumumDeposit(500 * ONE);

        sourceController = new LimitController(address(source));
        sourceController.setDefaultLimit(0, 0, DEFAULT_LIMIT);
        sourceController.setDefaultLimit(0, 30, DEFAULT_LIMIT + ONE);
        source.setLimitController(address(sourceController));
    }

    function _params() internal view returns (DeployV050.Params memory p) {
        address[] memory admins = new address[](1);
        admins[0] = adminA;
        p = DeployV050.Params({
            sourceStaking: address(source),
            requirementCheckerV2: address(0),
            voucherSigner: voucherSigner,
            treasury: treasury,
            maxExtraApyBps: 2_000,
            maxExtraLimitTotal: 50_000 * ONE,
            maxExtraLimitPerCell: 50_000 * ONE,
            maxVoucherValidity: 1_800,
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

    function _fill(uint256 n, uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = v;
        }
    }

    // ======================================================================
    // = #13 VERIFY_ONLY: the relaxed owner check must not accept a WRONG owner
    // ======================================================================

    /// @notice THE question finding #13 has to answer: can verify-only pass a deployment whose ownership went to
    ///         the wrong address? Hand the controller to an attacker who accepts, then verify.
    function test_verifyOnly_rejectsControllerOwnedByTheWrongAddress() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        // The deployer fat-fingers the controller to the attacker, who accepts.
        vm.prank(address(deployScript));
        d.controller.transferOwnership(attacker);
        vm.prank(attacker);
        d.controller.acceptOwnership();
        assertEq(d.controller.owner(), attacker, "attacker owns the controller");

        vm.expectRevert(bytes("check: controller ownership"));
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice Same for the staking contract.
    function test_verifyOnly_rejectsStakingOwnedByTheWrongAddress() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        vm.prank(address(deployScript));
        d.staking.transferOwnership(attacker);
        vm.prank(attacker);
        d.staking.acceptOwnership();

        vm.expectRevert(bytes("check: staking ownership"));
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice A WRONG PENDING owner (typo at nomination time, nobody has accepted) must also fail.
    function test_verifyOnly_rejectsWrongPendingOwner() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        // Re-point the nomination to the attacker without accepting.
        vm.prank(address(deployScript));
        d.controller.transferOwnership(attacker);

        vm.expectRevert(bytes("check: controller ownership"));
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice Verify-only must work BEFORE acceptOwnership (the nominated stage).
    function test_verifyOnly_passesBeforeAcceptance() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice ...and AFTER it (the accepted stage, on both contracts).
    function test_verifyOnly_passesAfterAcceptanceOnBoth() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        vm.prank(newOwner);
        d.staking.acceptOwnership();
        vm.prank(newOwner);
        d.controller.acceptOwnership();

        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice GAP CLOSED: a HALF-finished hand-off (staking accepted, controller still pending) used to pass
    ///         verify-only, because each contract was judged on its own. The two contracts must now be at the
    ///         SAME stage, so verify-only is the check that the operator did not forget the second
    ///         acceptOwnership() -- exactly the mistake the two-step change makes possible.
    function test_verifyOnly_rejectsAHalfFinishedHandoff_stakingAccepted() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        vm.prank(newOwner);
        d.staking.acceptOwnership();
        assertEq(d.controller.owner(), address(deployScript), "controller NOT handed over");

        vm.expectRevert(
            bytes(
                "check: half-finished hand-off - NEW_OWNER accepted ONE contract, not both. Call acceptOwnership() on the other (see the two lines above) and re-run --verify-only"
            )
        );
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice ...and the mirror image: controller accepted, staking still pending.
    function test_verifyOnly_rejectsAHalfFinishedHandoff_controllerAccepted() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        vm.prank(newOwner);
        d.controller.acceptOwnership();
        assertEq(d.staking.contractOwner(), address(deployScript), "staking NOT handed over");

        vm.expectRevert(
            bytes(
                "check: half-finished hand-off - NEW_OWNER accepted ONE contract, not both. Call acceptOwnership() on the other (see the two lines above) and re-run --verify-only"
            )
        );
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice Loud failure when the addresses hold no code.
    function test_verifyOnly_failsOnAddressesWithNoCode() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        vm.expectRevert(bytes("DeployV050: VERIFY_STAKING has no code on this chain"));
        deployScript.verifyOnly(
            o, p, _noRows(), makeAddr("nothing"), address(d.controller), address(deployScript)
        );

        vm.expectRevert(bytes("DeployV050: VERIFY_CONTROLLER has no code on this chain"));
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), makeAddr("nothing2"), address(deployScript)
        );

        vm.expectRevert(bytes("DeployV050: DEPLOYER_ADDRESS must be non-zero"));
        deployScript.verifyOnly(o, p, _noRows(), address(d.staking), address(d.controller), address(0));
    }

    /// @notice The two addresses must not be swapped: VERIFY_STAKING/VERIFY_CONTROLLER the wrong way round must
    ///         fail rather than half-pass.
    function test_verifyOnly_failsWhenTheTwoAddressesAreSwapped() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        vm.expectRevert();
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.controller), address(d.staking), address(deployScript)
        );
    }

    /// @notice The reward-pool comparison: REWARD_TOP_UP requested but the pool is empty on chain must fail.
    function test_verifyOnly_rewardPoolZeroWithATopUpRequestedFails() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        // The deployment ran with no top-up; the operator's env file says there was one.
        p.rewardTopUp = 10_000 * ONE;
        vm.expectRevert(bytes("check: REWARD_TOP_UP requested but the reward pool is 0"));
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice OPS FOOTGUN CLOSED: the pool check was `!= 0`, so 1 wei satisfied a REWARD_TOP_UP of 10,000
    ///         tokens and the shortfall was a console warning only. It is now `rewardPool() >= REWARD_TOP_UP`.
    function test_verifyOnly_rejectsAPoolOfOneWeiAgainstAHugeTopUp() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        token.transfer(address(deployScript), 1);
        vm.startPrank(address(deployScript));
        token.approve(address(d.staking), 1);
        d.staking.provideReward(1);
        vm.stopPrank();
        assertEq(d.staking.rewardPool(), 1, "pool is 1 wei");

        p.rewardTopUp = 10_000 * ONE;
        vm.expectRevert(
            bytes(
                "check: reward pool is BELOW REWARD_TOP_UP (see the shortfall above). Fund it, or set REWARD_TOP_UP=0 for verify-only once rewards have been paid out"
            )
        );
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice A pool that EXACTLY meets REWARD_TOP_UP passes (the boundary is >=, not >).
    function test_verifyOnly_acceptsAPoolThatExactlyMeetsTheTopUp() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        uint256 topUp = 10_000 * ONE;
        token.transfer(address(deployScript), topUp);
        vm.startPrank(address(deployScript));
        token.approve(address(d.staking), topUp);
        d.staking.provideReward(topUp);
        vm.stopPrank();

        p.rewardTopUp = topUp;
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice OPS FOOTGUN CLOSED: verify-only used to compare LIVE, admin-mutable availability flags against
    ///         the env file, so opening staking after the deploy -- the last documented hand-off step -- made
    ///         every later verify-only run revert on a perfectly healthy deployment. Availability is now
    ///         informational in verify-only mode (logged, not fatal).
    function test_verifyOnly_stillPassesOnceOpsOpensStaking() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );

        vm.prank(address(deployScript));
        d.staking.changeActionAvailability(Types.DataType.STAKING, true);
        assertTrue(d.staking.checkActionAvailability(Types.DataType.STAKING), "ops opened staking");
        assertFalse(p.openStaking, "...while the env file still says OPEN_STAKING=false");

        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    /// @notice The relaxation is scoped to availability and to verify-only ONLY: the deploy-time self-check
    ///         still treats a STAKING availability mismatch as fatal, and verify-only still compares every
    ///         immutable/critical setting strictly. Proven here on the treasury.
    function test_verifyOnly_stillRejectsAWrongTreasury() public {
        DeployV050.Params memory p = _params();
        (DeployV050.OldConfig memory o, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        p.treasury = attacker;
        vm.expectRevert(bytes("check: treasury"));
        deployScript.verifyOnly(
            o, p, _noRows(), address(d.staking), address(d.controller), address(deployScript)
        );
    }

    // ======================================================================
    // = #31a role clashes _preflightRoles does NOT catch
    // ======================================================================

    /// @notice GAP CLOSED: TREASURY == an address in ADMINS is now a clash. A contract admin can freeze and
    ///         seize deposits, and the treasury is where seized funds land, so one compromised admin key would
    ///         both take the funds and receive them.
    function test_preflightRoles_rejectsTreasuryEqualsAnAdmin() public {
        DeployV050.Params memory p = _params();
        p.treasury = adminA; // adminA is in p.admins
        assertFalse(p.allowSharedRoles, "shared roles NOT allowed");

        vm.expectRevert(
            bytes("DeployV050: TREASURY equals an address in ADMINS (one address per role; ALLOW_SHARED_ROLES=true overrides)")
        );
        deployScript.deployFrom(p, _noRows());
    }

    /// @notice ...and ALLOW_SHARED_ROLES=true is still the documented override for it (testnets).
    function test_preflightRoles_treasuryEqualsAnAdmin_allowedWithTheOverride() public {
        DeployV050.Params memory p = _params();
        p.treasury = adminA;
        p.allowSharedRoles = true;

        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());
        assertEq(d.staking.treasury(), adminA, "deployed with treasury == admin");
        assertTrue(d.staking.contractAdmins(adminA), "same address is also an admin");
    }

    /// @notice GAP CLOSED: TREASURY == NEW_OWNER is a clash too. The owner can already move everything; making
    ///         it the seizure destination removes the last separation between the two.
    function test_preflightRoles_rejectsTreasuryEqualsNewOwner() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;
        p.treasury = newOwner;

        vm.expectRevert(
            bytes("DeployV050: TREASURY equals NEW_OWNER (one address per role; ALLOW_SHARED_ROLES=true overrides)")
        );
        deployScript.deployFrom(p, _noRows());
    }

    /// @notice A treasury that is neither an admin nor NEW_OWNER is untouched by the two new clashes.
    function test_preflightRoles_acceptsADistinctTreasury() public {
        DeployV050.Params memory p = _params();
        p.newOwner = newOwner;

        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());
        assertEq(d.staking.treasury(), treasury, "distinct treasury deployed");
    }

    /// @notice NOT a gap (hypothesis disproved): NEW_OWNER == the deployer is already rejected by a separate
    ///         pre-existing preflight check, so a self-nomination cannot slip through as a "completed" hand-off.
    function test_preflight_rejectsNewOwnerEqualToTheDeployer() public {
        DeployV050.Params memory p = _params();
        p.newOwner = address(deployScript);

        vm.expectRevert(bytes("DeployV050: NEW_OWNER equals the deployer, leave it unset"));
        deployScript.deployFrom(p, _noRows());
    }

    /// @notice Duplicate entries in ADMINS stay NON-FATAL by design (addContractAdmin is guarded by the
    ///         `if (!contractAdmins(..))` check, so they are harmless) but the preflight now prints a
    ///         "WARNING: ADMINS lists the same address more than once" line so the operator is told. The
    ///         deployment must still succeed, which is what this asserts.
    function test_preflightRoles_duplicateAdminsAreWarnedButNotFatal() public {
        DeployV050.Params memory p = _params();
        address[] memory admins = new address[](3);
        admins[0] = adminA;
        admins[1] = adminA;
        admins[2] = adminA;
        p.admins = admins;

        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());
        assertTrue(d.staking.contractAdmins(adminA), "admin set once");
    }

    /// @notice The post-deploy treasury assertion DOES run: it is the only thing standing between the operator
    ///         and a treasury pointed at the freshly deployed LimitController, which _preflightRoles cannot
    ///         check because that address does not exist yet. Proven by pointing TREASURY at a controller that
    ///         a resume then reuses.
    function test_postDeployTreasuryCheck_runsAgainstTheReusedController() public {
        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, _noRows());

        p.resumeStaking = address(d.staking);
        p.resumeController = address(d.controller);
        p.treasury = address(d.controller);

        vm.expectRevert(bytes("check: treasury is the new LimitController"));
        deployScript.deployFrom(p, _noRows());
    }

    // ======================================================================
    // = deployFrom: the wallet-limits rows path (untested by DeployV050Local)
    // ======================================================================

    /// @notice _applyWalletLimits had no test. Rows are batched per (phase, period) run; a run that is NOT
    ///         grouped must still land every row correctly.
    function test_applyWalletLimits_writesEveryRowIncludingUngroupedOnes() public {
        address w1 = makeAddr("w1");
        address w2 = makeAddr("w2");

        DeployV050.WalletLimitRow[] memory rows = new DeployV050.WalletLimitRow[](4);
        // Deliberately interleaved so the per-(phase,period) run batching is exercised at length 1.
        rows[0] = DeployV050.WalletLimitRow({wallet: w1, phase: 0, period: 0, limit: 1 * ONE});
        rows[1] = DeployV050.WalletLimitRow({wallet: w2, phase: 0, period: 30, limit: 2 * ONE});
        rows[2] = DeployV050.WalletLimitRow({wallet: w1, phase: 0, period: 30, limit: 3 * ONE});
        rows[3] = DeployV050.WalletLimitRow({wallet: w2, phase: 0, period: 0, limit: 4 * ONE});

        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, rows);
        LimitController c = d.controller;

        assertEq(c.walletPhasePeriodLimit(w1, 0, 0), 1 * ONE, "w1/0/0");
        assertEq(c.walletPhasePeriodLimit(w2, 0, 30), 2 * ONE, "w2/0/30");
        assertEq(c.walletPhasePeriodLimit(w1, 0, 30), 3 * ONE, "w1/0/30");
        assertEq(c.walletPhasePeriodLimit(w2, 0, 0), 4 * ONE, "w2/0/0");
        assertTrue(c.hasWalletLimit(w1, 0, 0), "w1/0/0 set");
        assertTrue(c.hasWalletLimit(w2, 0, 0), "w2/0/0 set");
    }

    /// @notice ...and a resume with the SAME rows must write nothing (the dedupe in _applyWalletLimits).
    function test_applyWalletLimits_resumeWithTheSameRowsWritesNothing() public {
        address w1 = makeAddr("w1");
        DeployV050.WalletLimitRow[] memory rows = new DeployV050.WalletLimitRow[](2);
        rows[0] = DeployV050.WalletLimitRow({wallet: w1, phase: 0, period: 0, limit: 7 * ONE});
        rows[1] = DeployV050.WalletLimitRow({wallet: w1, phase: 0, period: 30, limit: 8 * ONE});

        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, rows);

        p.resumeStaking = address(d.staking);
        p.resumeController = address(d.controller);

        vm.recordLogs();
        deployScript.deployFrom(p, rows);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 writes;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(d.controller) || logs[i].emitter == address(d.staking)) ++writes;
        }
        assertEq(writes, 0, "a resume with identical wallet limits must emit nothing");
        assertEq(d.controller.walletPhasePeriodLimit(w1, 0, 0), 7 * ONE, "unchanged");
    }

    /// @notice A CHANGED wallet limit on a resume is rewritten (the dedupe compares the value, not just
    ///         presence). This is what lets ops correct a bad row by re-running with an edited CSV.
    function test_applyWalletLimits_resumeRewritesAChangedRow() public {
        address w1 = makeAddr("w1");
        DeployV050.WalletLimitRow[] memory rows = new DeployV050.WalletLimitRow[](1);
        rows[0] = DeployV050.WalletLimitRow({wallet: w1, phase: 0, period: 0, limit: 7 * ONE});

        DeployV050.Params memory p = _params();
        (, DeployV050.Deployment memory d) = deployScript.deployFrom(p, rows);

        rows[0].limit = 9 * ONE;
        p.resumeStaking = address(d.staking);
        p.resumeController = address(d.controller);
        deployScript.deployFrom(p, rows);

        assertEq(d.controller.walletPhasePeriodLimit(w1, 0, 0), 9 * ONE, "corrected row applied");
    }

    // ======================================================================
    // = #12/#40 no inherited OZ path can leave the controller ownerless
    // ======================================================================

    /// @notice transferOwnership(address(0)) only CANCELS a nomination in Ownable2Step -- it cannot hand the
    ///         contract to nobody, because acceptOwnership can never be called by address(0).
    function test_controller_transferToZeroCannotStrandIt() public {
        LimitController c = new LimitController(address(source));
        c.transferOwnership(address(0));
        assertEq(c.pendingOwner(), address(0), "nomination cleared");
        assertEq(c.owner(), address(this), "still owned");

        // No caller can accept a zero nomination.
        vm.prank(attacker);
        vm.expectRevert();
        c.acceptOwnership();
        assertEq(c.owner(), address(this), "still owned after a stranger tries");
    }

    /// @notice renounceOwnership is dead on every calling path, including a low-level call that ignores the
    ///         Solidity interface.
    function test_controller_renounceIsDeadEvenViaRawCall() public {
        LimitController c = new LimitController(address(source));
        (bool ok,) = address(c).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "renounceOwnership must revert even from a raw call");
        assertEq(c.owner(), address(this), "still owned");

        vm.prank(attacker);
        (bool ok2,) = address(c).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok2, "and from a stranger");
        assertEq(c.owner(), address(this), "still owned");
    }

}
