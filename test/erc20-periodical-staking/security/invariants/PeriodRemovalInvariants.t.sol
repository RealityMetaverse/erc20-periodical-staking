// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {InvariantBase} from "./InvariantBase.sol";
import {Handler} from "./Handler.sol";

/// @title PeriodRemovalInvariants
/// @notice Lighter suite that focuses the invariant runner on period/phase add -> remove -> re-add churn while
///         deposits are open. The star is the liveness invariant (the known production lockup).
/// @dev Selector weights: stake x3, remove/add period x2 each, push/pop phase, warp x2, claim/withdraw.
contract PeriodRemovalInvariants is InvariantBase {
    function setUp() external {
        _deploy(false);

        bytes4[] memory s = new bytes4[](15);
        s[0] = Handler.stake.selector;
        s[1] = Handler.stake.selector;
        s[2] = Handler.stake.selector;
        s[3] = Handler.removeStakingPeriod.selector;
        s[4] = Handler.removeStakingPeriod.selector;
        s[5] = Handler.addStakingPeriod.selector;
        s[6] = Handler.addStakingPeriod.selector;
        s[7] = Handler.pushStakingPhase.selector;
        s[8] = Handler.popStakingPhase.selector;
        s[9] = Handler.changeStakingPhase.selector;
        s[10] = Handler.warp.selector;
        s[11] = Handler.warp.selector;
        s[12] = Handler.claim.selector;
        s[13] = Handler.withdraw.selector;
        s[14] = Handler.claimAll.selector;
        _target(s);
    }

    /// @notice LIVENESS: every open deposit stays closable through arbitrary period/phase churn.
    function invariant_churn_everyOpenDepositIsClosable() external {
        _check_everyOpenDepositIsClosable();
    }

    /// @notice Period/phase removal must never touch token accounting.
    function invariant_churn_tokenConservation() external {
        _check_tokenConservation();
    }

    /// @notice Per-(phase,period) STAKED sums survive removal/re-add.
    function invariant_churn_phasePeriodStakedSum() external {
        _check_phasePeriodStakedSum();
    }

    /// @notice Per-user (phase,period) sums survive removal/re-add.
    function invariant_churn_userPhasePeriodSums() external {
        _check_userPhasePeriodSums();
    }

    /// @notice Reserved rewards still match the open deposits after churn.
    function invariant_churn_rewardExpectedMatchesOpenDeposits() external {
        _check_rewardExpectedMatchesOpenDeposits();
    }

    /// @notice Reserve properties (a)+(b) hold through churn (collect guard, indefinite payouts from the free pool only).
    function invariant_churn_reserveRespected() external {
        _check_reserveRespected();
    }

    /// @notice Matured periodical deposits on removed/re-added periods are claimable with no pool top-up whenever
    ///         the pool covers REWARD_EXPECTED; otherwise they fail only with NotEnoughFundsInRewardPool.
    function invariant_churn_maturedDepositsClaimableWithoutTopUp() external {
        _check_maturedDepositsClaimableWithoutTopUp();
    }

    /// @notice Period list stays sorted/unique through remove/re-add; phase index stays valid.
    function invariant_churn_periodListAndPhaseIndex() external {
        _check_periodListAndPhaseIndex();
    }

    /// @notice No claim/withdraw/admin call hit an unexplained revert (panics from zeroed counters).
    function invariant_churn_noUnexpectedReverts() external {
        _check_noUnexpectedReverts();
    }
}
