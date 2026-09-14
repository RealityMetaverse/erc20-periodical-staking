// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract StakingFunctions is ReadFunctions, WriteFunctions {
    /// @notice Open a deposit authorised by a backend-signed voucher.
    /// @dev The voucher fixes the phase and period; its extraApyBps is added to the base APY for the deposit's
    ///      whole life and its extraLimit is added to the controller limit for this stake only. The signature is
    ///      checked with SignatureChecker, so a contract signer (ERC-1271) works too.
    ///      No reward-pool check is performed at stake time. Periodical deposits (period != 0) add their full
    ///      reward to `totalDataList[REWARD_EXPECTED]`, which `collectReward` can never take from the pool; if the
    ///      pool is short when the deposit matures, `claimDeposit` reverts `NotEnoughFundsInRewardPool` until the
    ///      owner tops up (no loss). Indefinite deposits (period 0) are paid only from `getCollectableReward()`.
    /// @param voucher The signed voucher; voucher.wallet must be the caller
    /// @param signature voucherSigner's signature over getVoucherDigest(voucher)
    /// @param tokenAmount Amount to stake (caller must have approved the contract)
    /// @param expectedApyBps Front-running guard: reverts if the effective APY (bps) is lower than this
    /// @return depositNumber Index of the new deposit in the caller's deposit list
    function stakeWithVoucher(
        Types.StakeVoucher calldata voucher,
        bytes calldata signature,
        uint256 tokenAmount,
        uint256 expectedApyBps
    ) external nonReentrant returns (uint256 depositNumber) {
        if (!stakingOpen) revert NotOpen(Types.DataType.STAKING);
        address controller = limitController;

        address signer = voucherSigner;
        if (signer == address(0)) revert VoucherSignerNotSet();
        if (controller == address(0)) revert LimitControllerNotSet();
        if (voucher.wallet != msg.sender) revert VoucherWalletMismatch(voucher.wallet, msg.sender);
        if (block.timestamp > voucher.validUntil) revert VoucherExpired(voucher.validUntil, block.timestamp);

        uint256 word = voucher.nonce >> 8;
        uint256 mask = 1 << (voucher.nonce & 0xff);
        uint256 bitmap = voucherNonceBitmap[msg.sender][word];
        if ((bitmap & mask) != 0) revert VoucherNonceUsed(msg.sender, voucher.nonce);

        if (voucher.extraApyBps > maxExtraApyBps) revert VoucherExtraApyTooHigh(voucher.extraApyBps, maxExtraApyBps);
        if (voucher.extraLimit > maxExtraLimit) revert VoucherExtraLimitTooHigh(voucher.extraLimit, maxExtraLimit);

        if (!SignatureChecker.isValidSignatureNow(signer, getVoucherDigest(voucher), signature)) {
            revert InvalidVoucherSignature();
        }

        if (tokenAmount < minimumDeposit) revert InsufficientDeposit(tokenAmount, minimumDeposit);

        uint256 phase = voucher.phase;
        uint256 period = voucher.period;
        uint256 currentPhase = currentStakingPhase;
        if (phase != currentPhase) revert IncorrectStakingPhase(phase, currentPhase);
        if (phase >= stakingPhaseCount) revert StakingPhaseDoesNotExist(phase);

        // For an existing phase, APY != 0 if and only if the period is configured (APY 0 is rejected on write and
        // removal clears the cell), so this replaces the stakingPeriodList scan.
        uint256 baseApyBps = phasePeriodDataList[Types.PhasePeriodDataType.APY][phase][period];
        if (baseApyBps == 0) revert StakingPeriodDoesNotExist(period);

        uint256 effectiveApyBps = baseApyBps + voucher.extraApyBps;
        if (effectiveApyBps < expectedApyBps) {
            revert ApyBelowExpected(phase, period, effectiveApyBps, expectedApyBps);
        }

        {
            uint256 staked = phasePeriodDataList[Types.PhasePeriodDataType.STAKED][phase][period];
            uint256 target = phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][phase][period];
            if (tokenAmount + staked > target) revert AmountExceedsTarget(phase, period, target);
        }

        {
            (uint256 allowed, uint256 used) = ILimitController(controller).getAllowedAndUsed(msg.sender, phase, period);
            uint256 extraLimit = voucher.extraLimit;
            uint256 cap = allowed > type(uint256).max - extraLimit ? type(uint256).max : allowed + extraLimit;
            uint256 headroom = used >= cap ? 0 : cap - used;
            if (tokenAmount > headroom) revert StakingLimitExceeded(msg.sender, phase, period, tokenAmount, headroom);
        }

        voucherNonceBitmap[msg.sender][word] = bitmap | mask;

        uint256 endDate = 0;
        uint256 reward = 0;
        if (period != 0) {
            endDate = block.timestamp + period * 1 days;
            reward = calculateReward(tokenAmount, effectiveApyBps, period);
            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] += reward;
            totalDataList[Types.DataType.REWARD_EXPECTED] += reward;
        }

        _updateAllDataAfterAction(Types.DataType.STAKING, msg.sender, phase, period, tokenAmount, 0);

        PackedDeposit[] storage deposits = stakerDepositList[msg.sender];
        depositNumber = deposits.length;
        if (depositNumber == 0) stakerAddressList.push(msg.sender);

        deposits.push(
            PackedDeposit({
                amount: SafeCast.toUint128(tokenAmount),
                stakingStartDate: SafeCast.toUint40(block.timestamp),
                stakingEndDate: SafeCast.toUint40(endDate),
                withdrawalDate: 0,
                flags: 0,
                rewardGenerated: SafeCast.toUint128(reward),
                stakingPhase: uint32(phase),
                stakingPeriod: SafeCast.toUint32(period),
                apyBps: SafeCast.toUint32(effectiveApyBps)
            })
        );

        emit Stake(
            msg.sender, phase, period, effectiveApyBps, voucher.extraApyBps, tokenAmount, depositNumber, voucher.nonce
        );

        _receiveToken(tokenAmount);
    }
}
