// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../AuxiliaryFunctions.sol";
import "../../../src/common/Types.sol";
import "../../../src/common/Errors.sol";

/// @dev v0.4.0: staking only happens through a backend-signed voucher. The whitelist tests were removed with the
///      whitelist; voucher gating (signer, wallet, nonce, expiry, max extras) replaces them here.
contract StakingScenarious is AuxiliaryFunctions {
    uint256 constant PERIOD = 90;

    function _expectStakeRevert(
        address user,
        Types.StakeVoucher memory v,
        bytes memory sig,
        uint256 amount,
        uint256 expectedApy,
        bytes memory err
    ) internal {
        vm.prank(user);
        vm.expectRevert(err);
        stakingContract.stakeWithVoucher(v, sig, amount, expectedApy);
    }

    function test_Staking_BeforeLaunch() external {
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        _increaseAllowance(userOne, amountToStake);
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.StakingPhaseDoesNotExist.selector, 0)
        );
    }

    function test_Staking_NoAllowance() external {
        _addPhasesAndPeriods();

        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);
    }

    function test_Staking_IncreasedAllowance() external {
        _addPhasesAndPeriods();

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, false);
    }

    function test_Staking_MultiplePools() external {
        _tryMultiUserMultiStake();
    }

    function test_Staking_InsufficientDeposit() external {
        _addPhasesAndPeriods();

        _increaseAllowance(userOne, 1);
        _stakeTokenWithTest(userOne, 0, 0, 1, true);

        uint256 minimum = stakingContract.minimumDeposit();
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        _expectStakeRevert(
            userOne,
            v,
            sig,
            minimum - 1,
            _getPhasePeriodAPY(0, 0),
            abi.encodeWithSelector(Errors.InsufficientDeposit.selector, minimum - 1, minimum)
        );
    }

    function test_Staking_AmountExceedsTarget() external {
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);
        _stakeTokenWithAllowance(userThree, 0, 0, _getPhasePeriodStakingTarget(0, 0));

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0 + _refPeriodModifier, amountToStake, false);
    }

    function test_Staking_NotOpen() external {
        _addPhasesAndPeriods();
        stakingContract.changeActionAvailability(Types.DataType.STAKING, false);

        _increaseAllowance(userOne, amountToStake);
        _stakeTokenWithTest(userOne, 0, 0, amountToStake, true);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            _getPhasePeriodAPY(0, 0),
            abi.encodeWithSelector(Errors.NotOpen.selector, Types.DataType.STAKING)
        );
    }

    // ======================================
    // =        Voucher APY (bps)           =
    // ======================================

    /// @notice The deposit records base + voucher extra APY in bps, and the reward uses it with a single truncation.
    function testFuzz_Staking_ExtraApyIsRecordedAndPaysReward(uint256 extraApyBps, uint256 amount) external {
        _addPhasesAndPeriods();
        extraApyBps = bound(extraApyBps, 0, stakingContract.maxExtraApyBps());
        amount = bound(amount, stakingContract.minimumDeposit(), tokenToDistribute);

        uint256 baseApy = _getPhasePeriodAPY(0, PERIOD);
        uint256 effective = baseApy + extraApyBps;
        uint256 expectedReward = amount * (effective * PERIOD) / (10_000 * 365);

        _increaseAllowance(userOne, amount);
        uint256 depositNumber = _stakeVWith(stakingContract, userOne, 0, PERIOD, amount, extraApyBps, 0);

        ProgramManager.TokenDeposit memory d = stakingContract.getDeposit(userOne, depositNumber);
        assertEq(d.APY, effective, "effective APY");
        assertEq(d.amount, amount);
        assertEq(d.rewardGenerated, expectedReward, "reward");
        assertEq(stakingContract.calculateReward(amount, effective, PERIOD), expectedReward);
        assertEq(_getTotalRewardExpectedBy(userOne), expectedReward);
        assertEq(_getTotalRewardExpected(), expectedReward);
        assertEq(stakingContract.getUserPhasePeriodData(Types.DataType.STAKING, userOne, 0, PERIOD), amount);
    }

    /// @notice x.yz% APY: 2.25% of 1000 tokens for a year is exactly 22.5 tokens.
    function test_Staking_FractionalPercentApy() external {
        assertEq(stakingContract.calculateReward(1000e18, 225, 365), 22.5e18);
        assertEq(stakingContract.calculateReward(1000e18, 1, 365), 0.1e18);
    }

    /// @notice expectedApyBps is a floor: a lower effective APY reverts, a higher one is accepted.
    function test_Staking_ApyFloor() external {
        _addPhasesAndPeriods();
        uint256 baseApy = _getPhasePeriodAPY(0, PERIOD);
        _increaseAllowance(userOne, amountToStake * 2);

        (Types.StakeVoucher memory v, bytes memory sig) =
            _prepareVoucherStake(stakingContract, userOne, 0, PERIOD, 0, 0);
        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            baseApy + 1,
            abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, PERIOD, baseApy, baseApy + 1)
        );

        // Same (unused) voucher, lower expectation: accepted at the real rate.
        vm.prank(userOne);
        uint256 n = stakingContract.stakeWithVoucher(v, sig, amountToStake, baseApy - 1);
        assertEq(stakingContract.getDeposit(userOne, n).APY, baseApy);

        // Extra APY above the expectation is also accepted.
        (v, sig) = _prepareVoucherStake(stakingContract, userOne, 0, PERIOD, 200, 0);
        vm.prank(userOne);
        n = stakingContract.stakeWithVoucher(v, sig, amountToStake, baseApy);
        assertEq(stakingContract.getDeposit(userOne, n).APY, baseApy + 200);
    }

    /// @notice Front-running guard: the owner lowering the base APY before the tx lands makes it revert.
    function test_Staking_ApyLoweredBeforeInclusion_Reverts() external {
        _addPhasesAndPeriods();
        uint256 baseApy = _getPhasePeriodAPY(0, PERIOD);
        _increaseAllowance(userOne, amountToStake);
        (Types.StakeVoucher memory v, bytes memory sig) =
            _prepareVoucherStake(stakingContract, userOne, 0, PERIOD, 100, 0);

        stakingContract.setPhasePeriodData(Types.PhasePeriodDataType.APY, 0, PERIOD, baseApy - 150);

        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            baseApy + 100,
            abi.encodeWithSelector(Errors.ApyBelowExpected.selector, 0, PERIOD, baseApy - 50, baseApy + 100)
        );
    }

    // ======================================
    // =          Voucher gating            =
    // ======================================

    function test_Staking_VoucherSignerNotSet() external {
        _addPhasesAndPeriods();
        stakingContract.setVoucherSigner(address(0));
        _increaseAllowance(userOne, amountToStake);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.VoucherSignerNotSet.selector)
        );
    }

    function test_Staking_WrongSigner() external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake);

        Types.StakeVoucher memory v = _makeVoucher(userOne, 0, 0, 0, 0);
        bytes memory sig = _signVoucher(address(stakingContract), v, 0xBAD);
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );
    }

    function test_Staking_TamperedVoucher() external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        v.extraApyBps = 500;
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );

        // A voucher signed for another staking contract does not verify here.
        (v,) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        sig = _signVoucher(address(0xdead), v, VOUCHER_SIGNER_KEY);
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.InvalidVoucherSignature.selector)
        );
    }

    function test_Staking_VoucherForAnotherWallet() external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userTwo, 0, 0, 0, 0);
        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            0,
            abi.encodeWithSelector(Errors.VoucherWalletMismatch.selector, userTwo, userOne)
        );
    }

    function test_Staking_VoucherReplay() external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake * 2);
        uint256 apy = _getPhasePeriodAPY(0, 0);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        assertFalse(stakingContract.isVoucherNonceUsed(userOne, v.nonce));
        vm.prank(userOne);
        stakingContract.stakeWithVoucher(v, sig, amountToStake, apy);
        assertTrue(stakingContract.isVoucherNonceUsed(userOne, v.nonce));

        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            apy,
            abi.encodeWithSelector(Errors.VoucherNonceUsed.selector, userOne, v.nonce)
        );
        assertEq(_getUserDepositCount(userOne), 1);
    }

    function test_Staking_VoucherExpired() external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake * 2);
        uint256 apy = _getPhasePeriodAPY(0, 0);

        Types.StakeVoucher memory v = _makeVoucher(userOne, 0, 0, 0, 0);
        v.validUntil = _now() + 1 days;
        bytes memory sig = _signVoucher(address(stakingContract), v, VOUCHER_SIGNER_KEY);

        // validUntil is inclusive.
        skip(1 days);
        Types.StakeVoucher memory v2 = _makeVoucher(userOne, 0, 0, 0, 0);
        v2.validUntil = _now();
        bytes memory sig2 = _signVoucher(address(stakingContract), v2, VOUCHER_SIGNER_KEY);
        vm.prank(userOne);
        stakingContract.stakeWithVoucher(v2, sig2, amountToStake, apy);

        skip(1);
        uint256 nowTs = _now();
        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            apy,
            abi.encodeWithSelector(Errors.VoucherExpired.selector, v.validUntil, nowTs)
        );
    }

    function test_Staking_ExtraApyAboveMax() external {
        _addPhasesAndPeriods();
        stakingContract.setMaxExtraApyBps(100);
        _increaseAllowance(userOne, amountToStake);
        uint256 apy = _getPhasePeriodAPY(0, 0);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 101, 0);
        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            apy,
            abi.encodeWithSelector(Errors.VoucherExtraApyTooHigh.selector, 101, 100)
        );

        // Exactly at the maximum is fine.
        uint256 n = _stakeVWith(stakingContract, userOne, 0, 0, amountToStake, 100, 0);
        assertEq(stakingContract.getDeposit(userOne, n).APY, apy + 100);
    }

    function test_Staking_ExtraLimitAboveMax() external {
        _addPhasesAndPeriods();
        stakingContract.setMaxExtraLimit(5e18);
        _increaseAllowance(userOne, amountToStake);

        (Types.StakeVoucher memory v, bytes memory sig) =
            _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 5e18 + 1);
        _expectStakeRevert(
            userOne,
            v,
            sig,
            amountToStake,
            0,
            abi.encodeWithSelector(Errors.VoucherExtraLimitTooHigh.selector, 5e18 + 1, 5e18)
        );
    }

    /// @notice The stake uses the voucher's phase and period: a voucher for a non-current phase or an
    ///         unconfigured period is rejected.
    function test_Staking_VoucherPhaseAndPeriodMustBeValid() external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 1, 0, 0, 0);
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.IncorrectStakingPhase.selector, 1, 0)
        );

        (v, sig) = _prepareVoucherStake(stakingContract, userOne, 0, 45, 0, 0);
        _expectStakeRevert(
            userOne, v, sig, amountToStake, 0, abi.encodeWithSelector(Errors.StakingPeriodDoesNotExist.selector, 45)
        );

        // After switching phase, the phase-1 voucher kind works and is recorded on phase 1.
        stakingContract.changeStakingPhase(1);
        uint256 n = _stakeV(stakingContract, userOne, 1, PERIOD, amountToStake);
        assertEq(stakingContract.getDeposit(userOne, n).stakingPhase, 1);
        assertEq(stakingContract.getDeposit(userOne, n).stakingPeriod, PERIOD);
        assertEq(_getPhasePeriodStakingStaked(1, PERIOD), amountToStake);
    }

    /// @notice Nonces are a per-wallet bitmap: using one nonce never marks another nonce or another wallet's nonce.
    function testFuzz_Staking_NonceBitmapIsolation(uint256 nonce) external {
        _addPhasesAndPeriods();
        _increaseAllowance(userOne, amountToStake);
        uint256 apy = _getPhasePeriodAPY(0, 0);

        Types.StakeVoucher memory v = _makeVoucher(userOne, 0, 0, 0, 0);
        v.nonce = nonce;
        bytes memory sig = _signVoucher(address(stakingContract), v, VOUCHER_SIGNER_KEY);
        vm.prank(userOne);
        stakingContract.stakeWithVoucher(v, sig, amountToStake, apy);

        assertTrue(stakingContract.isVoucherNonceUsed(userOne, nonce));
        assertFalse(stakingContract.isVoucherNonceUsed(userTwo, nonce));
        unchecked {
            assertFalse(stakingContract.isVoucherNonceUsed(userOne, nonce + 1));
            assertFalse(stakingContract.isVoucherNonceUsed(userOne, nonce - 1));
            assertFalse(stakingContract.isVoucherNonceUsed(userOne, nonce ^ (1 << 8)));
        }
    }
}
