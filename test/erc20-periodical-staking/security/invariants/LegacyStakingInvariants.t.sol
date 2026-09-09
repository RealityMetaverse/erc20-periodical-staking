// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {InvariantBase} from "./InvariantBase.sol";
import {Handler} from "./Handler.sol";

/// @dev Minimal cheatcode surface missing from the vendored forge-std 1.2.0 Vm interface.
interface VmExtra {
    function skip(bool skipTest) external;
    function envOr(string calldata name, bool defaultValue) external view returns (bool);
}

/// @title LegacyStakingInvariants
/// @notice Runs the same invariants against the mirrored v0.2.4 code (./legacy, git 6d63bbe).
///         This suite is EXPECTED TO FAIL: it exists to prove the invariants detect the known
///         period-removal lockup and the v0.2.4 accounting gaps (zeroed cells, unprotected reward pool), so a future regression cannot slip
///         through silently. It is skipped unless INVARIANT_LEGACY=true is set, so the normal test
///         run stays green.
/// @dev    INVARIANT_LEGACY=true FOUNDRY_INVARIANT_RUNS=32 FOUNDRY_INVARIANT_DEPTH=40 \
///           forge test --match-contract LegacyStakingInvariants
contract LegacyStakingInvariants is InvariantBase {
    function setUp() external {
        if (!VmExtra(address(vm)).envOr("INVARIANT_LEGACY", false)) {
            VmExtra(address(vm)).skip(true);
        }
        _deploy(true);

        bytes4[] memory s = new bytes4[](12);
        s[0] = Handler.stake.selector;
        s[1] = Handler.stake.selector;
        s[2] = Handler.withdraw.selector;
        s[3] = Handler.claim.selector;
        s[4] = Handler.claimAll.selector;
        s[5] = Handler.warp.selector;
        s[6] = Handler.removeStakingPeriod.selector;
        s[7] = Handler.addStakingPeriod.selector;
        s[8] = Handler.pushStakingPhase.selector;
        s[9] = Handler.popStakingPhase.selector;
        s[10] = Handler.collectReward.selector;
        s[11] = Handler.provideReward.selector;
        _target(s);
    }

    /// @notice v0.2.4: removeStakingPeriod/popStakingPhase zero STAKED -> claim/withdraw underflow (README incident).
    function invariant_legacy_everyOpenDepositIsClosable() external {
        _check_everyOpenDepositIsClosable();
    }

    /// @notice v0.2.4: per-(phase,period) STAKED zeroed on removal while totalDataList[STAKING] is not.
    function invariant_legacy_phasePeriodStakedSum() external {
        _check_phasePeriodStakedSum();
    }

    /// @notice v0.2.4: userPhasePeriodDataList zeroed on removal while userDataList is not.
    function invariant_legacy_userPhasePeriodSums() external {
        _check_userPhasePeriodSums();
    }

    /// @notice v0.2.4: collectReward may drain below committed rewards (recorded as a reserve violation).
    function invariant_legacy_reserveRespected() external {
        _check_reserveRespected();
    }

    /// @notice v0.2.4: claim/withdraw on a removed period revert with Panic(0x11) -> unexplained reverts.
    function invariant_legacy_noUnexpectedReverts() external {
        _check_noUnexpectedReverts();
    }

    /// @notice Token conservation should hold even on v0.2.4 (removal never moved tokens) -- control invariant.
    function invariant_legacy_tokenConservation() external {
        _check_tokenConservation();
    }
}
