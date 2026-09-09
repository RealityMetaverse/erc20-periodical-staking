// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AttackBase.t.sol";
import {ReentrantERC20} from "../../../shared/malicious/MaliciousTokens.sol";
import {
    MaliciousLimitController,
    MaliciousRequirementChecker,
    ReentrancyAttacker
} from "../../../shared/malicious/MaliciousControllers.sol";

/// @title Reentrancy
/// @notice The only external call surfaces of the staking contract are the token, the limit controller
///         and the requirement checker. Every re-entry attempt through them must be rejected and must
///         leave accounting untouched.
contract ReentrancyTest is AttackBase {
    ReentrantERC20 internal rtoken;
    ERC20PeriodicalStaking internal rs;
    ReentrancyAttacker internal atk;

    MaliciousLimitController internal mlc;
    MaliciousRequirementChecker internal mrc;

    uint256 internal constant AMT = 10_000 * ONE;

    function setUp() public override {
        super.setUp();
        rtoken = new ReentrantERC20();
        rtoken.mint(address(this), 10_000_000 * ONE);
        rs = _deployConfigured(address(rtoken));
        atk = new ReentrancyAttacker(address(rs), address(rtoken));
        rtoken.mint(address(atk), 100_000 * ONE);
        atk.approveAll();

        mlc = new MaliciousLimitController();
        mrc = new MaliciousRequirementChecker();
    }

    function _rsApy(uint256 phase, uint256 period) internal view returns (uint256) {
        return rs.getPhasePeriodData(Types.PhasePeriodDataType.APY, phase, period);
    }

    function _atkStake(uint256 period, uint256 amount) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = atk.exec(abi.encodeCall(rs.safeStake, (0, period, amount, _rsApy(0, period))));
    }

    function _rsConservation() internal {
        assertEq(
            rtoken.balanceOf(address(rs)),
            rs.totalDataList(Types.DataType.STAKING) + rs.rewardPool(),
            "conservation broken on reentrant token deployment"
        );
    }

    // ---------------------------------------------------------------------
    // Token hooks: transferFrom (inside safeStake / provideReward)
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: re-entering safeStake from inside the token's transferFrom creates a second deposit.
    function test_reenter_safeStake_fromTransferFrom_isBlocked() public {
        atk.setReenter(abi.encodeCall(rs.safeStake, (0, P0, AMT, _rsApy(0, P0))));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), false, true, true, 5);

        (bool ok,) = _atkStake(P0, AMT);
        assertTrue(ok, "outer stake should succeed");
        assertEq(atk.pokes(), 1);
        assertFalse(atk.lastSuccess(), "inner stake must fail");
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR, "must be blocked by nonReentrant");
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 1, "exactly one deposit");
        assertEq(rs.totalDataList(Types.DataType.STAKING), AMT);
        _rsConservation();
    }

    /// @dev Hypothesis: when the token propagates the inner revert, the outer stake fully reverts and nothing moves.
    function test_reenter_safeStake_fromTransferFrom_propagated_revertsAtomically() public {
        atk.setReenter(abi.encodeCall(rs.safeStake, (0, P0, AMT, _rsApy(0, P0))));
        rtoken.setHook(address(atk), abi.encodeCall(atk.pokeStrict, ()), false, true, false, 5);

        uint256 balBefore = rtoken.balanceOf(address(atk));
        (bool ok, bytes memory ret) = _atkStake(P0, AMT);
        assertFalse(ok, "outer stake must revert");
        assertEq(_selectorOf(ret), REENTRANT_CALL_SELECTOR);
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 0);
        assertEq(rtoken.balanceOf(address(atk)), balBefore, "no tokens may leave the attacker");
        assertEq(rs.totalDataList(Types.DataType.STAKING), 0);
        _rsConservation();
    }

    /// @dev Hypothesis: re-entering withdrawDeposit from inside transferFrom during a stake (cross-function).
    function test_reenter_withdraw_fromTransferFrom_duringStake_isBlocked() public {
        rtoken.clearHook();
        (bool ok0,) = _atkStake(P0, AMT);
        assertTrue(ok0);

        atk.setReenter(abi.encodeCall(rs.withdrawDeposit, (0)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), false, true, true, 5);
        (bool ok,) = _atkStake(P0, AMT);
        assertTrue(ok);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rs.totalDataList(Types.DataType.STAKING), 2 * AMT, "both deposits still open");
        _rsConservation();
    }

    // ---------------------------------------------------------------------
    // Token hooks: transfer (inside withdraw / claim / claimAll / collectReward)
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: re-entering withdrawDeposit from the payout transfer pays twice.
    function test_reenter_withdraw_fromTransfer_isBlocked_paysOnce() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        vm.warp(_now() + 10 days);
        uint256 reward = rs.getDeposit(address(atk), 0).rewardGenerated;
        assertGt(reward, 0);

        atk.setReenter(abi.encodeCall(rs.withdrawDeposit, (0)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        uint256 before = rtoken.balanceOf(address(atk));
        (bool ok,) = atk.exec(abi.encodeCall(rs.withdrawDeposit, (0)));
        assertTrue(ok);
        assertEq(atk.pokes(), 1);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rtoken.balanceOf(address(atk)) - before, AMT + reward, "paid exactly once");
        assertEq(uint256(rs.checkDepositStatus(address(atk), 0)), uint256(ProgramManager.DepositStatus.WITHDRAWN));
        _rsConservation();
    }

    /// @dev Hypothesis: re-entering claimDeposit from the payout transfer of a matured deposit pays twice.
    function test_reenter_claim_fromTransfer_isBlocked_paysOnce() public {
        rtoken.clearHook();
        _atkStake(P30, AMT);
        uint256 reward = rs.getDeposit(address(atk), 0).rewardGenerated;
        vm.warp(_now() + 30 days);

        atk.setReenter(abi.encodeCall(rs.claimDeposit, (0)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        uint256 before = rtoken.balanceOf(address(atk));
        (bool ok,) = atk.exec(abi.encodeCall(rs.claimDeposit, (0)));
        assertTrue(ok);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rtoken.balanceOf(address(atk)) - before, AMT + reward);
        assertEq(rs.totalDataList(Types.DataType.REWARD_EXPECTED), 0);
        _rsConservation();
    }

    /// @dev Hypothesis: re-entering claimAll from inside claimAll's first payout double-claims later deposits.
    function test_reenter_claimAll_fromTransfer_isBlocked_eachPaidOnce() public {
        rtoken.clearHook();
        _atkStake(P30, AMT);
        _atkStake(P30, AMT);
        _atkStake(P30, AMT);
        uint256 rewardEach = rs.getDeposit(address(atk), 0).rewardGenerated;
        vm.warp(_now() + 30 days);

        atk.setReenter(abi.encodeWithSignature("claimAll()"));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 10);

        uint256 before = rtoken.balanceOf(address(atk));
        (bool ok,) = atk.exec(abi.encodeWithSignature("claimAll()"));
        assertTrue(ok);
        assertEq(atk.pokes(), 3, "one hook per payout");
        assertFalse(atk.lastSuccess());
        assertEq(rtoken.balanceOf(address(atk)) - before, 3 * (AMT + rewardEach), "each deposit paid exactly once");
        assertEq(rs.totalDataList(Types.DataType.STAKING), 0);
        _rsConservation();
    }

    /// @dev Hypothesis: re-entering safeStake from the payout transfer of a withdraw (cross-function).
    function test_reenter_stake_fromTransfer_duringWithdraw_isBlocked() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        atk.setReenter(abi.encodeCall(rs.safeStake, (0, P0, AMT, _rsApy(0, P0))));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        (bool ok,) = atk.exec(abi.encodeCall(rs.withdrawDeposit, (0)));
        assertTrue(ok);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 1, "no new deposit sneaked in");
        _rsConservation();
    }

    /// @dev Hypothesis (read-only reentrancy): state observed from inside the payout transfer is already final (CEI).
    function test_readOnlyReentrancy_stateIsFinalBeforeTransfer() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        atk.setReenter(abi.encodeCall(rs.totalDataList, (Types.DataType.STAKING)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        (bool ok,) = atk.exec(abi.encodeCall(rs.withdrawDeposit, (0)));
        assertTrue(ok);
        assertTrue(atk.lastSuccess());
        assertEq(abi.decode(atk.lastReturn(), (uint256)), 0, "totalStaked must already be 0 during payout");
    }

    /// @dev Hypothesis: the deposit status observed mid-payout is already WITHDRAWN (no window for double spend).
    function test_readOnlyReentrancy_statusAlreadyClosedDuringPayout() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        atk.setReenter(abi.encodeCall(rs.checkDepositStatus, (address(atk), 0)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        (bool ok,) = atk.exec(abi.encodeCall(rs.withdrawDeposit, (0)));
        assertTrue(ok);
        assertTrue(atk.lastSuccess());
        assertEq(abi.decode(atk.lastReturn(), (uint8)), uint8(ProgramManager.DepositStatus.WITHDRAWN));
    }

    /// @dev Hypothesis: the owner re-entering collectReward from the collect payout drains twice.
    function test_reenter_collectReward_fromTransfer_isBlocked() public {
        // owner (this) receives the collect payout; hook calls back into collectReward as the token contract,
        // which is not the owner, so it must fail on access control OR reentrancy — never succeed.
        rtoken.setHook(address(rs), abi.encodeCall(rs.collectReward, (1)), true, false, true, 5);
        uint256 collectable = rs.getCollectableReward();
        uint256 before = rtoken.balanceOf(address(this));
        rs.collectReward(collectable / 2);
        assertFalse(rtoken.lastHookSuccess(), "reentrant collect must fail");
        assertEq(rtoken.balanceOf(address(this)) - before, collectable / 2);
        _rsConservation();
    }

    // ---------------------------------------------------------------------
    // Malicious limit controller
    // ---------------------------------------------------------------------

    function _useMLC(MaliciousLimitController.Mode m) internal {
        mlc.setMode(m);
        staking.setLimitController(address(mlc));
    }

    /// @dev Hypothesis: a limit controller that re-enters safeStake during the limit check creates a deposit.
    function test_maliciousLC_reenter_cannotMutate() public {
        mlc.setReenter(address(staking), abi.encodeCall(staking.safeStake, (0, P0, 1_000 * ONE, _apy(0, P0))));
        _useMLC(MaliciousLimitController.Mode.REENTER);
        _stake(alice, 0, P0, 1_000 * ONE);
        assertEq(staking.checkDepositCountOfAddress(alice), 1, "controller must not have created a deposit");
        assertEq(_total(Types.DataType.STAKING), 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a reverting limit controller bricks the contract. It may only block *new* stakes.
    function test_maliciousLC_revert_onlyBlocksStake_claimsUnaffected() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 e = _stake(bob, 0, P0, 1_000 * ONE);
        _useMLC(MaliciousLimitController.Mode.REVERT);

        uint256 h1 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(MaliciousLimitController.ControllerRevert.selector);
        staking.safeStake(0, P30, 1_000 * ONE, h1);
        _assertAccounting();

        _warpDays(30);
        _claim(alice, d);
        _withdraw(bob, e);
        _assertAccounting();

        staking.setLimitController(address(0));
        _stake(alice, 0, P30, 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a controller that reverts with empty data leaves state half-written.
    function test_maliciousLC_emptyRevert_atomic() public {
        _useMLC(MaliciousLimitController.Mode.EMPTY_REVERT);
        uint256 bal = token.balanceOf(alice);
        uint256 h2 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert();
        staking.safeStake(0, P30, 1_000 * ONE, h2);
        assertEq(token.balanceOf(alice), bal);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: a gas-burning controller consumes the stake's gas; the call must simply revert.
    function test_maliciousLC_gasBurn_revertsCleanly() public {
        _useMLC(MaliciousLimitController.Mode.GAS_BURN);
        uint256 bal = token.balanceOf(alice);
        bytes memory data = abi.encodeCall(staking.safeStake, (0, P30, 1_000 * ONE, _apy(0, P30)));
        vm.prank(alice);
        (bool ok,) = address(staking).call{gas: 3_000_000}(data);
        assertFalse(ok);
        assertEq(token.balanceOf(alice), bal);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: wrong-length batch arrays from the controller corrupt UI reads but must not affect staking.
    function test_maliciousLC_wrongLength_stakeStillWorks_viewReverts() public {
        _useMLC(MaliciousLimitController.Mode.WRONG_LENGTH);
        _stake(alice, 0, P30, 1_000 * ONE);
        _assertAccounting();
        vm.expectRevert();
        staking.getPhasePeriodUserData(alice);
        vm.expectRevert();
        staking.getProgramDataWithUserData(alice);
        // Reads that do not touch the controller keep working
        staking.getProgramData();
        staking.checkClaimableDataFor(alice);
    }

    /// @dev Hypothesis: a controller returning 0 for everyone blocks stakes with an exact error, nothing else.
    function test_maliciousLC_allowNone_exactError() public {
        _useMLC(MaliciousLimitController.Mode.ALLOW_NONE);
        uint256 h3 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 1_000 * ONE, 0));
        staking.safeStake(0, P30, 1_000 * ONE, h3);
    }

    // ---------------------------------------------------------------------
    // Malicious requirement checker
    // ---------------------------------------------------------------------

    function _useMRC(MaliciousRequirementChecker.Mode m) internal {
        mrc.setMode(m);
        staking.setRequirementChecker(address(mrc));
    }

    /// @dev Hypothesis: a requirement checker re-entering withdrawDeposit during the check mutates state.
    function test_maliciousRC_reenter_cannotMutate() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        mrc.setReenter(address(staking), abi.encodeCall(staking.withdrawDeposit, (d)));
        _useMRC(MaliciousRequirementChecker.Mode.REENTER);
        _stake(alice, 0, P0, 1_000 * ONE);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.INDEFINITE), "not withdrawn");
        assertEq(_total(Types.DataType.STAKING), 2_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a reverting checker only blocks new stakes; claims/withdrawals must not consult it.
    function test_maliciousRC_revert_onlyBlocksStake() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        _useMRC(MaliciousRequirementChecker.Mode.REVERT);
        uint256 h4 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(MaliciousRequirementChecker.CheckerRevert.selector);
        staking.safeStake(0, P30, 1_000 * ONE, h4);
        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: FAIL mode yields the exact RequirementNotMet error with the checker's figures.
    function test_maliciousRC_fail_exactError() public {
        _useMRC(MaliciousRequirementChecker.Mode.FAIL);
        uint256 h5 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.RequirementNotMet.selector, 1, 0));
        staking.safeStake(0, P30, 1_000 * ONE, h5);
        assertFalse(staking.checkIfUserMeetsRequirements(alice, 0, P30));
    }

    /// @dev Hypothesis: gas-burning checker.
    function test_maliciousRC_gasBurn_revertsCleanly() public {
        _useMRC(MaliciousRequirementChecker.Mode.GAS_BURN);
        bytes memory data = abi.encodeCall(staking.safeStake, (0, P30, 1_000 * ONE, _apy(0, P30)));
        vm.prank(alice);
        (bool ok,) = address(staking).call{gas: 3_000_000}(data);
        assertFalse(ok);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: wrong-length batch from the checker must not affect staking or claiming.
    function test_maliciousRC_wrongLength_writePathsUnaffected() public {
        _useMRC(MaliciousRequirementChecker.Mode.WRONG_LENGTH);
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        vm.expectRevert();
        staking.getProgramData();
        vm.expectRevert();
        staking.getPhasePeriodUserData(alice);
        _warpDays(30);
        _claim(alice, d);
        _assertAccounting();
    }

    /// @dev Hypothesis: after the owner removes a hostile checker/controller everything is back to normal.
    function test_hostileExternals_recoverableByOwner() public {
        _useMRC(MaliciousRequirementChecker.Mode.REVERT);
        _useMLC(MaliciousLimitController.Mode.REVERT);
        uint256 h6 = _apy(0, P30);
        vm.prank(alice);
        vm.expectRevert();
        staking.safeStake(0, P30, 1_000 * ONE, h6);
        staking.setRequirementChecker(address(0));
        staking.setLimitController(address(0));
        _stake(alice, 0, P30, 1_000 * ONE);
        staking.getProgramDataWithUserData(alice);
        _assertAccounting();
    }
}
