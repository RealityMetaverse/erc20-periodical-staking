// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/LimitControllerFunctions.sol";
import "../../../src/common/Errors.sol";
import "../../../src/common/Types.sol";

/// @title LimitController wallet-limit semantics
/// @notice An explicit wallet limit is authoritative even when it is 0 ("no staking allowed"); `hasWalletLimit`
///         distinguishes "set to 0" from "not set" (use the default), and `clearWalletLimit(s)` restores the default.
contract LimitControllerWalletLimitTest is LimitControllerFunctions {
    event WalletLimitSet(address indexed wallet, uint256 phase, uint256 period, uint256 limit);
    event WalletLimitCleared(address indexed wallet, uint256 phase, uint256 period);

    uint256 constant DEFAULT_LIMIT = 1_000 ether;
    uint256 constant PHASE = 0;
    uint256 constant PERIOD = 90;

    function _deployWithDefault() internal {
        _deployLimitController(address(stakingContract));
        limitController.setDefaultLimit(PHASE, PERIOD, DEFAULT_LIMIT);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    // ======================================
    // =        Zero-limit semantics         =
    // ======================================

    function test_NotSet_UsesDefault() public {
        _deployWithDefault();
        assertFalse(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
        assertEq(_getAllowed(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
        assertEq(_getRemaining(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
    }

    function test_ExplicitZero_BlocksWallet_AllReadPaths() public {
        _deployWithDefault();

        vm.expectEmit(true, false, false, true);
        emit WalletLimitSet(userOne, PHASE, PERIOD, 0);
        limitController.setWalletLimit(userOne, PHASE, PERIOD, 0);

        assertTrue(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
        assertEq(limitController.walletPhasePeriodLimit(userOne, PHASE, PERIOD), 0);
        assertEq(_getAllowed(userOne, PHASE, PERIOD), 0, "getAllowed");
        assertEq(_getRemaining(userOne, PHASE, PERIOD), 0, "getRemaining");

        uint256[] memory allowed = limitController.getAllowedBatch(_one(userOne), _one(PHASE), _one(PERIOD));
        assertEq(allowed[0], 0, "getAllowedBatch");
        uint256[] memory remaining = limitController.getRemainingBatch(_one(userOne), _one(PHASE), _one(PERIOD));
        assertEq(remaining[0], 0, "getRemainingBatch");

        // Other wallets on the same cell still get the default.
        assertEq(_getAllowed(userTwo, PHASE, PERIOD), DEFAULT_LIMIT);
    }

    function test_ExplicitZero_OtherCellsUnaffected() public {
        _deployWithDefault();
        limitController.setDefaultLimit(PHASE, 0, DEFAULT_LIMIT);
        limitController.setWalletLimit(userOne, PHASE, PERIOD, 0);

        assertEq(_getAllowed(userOne, PHASE, 0), DEFAULT_LIMIT);
        assertFalse(limitController.hasWalletLimit(userOne, PHASE, 0));
    }

    function test_ExplicitNonZero_OverridesDefault_AndZeroDefault() public {
        _deployWithDefault();
        limitController.setWalletLimit(userOne, PHASE, PERIOD, 5 ether);
        assertEq(_getAllowed(userOne, PHASE, PERIOD), 5 ether);

        // Default 0 with a non-zero wallet limit: wallet limit wins.
        limitController.setDefaultLimit(PHASE, PERIOD, 0);
        assertEq(_getAllowed(userOne, PHASE, PERIOD), 5 ether);
        assertEq(_getAllowed(userTwo, PHASE, PERIOD), 0);
    }

    // ======================================
    // =          clearWalletLimit           =
    // ======================================

    function test_ClearWalletLimit_RestoresDefault() public {
        _deployWithDefault();
        limitController.setWalletLimit(userOne, PHASE, PERIOD, 0);
        assertEq(_getAllowed(userOne, PHASE, PERIOD), 0);

        vm.expectEmit(true, false, false, true);
        emit WalletLimitCleared(userOne, PHASE, PERIOD);
        limitController.clearWalletLimit(userOne, PHASE, PERIOD);

        assertFalse(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
        assertEq(limitController.walletPhasePeriodLimit(userOne, PHASE, PERIOD), 0);
        assertEq(_getAllowed(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
        assertEq(_getRemaining(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
    }

    function test_ClearWalletLimit_NonZeroLimit_RestoresDefault() public {
        _deployWithDefault();
        limitController.setWalletLimit(userOne, PHASE, PERIOD, 5 ether);
        limitController.clearWalletLimit(userOne, PHASE, PERIOD);
        assertFalse(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
        assertEq(limitController.walletPhasePeriodLimit(userOne, PHASE, PERIOD), 0);
        assertEq(_getAllowed(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
    }

    function test_ClearWalletLimit_WhenNotSet_IsNoOp() public {
        _deployWithDefault();
        limitController.clearWalletLimit(userOne, PHASE, PERIOD);
        assertFalse(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
        assertEq(_getAllowed(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
    }

    function test_ClearWalletLimit_ZeroAddressReverts() public {
        _deployWithDefault();
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        limitController.clearWalletLimit(address(0), PHASE, PERIOD);
    }

    function test_ClearWalletLimit_NotOwnerReverts() public {
        _deployWithDefault();
        limitController.setWalletLimit(userOne, PHASE, PERIOD, 0);
        vm.prank(userOne);
        vm.expectRevert();
        limitController.clearWalletLimit(userOne, PHASE, PERIOD);
        assertTrue(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
    }

    // ======================================
    // =        Batch set / clear            =
    // ======================================

    function test_SetWalletLimits_MarksEveryWalletSet() public {
        _deployWithDefault();
        address[] memory wallets = new address[](3);
        wallets[0] = userOne;
        wallets[1] = userTwo;
        wallets[2] = userThree;
        uint256[] memory limits = new uint256[](3);
        limits[0] = 0;
        limits[1] = 7 ether;
        limits[2] = 0;

        limitController.setWalletLimits(wallets, PHASE, PERIOD, limits);

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(limitController.hasWalletLimit(wallets[i], PHASE, PERIOD));
        }
        uint256[] memory phases = new uint256[](3);
        uint256[] memory periods = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            phases[i] = PHASE;
            periods[i] = PERIOD;
        }
        uint256[] memory allowed = limitController.getAllowedBatch(wallets, phases, periods);
        assertEq(allowed[0], 0);
        assertEq(allowed[1], 7 ether);
        assertEq(allowed[2], 0);
    }

    function test_ClearWalletLimits_Batch() public {
        _deployWithDefault();
        address[] memory wallets = new address[](2);
        wallets[0] = userOne;
        wallets[1] = userTwo;
        uint256[] memory limits = new uint256[](2);
        limits[0] = 0;
        limits[1] = 3 ether;
        limitController.setWalletLimits(wallets, PHASE, PERIOD, limits);

        vm.expectEmit(true, false, false, true);
        emit WalletLimitCleared(userOne, PHASE, PERIOD);
        vm.expectEmit(true, false, false, true);
        emit WalletLimitCleared(userTwo, PHASE, PERIOD);
        limitController.clearWalletLimits(wallets, PHASE, PERIOD);

        assertFalse(limitController.hasWalletLimit(userOne, PHASE, PERIOD));
        assertFalse(limitController.hasWalletLimit(userTwo, PHASE, PERIOD));
        assertEq(_getAllowed(userOne, PHASE, PERIOD), DEFAULT_LIMIT);
        assertEq(_getAllowed(userTwo, PHASE, PERIOD), DEFAULT_LIMIT);
        // untouched wallet keeps the default too
        assertEq(_getAllowed(userThree, PHASE, PERIOD), DEFAULT_LIMIT);
    }

    function test_ClearWalletLimits_ZeroAddressInArrayReverts() public {
        _deployWithDefault();
        address[] memory wallets = new address[](2);
        wallets[0] = userOne;
        wallets[1] = address(0);
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        limitController.clearWalletLimits(wallets, PHASE, PERIOD);
    }

    function test_ClearWalletLimits_NotOwnerReverts() public {
        _deployWithDefault();
        vm.prank(userOne);
        vm.expectRevert();
        limitController.clearWalletLimits(_one(userOne), PHASE, PERIOD);
    }

    // ======================================
    // =   Integration with stakeWithVoucher =
    // ======================================

    function _integrationSetup() internal {
        _deployWithDefault();
        _addPhasesAndPeriods();
        _increaseAllowance(address(this), amountToProvide);
        stakingContract.provideReward(amountToProvide);
        limitController.setDefaultLimit(0, 0, DEFAULT_LIMIT);
        _setLimitControllerOnStakingContract(address(limitController));
    }

    function test_Integration_ZeroLimitBlocksStake_ClearUnblocks() public {
        _integrationSetup();
        limitController.setWalletLimit(userOne, 0, 0, 0);
        uint256 apy = _getPhasePeriodAPY(0, 0);

        _increaseAllowance(userOne, amountToStake);
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, 0);
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, userOne, 0, 0, amountToStake, 0));
        stakingContract.stakeWithVoucher(v, sig, amountToStake, apy);

        limitController.clearWalletLimit(userOne, 0, 0);
        _stakeV(stakingContract, userOne, 0, 0, amountToStake);
        assertEq(stakingContract.userDataList(Types.DataType.STAKING, userOne), amountToStake);
        assertEq(_getRemaining(userOne, 0, 0), DEFAULT_LIMIT - amountToStake);
    }

    /// @notice A wallet explicitly blocked with limit 0 can still stake up to the voucher's extraLimit. The extra
    ///         is per voucher, not cumulative: a second voucher with the same extra finds its headroom used up.
    function test_Integration_ZeroLimit_VoucherExtraLimitIsTheOnlyHeadroom() public {
        _integrationSetup();
        limitController.setWalletLimit(userOne, 0, 0, 0);
        uint256 apy = _getPhasePeriodAPY(0, 0);
        _increaseAllowance(userOne, 3 * amountToStake);

        (Types.StakeVoucher memory v, bytes memory sig) =
            _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, amountToStake);
        vm.prank(userOne);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.StakingLimitExceeded.selector, userOne, 0, 0, amountToStake + 1, amountToStake
            )
        );
        stakingContract.stakeWithVoucher(v, sig, amountToStake + 1, apy);

        // The reverted call did not burn the nonce: the same voucher stakes exactly the extra.
        vm.prank(userOne);
        stakingContract.stakeWithVoucher(v, sig, amountToStake, apy);
        assertEq(stakingContract.userDataList(Types.DataType.STAKING, userOne), amountToStake);
        assertEq(_getRemaining(userOne, 0, 0), 0, "controller view excludes voucher extras");

        (v, sig) = _prepareVoucherStake(stakingContract, userOne, 0, 0, 0, amountToStake);
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, userOne, 0, 0, amountToStake, 0));
        stakingContract.stakeWithVoucher(v, sig, amountToStake, apy);

        // Clearing the explicit 0 restores the default on top of the extra.
        limitController.clearWalletLimit(userOne, 0, 0);
        vm.prank(userOne);
        stakingContract.stakeWithVoucher(v, sig, amountToStake, apy);
        assertEq(stakingContract.userDataList(Types.DataType.STAKING, userOne), 2 * amountToStake);
        assertEq(_getRemaining(userOne, 0, 0), DEFAULT_LIMIT - 2 * amountToStake);
    }
}
