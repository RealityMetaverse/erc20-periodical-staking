// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {InvariantBase} from "./InvariantBase.sol";
import {Handler} from "./Handler.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Errors} from "../../../../src/common/Errors.sol";
import {Types} from "../../../../src/common/Types.sol";

/// @notice Freeze / seize checks shared by the src invariant suites (v0.4.0).
/// @dev Checks that open a snapshot collect failures and assert only after vm.revertTo: the vendored ds-test
///      records a failed assertion in storage, which a revertTo would silently undo.
abstract contract EnforcementInvariantChecks is InvariantBase {
    /// @dev The treasury only ever receives seized funds, and every seized token is principal (seize never pays a
    ///      reward).
    function _check_treasuryReceivesOnlySeizedFunds() internal {
        assertEq(
            token.balanceOf(staking.treasury()),
            handler.ghost_seizedOut(),
            "treasury balance != total seized (ghost)"
        );
        assertEq(handler.ghost_seizedOut(), handler.ghost_seizedPrincipal(), "seizedOut != seizedPrincipal");
    }

    /// @dev Flag consistency: a frozen deposit is always open; a SEIZED deposit is closed (withdrawalDate != 0)
    ///      and no longer frozen. Seized deposits never hold a REWARD_EXPECTED reservation (checked by
    ///      _check_rewardExpectedMatchesOpenDeposits, which counts only withdrawalDate == 0).
    function _check_freezeSeizeStateConsistency() internal {
        address[] memory users = handler.getUsers();
        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            for (uint256 i = 0; i < count; i++) {
                ProgramManager.DepositStatus st = staking.checkDepositStatus(users[u], i);
                bool frozen = staking.isDepositFrozen(users[u], i);
                if (frozen) {
                    assertTrue(_isOpen(st), "frozen deposit is not open");
                }
                if (st == ProgramManager.DepositStatus.SEIZED) {
                    assertFalse(frozen, "seized deposit still frozen");
                    assertTrue(staking.getDeposit(users[u], i).withdrawalDate != 0, "seized deposit has no close date");
                }
            }
        }
    }

    /// @dev SOLVENCY of the enforcement path: every frozen deposit can be seized right now, with every user action
    ///      closed and WITHOUT a pool top-up. The treasury receives exactly the principal and rewardPool does not
    ///      move (periodical reservation released, indefinite accrual stays in the pool). Afterwards the deposit is
    ///      SEIZED, its STAKING cell has shrunk by the principal, token conservation and the reward reservation
    ///      still reconcile, and it can be neither seized again, claimed nor withdrawn.
    function _check_everyFrozenDepositSeizableWithoutTopUp() internal {
        address[] memory users = handler.getUsers();
        uint256 ts = handler.currentTime();
        address treasury = staking.treasury();
        string memory failures;
        uint256 failureCount;

        // Every user action is closed once; every seize trial starts from that `env` snapshot.
        uint256 pre = vm.snapshot();
        vm.startPrank(owner);
        staking.changeActionAvailability(Types.DataType.STAKING, false);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, false);
        staking.changeActionAvailability(Types.DataType.CLAIM, false);
        vm.stopPrank();
        uint256 env = vm.snapshot();

        SeizeStart memory start;
        bool haveStart;
        for (uint256 u = 0; u < users.length; u++) {
            uint256 count = staking.checkDepositCountOfAddress(users[u]);
            for (uint256 i = 0; i < count; i++) {
                if (!staking.isDepositFrozen(users[u], i)) continue;
                // Read once, at the first frozen deposit, in the `env` state -- the state every trial starts from.
                if (!haveStart) {
                    start = _seizeStart(users, treasury);
                    haveStart = true;
                }
                string memory why = _trySeize(users[u], i, start, env);
                if (bytes(why).length != 0) {
                    failureCount++;
                    failures = string.concat(
                        failures, " [user=", vm.toString(users[u]), " deposit=", vm.toString(i), " ", why, "]"
                    );
                }
                vm.warp(ts);
            }
        }
        assertTrue(vm.revertTo(pre), "revertTo(pre) failed");
        vm.warp(ts);
        assertEq(failureCount, 0, string.concat("FROZEN DEPOSITS NOT SEIZABLE:", failures));
    }

    /// @dev Values of the `env` state that every seize trial used to re-read for itself before its seize. Every trial
    ///      starts from that same state (vm.revertTo(env)), so reading them once gives each trial identical values.
    struct SeizeStart {
        address treasury;
        uint256 treasuryBalance; // token.balanceOf(treasury)
        uint256 excess; // _excess()
        uint256 rewardPool;
        uint256 openReserved; // _openPeriodicalRewardSum(): sum of _openPeriodicalReward over every user deposit
    }

    function _seizeStart(address[] memory users, address treasury) private view returns (SeizeStart memory s) {
        s.treasury = treasury;
        s.treasuryBalance = token.balanceOf(treasury);
        s.excess = _excess();
        s.rewardPool = staking.rewardPool();
        s.openReserved = _openPeriodicalRewardSum(users);
    }

    /// @dev Runs one seize from the `env` snapshot (all actions closed), reverts back to it, and returns a
    ///      non-empty reason on any mismatch.
    function _trySeize(address user, uint256 idx, SeizeStart memory start, uint256 env)
        private
        returns (string memory why)
    {
        ProgramManager.TokenDeposit memory d = staking.getDeposit(user, idx);
        uint256 cellBefore = staking.getUserPhasePeriodData(Types.DataType.STAKING, user, d.stakingPhase, d.stakingPeriod);
        _requireDepositSlotLayout(user, idx, d.amount);

        vm.record(); // the seize's own storage writes, for _reservationMatchesAfterSeize
        vm.prank(owner);
        try staking.seizeDeposit(user, idx) {
            (, bytes32[] memory seizeWrites) = vm.accesses(address(staking));
            if (token.balanceOf(start.treasury) - start.treasuryBalance != d.amount) {
                why = "payout != principal";
            } else if (staking.rewardPool() != start.rewardPool) {
                why = "seize moved rewardPool";
            } else if (staking.checkDepositStatus(user, idx) != ProgramManager.DepositStatus.SEIZED) {
                why = "status != SEIZED";
            } else if (
                staking.getUserPhasePeriodData(Types.DataType.STAKING, user, d.stakingPhase, d.stakingPeriod)
                    != cellBefore - d.amount
            ) {
                why = "STAKING cell not freed";
            } else if (_excess() != start.excess) {
                why = "balance - (staked + pool) changed";
            } else if (!_reservationMatchesAfterSeize(user, idx, d, start.openReserved, seizeWrites)) {
                why = "REWARD_EXPECTED != open periodical rewards";
            } else {
                why = _checkSeizedIsFinal(user, idx);
            }
        } catch (bytes memory reason) {
            why = string.concat("seize reverted: ", vm.toString(reason));
        }

        assertTrue(vm.revertTo(env), "revertTo(env) failed");
    }

    function _checkSeizedIsFinal(address user, uint256 idx) private returns (string memory) {
        vm.prank(owner);
        (bool ok, bytes memory r) = address(staking).call(abi.encodeCall(staking.seizeDeposit, (user, idx)));
        if (ok || _selectorOf(r) != Errors.DepositNotFrozen.selector) return "second seize not DepositNotFrozen";

        vm.startPrank(owner);
        staking.changeActionAvailability(Types.DataType.WITHDRAWAL, true);
        staking.changeActionAvailability(Types.DataType.CLAIM, true);
        vm.stopPrank();

        vm.prank(user);
        (ok, r) = address(staking).call(abi.encodeCall(staking.claimDeposit, (idx)));
        if (ok || _selectorOf(r) != Errors.NotClaimable.selector) return "seized deposit claim not NotClaimable";
        vm.prank(user);
        (ok, r) = address(staking).call(abi.encodeCall(staking.withdrawDeposit, (idx)));
        if (ok || _selectorOf(r) != Errors.NotWithdrawable.selector) return "seized deposit withdraw not NotWithdrawable";
        return "";
    }

    function _excess() private view returns (uint256) {
        return token.balanceOf(address(staking)) - staking.totalDataList(Types.DataType.STAKING) - staking.rewardPool();
    }

    /// @dev Full rescan: REWARD_EXPECTED == sum of rewardGenerated over every open periodical deposit of every user.
    function _reservationMatchesOpenDeposits() private view returns (bool) {
        return _openPeriodicalRewardSum(handler.getUsers()) == staking.totalDataList(Types.DataType.REWARD_EXPECTED);
    }

    function _openPeriodicalRewardSum(address[] memory users) private view returns (uint256 total) {
        for (uint256 u = 0; u < users.length; u++) {
            // one call per user; getDepositsInRangeBy returns exactly getDeposit(user, i) for every i
            ProgramManager.TokenDeposit[] memory ds =
                lens.getDepositsInRangeBy(users[u], 0, staking.checkDepositCountOfAddress(users[u]));
            for (uint256 i = 0; i < ds.length; i++) {
                total += _openPeriodicalReward(ds[i]);
            }
        }
    }

    /// @dev One deposit's term of _openPeriodicalRewardSum.
    function _openPeriodicalReward(ProgramManager.TokenDeposit memory d) private pure returns (uint256) {
        return d.withdrawalDate == 0 && d.stakingEndDate != 0 ? d.rewardGenerated : 0;
    }

    /// @dev Same result as `_reservationMatchesOpenDeposits()` evaluated right after the seize, without re-reading
    ///      every deposit of every user in every trial.
    ///      `openReserved` is _openPeriodicalRewardSum() of the pre-seize `env` state and `before` is
    ///      getDeposit(user, idx) of that same state. A deposit's term reads getDeposit(u, j).{withdrawalDate,
    ///      stakingEndDate, rewardGenerated}; with stakingEndDate != 0 the status is never INDEFINITE, so getDeposit
    ///      returns all three straight from the stored PackedDeposit (slots 0 and 1 of element j), and which j
    ///      exist depends only on the array length. So when the seize wrote neither any user's stakerDepositList
    ///      length slot nor any element slot other than (user, idx)'s, every other term -- and the set of terms --
    ///      is unchanged and the post-seize full sum is exactly openReserved - term(before) + term(after).
    ///      Otherwise it falls back to the full rescan.
    function _reservationMatchesAfterSeize(
        address user,
        uint256 idx,
        ProgramManager.TokenDeposit memory before,
        uint256 openReserved,
        bytes32[] memory seizeWrites
    ) private view returns (bool) {
        if (_seizeWroteOtherDepositSlots(user, idx, seizeWrites)) return _reservationMatchesOpenDeposits();
        uint256 total = openReserved + _openPeriodicalReward(staking.getDeposit(user, idx)) - _openPeriodicalReward(before);
        return total == staking.totalDataList(Types.DataType.REWARD_EXPECTED);
    }

    /// @dev Storage slot of ProgramManager.stakerDepositList, a mapping(address => PackedDeposit[]), per
    ///      `forge inspect ERC20PeriodicalStaking storageLayout`. The array length of `u` is at
    ///      keccak256(abi.encode(u, SLOT)); element j occupies the 2 slots at keccak256(lengthSlot) + 2j (+1), with
    ///      `amount` in the low 128 bits of the first. Checked on every trial by _requireDepositSlotLayout.
    uint256 private constant STAKER_DEPOSIT_LIST_SLOT = 8;

    function _depositListLengthSlot(address u) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(u, STAKER_DEPOSIT_LIST_SLOT)));
    }

    /// @dev Test-harness guard, not a protocol property: reverts (failing the invariant with this message) if
    ///      STAKER_DEPOSIT_LIST_SLOT no longer points at stakerDepositList after a src storage change, so the slot
    ///      arithmetic in _seizeWroteOtherDepositSlots never silently looks at the wrong place.
    function _requireDepositSlotLayout(address user, uint256 idx, uint256 amount) private view {
        uint256 lenSlot = _depositListLengthSlot(user);
        uint256 slot0 = uint256(vm.load(address(staking), bytes32(uint256(keccak256(abi.encode(lenSlot))) + 2 * idx)));
        require(
            uint256(vm.load(address(staking), bytes32(lenSlot))) == staking.checkDepositCountOfAddress(user)
                && uint128(slot0) == amount,
            "test harness: STAKER_DEPOSIT_LIST_SLOT no longer matches stakerDepositList (forge inspect storageLayout)"
        );
    }

    /// @dev True if any written slot is a handler user's stakerDepositList length slot, or lies in a handler user's
    ///      element area (any index, existing or not) other than the two slots of (user, idx).
    function _seizeWroteOtherDepositSlots(address user, uint256 idx, bytes32[] memory writes)
        private
        view
        returns (bool)
    {
        address[] memory users = handler.getUsers();
        uint256[] memory lenSlots = new uint256[](users.length);
        uint256[] memory bases = new uint256[](users.length);
        for (uint256 u = 0; u < users.length; u++) {
            lenSlots[u] = _depositListLengthSlot(users[u]);
            bases[u] = uint256(keccak256(abi.encode(lenSlots[u])));
        }
        for (uint256 w = 0; w < writes.length; w++) {
            uint256 s = uint256(writes[w]);
            for (uint256 u = 0; u < users.length; u++) {
                if (s == lenSlots[u]) return true;
                // 2^64 elements is far beyond any array here; bases are keccak outputs, so no user areas overlap.
                if (s >= bases[u] && s - bases[u] < (1 << 65)) {
                    if (users[u] != user || (s - bases[u]) / 2 != idx) return true;
                }
            }
        }
        return false;
    }
}

