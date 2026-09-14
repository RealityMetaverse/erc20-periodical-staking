// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./VoucherAttackBase.sol";

/// @title Griefing
/// @notice Dust spam (default minimumDeposit is 100 wei) must not push user-facing or enforcement functions past a
///         block's gas, and admin functions must not scale with staker count (v0.3.0 removed the per-staker
///         clearing loops). Since v0.4.0 every stake needs a backend voucher, so spam costs signed vouchers;
///         these tests assume the backend issues them anyway (worst case).
contract GriefingTest is VoucherAttackBase {
    uint256 internal constant SPAM = 300;
    uint256 internal constant GAS_BLOCK = 15_000_000;

    function _spamAddress(uint256 i) internal pure returns (address) {
        return address(uint160(0x100000 + i));
    }

    /// @dev Registers SPAM distinct dust stakers (each 100 wei on period 0).
    function _spamStakers() internal {
        for (uint256 i = 0; i < SPAM; i++) {
            address s = _spamAddress(i);
            token.transfer(s, 100);
            vm.prank(s);
            token.approve(address(staking), 100);
            _stake(s, 0, P0, 100);
        }
    }

    function _gasOf(bytes memory data) internal returns (uint256 used, bool ok) {
        uint256 g = gasleft();
        (ok,) = address(staking).call(data);
        used = g - gasleft();
    }

    function _spamOwnDeposits(uint256 period) internal {
        staking.setMiniumumDeposit(1);
        for (uint256 i = 0; i < SPAM; i++) {
            _stake(alice, 0, period, 100);
        }
    }

    /// @dev Hypothesis: 300 dust deposits make claimAll for that user exceed a block.
    function test_dustSpam_ownClaimAll_underBlockGas() public {
        _spamOwnDeposits(P30);
        _warpDays(30);
        vm.prank(alice);
        (uint256 used, bool ok) = _gasOf(abi.encodeWithSignature("claimAll()"));
        assertTrue(ok);
        assertLt(used, GAS_BLOCK, "claimAll over block gas");
        assertEq(_user(Types.DataType.STAKING, alice), 0);
        _assertAccounting();
    }

    /// @dev claimRange lets a heavy user drain in slices with predictable gas.
    function test_dustSpam_claimRange_slices() public {
        _spamOwnDeposits(P30);
        _warpDays(30);
        vm.prank(alice);
        (uint256 used, bool ok) = _gasOf(abi.encodeWithSignature(SIG_CLAIM_RANGE, 0, 50));
        assertTrue(ok);
        assertLt(used, 3_000_000, "50-slice claimRange too expensive");
        assertEq(staking.stakerActiveDepositStartIndex(alice), 50);
        for (uint256 from = 50; from < SPAM; from += 50) {
            vm.prank(alice);
            staking.claimRange(from, from + 50);
        }
        assertEq(_user(Types.DataType.STAKING, alice), 0);
        assertEq(staking.stakerActiveDepositStartIndex(alice), SPAM);
    }

    /// @dev Hypothesis: a spammer whose 300 deposits are all frozen turns claimAll (which must skip each one)
    ///      or the batch enforcement calls into block-gas bombs.
    function test_frozenSpam_claimAllAndBatchEnforcement_underBlockGas() public {
        _spamOwnDeposits(P30);
        address[] memory w = new address[](SPAM);
        uint256[] memory n = new uint256[](SPAM);
        for (uint256 i = 0; i < SPAM; i++) {
            w[i] = alice;
            n[i] = i;
        }

        vm.prank(admin);
        (uint256 usedFreeze, bool okFreeze) = _gasOf(abi.encodeCall(staking.freezeDeposits, (w, n)));
        assertTrue(okFreeze);
        assertLt(usedFreeze, GAS_BLOCK, "freezeDeposits(300) over block gas");
        assertTrue(staking.isDepositFrozen(alice, SPAM - 1));

        _warpDays(30);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        (uint256 usedClaim, bool okClaim) = _gasOf(abi.encodeWithSignature("claimAll()"));
        assertTrue(okClaim, "claimAll must skip frozen deposits, not revert");
        assertLt(usedClaim, GAS_BLOCK, "claimAll over 300 frozen deposits over block gas");
        assertEq(token.balanceOf(alice), before, "nothing paid while frozen");
        assertEq(staking.stakerActiveDepositStartIndex(alice), 0);

        (uint256 usedSeize, bool okSeize) = _gasOf(abi.encodeCall(staking.seizeDeposits, (w, n)));
        assertTrue(okSeize);
        assertLt(usedSeize, GAS_BLOCK, "seizeDeposits(300) over block gas");
        assertEq(token.balanceOf(treasury), SPAM * 100, "one aggregated payout of every principal");
        assertEq(staking.stakerActiveDepositStartIndex(alice), SPAM);
        assertEq(_user(Types.DataType.STAKING, alice), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: a spammer's 300 deposits slow down *other* users' claims or stakes.
    function test_dustSpam_doesNotAffectOtherUsers() public {
        staking.setMiniumumDeposit(1);
        uint256 d = _stake(bob, 0, P30, 1_000 * ONE);
        for (uint256 i = 0; i < SPAM; i++) {
            _stake(alice, 0, P30, 100);
        }
        _warpDays(30);
        vm.prank(bob);
        (uint256 usedClaim, bool ok) = _gasOf(abi.encodeCall(staking.claimDeposit, (d)));
        assertTrue(ok);
        assertLt(usedClaim, 300_000, "bob's claim affected by alice's spam");
        bytes memory data = _stakeData(staking, bob, 0, P30, 1_000 * ONE, _apy(0, P30));
        vm.prank(bob);
        (uint256 usedStake, bool ok2) = _gasOf(data);
        assertTrue(ok2);
        assertLt(usedStake, 500_000);
    }

    /// @dev removeStakingPeriod gas is independent of the number of stakers.
    function test_removeStakingPeriod_gasIndependentOfStakerCount() public {
        _stake(alice, 0, P90, 1_000 * ONE);
        (uint256 gasFew, bool ok1) = _gasOf(abi.encodeCall(staking.removeStakingPeriod, (P90)));
        assertTrue(ok1);
        _addPeriod(P90, 20, TARGET);

        _spamStakers();
        (uint256 gasMany, bool ok2) = _gasOf(abi.encodeCall(staking.removeStakingPeriod, (P90)));
        assertTrue(ok2);
        assertLt(gasMany, 400_000, "removeStakingPeriod too expensive");
        assertLt(gasMany, gasFew * 3 / 2, "removeStakingPeriod scales with staker count");
    }

    /// @dev popStakingPhase gas is independent of the number of stakers.
    function test_popStakingPhase_gasIndependentOfStakerCount() public {
        (uint256 gasFew, bool ok1) = _gasOf(abi.encodeCall(staking.popStakingPhase, ()));
        assertTrue(ok1);
        _pushPhase(7, TARGET);
        _spamStakers();
        (uint256 gasMany, bool ok2) = _gasOf(abi.encodeCall(staking.popStakingPhase, ()));
        assertTrue(ok2);
        assertLt(gasMany, 400_000);
        assertLt(gasMany, gasFew * 3 / 2, "popStakingPhase scales with staker count");
    }

    /// @dev Hypothesis: checkTotalClaimableData (unbounded by design) becomes uncallable after dust spam.
    function test_checkTotalClaimableData_300stakers_underBound() public {
        _spamStakers();
        _warpDays(10);
        uint256 g = gasleft();
        staking.checkTotalClaimableData();
        uint256 used = g - gasleft();
        assertLt(used, 30_000_000, "checkTotalClaimableData unusable at 300 stakers");
    }

    /// @dev Hypothesis: a single user with 300 deposits breaks checkClaimableDataFor / getDepositsInRangeBy.
    function test_userViews_300deposits_underBound() public {
        _spamOwnDeposits(P0);
        _warpDays(10);
        uint256 g = gasleft();
        staking.checkClaimableDataFor(alice);
        assertLt(g - gasleft(), 10_000_000);
        g = gasleft();
        staking.getDepositsInRangeBy(alice, 0, SPAM);
        assertLt(g - gasleft(), 10_000_000);
        assertEq(staking.getDepositsInRangeBy(alice, 100, 150).length, 50);
    }

    /// @dev Hypothesis: 300 stakers make stakeWithVoucher for a new user more expensive (stakerAddressList push
    ///      is O(1), the nonce bitmap is per wallet).
    function test_stakeGas_independentOfStakerCount() public {
        uint256 apy0 = _apy(0, P0);
        bytes memory dataBob = _stakeData(staking, bob, 0, P0, 1_000 * ONE, apy0);
        vm.prank(bob);
        (uint256 gasFew, bool ok1) = _gasOf(dataBob);
        assertTrue(ok1);
        _spamStakers();
        bytes memory dataCarol = _stakeData(staking, carol, 0, P0, 1_000 * ONE, apy0);
        vm.prank(carol);
        (uint256 gasMany, bool ok2) = _gasOf(dataCarol);
        assertTrue(ok2);
        assertLe(gasMany, gasFew + 10_000, "stake gas grew with staker count");
    }

    /// @dev Hypothesis: a wallet that burns huge / scattered voucher nonces makes its later stakes more expensive.
    ///      The bitmap costs one word per 256 nonces, independent of how many were used before.
    function test_scatteredNonces_stakeGasFlat() public {
        uint256 apy0 = _apy(0, P0);
        uint256 gasFirst;
        uint256 gasLast;
        for (uint256 i = 0; i < 20; i++) {
            Types.StakeVoucher memory v = _makeVoucher(alice, 0, P0, 0, 0);
            v.nonce = uint256(keccak256(abi.encode(i))); // a fresh bitmap word every time
            bytes memory sig = _signVoucher(address(staking), v, VOUCHER_SIGNER_KEY);
            bytes memory data = abi.encodeCall(staking.stakeWithVoucher, (v, sig, 1_000 * ONE, apy0));
            vm.prank(alice);
            (uint256 used, bool ok) = _gasOf(data);
            assertTrue(ok);
            if (i == 1) gasFirst = used;
            if (i == 19) gasLast = used;
        }
        assertLe(gasLast, gasFirst + 5_000, "stake gas grew with the number of used nonces");
    }

    /// @dev Hypothesis: dust periodical deposits (reward rounds to 0) can be used to fill a target without pool backing,
    ///      but must still be fully closable and must not desync REWARD_EXPECTED.
    function test_dustPeriodical_zeroRewardDeposits_closeCleanly() public {
        staking.setMiniumumDeposit(1);
        staking.collectReward(staking.getCollectableReward()); // pool = 0
        for (uint256 i = 0; i < 50; i++) {
            uint256 d = _stake(alice, 0, P30, 1);
            assertEq(_deposit(alice, d).rewardGenerated, 0);
        }
        assertEq(_total(Types.DataType.REWARD_EXPECTED), 0);
        _warpDays(30);
        _claimAll(alice);
        assertEq(_user(Types.DataType.STAKING, alice), 0);
        _assertAccounting();
    }

    /// @dev Hypothesis: a griefer can fill a period's target with dust to block real stakers, and the owner
    ///      has no way to free it except raising the target (or, since v0.4.0, freezing and seizing the squat).
    function test_targetSquat_ownerCanRaiseTargetOrSeize() public {
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P0, 1_000 * ONE);
        uint256 squat = _stake(alice, 0, P0, 1_000 * ONE);
        _expectStakeRevert(
            bob, 0, P0, 100, _apy(0, P0), abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P0, 1_000 * ONE)
        );
        staking.setPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, 0, P0, 2_000 * ONE);
        _stake(bob, 0, P0, 1_000 * ONE);

        // cell full again; seizing the squat frees exactly its amount of target
        _expectStakeRevert(
            carol, 0, P0, 1_000 * ONE, _apy(0, P0), abi.encodeWithSelector(Errors.AmountExceedsTarget.selector, 0, P0, 2_000 * ONE)
        );
        _freeze(alice, squat);
        _seize(alice, squat);
        _stake(carol, 0, P0, 1_000 * ONE);
        assertEq(_staked(0, P0), 2_000 * ONE);
        _assertAccounting();
    }
}
