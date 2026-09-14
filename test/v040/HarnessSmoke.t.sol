// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {InvariantBase} from "../erc20-periodical-staking/security/invariants/InvariantBase.sol";
import {AttackBase} from "../erc20-periodical-staking/security/attacks/AttackBase.t.sol";
import {V030Base} from "../erc20-periodical-staking/v030/V030Base.sol";
import {ProgramManager} from "../../src/contracts/erc20-periodical-staking/ProgramManager.sol";

/// @notice Proves the migrated shared fixtures drive the v0.4.0 contract: invariant handler (voucher stake,
///         freeze, seize, claim), AttackBase accounting, and the TestSetUp/V030Base voucher path.
contract HandlerHarnessSmokeTest is InvariantBase {
    function setUp() external {
        _deploy(false);
    }

    function test_handler_voucherStakeFreezeSeizeClaim() external {
        for (uint256 i = 0; i < 6; i++) {
            handler.stake(i, i, uint256(keccak256(abi.encode(i))), i);
        }
        handler.warp(100 days);
        handler.freeze(0, 0);
        handler.freeze(1, 0);
        handler.seize(0, 0);
        handler.unfreeze(1, 0);
        for (uint256 i = 0; i < 6; i++) {
            handler.claimAll(i);
        }

        assertGt(handler.ghost_userIn(), 0, "no stake went through");
        assertGt(handler.calls("seize"), 0);
        _check_noUnexpectedReverts();
        _check_payoutCommitments();
        _check_reserveRespected();
        _check_tokenConservation();
        _check_tokenFlowGhosts();
        _check_rewardPoolAccounting();
        _check_userSumsMatchTotals();
        _check_phasePeriodStakedSum();
        _check_userPhasePeriodSums();
        _check_rewardExpectedMatchesOpenDeposits();
        _check_activeStartIndex();
        _check_everyOpenDepositIsClosable();
        _check_claimableDataMatchesPayout();
    }
}

contract AttackBaseHarnessSmokeTest is AttackBase {
    function test_attackBase_voucherStakeAndAccounting() external {
        uint256 n = _stake(alice, 0, P30, 1_000 * ONE);
        _stake(bob, 0, P0, 500 * ONE);
        assertEq(_deposit(alice, n).APY, APY_PHASE0[1]);
        _warpDays(P30);
        _claim(alice, n);
        _assertAccounting();
    }
}

contract V030BaseHarnessSmokeTest is V030Base {
    function test_v030Base_voucherStake() external {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        ProgramManager.TokenDeposit memory d = stakingContract.getDeposit(userOne, 0);
        assertEq(d.APY, APY);
        assertEq(d.rewardGenerated, _periodicalReward(STAKE_AMOUNT, PERIOD_SHORT));
    }
}