/// @title StakingInvariants
/// @notice Full stateful-fuzzing suite for ERC20PeriodicalStaking. All handler actions enabled, including
///         voucher stakes with random extra APY and the admin freeze / unfreeze / owner seize actions.
/// @dev Run with, e.g.:
///      FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=50 forge test --match-path 'test/erc20-periodical-staking/security/invariants/*'
///      Handler reverts are caught inside the handler, so fail_on_revert is irrelevant.
contract StakingInvariants is EnforcementInvariantChecks {
    function setUp() external {
        _deploy(false);

        bytes4[] memory s = new bytes4[](22);
        // user actions
        s[0] = Handler.stake.selector;
        s[1] = Handler.withdraw.selector;
        s[2] = Handler.claim.selector;
        s[3] = Handler.claimAll.selector;
        s[4] = Handler.warp.selector;
        // owner / admin actions
        s[5] = Handler.pushStakingPhase.selector;
        s[6] = Handler.popStakingPhase.selector;
        s[7] = Handler.addStakingPeriod.selector;
        s[8] = Handler.removeStakingPeriod.selector;
        s[9] = Handler.setPhasePeriodData.selector;
        s[10] = Handler.changeStakingPhase.selector;
        s[11] = Handler.provideReward.selector;
        s[12] = Handler.collectReward.selector;
        s[13] = Handler.setActionAvailability.selector;
        s[14] = Handler.setMinimumDeposit.selector;
        // weight: a second stake entry doubles its selection probability
        s[15] = Handler.stake.selector;
        // direct donations + owner rescue of the excess only
        s[16] = Handler.donate.selector;
        s[17] = Handler.rescue.selector;
        // enforcement: freeze weighted x2 so seize regularly finds a frozen deposit
        s[18] = Handler.freeze.selector;
        s[19] = Handler.freeze.selector;
        s[20] = Handler.unfreeze.selector;
        s[21] = Handler.seize.selector;
        _target(s);
    }

    /// @notice token.balanceOf(contract) == totalDataList[STAKING] + rewardPool + (donated - rescued), exactly.
    ///         Direct donations are the only legitimate excess; rescueTokens may take at most that excess.
    function invariant_tokenConservation() external {
        _check_tokenConservation();
    }

    /// @notice Contract balance and staked total also reconcile against handler token-flow ghosts (seize included).
    function invariant_tokenFlowGhosts() external {
        _check_tokenFlowGhosts();
    }

    /// @notice Reserve properties (a)+(b): no successful collectReward exceeded getCollectableReward() at call time,
    ///         and no user payout or seize ever took rewardPool from >= REWARD_EXPECTED to below it.
    function invariant_reserveRespected() external {
        _check_reserveRespected();
    }

    /// @notice rewardPool == provided - collected - rewards paid (only those flows move it; seize never does).
    function invariant_rewardPoolAccounting() external {
        _check_rewardPoolAccounting();
    }

    /// @notice For every DataType, sum over users of userDataList == totalDataList.
    function invariant_userSumsMatchTotals() external {
        _check_userSumsMatchTotals();
    }

    /// @notice Sum over every (phase, period) ever seen of phasePeriodDataList[STAKED] == totalDataList[STAKING].
    function invariant_phasePeriodStakedSum() external {
        _check_phasePeriodStakedSum();
    }

    /// @notice Per user, sum over (phase, period) of the STAKING cell == userDataList[STAKING]
    ///         (the only per-phase/period user cell since v0.4.0; seize frees it like a close).
    function invariant_userPhasePeriodSums() external {
        _check_userPhasePeriodSums();
    }

    /// @notice totalDataList[REWARD_EXPECTED] == sum of rewardGenerated of all open periodical deposits.
    function invariant_rewardExpectedMatchesOpenDeposits() external {
        _check_rewardExpectedMatchesOpenDeposits();
    }

    /// @notice A user with no open periodical deposit has zero REWARD_EXPECTED reserved.
    function invariant_noPhantomReservations() external {
        _check_noPhantomReservations();
    }

    /// @notice LIVENESS: every open, unfrozen deposit can be closed (claim after maturity / withdraw for indefinite)
    ///         with actions open and the pool funded. Known-incident detector.
    function invariant_everyOpenDepositIsClosable() external {
        _check_everyOpenDepositIsClosable();
    }

    /// @notice Reserve property (c): whenever rewardPool >= REWARD_EXPECTED, every open unfrozen periodical deposit
    ///         is claimable at maturity WITHOUT any pool top-up. When the pool is short, a matured claim may only
    ///         fail with NotEnoughFundsInRewardPool (never a panic).
    function invariant_maturedDepositsClaimableWithoutTopUp() external {
        _check_maturedDepositsClaimableWithoutTopUp();
    }

    /// @notice stakerActiveDepositStartIndex <= depositCount and no open deposit sits below it.
    function invariant_activeStartIndex() external {
        _check_activeStartIndex();
    }

    /// @notice stakingPeriodList strictly ascending, no duplicates; currentStakingPhase < stakingPhaseCount.
    function invariant_periodListAndPhaseIndex() external {
        _check_periodListAndPhaseIndex();
    }

    /// @notice checkClaimableDataFor(user) equals what claimAll actually pays (both skip frozen deposits).
    function invariant_claimableDataMatchesPayout() external {
        _check_claimableDataMatchesPayout();
    }

    /// @notice Every payout equals principal + committed reward; early withdraw never pays a reward; every seize
    ///         pays exactly the principal and leaves rewardPool unchanged.
    function invariant_payoutCommitments() external {
        _check_payoutCommitments();
    }

    /// @notice actionAvailability matches the handler's mirror.
    function invariant_actionAvailability() external {
        _check_actionAvailability();
    }

    /// @notice No handler action reverted for a reason we could not explain (includes panics).
    function invariant_noUnexpectedReverts() external {
        _check_noUnexpectedReverts();
    }

    /// @notice The treasury receives exactly the seized funds and nothing else.
    function invariant_treasuryReceivesOnlySeizedFunds() external {
        _check_treasuryReceivesOnlySeizedFunds();
    }

    /// @notice Frozen deposits are open; seized deposits are closed and unfrozen.
    function invariant_freezeSeizeStateConsistency() external {
        _check_freezeSeizeStateConsistency();
    }

    /// @notice SOLVENCY: every frozen deposit is seizable with actions closed and no pool top-up, frees its limit
    ///         cell, keeps balance == staked + pool (+ donations), and is final afterwards.
    function invariant_everyFrozenDepositSeizableWithoutTopUp() external {
        _check_everyFrozenDepositSeizableWithoutTopUp();
    }
}
