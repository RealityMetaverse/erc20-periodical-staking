// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Handler} from "./Handler.sol";
import {TestToken} from "../../../shared/TestToken.sol";
import {ERC20PeriodicalStaking} from
    "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Errors} from "../../../../src/common/Errors.sol";
import {Types} from "../../../../src/common/Types.sol";

/// @title InvariantBase
/// @notice Shared plumbing + invariant checks for the ERC20PeriodicalStaking invariant suites.
/// @dev The vendored forge-std (1.2.0) predates StdInvariant, so the invariant-runner discovery hooks
///      (`targetContracts`, `targetSelectors`) are implemented here with the ABI shape the
///      forge invariant runner expects. Every check is an internal function so that the two
///      concrete suites can expose different subsets as `invariant_*` entrypoints.
abstract contract InvariantBase is Test {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    Handler internal handler;
    ERC20PeriodicalStaking internal staking;
    TestToken internal token;
    address internal owner;
    address internal admin;

    address[] internal _targets;
    FuzzSelector[] internal _selectors;

    uint256 internal constant LIVENESS_TOPUP = 1_000_000_000e18;

    // ======================================
    // =        Fuzzer discovery hooks      =
    // ======================================
    function targetContracts() external view returns (address[] memory) {
        return _targets;
    }

    function targetSelectors() external view returns (FuzzSelector[] memory) {
        return _selectors;
    }

    // ======================================
    // =               Setup                =
    // ======================================
    /// @param legacy true = fuzz the mirrored v0.2.4 code (must fail), false = fuzz src (must pass).
    function _deploy(bool legacy) internal {
        handler = new Handler(legacy);
        staking = handler.staking();
        token = handler.token();
        owner = handler.owner();
        admin = handler.admin();
        _targets.push(address(handler));
    }

    function _target(bytes4[] memory selectors) internal {
        _selectors.push(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ======================================
    // =            Data helpers            =
    // ======================================
    function _dataTypes() internal pure returns (Types.DataType[6] memory dts) {
        dts = [
            Types.DataType.STAKING,
            Types.DataType.WITHDRAWAL,
            Types.DataType.CLAIM,
            Types.DataType.REWARD_EXPECTED,
            Types.DataType.REWARD_PROVIDED,
            Types.DataType.REWARD_COLLECTED
        ];
    }

    function _isOpen(ProgramManager.DepositStatus st) internal pure returns (bool) {
        return st == ProgramManager.DepositStatus.TIME_LEFT || st == ProgramManager.DepositStatus.READY_TO_CLAIM
            || st == ProgramManager.DepositStatus.INDEFINITE;
    }

    /// @dev Inside a snapshot: reopen withdraw/claim and fund the pool massively so that the only
    ///      thing that can stop a deposit from closing is the contract's own accounting.
    function _makeClosableEnvironment() internal {
        vm.startPrank(owner);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, true);
        staking.changeActionAvailability(Types.DataType.CLAIM, true);
        vm.stopPrank();

        deal(address(token), admin, LIVENESS_TOPUP);
        vm.startPrank(admin);
        token.approve(address(staking), type(uint256).max);
        staking.provideReward(LIVENESS_TOPUP);
        vm.stopPrank();
    }

    // ======================================
    // =            Invariant checks        =
    // ======================================

    /// @dev Contract balance == staked principal + reward pool, exactly, plus whatever was donated straight
    ///      to the contract and not yet rescued. No dust, no orphaned tokens, and rescue can never dip
    ///      into principal or the pool.
    function _check_tokenConservation() internal {
        uint256 bal = token.balanceOf(address(staking));
        uint256 staked = staking.totalDataList(Types.DataType.STAKING);
        uint256 pool = staking.rewardPool();
        uint256 unrescuedDonations = handler.ghost_donated() - handler.ghost_rescued();
        assertEq(
            bal,
            staked + pool + unrescuedDonations,
            "balanceOf(staking) != totalDataList[STAKING] + rewardPool + (donated - rescued)"
        );
    }

    /// @dev Cross-check of the same quantity against handler token-flow ghosts.
    function _check_tokenFlowGhosts() internal {
        uint256 bal = token.balanceOf(address(staking));
        uint256 expectedBal = handler.ghost_userIn() + handler.ghost_provided() + handler.ghost_donated()
            - handler.ghost_userOut() - handler.ghost_collected() - handler.ghost_rescued();
        assertEq(
            bal, expectedBal, "balanceOf(staking) != userIn + provided + donated - userOut - collected - rescued (ghost)"
        );
        assertEq(
            staking.totalDataList(Types.DataType.STAKING),
            handler.ghost_userIn() - handler.ghost_principalPaid(),
            "totalDataList[STAKING] != userIn - principalPaid (ghost)"
        );
    }

    /// @dev Reserve properties (a)+(b), recorded by the handler at call time: no successful collectReward exceeded
    ///      getCollectableReward(), and no user payout took rewardPool from >= REWARD_EXPECTED to below it.
    ///      (`rewardPool >= REWARD_EXPECTED` itself is no longer an invariant: stakes are never blocked by
    ///      pool state, so the pool may legitimately be short until the owner tops up.)
    function _check_reserveRespected() internal {
        uint256 n = handler.ghost_reserveViolations();
        string memory notes;
        uint256 shown = handler.reserveViolationNoteCount();
        for (uint256 i = 0; i < shown && i < 5; i++) {
            notes = string.concat(notes, " | ", handler.ghost_reserveViolationNotes(i));
        }
        assertEq(n, 0, string.concat("reserve violations:", notes));
    }

    function _selectorOf(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(reason, 32))
        }
    }

    /// @dev rewardPool only moves through provideReward (+), collectReward (-) and reward payouts (-).
    function _check_rewardPoolAccounting() internal {
        uint256 expected = handler.ghost_provided() - handler.ghost_collected() - handler.ghost_rewardsPaid();
        assertEq(staking.rewardPool(), expected, "rewardPool != provided - collected - rewardsPaid (ghost)");
    }

    /// @dev For every DataType, sum of per-user data over all actors == the global total.
    function _check_userSumsMatchTotals() internal {
        address[] memory actors = handler.getActors();
        Types.DataType[6] memory dts = _dataTypes();
        for (uint256 t = 0; t < dts.length; t++) {
            uint256 sum;
            for (uint256 i = 0; i < actors.length; i++) {
                sum += staking.userDataList(dts[t], actors[i]);
            }
            assertEq(
                sum,
                staking.totalDataList(dts[t]),
                string.concat("sum(userDataList) != totalDataList for DataType ", vm.toString(t))
            );
        }
    }

    /// @dev Sum of phasePeriodDataList[STAKED] over every phase/period that ever existed == total staked.
    function _check_phasePeriodStakedSum() internal {
        uint256[] memory periods = handler.getEverSeenPeriods();
        uint256 phases = handler.ghost_maxPhaseCount();
        uint256 sum;
        for (uint256 p = 0; p < phases; p++) {
            for (uint256 k = 0; k < periods.length; k++) {
                sum += staking.getPhasePeriodData(Types.PhasePeriodDataType.STAKED, p, periods[k]);
            }
        }
        assertEq(sum, staking.totalDataList(Types.DataType.STAKING), "sum(phasePeriod STAKED) != totalDataList[STAKING]");
    }

    /// @dev Per user: sum over (phase, period) of userPhasePeriodDataList[t] == userDataList[t]
    ///      for STAKING, REWARD_EXPECTED, WITHDRAWAL, CLAIM.
    function _check_userPhasePeriodSums() internal {
        address[] memory users = handler.getUsers();
        uint256[] memory periods = handler.getEverSeenPeriods();
        uint256 phases = handler.ghost_maxPhaseCount();
        Types.DataType[4] memory dts =
            [Types.DataType.STAKING, Types.DataType.REWARD_EXPECTED, Types.DataType.WITHDRAWAL, Types.DataType.CLAIM];

        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 t = 0; t < dts.length; t++) {
                uint256 sum;
                for (uint256 p = 0; p < phases; p++) {
                    for (uint256 k = 0; k < periods.length; k++) {
                        sum += staking.userPhasePeriodDataList(dts[t], p, periods[k], users[u]);
                    }
                }
                assertEq(
                    sum,
                    staking.userDataList(dts[t], users[u]),
                    string.concat(
                        "sum(userPhasePeriodDataList) != userDataList for user ",
                        vm.toString(users[u]),
                        " DataType ",
                        vm.toString(uint256(dts[t]))
                    )
                );
            }
        }
    }

    /// @dev totalDataList[REWARD_EXPECTED] == sum of rewardGenerated over every OPEN periodical deposit
    ///      (withdrawalDate == 0 && stakingEndDate != 0). Also the per-user version.
    function _check_rewardExpectedMatchesOpenDeposits() internal {
        address[] memory users = handler.getUsers();
        uint256 total;
        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            uint256 userSum;
            for (uint256 i = 0; i < count; i++) {
                ProgramManager.TokenDeposit memory d = staking.getDeposit(users[u], i);
                if (d.withdrawalDate == 0 && d.stakingEndDate != 0) userSum += d.rewardGenerated;
            }
            assertEq(
                staking.userDataList(Types.DataType.REWARD_EXPECTED, users[u]),
                userSum,
                string.concat("userDataList[REWARD_EXPECTED] != sum(open deposits) for ", vm.toString(users[u]))
            );
            total += userSum;
        }
        assertEq(
            staking.totalDataList(Types.DataType.REWARD_EXPECTED),
            total,
            "totalDataList[REWARD_EXPECTED] != sum(rewardGenerated of open periodical deposits)"
        );
    }

    /// @dev LIVENESS (known-incident detector): every open deposit can be closed once matured, with
    ///      actions open and the pool funded. Any revert here means principal is locked.
    function _check_everyOpenDepositIsClosable() internal {
        address[] memory users = handler.getUsers();
        uint256 ts = handler.currentTime(); // external call: immune to via_ir timestamp rematerialization
        string memory failures;
        uint256 failureCount;

        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            for (uint256 i = 0; i < count; i++) {
                if (!_isOpen(staking.checkDepositStatus(users[u], i))) continue;

                uint256 snap = vm.snapshot();
                _makeClosableEnvironment();
                ProgramManager.TokenDeposit memory d = staking.getDeposit(users[u], i);
                if (d.stakingEndDate != 0 && block.timestamp < d.stakingEndDate) vm.warp(d.stakingEndDate);

                bytes memory reason;
                bool ok;
                vm.prank(users[u]);
                if (d.stakingEndDate == 0) {
                    try staking.withdrawDeposit(i) {
                        ok = true;
                    } catch (bytes memory r) {
                        reason = r;
                    }
                } else {
                    try staking.claimDeposit(i) {
                        ok = true;
                    } catch (bytes memory r) {
                        reason = r;
                    }
                }
                if (!ok) {
                    failureCount++;
                    failures = string.concat(
                        failures,
                        " [user=",
                        vm.toString(users[u]),
                        " deposit=",
                        vm.toString(i),
                        " phase=",
                        vm.toString(d.stakingPhase),
                        " period=",
                        vm.toString(d.stakingPeriod),
                        " reason=",
                        vm.toString(reason),
                        "]"
                    );
                }
                vm.revertTo(snap);
                vm.warp(ts);
            }
        }
        assertEq(failureCount, 0, string.concat("LOCKED DEPOSITS:", failures));
    }

    /// @dev Reserve property (c): every open PERIODICAL deposit can be claimed at maturity WITHOUT anyone topping up
    ///      the pool whenever `rewardPool >= REWARD_EXPECTED` at check time (only actions are reopened).
    ///      When the pool is short, a claim may fail, but ONLY with `NotEnoughFundsInRewardPool`, only when the
    ///      deposit's own reward exceeds the pool, and never with a panic or any other error.
    function _check_maturedDepositsClaimableWithoutTopUp() internal {
        address[] memory users = handler.getUsers();
        uint256 ts = handler.currentTime();
        uint256 pool = staking.rewardPool();
        bool covered = pool >= staking.totalDataList(Types.DataType.REWARD_EXPECTED);
        string memory failures;
        uint256 failureCount;

        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            for (uint256 i = 0; i < count; i++) {
                ProgramManager.TokenDeposit memory d = staking.getDeposit(users[u], i);
                if (d.withdrawalDate != 0 || d.stakingEndDate == 0) continue; // closed or indefinite

                uint256 snap = vm.snapshot();
                vm.prank(owner);
                staking.changeActionAvailability(Types.DataType.CLAIM, true);
                if (block.timestamp < d.stakingEndDate) vm.warp(d.stakingEndDate);

                bytes memory reason;
                bool ok;
                vm.prank(users[u]);
                try staking.claimDeposit(i) {
                    ok = true;
                } catch (bytes memory r) {
                    reason = r;
                }
                // With a short pool the only acceptable failure is the typed "pool short" revert, and only
                // when this deposit's reward really exceeds the pool (never a panic, never anything else).
                bool acceptable = !covered && d.rewardGenerated > pool
                    && _selectorOf(reason) == Errors.NotEnoughFundsInRewardPool.selector;
                if (!ok && !acceptable) {
                    failureCount++;
                    failures = string.concat(
                        failures,
                        " [user=",
                        vm.toString(users[u]),
                        " deposit=",
                        vm.toString(i),
                        " reward=",
                        vm.toString(d.rewardGenerated),
                        " rewardPool=",
                        vm.toString(pool),
                        " reserved=",
                        vm.toString(staking.totalDataList(Types.DataType.REWARD_EXPECTED)),
                        " reason=",
                        vm.toString(reason),
                        "]"
                    );
                }
                vm.revertTo(snap);
                vm.warp(ts);
            }
        }
        assertEq(
            failureCount,
            0,
            string.concat(
                covered
                    ? "MATURED DEPOSITS NOT CLAIMABLE WITHOUT TOP-UP:"
                    : "MATURED CLAIM ON A SHORT POOL FAILED OTHER THAN NotEnoughFundsInRewardPool:",
                failures
            )
        );
    }

    /// @dev stakerActiveDepositStartIndex[user] <= depositCount, and nothing before it is open.
    function _check_activeStartIndex() internal {
        address[] memory users = handler.getUsers();
        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            uint256 start = staking.stakerActiveDepositStartIndex(users[u]);
            assertLe(start, count, "stakerActiveDepositStartIndex > depositCount");
            for (uint256 i = 0; i < start && i < count; i++) {
                assertFalse(
                    _isOpen(staking.checkDepositStatus(users[u], i)),
                    string.concat(
                        "open deposit below stakerActiveDepositStartIndex: user=",
                        vm.toString(users[u]),
                        " idx=",
                        vm.toString(i)
                    )
                );
            }
        }
    }

    /// @dev stakingPeriodList strictly ascending (no duplicates); currentStakingPhase valid.
    function _check_periodListAndPhaseIndex() internal {
        uint256[] memory periods = staking.getStakingPeriods();
        for (uint256 i = 1; i < periods.length; i++) {
            assertLt(periods[i - 1], periods[i], "stakingPeriodList not strictly ascending");
        }
        for (uint256 i = 0; i < periods.length; i++) {
            assertTrue(staking.checkIfStakingPeriodExists(periods[i]), "listed period reported as non-existent");
        }
        uint256 phaseCount = staking.stakingPhaseCount();
        if (phaseCount > 0) {
            assertLt(staking.currentStakingPhase(), phaseCount, "currentStakingPhase >= stakingPhaseCount");
        }
    }

    /// @dev checkClaimableDataFor(user) must equal what claimAll actually pays (with a funded pool).
    function _check_claimableDataMatchesPayout() internal {
        address[] memory users = handler.getUsers();
        uint256 ts = handler.currentTime(); // external call: immune to via_ir timestamp rematerialization
        for (uint256 u = 0; u < users.length; u++) {
            if (staking.checkDepositCountOfAddress(users[u]) == 0) continue;
            uint256 snap = vm.snapshot();
            _makeClosableEnvironment();

            (uint256 cStaking, uint256 cPeriodical, uint256 cIndefinite) = staking.checkClaimableDataFor(users[u]);
            uint256 balBefore = token.balanceOf(users[u]);
            bool ok;
            bytes memory reason;
            vm.prank(users[u]);
            try staking.claimAll() {
                ok = true;
            } catch (bytes memory r) {
                reason = r;
            }
            uint256 got = token.balanceOf(users[u]) - balBefore;
            vm.revertTo(snap);
            vm.warp(ts);

            assertTrue(
                ok, string.concat("claimAll reverted for ", vm.toString(users[u]), ": ", vm.toString(reason))
            );
            assertEq(
                got,
                cStaking + cPeriodical + cIndefinite,
                string.concat("claimAll payout != checkClaimableDataFor for ", vm.toString(users[u]))
            );
        }
    }

    /// @dev Per-action payout reconciliation recorded by the handler.
    function _check_payoutCommitments() internal {
        uint256 n = handler.ghost_payoutViolations();
        string memory notes;
        uint256 shown = handler.payoutViolationNoteCount();
        for (uint256 i = 0; i < shown && i < 5; i++) {
            notes = string.concat(notes, " | ", handler.ghost_payoutViolationNotes(i));
        }
        assertEq(n, 0, string.concat("payout violations:", notes));
    }

    /// @dev actionAvailability mirror.
    function _check_actionAvailability() internal {
        for (uint256 a = 0; a < 3; a++) {
            assertEq(
                staking.checkActionAvailability(Types.DataType(a)),
                handler.ghost_actionOpen(a),
                string.concat("actionAvailability mismatch for DataType ", vm.toString(a))
            );
        }
    }

    /// @dev Handler saw a revert it could not explain (panics included).
    function _check_noUnexpectedReverts() internal {
        uint256 n = handler.unexpectedRevertCount();
        string memory notes;
        for (uint256 i = 0; i < n && i < 5; i++) {
            notes = string.concat(notes, " | ", handler.ghost_unexpectedReverts(i));
        }
        assertEq(n, 0, string.concat("unexpected reverts:", notes));
    }

    /// @dev Reserved reward per user never exceeds what that user's open deposits could pay out, and
    ///      is zero for users with no open periodical deposit.
    function _check_noPhantomReservations() internal {
        address[] memory users = handler.getUsers();
        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            bool hasOpenPeriodical;
            for (uint256 i = 0; i < count; i++) {
                ProgramManager.TokenDeposit memory d = staking.getDeposit(users[u], i);
                if (d.withdrawalDate == 0 && d.stakingEndDate != 0) {
                    hasOpenPeriodical = true;
                    break;
                }
            }
            if (!hasOpenPeriodical) {
                assertEq(
                    staking.userDataList(Types.DataType.REWARD_EXPECTED, users[u]),
                    0,
                    string.concat("phantom REWARD_EXPECTED reservation for ", vm.toString(users[u]))
                );
            }
        }
    }
}
