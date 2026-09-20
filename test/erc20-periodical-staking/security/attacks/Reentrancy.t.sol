// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ReentrantERC20} from "../../../shared/malicious/MaliciousTokens.sol";
import {MaliciousLimitController, ReentrancyAttacker} from "../../../shared/malicious/MaliciousControllers.sol";

/// @notice ERC-1271 voucher signer that can be switched into hostile modes.
/// @dev Since audit finding #39 the staking contract never calls a contract signer (ECDSA only). Kept to prove that.
contract MaliciousVoucherSigner is IERC1271 {
    enum Mode {
        VALID, // approves every hash
        INVALID, // wrong magic value
        REVERT,
        REENTER, // tries to call back into the staking contract; approves only if the guard blocked it
        GAS_BURN
    }

    bytes4 internal constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    Mode public mode;
    address public target;
    bytes public reenterData;

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenter(address target_, bytes calldata data) external {
        target = target_;
        reenterData = data;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        if (mode == Mode.VALID) return IERC1271.isValidSignature.selector;
        if (mode == Mode.INVALID) return 0xffffffff;
        if (mode == Mode.REVERT) revert("signer says no");
        if (mode == Mode.REENTER) {
            (bool ok, bytes memory ret) = target.staticcall(reenterData);
            if (!ok && ret.length >= 4 && bytes4(ret) == REENTRANT) return IERC1271.isValidSignature.selector;
            return 0x00000000;
        }
        uint256 x;
        while (true) {
            x++;
        }
        return 0x00000000;
    }
}

