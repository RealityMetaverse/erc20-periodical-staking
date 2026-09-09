// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {InvariantBase} from "./InvariantBase.sol";
import {Handler} from "./Handler.sol";

/// @title StakingInvariants
/// @notice Full stateful-fuzzing suite for ERC20PeriodicalStaking. All handler actions enabled.
/// @dev Run with, e.g.:
///      FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=50 forge test --match-path 'test/erc20-periodical-staking/security/invariants/*'
///      Handler reverts are caught inside the handler, so fail_on_revert is irrelevant.
contract StakingInvariants is InvariantBase {
    function setUp() external {
        _deploy(false);

        bytes4[] memory s = new bytes4[](18);
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
        _target(s);
    }

    /// @notice token.balanceOf(contract) == totalDataList[STAKING] + rewardPool + (donated - rescued), exactly.
    ///         Direct donations are the only legitimate excess; rescueTokens may take at most that excess.
    function invariant_tokenConservation() external {
        _check_tokenConservation();
    }

    /// @notice Contract balance and staked total also reconcile against handler token-flow ghosts.
    function invariant_tokenFlowGhosts() external {
        _check_tokenFlowGhosts();
    }

    /// @notice Reserve properties (a)+(b): no successful collectReward exceeded getCollectableReward() at call time,
    ///         and no user payout ever took rewardPool from >= REWARD_EXPECTED to below it.
    function invariant_reserveRespected() external {
        _check_reserveRespected();
    }

    /// @notice rewardPool == provided - collected - rewards actually paid (only those three flows move it).
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

    /// @notice Per user, sum over (phase, period) of userPhasePeriodDataList[t] == userDataList[t]
    ///         for STAKING, REWARD_EXPECTED, WITHDRAWAL, CLAIM.
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

    /// @notice LIVENESS: every open deposit can be closed (claim after maturity / withdraw for indefinite)
    ///         with actions open and the pool funded. Known-incident detector.
    function invariant_everyOpenDepositIsClosable() external {
        _check_everyOpenDepositIsClosable();
    }

    /// @notice Reserve property (c): whenever rewardPool >= REWARD_EXPECTED, every open periodical deposit is
    ///         claimable at maturity WITHOUT any pool top-up. When the pool is short, a matured claim may only
    ///         fail with NotEnoughFundsInRewardPool (never a panic). Detects reserve leaks that the funded
    ///         liveness check above deliberately masks.
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

    /// @notice checkClaimableDataFor(user) equals what claimAll actually pays.
    function invariant_claimableDataMatchesPayout() external {
        _check_claimableDataMatchesPayout();
    }

    /// @notice Every payout equals principal + committed reward; early withdraw never pays a reward.
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
}
