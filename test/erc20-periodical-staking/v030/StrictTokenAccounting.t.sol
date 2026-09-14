// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";
import {FeeOnTransferToken} from "../../shared/FeeOnTransferToken.sol";

/// @title Strict token accounting rejects fee-on-transfer tokens
contract StrictTokenAccountingTest is V030Base {
    FeeOnTransferToken feeToken;
    ERC20PeriodicalStaking feeStaking;
    uint256 constant FEE_BPS = 100; // 1%

    function _setupFeeProgram() internal {
        feeToken = new FeeOnTransferToken(FEE_BPS);
        feeStaking = new ERC20PeriodicalStaking(address(feeToken));

        uint256[] memory empty = new uint256[](0);
        feeStaking.addStakingPeriod(0, empty, empty);
        feeStaking.addStakingPeriod(PERIOD_SHORT, empty, empty);
        uint256[] memory apys = new uint256[](2);
        uint256[] memory targets = new uint256[](2);
        apys[0] = APY;
        apys[1] = APY;
        targets[0] = TARGET;
        targets[1] = TARGET;
        feeStaking.pushStakingPhase(apys, targets);
        _enableVoucherStaking(feeStaking);

        feeToken.transfer(userOne, 1_000 ether);
    }

    function test_ProvideReward_RevertsOnFeeOnTransfer() public {
        _setupFeeProgram();
        uint256 amount = 100 ether;
        uint256 received = amount - (amount * FEE_BPS) / 10_000;

        feeToken.approve(address(feeStaking), amount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnexpectedTokenAmount.selector, amount, received));
        feeStaking.provideReward(amount);

        assertEq(feeStaking.rewardPool(), 0);
        assertEq(feeToken.balanceOf(address(feeStaking)), 0);
    }

    function test_Stake_RevertsOnFeeOnTransfer() public {
        _setupFeeProgram();
        uint256 amount = STAKE_AMOUNT;
        uint256 received = amount - (amount * FEE_BPS) / 10_000;

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(feeStaking, userOne, 0, 0, 0, 0);
        vm.startPrank(userOne);
        feeToken.approve(address(feeStaking), amount);
        // Indefinite stake needs no pool, so the only failure is the delta check.
        vm.expectRevert(abi.encodeWithSelector(Errors.UnexpectedTokenAmount.selector, amount, received));
        feeStaking.stakeWithVoucher(v, sig, amount, APY);
        vm.stopPrank();

        assertEq(feeStaking.totalDataList(Types.DataType.STAKING), 0);
        assertEq(feeStaking.checkDepositCountOfAddress(userOne), 0);
        assertEq(feeToken.balanceOf(address(feeStaking)), 0);
        // The whole call reverted, so the voucher nonce was not burned.
        assertFalse(feeStaking.isVoucherNonceUsed(userOne, v.nonce));
    }

    function test_ZeroFeeTokenPassesDeltaCheck() public {
        FeeOnTransferToken zeroFee = new FeeOnTransferToken(0);
        ERC20PeriodicalStaking s = new ERC20PeriodicalStaking(address(zeroFee));
        uint256[] memory empty = new uint256[](0);
        s.addStakingPeriod(PERIOD_SHORT, empty, empty);
        uint256[] memory apys = new uint256[](1);
        uint256[] memory targets = new uint256[](1);
        apys[0] = APY;
        targets[0] = TARGET;
        s.pushStakingPhase(apys, targets);
        _enableVoucherStaking(s);

        zeroFee.approve(address(s), 100 ether);
        s.provideReward(100 ether);
        assertEq(s.rewardPool(), 100 ether);
        assertEq(zeroFee.balanceOf(address(s)), 100 ether);

        // A voucher stake with a zero-fee token passes the delta check too.
        zeroFee.transfer(userOne, STAKE_AMOUNT);
        vm.prank(userOne);
        zeroFee.approve(address(s), STAKE_AMOUNT);
        _stakeV(s, userOne, 0, PERIOD_SHORT, STAKE_AMOUNT);
        assertEq(zeroFee.balanceOf(address(s)), 100 ether + STAKE_AMOUNT);
        assertEq(s.totalDataList(Types.DataType.STAKING), STAKE_AMOUNT);
    }

    /// @notice Standard token: the contract balance always equals staked principal + reward pool.
    function test_StandardToken_BalanceMatchesAccounting() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);
        assertEq(
            myToken.balanceOf(address(stakingContract)),
            stakingContract.totalDataList(Types.DataType.STAKING) + stakingContract.rewardPool()
        );

        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        vm.prank(userTwo);
        stakingContract.withdrawDeposit(0);
        assertEq(
            myToken.balanceOf(address(stakingContract)),
            stakingContract.totalDataList(Types.DataType.STAKING) + stakingContract.rewardPool()
        );
    }
}