/// @title Reentrancy
/// @notice The external call surfaces of the staking contract are the token, the limit controller and (since
///         v0.4.0) an ERC-1271 voucher signer. Every re-entry attempt through them must be rejected and must
///         leave accounting untouched; a voucher must never be spendable twice through re-entry.
contract ReentrancyTest is VoucherAttackBase {
    ReentrantERC20 internal rtoken;
    ERC20PeriodicalStaking internal rs;
    ReentrancyAttacker internal atk;

    MaliciousLimitController internal mlc;
    MaliciousVoucherSigner internal msig;

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
        msig = new MaliciousVoucherSigner();
    }

    function _rsApy(uint256 phase, uint256 period) internal view returns (uint256) {
        return rs.getPhasePeriodData(Types.PhasePeriodDataType.APY, phase, period);
    }

    /// @dev Calldata for a fresh, validly signed stake of the attacker contract on `rs`.
    function _atkStakeData(uint256 period, uint256 amount) internal returns (bytes memory) {
        return _stakeData(rs, address(atk), 0, period, amount, _rsApy(0, period));
    }

    function _atkStake(uint256 period, uint256 amount) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = atk.exec(_atkStakeData(period, amount));
    }

    function _rsConservation() internal {
        assertEq(
            rtoken.balanceOf(address(rs)),
            rs.totalDataList(Types.DataType.STAKING) + rs.rewardPool(),
            "conservation broken on reentrant token deployment"
        );
    }

    // ---------------------------------------------------------------------
    // Token hooks: transferFrom (inside stakeWithVoucher / provideReward)
    // ---------------------------------------------------------------------

    /// @dev Hypothesis: re-entering stakeWithVoucher (fresh voucher) from inside transferFrom creates a second deposit.
    function test_reenter_stake_fromTransferFrom_isBlocked() public {
        atk.setReenter(_atkStakeData(P0, AMT));
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

    /// @dev Hypothesis: re-entering with the SAME voucher while its nonce is not yet visible as used spends it
    ///      twice. The guard blocks the inner call, and afterwards the voucher is spent for good.
    function test_reenter_sameVoucher_fromTransferFrom_blocked_thenReplayRejected() public {
        bytes memory data = _atkStakeData(P0, AMT);
        atk.setReenter(data);
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), false, true, true, 5);

        (bool ok,) = atk.exec(data);
        assertTrue(ok);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 1);

        rtoken.clearHook();
        (bool ok2, bytes memory ret) = atk.exec(data);
        assertFalse(ok2, "replay after the outer stake must fail");
        assertEq(_selectorOf(ret), Errors.VoucherNonceUsed.selector);
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 1);
        _rsConservation();
    }

    /// @dev Hypothesis: when the token propagates the inner revert, the outer stake fully reverts and nothing moves
    ///      (the voucher nonce included: it stays usable).
    function test_reenter_stake_fromTransferFrom_propagated_revertsAtomically() public {
        atk.setReenter(_atkStakeData(P0, AMT));
        rtoken.setHook(address(atk), abi.encodeCall(atk.pokeStrict, ()), false, true, false, 5);

        uint256 balBefore = rtoken.balanceOf(address(atk));
        uint256 nonce = _nextVoucherNonce[address(atk)];
        (bool ok, bytes memory ret) = _atkStake(P0, AMT);
        assertFalse(ok, "outer stake must revert");
        assertEq(_selectorOf(ret), REENTRANT_CALL_SELECTOR);
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 0);
        assertEq(rtoken.balanceOf(address(atk)), balBefore, "no tokens may leave the attacker");
        assertEq(rs.totalDataList(Types.DataType.STAKING), 0);
        assertFalse(rs.isVoucherNonceUsed(address(atk), nonce), "reverted stake must not burn the nonce");
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
    // Token hooks: transfer (inside withdraw / claim / claimAll / collectReward / seize)
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

    /// @dev Hypothesis: re-entering claimAll from inside claimAll's payout double-claims deposits. claimAll now
    ///      aggregates into ONE transfer, so the hook fires once and every deposit is already closed by then.
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
        assertEq(atk.pokes(), 1, "one aggregated payout");
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rtoken.balanceOf(address(atk)) - before, 3 * (AMT + rewardEach), "each deposit paid exactly once");
        assertEq(rs.totalDataList(Types.DataType.STAKING), 0);
        _rsConservation();
    }

    /// @dev Hypothesis: re-entering stakeWithVoucher from the payout transfer of a withdraw (cross-function).
    function test_reenter_stake_fromTransfer_duringWithdraw_isBlocked() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        atk.setReenter(_atkStakeData(P0, AMT));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        (bool ok,) = atk.exec(abi.encodeCall(rs.withdrawDeposit, (0)));
        assertTrue(ok);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rs.checkDepositCountOfAddress(address(atk)), 1, "no new deposit sneaked in");
        _rsConservation();
    }

    /// @dev Hypothesis: a depositor being seized re-enters withdrawDeposit from the treasury payout to rescue its
    ///      principal as well. The guard blocks it; the treasury is paid once and the attacker nothing.
    function test_reenter_withdraw_fromSeizePayout_isBlocked() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        rs.freezeDeposit(address(atk), 0);
        atk.setReenter(abi.encodeCall(rs.withdrawDeposit, (0)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        uint256 atkBefore = rtoken.balanceOf(address(atk));
        rs.seizeDeposit(address(atk), 0);
        assertEq(atk.pokes(), 1);
        assertFalse(atk.lastSuccess());
        assertEq(_selectorOf(atk.lastReturn()), REENTRANT_CALL_SELECTOR);
        assertEq(rtoken.balanceOf(treasury), AMT, "treasury paid once");
        assertEq(rtoken.balanceOf(address(atk)), atkBefore, "attacker receives nothing");
        assertEq(uint256(rs.checkDepositStatus(address(atk), 0)), uint256(ProgramManager.DepositStatus.SEIZED));
        _rsConservation();
    }

    /// @dev Hypothesis (read-only reentrancy): during the seize payout the deposit still looks open.
    function test_readOnlyReentrancy_statusSeizedDuringSeizePayout() public {
        rtoken.clearHook();
        _atkStake(P0, AMT);
        rs.freezeDeposit(address(atk), 0);
        atk.setReenter(abi.encodeCall(rs.checkDepositStatus, (address(atk), 0)));
        rtoken.setHook(address(atk), abi.encodeCall(atk.poke, ()), true, false, true, 5);

        rs.seizeDeposit(address(atk), 0);
        assertTrue(atk.lastSuccess());
        assertEq(abi.decode(atk.lastReturn(), (uint8)), uint8(ProgramManager.DepositStatus.SEIZED));
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
        mlc.setStakingContract(address(staking)); // setLimitController checks stakingContract() (finding #16)
        staking.setLimitController(address(mlc));
    }

    /// @dev Hypothesis: a limit controller that re-enters stakeWithVoucher during the limit check creates a deposit.
    function test_maliciousLC_reenter_cannotMutate() public {
        mlc.setReenter(address(staking), _stakeData(staking, alice, 0, P0, 1_000 * ONE, _apy(0, P0)));
        _useMLC(MaliciousLimitController.Mode.REENTER);
        _stake(alice, 0, P0, 1_000 * ONE);
        assertEq(staking.checkDepositCountOfAddress(alice), 1, "controller must not have created a deposit");
        assertEq(_total(Types.DataType.STAKING), 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a reverting limit controller bricks the contract. It may only block *new* stakes.
    ///      Removing it does not reopen staking without limits; a working controller does.
    function test_maliciousLC_revert_onlyBlocksStake_claimsUnaffected() public {
        uint256 d = _stake(alice, 0, P30, 1_000 * ONE);
        uint256 e = _stake(bob, 0, P0, 1_000 * ONE);
        _useMLC(MaliciousLimitController.Mode.REVERT);

        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, _apy(0, P30), abi.encodeWithSelector(MaliciousLimitController.ControllerRevert.selector)
        );
        _assertAccounting();

        _warpDays(30);
        _claim(alice, d);
        _withdraw(bob, e);
        _assertAccounting();

        staking.setLimitController(address(0));
        _expectStakeRevert(
            alice, 0, P30, 1_000 * ONE, _apy(0, P30), abi.encodeWithSelector(Errors.LimitControllerNotSet.selector)
        );
        staking.setLimitController(address(new OpenLimitController(address(staking))));
        _stake(alice, 0, P30, 1_000 * ONE);
        _assertAccounting();
    }

    /// @dev Hypothesis: a controller that reverts with empty data leaves state half-written.
    function test_maliciousLC_emptyRevert_atomic() public {
        _useMLC(MaliciousLimitController.Mode.EMPTY_REVERT);
        uint256 bal = token.balanceOf(alice);
        uint256 nonce = _nextVoucherNonce[alice];
        _expectStakeRevert(alice, 0, P30, 1_000 * ONE, _apy(0, P30), "");
        assertEq(token.balanceOf(alice), bal);
        assertEq(staking.checkDepositCountOfAddress(alice), 0);
        assertFalse(staking.isVoucherNonceUsed(alice, nonce));
        _assertAccounting();
    }

    /// @dev Hypothesis: a gas-burning controller consumes the stake's gas; the call must simply revert.
    function test_maliciousLC_gasBurn_revertsCleanly() public {
        _useMLC(MaliciousLimitController.Mode.GAS_BURN);
        uint256 bal = token.balanceOf(alice);
        bytes memory data = _stakeData(staking, alice, 0, P30, 1_000 * ONE, _apy(0, P30));
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
        // 2 phases x 3 periods = 6 cells, the controller returns 5
        _lens(staking);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 6, 5));
        _lens(staking).getPhasePeriodUserData(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 6, 5));
        _lens(staking).getProgramDataWithUserData(alice);
        // Reads that do not touch the controller keep working
        staking.getProgramData();
        staking.checkClaimableDataFor(alice);
    }

    /// @dev Hypothesis: a controller returning 0 for everyone blocks stakes with an exact error, and the voucher's
    ///      extraLimit becomes exact (non-accumulating) headroom on top of it.
    function test_maliciousLC_allowNone_exactError_extraLimitExact() public {
        _useMLC(MaliciousLimitController.Mode.ALLOW_NONE);
        uint256 apy = _apy(0, P30);
        _expectStakeRevert(
            alice,
            0,
            P30,
            1_000 * ONE,
            apy,
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 1_000 * ONE, 0)
        );
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 500 * ONE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, alice, 0, P30, 500 * ONE + 1, 500 * ONE)
        );
        staking.stakeWithVoucher(v, sig, 500 * ONE + 1, apy);
        vm.prank(alice);
        staking.stakeWithVoucher(v, sig, 500 * ONE, apy);
    }

    /// @dev Hypothesis: a controller returning max allowed, combined with a max extraLimit, overflows the cap.
    function test_maliciousLC_allowAll_maxExtraLimitTotal_noOverflow() public {
        _useMLC(MaliciousLimitController.Mode.ALLOW_ALL);
        _stakeVWith(staking, alice, 0, P30, 1_000 * ONE, 0, type(uint128).max);
        assertEq(staking.checkDepositCountOfAddress(alice), 1);
        _assertAccounting();
    }

    // ---------------------------------------------------------------------
    // Malicious ERC-1271 voucher signer
    // ---------------------------------------------------------------------

    function _useSigner(MaliciousVoucherSigner.Mode m) internal {
        msig.setMode(m);
        staking.setVoucherSigner(address(msig));
    }

    /// @dev Audit finding #39: the voucher signer is always an EOA, the signature is checked with plain ECDSA
    ///      recovery, and a contract signer is never CALLED. So this whole external-call surface is gone: whatever
    ///      the contract at `voucherSigner` would do (approve, refuse, revert, re-enter, burn gas), the stake
    ///      reverts InvalidVoucherSignature cheaply, with or without an ECDSA signature, and nothing moves.
    function test_fixed39_contractSigner_neverConsulted_everyModeRejected() public {
        uint256 d = _stake(alice, 0, P0, 1_000 * ONE);
        msig.setReenter(address(staking), abi.encodeCall(staking.withdrawDeposit, (d)));
        uint256 apy = _apy(0, P30);
        uint256 bal = token.balanceOf(alice);

        for (uint256 m = 0; m <= uint256(MaliciousVoucherSigner.Mode.GAS_BURN); m++) {
            _useSigner(MaliciousVoucherSigner.Mode(m));
            (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);

            // No signature at all (what an ERC-1271 "approve everything" signer used to accept).
            vm.prank(alice);
            vm.expectRevert(Errors.InvalidVoucherSignature.selector);
            staking.stakeWithVoucher{gas: 300_000}(v, "", 1_000 * ONE, apy);

            // A real ECDSA signature by the usual EOA key: the signer is now the contract, so it does not match.
            vm.prank(alice);
            vm.expectRevert(Errors.InvalidVoucherSignature.selector);
            staking.stakeWithVoucher{gas: 300_000}(v, sig, 1_000 * ONE, apy);

            assertFalse(staking.isVoucherNonceUsed(alice, v.nonce));
        }

        assertEq(staking.checkDepositCountOfAddress(alice), 1);
        assertEq(uint256(_status(alice, d)), uint256(ProgramManager.DepositStatus.INDEFINITE), "not withdrawn");
        assertEq(token.balanceOf(alice), bal);
        _assertAccounting();
    }

    /// @dev Hypothesis: after the owner replaces a hostile signer/controller everything is back to normal.
    function test_hostileExternals_recoverableByOwner() public {
        _useSigner(MaliciousVoucherSigner.Mode.REVERT);
        _useMLC(MaliciousLimitController.Mode.REVERT);
        _expectStakeRevert(alice, 0, P30, 1_000 * ONE, _apy(0, P30), "");
        staking.setVoucherSigner(_voucherSignerAddr());
        staking.setLimitController(address(new OpenLimitController(address(staking))));
        _stake(alice, 0, P30, 1_000 * ONE);
        _lens(staking).getProgramDataWithUserData(alice);
        _assertAccounting();
    }
}
