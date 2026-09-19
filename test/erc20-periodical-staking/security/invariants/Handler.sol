// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {TestToken} from "../../../shared/TestToken.sol";
import {ERC20PeriodicalStaking} from
    "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
// Pre-fix v0.2.4 sources (git 6d63bbe), mirrored under ./legacy so the suite can prove it detects the
// known incident without touching src/. Only used when the handler is constructed with legacy=true.
import {ERC20PeriodicalStaking as LegacyERC20PeriodicalStaking} from
    "./legacy/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {Errors} from "../../../../src/common/Errors.sol";
import {Types} from "../../../../src/common/Types.sol";
import {VoucherHelper} from "../../../shared/VoucherHelper.sol";

/// @title Handler
/// @notice Stateful-fuzzing handler for ERC20PeriodicalStaking.
/// @dev Design rules:
///      - Every action bounds its inputs and pre-checks the contract state so that the call
///        only reverts for a reason we can classify.
///      - Reverts we can classify are counted in `expectedReverts[label]`.
///      - Anything else is appended to `ghost_unexpectedReverts` (asserted empty by an invariant).
///      - Per-action payout checks never `assert` inside the handler (a handler revert would be
///        silently swallowed with fail_on_revert=false); they record into `ghost_payoutViolations`.
///      - The handler is written against the v0.3.0 behaviour. Whether a call is expected to revert is
///        decided from the contract state before the call (precondition), not by matching an error
///        selector, so the same handler also drives the mirrored v0.2.4 sources under ./legacy.
///        Views that only exist in v0.3.0 (getCollectableReward) are routed through `_collectable()`, which
///        falls back to the whole rewardPool on the legacy deployment; an unguarded call would revert the
///        handler action itself and silently leave that action inert in the legacy run.
///      v0.4.0: src stakes through a signed voucher (random extra APY); the legacy deployment still uses
///      safeStake through a low-level call. APY bounds are bps for src and percent for legacy (_maxApy).
///      freeze / unfreeze / seize actions exist for src only (no-ops on legacy); frozen deposits are never
///      picked for withdraw / claim, and seized tokens are tracked in the ghost_seized* flows.
contract Handler is VoucherHelper {
    // ======================================
    // =            Deployment              =
    // ======================================
    TestToken public token;
    ERC20PeriodicalStaking public staking;
    /// @dev true when `staking` is the mirrored v0.2.4 code (no getCollectableReward / reserve accounting).
    bool public immutable legacy;

    address public owner = makeAddr("owner");
    address public admin = makeAddr("admin");
    address[] internal users;

    uint256 internal constant USER_COUNT = 6;
    uint256 internal constant USER_FUNDS = 500_000e18;
    uint256 internal constant MAX_PERIOD_DAYS = 400;
    uint256 internal constant MAX_APY_BPS = 10_000; // src: bps
    uint256 internal constant MAX_APY_LEGACY = 100; // v0.2.4: percent
    uint256 internal constant MAX_TARGET = 2_000_000e18;
    // Kept small so the invariant runner regularly sees rewardPool < REWARD_EXPECTED and matured periodical
    // claims that exceed the pool; the provideReward action (up to 1M per call) still reaches funded states.
    uint256 internal constant SEED_POOL = 20_000e18;

    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    // ======================================
    // =          Ghost variables           =
    // ======================================
    /// @dev Token flow into/out of the staking contract, split by counterparty.
    uint256 public ghost_userIn; // principal sent by users via safeStake
    uint256 public ghost_userOut; // everything paid to users (principal + rewards)
    uint256 public ghost_principalPaid; // principal component of ghost_userOut
    uint256 public ghost_rewardsPaid; // reward component of ghost_userOut
    uint256 public ghost_provided; // provideReward total
    uint256 public ghost_collected; // collectReward total
    uint256 public ghost_donated; // tokens sent straight to the contract (not via any function)
    uint256 public ghost_rescued; // rescueTokens(STAKING_TOKEN) total
    uint256 public ghost_seizedOut; // everything sent to the treasury by seizeDeposit
    uint256 public ghost_seizedPrincipal; // principal seized; equals ghost_seizedOut (seize never pays a reward)

    /// @dev Mirror of actionAvailabilityStatuses for STAKING / WITHDRAWAL / CLAIM.
    bool[3] public ghost_actionOpen;

    /// @dev Highest stakingPhaseCount ever observed (phases 0..max-1 may hold accounting data).
    uint256 public ghost_maxPhaseCount;
    /// @dev Every period value that has ever existed in stakingPeriodList (including removed ones).
    uint256[] internal everSeenPeriods;
    mapping(uint256 => bool) internal seenPeriod;

    /// @dev Every (user, phase, period) STAKING cell a successful stake has written to, and every (phase, period)
    ///      pair with at least one such cell. The per-call sum checks read only these cells; the full grid
    ///      (users x phases x every period ever seen) is read once per run in InvariantBase.afterInvariant(),
    ///      which is what catches a write into a cell nobody staked into.
    struct StakingCell {
        address user;
        uint256 phase;
        uint256 period;
    }

    StakingCell[] internal touchedCells;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal cellTouched;
    uint256[2][] internal touchedPhasePeriods;
    mapping(uint256 => mapping(uint256 => bool)) internal phasePeriodTouched;

    /// @dev Reverts that no precondition explains. Must stay empty.
    string[] public ghost_unexpectedReverts;
    /// @dev Payout mismatches versus what the deposit committed to. Must stay zero.
    uint256 public ghost_payoutViolations;
    string[] public ghost_payoutViolationNotes;

    /// @dev Reward-reserve properties, recorded at call time (asserted zero by invariant_reserveRespected):
    ///      (a) a successful collectReward never exceeded getCollectableReward();
    ///      (b) a user payout never took rewardPool from >= REWARD_EXPECTED to < REWARD_EXPECTED.
    uint256 public ghost_reserveViolations;
    string[] public ghost_reserveViolationNotes;

    mapping(string => uint256) public expectedReverts;
    mapping(string => uint256) public skipped;
    mapping(string => uint256) public calls;

    // ======================================
    // =            Construction            =
    // ======================================
    /// @param legacy_ Deploy the mirrored v0.2.4 implementation instead of src (regression detector).
    constructor(bool legacy_) {
        legacy = legacy_;
        token = new TestToken(18); // mints 10M * 1e18 to this handler

        vm.prank(owner);
        if (legacy_) {
            // Same ABI for everything the handler touches; cast to the current type.
            staking = ERC20PeriodicalStaking(address(new LegacyERC20PeriodicalStaking(address(token))));
        } else {
            staking = new ERC20PeriodicalStaking(address(token));
        }

        vm.prank(owner);
        staking.addContractAdmin(admin);

        if (!legacy_) {
            vm.startPrank(owner);
            _enableVoucherStaking(staking);
            vm.stopPrank();
        }

        for (uint256 i = 0; i < USER_COUNT; i++) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            users.push(u);
            token.transfer(u, USER_FUNDS);
            vm.prank(u);
            token.approve(address(staking), type(uint256).max);
        }
        // Everything left funds the reward pool via admin.
        token.transfer(admin, token.balanceOf(address(this)));
        vm.prank(admin);
        token.approve(address(staking), type(uint256).max);

        ghost_actionOpen[0] = true;
        ghost_actionOpen[1] = true;
        ghost_actionOpen[2] = true;

        _seedProgram(legacy_);
    }

    /// @dev Seed a small program so the invariant runner does not waste depth reaching a usable state.
    ///      Takes the flag as a parameter: the `legacy` immutable cannot be read during construction.
    function _seedProgram(bool legacy_) internal {
        uint256[4] memory periods = [uint256(0), 30, 90, 180];
        uint256[4] memory apys = legacy_ ? [uint256(5), 10, 15, 20] : [uint256(500), 1000, 1500, 2000];
        uint256[] memory noPhaseApy = new uint256[](0);
        uint256[] memory noPhaseTarget = new uint256[](0);

        vm.startPrank(owner);
        for (uint256 i = 0; i < periods.length; i++) {
            staking.addStakingPeriod(periods[i], noPhaseApy, noPhaseTarget);
            _markPeriodSeen(periods[i]);
        }
        uint256[] memory apy = new uint256[](periods.length);
        uint256[] memory target = new uint256[](periods.length);
        for (uint256 i = 0; i < periods.length; i++) {
            apy[i] = apys[i];
            target[i] = 1_000_000e18;
        }
        staking.pushStakingPhase(apy, target);
        ghost_maxPhaseCount = 1;
        vm.stopPrank();

        _topUpPool(SEED_POOL);
    }

    // ======================================
    // =              Views                 =
    // ======================================
    function getUsers() external view returns (address[] memory) {
        return users;
    }

    /// @notice All addresses that can appear as a key in userDataList.
    function getActors() external view returns (address[] memory actors) {
        actors = new address[](users.length + 2);
        for (uint256 i = 0; i < users.length; i++) {
            actors[i] = users[i];
        }
        actors[users.length] = owner;
        actors[users.length + 1] = admin;
    }

    function getEverSeenPeriods() external view returns (uint256[] memory) {
        return everSeenPeriods;
    }

    /// @notice Every (user, phase, period) STAKING cell a stake ever wrote to.
    function getTouchedCells() external view returns (StakingCell[] memory) {
        return touchedCells;
    }

    /// @notice Every (phase, period) pair with at least one touched STAKING cell.
    function getTouchedPhasePeriods() external view returns (uint256[2][] memory) {
        return touchedPhasePeriods;
    }

    /// @notice block.timestamp behind an external call. With via_ir the optimizer rematerializes a
    ///         `block.timestamp` local at its use site, so a value captured before vm.warp / vm.revertTo
    ///         can silently change; an external call result cannot be rematerialized.
    function currentTime() external view returns (uint256) {
        return block.timestamp;
    }

    function unexpectedRevertCount() external view returns (uint256) {
        return ghost_unexpectedReverts.length;
    }

    function payoutViolationNoteCount() external view returns (uint256) {
        return ghost_payoutViolationNotes.length;
    }

    function reserveViolationNoteCount() external view returns (uint256) {
        return ghost_reserveViolationNotes.length;
    }

    // ======================================
    // =            User actions            =
    // ======================================
    function stake(uint256 userSeed, uint256 periodSeed, uint256 amountSeed, uint256 capSeed) external {
        calls["stake"]++;
        address user = _pickUser(userSeed);

        if (staking.stakingPhaseCount() == 0) {
            skipped["stake_noPhase"]++;
            return;
        }
        uint256[] memory periods = staking.getStakingPeriods();
        if (periods.length == 0) {
            skipped["stake_noPeriod"]++;
            return;
        }
        uint256 phase = staking.currentStakingPhase();
        uint256 period = periods[bound(periodSeed, 0, periods.length - 1)];

        uint256 target = staking.getPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, phase, period);
        uint256 staked = staking.getPhasePeriodData(Types.PhasePeriodDataType.STAKED, phase, period);
        uint256 remaining = staked >= target ? 0 : target - staked;
        uint256 minDep = staking.minimumDeposit();
        uint256 maxAmt = _min(remaining, token.balanceOf(user));
        if (maxAmt < minDep) {
            skipped["stake_noRoom"]++;
            return;
        }
        // Bias towards human-sized stakes half of the time so many deposits fit in a run.
        if (bound(capSeed, 0, 1) == 0) maxAmt = _max(minDep, _min(maxAmt, 50_000e18));
        uint256 amount = bound(amountSeed, minDep, maxAmt);

        uint256 apy = staking.getPhasePeriodData(Types.PhasePeriodDataType.APY, phase, period);

        // There is no stake-time pool check. The pool is deliberately NOT pre-funded here so both funded
        // and unfunded states are explored; `provideReward` is the only way the pool grows.
        bool ok;
        bytes memory reason;
        if (legacy) {
            // v0.2.4 ABI; src no longer has safeStake.
            vm.prank(user);
            (ok, reason) = address(staking).call(
                abi.encodeWithSignature("safeStake(uint256,uint256,uint256,uint256)", phase, period, amount, apy)
            );
        } else {
            uint256 extraApy = bound(uint256(keccak256(abi.encode(amountSeed, capSeed))), 0, staking.maxExtraApyBps());
            (Types.StakeVoucher memory v, bytes memory sig) =
                _prepareVoucherStake(staking, user, phase, period, extraApy, 0);
            vm.prank(user);
            try staking.stakeWithVoucher(v, sig, amount, apy + extraApy) {
                ok = true;
            } catch (bytes memory r) {
                reason = r;
            }
        }
        if (ok) {
            ghost_userIn += amount;
            _markCellTouched(user, phase, period);
        } else {
            if (!ghost_actionOpen[0]) {
                _expectSelector("stake_notOpen", "stake", reason, Errors.NotOpen.selector);
            } else {
                _unexpected("stake", reason);
            }
        }
    }

    /// @notice Withdraw an open deposit (TIME_LEFT -> principal only, INDEFINITE -> principal + accrued).
    /// @dev The full withdraw never forfeits accrued indefinite reward: when the unreserved pool cannot
    ///      cover it the call reverts NotEnoughFundsInRewardPool and the deposit stays open (the opt-in
    ///      withdrawDepositPartial path is not driven here).
    function withdraw(uint256 userSeed, uint256 depositSeed) external {
        calls["withdraw"]++;
        address user = _pickUser(userSeed);
        uint256[] memory candidates = _depositsWithStatus(user, true, false, true);
        if (candidates.length == 0) {
            skipped["withdraw_none"]++;
            return;
        }
        uint256 idx = candidates[bound(depositSeed, 0, candidates.length - 1)];
        ProgramManager.DepositStatus st = staking.checkDepositStatus(user, idx);
        ProgramManager.TokenDeposit memory d = staking.getDeposit(user, idx);
        bool indefinite = st == ProgramManager.DepositStatus.INDEFINITE;
        uint256 accrued = indefinite ? d.rewardGenerated : 0;
        // Indefinite reward is paid only from the unreserved pool.
        uint256 collectable = _collectable();
        uint256 pending = accrued > collectable ? collectable : accrued;
        uint256 balBefore = token.balanceOf(user);
        bool coveredBefore = _poolCoversReserve();

        vm.prank(user);
        try staking.withdrawDeposit(idx) {
            uint256 got = token.balanceOf(user) - balBefore;
            _recordPayout("withdraw", user, idx, got, d.amount, pending);
            _checkReserveTransition("withdraw", user, idx, coveredBefore);
            if (st == ProgramManager.DepositStatus.TIME_LEFT && got > d.amount) {
                _payoutViolation("withdraw before maturity paid a reward", user, idx, got, d.amount);
            }
        } catch (bytes memory reason) {
            if (!ghost_actionOpen[1]) {
                _expectSelector("withdraw_notOpen", "withdraw", reason, Errors.NotOpen.selector);
            } else if (indefinite && accrued > collectable) {
                // The unreserved pool cannot pay the whole accrued reward: the full withdraw refuses rather
                // than silently forfeiting the remainder. Expected, never a panic.
                _expectSelector(
                    "withdraw_indefinitePoolShort", "withdraw", reason, Errors.NotEnoughFundsInRewardPool.selector
                );
            } else {
                _unexpected("withdraw", reason);
            }
        }
    }

    /// @notice Claim a matured periodical deposit or the accrued reward of an indefinite one.
    function claim(uint256 userSeed, uint256 depositSeed) external {
        calls["claim"]++;
        address user = _pickUser(userSeed);
        uint256[] memory candidates = _depositsWithStatus(user, false, true, true);
        if (candidates.length == 0) {
            skipped["claim_none"]++;
            return;
        }
        uint256 idx = candidates[bound(depositSeed, 0, candidates.length - 1)];
        ProgramManager.DepositStatus st = staking.checkDepositStatus(user, idx);
        ProgramManager.TokenDeposit memory d = staking.getDeposit(user, idx);
        bool indefinite = st == ProgramManager.DepositStatus.INDEFINITE;
        uint256 rewardDue = d.rewardGenerated; // committed reward (periodical) or pending (indefinite)
        uint256 principal = indefinite ? 0 : d.amount;
        uint256 pool = staking.rewardPool();
        uint256 collectable = _collectable();
        uint256 balBefore = token.balanceOf(user);
        bool coveredBefore = _poolCoversReserve();

        vm.prank(user);
        try staking.claimDeposit(idx) {
            uint256 got = token.balanceOf(user) - balBefore;
            // Periodical reward is paid in full (or the call reverts); indefinite reward is capped at collectable.
            uint256 rewardExpected = indefinite && rewardDue > collectable ? collectable : rewardDue;
            _recordPayout("claim", user, idx, got, principal, rewardExpected);
            _checkReserveTransition("claim", user, idx, coveredBefore);
        } catch (bytes memory reason) {
            if (!ghost_actionOpen[2]) {
                _expectSelector("claim_notOpen", "claim", reason, Errors.NotOpen.selector);
            } else if (indefinite && (rewardDue == 0 || collectable == 0)) {
                // Indefinite claims pay min(accrued, collectable) and revert NoRewardToClaim when that is 0.
                _expectSelector(
                    rewardDue == 0 ? "claim_indefiniteNoReward" : "claim_indefinitePoolShort",
                    "claim",
                    reason,
                    Errors.NoRewardToClaim.selector
                );
            } else if (!indefinite && rewardDue > pool) {
                // There is no stake-time reservation, so a matured periodical claim against a short pool
                // reverts NotEnoughFundsInRewardPool (retry after a top-up). Expected, never a panic.
                _expectSelector("claim_periodicalPoolShort", "claim", reason, Errors.NotEnoughFundsInRewardPool.selector);
            } else {
                _unexpected("claim", reason);
            }
        }
    }

    /// @notice claimAll for a user; payout is reconciled against per-deposit state deltas.
    function claimAll(uint256 userSeed) external {
        calls["claimAll"]++;
        address user = _pickUser(userSeed);
        uint256 count = staking.checkDepositCountOfAddress(user);
        if (count == 0) {
            skipped["claimAll_none"]++;
            return;
        }

        ProgramManager.DepositStatus[] memory stBefore = new ProgramManager.DepositStatus[](count);
        uint256[] memory amountBefore = new uint256[](count);
        uint256[] memory rewardBefore = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            stBefore[i] = staking.checkDepositStatus(user, i);
            ProgramManager.TokenDeposit memory d = staking.getDeposit(user, i);
            amountBefore[i] = d.amount;
            rewardBefore[i] = d.rewardGenerated;
        }
        uint256 balBefore = token.balanceOf(user);
        bool coveredBefore = _poolCoversReserve();

        vm.prank(user);
        try staking.claimAll() {
            uint256 got = token.balanceOf(user) - balBefore;
            _checkReserveTransition("claimAll", user, type(uint256).max, coveredBefore);
            uint256 principal;
            uint256 reward;
            for (uint256 i = 0; i < count; i++) {
                ProgramManager.DepositStatus stAfter = staking.checkDepositStatus(user, i);
                if (stBefore[i] == ProgramManager.DepositStatus.READY_TO_CLAIM) {
                    if (stAfter == ProgramManager.DepositStatus.CLAIMED) {
                        principal += amountBefore[i];
                        reward += rewardBefore[i];
                    } else if (stAfter != ProgramManager.DepositStatus.READY_TO_CLAIM) {
                        _payoutViolation("claimAll moved a READY deposit to a non-CLAIMED state", user, i, 0, 0);
                    }
                } else if (stBefore[i] == ProgramManager.DepositStatus.INDEFINITE) {
                    uint256 pendingAfter = staking.getDeposit(user, i).rewardGenerated;
                    if (pendingAfter > rewardBefore[i]) {
                        _payoutViolation("claimAll increased pending indefinite reward", user, i, pendingAfter, rewardBefore[i]);
                    } else {
                        reward += rewardBefore[i] - pendingAfter;
                    }
                } else if (stAfter != stBefore[i]) {
                    _payoutViolation("claimAll changed status of a non-claimable deposit", user, i, 0, 0);
                }
            }
            _recordPayout("claimAll", user, type(uint256).max, got, principal, reward);
        } catch (bytes memory reason) {
            if (!ghost_actionOpen[2]) {
                _expectSelector("claimAll_notOpen", "claimAll", reason, Errors.NotOpen.selector);
            } else {
                _unexpected("claimAll", reason);
            }
        }
    }

    /// @notice Advance time by 0..400 days.
    function warp(uint256 secondsSeed) external {
        calls["warp"]++;
        uint256 delta = bound(secondsSeed, 0, MAX_PERIOD_DAYS * 1 days);
        vm.warp(block.timestamp + delta);
    }

    // ======================================
    // =            Owner actions           =
    // ======================================
    function pushStakingPhase(uint256 apySeed, uint256 targetSeed) external {
        calls["pushStakingPhase"]++;
        uint256[] memory periods = staking.getStakingPeriods();
        (uint256[] memory apy, uint256[] memory target) = _randomApyTarget(periods.length, apySeed, targetSeed);

        vm.prank(owner);
        try staking.pushStakingPhase(apy, target) {
            uint256 count = staking.stakingPhaseCount();
            if (count > ghost_maxPhaseCount) ghost_maxPhaseCount = count;
        } catch (bytes memory reason) {
            _unexpected("pushStakingPhase", reason);
        }
    }

    function popStakingPhase() external {
        calls["popStakingPhase"]++;
        uint256 count = staking.stakingPhaseCount();

        vm.prank(owner);
        try staking.popStakingPhase() {
            if (count == 0) _payoutViolation("popStakingPhase succeeded with zero phases", address(0), 0, 0, 0);
        } catch (bytes memory reason) {
            if (count == 0) {
                // v0.3.0: NoStakingPhasesAddedYet (v0.2.x panicked with 0x11 here).
                _expectSelector("popPhase_empty", "popStakingPhase", reason, Errors.NoStakingPhasesAddedYet.selector);
            } else {
                _unexpected("popStakingPhase", reason);
            }
        }
    }

    /// @notice Add a period; half the time re-adds a previously removed period (re-add path).
    function addStakingPeriod(uint256 periodSeed, uint256 apySeed, uint256 targetSeed) external {
        calls["addStakingPeriod"]++;
        uint256 period = _pickPeriodToAdd(periodSeed);
        bool exists = staking.checkIfStakingPeriodExists(period);
        uint256 phaseCount = staking.stakingPhaseCount();
        (uint256[] memory apy, uint256[] memory target) = _randomApyTarget(phaseCount, apySeed, targetSeed);

        vm.prank(owner);
        try staking.addStakingPeriod(period, apy, target) {
            _markPeriodSeen(period);
            if (exists) _payoutViolation("addStakingPeriod accepted a duplicate period", address(0), period, 0, 0);
        } catch (bytes memory reason) {
            if (exists) {
                _expectSelector("addPeriod_exists", "addStakingPeriod", reason, Errors.StakingPeriodExists.selector);
            } else {
                _unexpected("addStakingPeriod", reason);
            }
        }
    }

    function removeStakingPeriod(uint256 periodSeed) external {
        calls["removeStakingPeriod"]++;
        uint256[] memory periods = staking.getStakingPeriods();
        if (periods.length == 0) {
            skipped["removePeriod_none"]++;
            return;
        }
        uint256 period = periods[bound(periodSeed, 0, periods.length - 1)];

        vm.prank(owner);
        try staking.removeStakingPeriod(period) {}
        catch (bytes memory reason) {
            _unexpected("removeStakingPeriod", reason);
        }
    }

    function setPhasePeriodData(uint256 phaseSeed, uint256 periodSeed, uint256 typeSeed, uint256 valueSeed)
        external
    {
        calls["setPhasePeriodData"]++;
        uint256 phaseCount = staking.stakingPhaseCount();
        uint256[] memory periods = staking.getStakingPeriods();
        if (phaseCount == 0 || periods.length == 0) {
            skipped["setPhasePeriodData_noPhasePeriod"]++;
            return;
        }
        uint256 phase = bound(phaseSeed, 0, phaseCount - 1);
        uint256 period = periods[bound(periodSeed, 0, periods.length - 1)];
        Types.PhasePeriodDataType dt;
        uint256 value;
        if (bound(typeSeed, 0, 1) == 0) {
            dt = Types.PhasePeriodDataType.APY;
            value = bound(valueSeed, 1, _maxApy());
        } else {
            dt = Types.PhasePeriodDataType.STAKING_TARGET;
            value = bound(valueSeed, 0, MAX_TARGET);
        }

        vm.prank(owner);
        try staking.setPhasePeriodData(dt, phase, period, value) {}
        catch (bytes memory reason) {
            _unexpected("setPhasePeriodData", reason);
        }
    }

    function changeStakingPhase(uint256 phaseSeed) external {
        calls["changeStakingPhase"]++;
        uint256 phaseCount = staking.stakingPhaseCount();
        if (phaseCount == 0) {
            skipped["changePhase_none"]++;
            return;
        }
        uint256 phase = bound(phaseSeed, 0, phaseCount - 1);

        vm.prank(owner);
        try staking.changeStakingPhase(phase) {}
        catch (bytes memory reason) {
            _unexpected("changeStakingPhase", reason);
        }
    }

    function provideReward(uint256 amountSeed) external {
        calls["provideReward"]++;
        uint256 amount = bound(amountSeed, 0, _min(token.balanceOf(admin), 1_000_000e18));

        vm.prank(admin);
        try staking.provideReward(amount) {
            ghost_provided += amount;
        } catch (bytes memory reason) {
            if (amount == 0) {
                _expectSelector("provideReward_zero", "provideReward", reason, Errors.ZeroAmountProvided.selector);
            } else {
                _unexpected("provideReward", reason);
            }
        }
    }

    /// @notice Collect from the pool. 80% of the time within the unreserved surplus, 20% anywhere
    ///         up to the whole pool so the collect guard is exercised (including a pool already short).
    function collectReward(uint256 amountSeed, uint256 modeSeed) external {
        calls["collectReward"]++;
        uint256 pool = staking.rewardPool();
        uint256 reserved = staking.totalDataList(Types.DataType.REWARD_EXPECTED);
        uint256 free = pool > reserved ? pool - reserved : 0;
        uint256 upper = bound(modeSeed, 0, 9) < 8 ? free : pool;
        uint256 amount = bound(amountSeed, 0, upper);

        vm.prank(owner);
        try staking.collectReward(amount) {
            ghost_collected += amount;
            // Reserve property (a): a successful collect must never exceed what was collectable at call time.
            if (amount > free) _reserveViolation("collectReward exceeded collectable", owner, 0, amount, free);
        } catch (bytes memory reason) {
            if (amount == 0) {
                _expectSelector("collect_zero", "collectReward", reason, Errors.ZeroAmountProvided.selector);
            } else if (amount > free) {
                // Collect guard. amount > pool is a strict subset of amount > collectable, same error.
                _expectSelector("collect_belowReserve", "collectReward", reason, Errors.RewardPoolBelowReserved.selector);
            } else {
                _unexpected("collectReward", reason);
            }
        }
    }

    /// @notice Toggle STAKING / WITHDRAWAL / CLAIM availability (80% open, 20% closed).
    function setActionAvailability(uint256 actionSeed, uint256 openSeed) external {
        calls["setActionAvailability"]++;
        uint256 a = bound(actionSeed, 0, 2);
        bool open = bound(openSeed, 0, 9) >= 2;

        vm.prank(owner);
        try staking.changeActionAvailability(Types.DataType(a), open) {
            ghost_actionOpen[a] = open;
        } catch (bytes memory reason) {
            _unexpected("changeActionAvailability", reason);
        }
    }

    /// @notice A user transfers tokens straight to the contract (the only legitimate way balanceOf can
    ///         exceed totalDataList[STAKING] + rewardPool).
    function donate(uint256 userSeed, uint256 amountSeed) external {
        calls["donate"]++;
        address user = _pickUser(userSeed);
        uint256 amount = bound(amountSeed, 0, _min(token.balanceOf(user), 10_000e18));
        if (amount == 0) {
            skipped["donate_zero"]++;
            return;
        }
        vm.prank(user);
        token.transfer(address(staking), amount);
        ghost_donated += amount;
    }

    /// @notice Owner rescues STAKING_TOKEN. Only the excess over staked principal + reward pool may leave;
    ///         we ask for up to 2x the excess so the guard is exercised.
    function rescue(uint256 amountSeed) external {
        calls["rescue"]++;
        uint256 reserved = staking.totalDataList(Types.DataType.STAKING) + staking.rewardPool();
        uint256 bal = token.balanceOf(address(staking));
        uint256 excess = bal > reserved ? bal - reserved : 0;
        uint256 amount = bound(amountSeed, 0, excess * 2);

        vm.prank(owner);
        try staking.rescueTokens(address(token), amount) {
            ghost_rescued += amount;
            if (amount > excess) _payoutViolation("rescueTokens took more than the excess", owner, 0, amount, excess);
        } catch (bytes memory reason) {
            if (amount == 0) {
                _expectSelector("rescue_zero", "rescueTokens", reason, Errors.ZeroAmountProvided.selector);
            } else if (amount > excess) {
                _expectSelector("rescue_exceedsExcess", "rescueTokens", reason, Errors.RescueAmountExceedsExcess.selector);
            } else {
                _unexpected("rescueTokens", reason);
            }
        }
    }

    function setMinimumDeposit(uint256 seed) external {
        calls["setMinimumDeposit"]++;
        uint256 value = bound(seed, 1, 1_000e18);

        vm.prank(owner);
        try staking.setMiniumumDeposit(value) {}
        catch (bytes memory reason) {
            _unexpected("setMiniumumDeposit", reason);
        }
    }

    // ======================================
    // =        Enforcement (src only)      =
    // ======================================
    /// @notice Admin freezes an open, unfrozen deposit.
    function freeze(uint256 userSeed, uint256 depositSeed) external {
        calls["freeze"]++;
        if (legacy) {
            skipped["freeze_legacy"]++;
            return;
        }
        address user = _pickUser(userSeed);
        uint256[] memory candidates = _depositsWithStatus(user, true, true, true);
        if (candidates.length == 0) {
            skipped["freeze_none"]++;
            return;
        }
        uint256 idx = candidates[bound(depositSeed, 0, candidates.length - 1)];

        vm.prank(admin);
        try staking.freezeDeposit(user, idx) {}
        catch (bytes memory reason) {
            _unexpected("freezeDeposit", reason);
        }
    }

    /// @notice Admin unfreezes a frozen deposit.
    function unfreeze(uint256 userSeed, uint256 depositSeed) external {
        calls["unfreeze"]++;
        if (legacy) {
            skipped["unfreeze_legacy"]++;
            return;
        }
        address user = _pickUser(userSeed);
        uint256[] memory candidates = _frozenDeposits(user);
        if (candidates.length == 0) {
            skipped["unfreeze_none"]++;
            return;
        }
        uint256 idx = candidates[bound(depositSeed, 0, candidates.length - 1)];

        vm.prank(admin);
        try staking.unfreezeDeposit(user, idx) {}
        catch (bytes memory reason) {
            _unexpected("unfreezeDeposit", reason);
        }
    }

    /// @notice Owner seizes a frozen deposit. Only the principal goes to the treasury; the reward pool never moves
    ///         (periodical: reservation released; indefinite: unpaid accrual stays in the pool).
    function seize(uint256 userSeed, uint256 depositSeed) external {
        calls["seize"]++;
        if (legacy) {
            skipped["seize_legacy"]++;
            return;
        }
        address user = _pickUser(userSeed);
        uint256[] memory candidates = _frozenDeposits(user);
        if (candidates.length == 0) {
            skipped["seize_none"]++;
            return;
        }
        uint256 idx = candidates[bound(depositSeed, 0, candidates.length - 1)];
        ProgramManager.TokenDeposit memory d = staking.getDeposit(user, idx);
        uint256 balBefore = token.balanceOf(treasury);
        uint256 poolBefore = staking.rewardPool();
        bool coveredBefore = _poolCoversReserve();

        vm.prank(owner);
        try staking.seizeDeposit(user, idx) {
            uint256 got = token.balanceOf(treasury) - balBefore;
            if (got != d.amount) {
                _payoutViolation("seize payout != principal", user, idx, got, d.amount);
            }
            if (staking.rewardPool() != poolBefore) {
                _payoutViolation("seize moved rewardPool", user, idx, staking.rewardPool(), poolBefore);
            }
            ghost_seizedOut += got;
            ghost_seizedPrincipal += got;
            _checkReserveTransition("seize", user, idx, coveredBefore);
            if (staking.checkDepositStatus(user, idx) != ProgramManager.DepositStatus.SEIZED) {
                _payoutViolation("seized deposit is not SEIZED", user, idx, 0, 0);
            }
        } catch (bytes memory reason) {
            _unexpected("seizeDeposit", reason);
        }
    }

    // ======================================
    // =              Helpers               =
    // ======================================
    function _pickUser(uint256 seed) internal view returns (address) {
        return users[bound(seed, 0, users.length - 1)];
    }

    function _maxApy() internal view returns (uint256) {
        return legacy ? MAX_APY_LEGACY : MAX_APY_BPS;
    }

    /// @dev The mirrored v0.2.4 code has no freeze, so nothing is ever frozen there.
    function _isFrozen(address user, uint256 idx) internal view returns (bool) {
        return !legacy && staking.isDepositFrozen(user, idx);
    }

    function _frozenDeposits(address user) internal view returns (uint256[] memory out) {
        uint256 count = staking.checkDepositCountOfAddress(user);
        uint256[] memory tmp = new uint256[](count);
        uint256 n;
        for (uint256 i = 0; i < count; i++) {
            if (_isFrozen(user, i)) tmp[n++] = i;
        }
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
    }

    /// @dev Indices of the user's UNFROZEN deposits whose status is in the requested set.
    function _depositsWithStatus(address user, bool timeLeft, bool ready, bool indefinite)
        internal
        view
        returns (uint256[] memory out)
    {
        uint256 count = staking.checkDepositCountOfAddress(user);
        uint256[] memory tmp = new uint256[](count);
        uint256 n;
        for (uint256 i = 0; i < count; i++) {
            if (_isFrozen(user, i)) continue;
            ProgramManager.DepositStatus st = staking.checkDepositStatus(user, i);
            if (
                (timeLeft && st == ProgramManager.DepositStatus.TIME_LEFT)
                    || (ready && st == ProgramManager.DepositStatus.READY_TO_CLAIM)
                    || (indefinite && st == ProgramManager.DepositStatus.INDEFINITE)
            ) {
                tmp[n++] = i;
            }
        }
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
    }

    function _pickPeriodToAdd(uint256 seed) internal view returns (uint256) {
        // Prefer re-adding a period that once existed but is gone now.
        if (bound(seed, 0, 1) == 0) {
            uint256 n = everSeenPeriods.length;
            uint256 start = bound(seed >> 8, 0, n == 0 ? 0 : n - 1);
            for (uint256 k = 0; k < n; k++) {
                uint256 p = everSeenPeriods[(start + k) % n];
                if (!staking.checkIfStakingPeriodExists(p)) return p;
            }
        }
        return bound(seed >> 16, 0, MAX_PERIOD_DAYS);
    }

    function _markCellTouched(address user, uint256 phase, uint256 period) internal {
        if (!cellTouched[user][phase][period]) {
            cellTouched[user][phase][period] = true;
            touchedCells.push(StakingCell({user: user, phase: phase, period: period}));
        }
        if (!phasePeriodTouched[phase][period]) {
            phasePeriodTouched[phase][period] = true;
            touchedPhasePeriods.push([phase, period]);
        }
    }

    function _markPeriodSeen(uint256 period) internal {
        if (!seenPeriod[period]) {
            seenPeriod[period] = true;
            everSeenPeriods.push(period);
        }
    }

    function _randomApyTarget(uint256 n, uint256 apySeed, uint256 targetSeed)
        internal
        view
        returns (uint256[] memory apy, uint256[] memory target)
    {
        apy = new uint256[](n);
        target = new uint256[](n);
        uint256 maxApy = _maxApy();
        for (uint256 i = 0; i < n; i++) {
            apy[i] = _bound(uint256(keccak256(abi.encode(apySeed, i))), 1, maxApy);
            uint256 t = uint256(keccak256(abi.encode(targetSeed, i)));
            // 10% zero target (nothing stakeable), otherwise something roomy.
            target[i] = t % 10 == 0 ? 0 : _bound(t, 1_000e18, MAX_TARGET);
        }
    }

    function _topUpPool(uint256 amount) internal {
        uint256 bal = token.balanceOf(admin);
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        vm.prank(admin);
        try staking.provideReward(amount) {
            ghost_provided += amount;
        } catch {}
    }

    function _recordPayout(
        string memory action,
        address user,
        uint256 idx,
        uint256 got,
        uint256 principalExpected,
        uint256 rewardExpected
    ) internal {
        uint256 expected = principalExpected + rewardExpected;
        if (got != expected) {
            _payoutViolation(string.concat(action, " payout != principal + committed reward"), user, idx, got, expected);
        }
        ghost_userOut += got;
        if (got >= principalExpected) {
            ghost_principalPaid += principalExpected;
            ghost_rewardsPaid += got - principalExpected;
        } else {
            // Short-paid principal: attribute everything to principal so the pool ghost stays meaningful.
            ghost_principalPaid += got;
        }
    }

    function _poolCoversReserve() internal view returns (bool) {
        return staking.rewardPool() >= staking.totalDataList(Types.DataType.REWARD_EXPECTED);
    }

    /// @dev Unreserved part of the pool that indefinite payouts may use. The mirrored v0.2.4 code has no
    ///      getCollectableReward() (and no reserve): there the whole rewardPool is payable, which is exactly
    ///      the behaviour the legacy run is meant to expose.
    function _collectable() internal view returns (uint256) {
        return legacy ? staking.rewardPool() : staking.getCollectableReward();
    }

    /// @dev Reserve property (b): a user payout may never take rewardPool from >= REWARD_EXPECTED to below it.
    ///      (A periodical claim lowers both by the same amount; an indefinite payout is capped at the free pool.)
    function _checkReserveTransition(string memory action, address user, uint256 idx, bool coveredBefore) internal {
        if (coveredBefore && !_poolCoversReserve()) {
            _reserveViolation(
                string.concat(action, " took rewardPool below REWARD_EXPECTED"),
                user,
                idx,
                staking.rewardPool(),
                staking.totalDataList(Types.DataType.REWARD_EXPECTED)
            );
        }
    }

    function _reserveViolation(string memory what, address user, uint256 idx, uint256 got, uint256 expected)
        internal
    {
        ghost_reserveViolations++;
        ghost_reserveViolationNotes.push(
            string.concat(
                what,
                " user=",
                vm.toString(user),
                " idx=",
                vm.toString(idx),
                " got=",
                vm.toString(got),
                " limit=",
                vm.toString(expected)
            )
        );
    }

    function _payoutViolation(string memory what, address user, uint256 idx, uint256 got, uint256 expected)
        internal
    {
        ghost_payoutViolations++;
        ghost_payoutViolationNotes.push(
            string.concat(
                what,
                " user=",
                vm.toString(user),
                " idx=",
                vm.toString(idx),
                " got=",
                vm.toString(got),
                " expected=",
                vm.toString(expected)
            )
        );
    }

    function _isSelector(bytes memory reason, bytes4 sel) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 got;
        assembly {
            got := mload(add(reason, 32))
        }
        return got == sel;
    }

    function _expectSelector(string memory label, string memory action, bytes memory reason, bytes4 sel) internal {
        if (_isSelector(reason, sel)) expectedReverts[label]++;
        else _unexpected(string.concat(action, " (", label, " expected)"), reason);
    }

    function _unexpected(string memory action, bytes memory reason) internal {
        ghost_unexpectedReverts.push(string.concat(action, ": ", _describe(reason)));
    }

    function _describe(bytes memory reason) internal pure returns (string memory) {
        if (_isSelector(reason, PANIC_SELECTOR) && reason.length >= 36) {
            uint256 code;
            assembly {
                code := mload(add(reason, 36))
            }
            return string.concat("Panic(", vm.toString(code), ")");
        }
        return vm.toString(reason);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
