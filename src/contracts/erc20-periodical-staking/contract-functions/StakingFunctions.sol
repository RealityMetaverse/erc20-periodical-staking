// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract StakingFunctions is ReadFunctions, WriteFunctions {
    /// @notice Open a deposit authorised by a backend-signed voucher.
    /// @dev The voucher fixes the phase and period; its extraApyBps is added to the base APY for the deposit's
    ///      whole life. Its extraLimitTotal / extraLimitPerCell are a bonus BUDGET, not a per-stake grant: the
    ///      part of this stake that goes above the wallet's controller limit is metered against them, so
    ///      re-presenting a voucher (or issuing a fresh one with the same numbers) never hands the bonus out
    ///      twice. One budget covers every phase, and it is concurrent -- closing the deposit frees it again,
    ///      but advancing the phase does not refill it. The signature is plain ECDSA: voucherSigner must be an
    ///      EOA, a contract signer (ERC-1271) is NOT supported and every voucher would be rejected.
    ///      The voucher must carry the current `voucherEpoch`, must not be post-dated (issuedAt <= now), and its
    ///      signed lifetime validUntil - issuedAt must not exceed `maxVoucherValidity`.
    ///      Bonus attribution is fixed at stake time: raising the wallet's controller limit afterwards does not
    ///      move bonus already charged to a deposit back into base room. It frees when that deposit closes.
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
        // First, before the nonce is consumed and before any storage read that costs real gas. A blocked wallet
        // must not be able to burn a nonce or pay for work it can never complete.
        if (walletBlocked[msg.sender]) revert WalletBlocked(msg.sender);
        address controller = limitController;

        address signer = voucherSigner;
        if (signer == address(0)) revert VoucherSignerNotSet();
        if (controller == address(0)) revert LimitControllerNotSet();
        if (voucher.wallet != msg.sender) revert VoucherWalletMismatch(voucher.wallet, msg.sender);
        if (block.timestamp > voucher.validUntil) revert VoucherExpired(voucher.validUntil, block.timestamp);
        // The voucher's WHOLE signed lifetime [issuedAt, validUntil] is bounded by maxVoucherValidity, and it
        // cannot start in the future. Both ends are signed, so a long-dated voucher is never usable -- not now
        // and not in the last maxVoucherValidity seconds before validUntil either -- and post-dating issuedAt
        // to get around the bound is rejected. This limits vouchers the backend signed honestly. It does NOT
        // limit a leaked signer key: the key holder signs a fresh short-lived voucher whenever they like. The
        // levers for that are bumpVoucherEpoch, setVoucherSigner and closeStaking.
        {
            uint256 issuedAt = voucher.issuedAt;
            if (issuedAt > block.timestamp) revert VoucherNotYetValid(issuedAt, block.timestamp);
            // issuedAt <= now <= validUntil here, so the sum cannot overflow: maxVoucherValidity is a uint32.
            uint256 maxValidUntil = issuedAt + maxVoucherValidity;
            if (voucher.validUntil > maxValidUntil) {
                revert VoucherValidityTooLong(voucher.validUntil, maxValidUntil);
            }
        }
        if (voucher.epoch != voucherEpoch) revert VoucherEpochMismatch(voucher.epoch, voucherEpoch);

        uint256 word = voucher.nonce >> 8;
        uint256 mask = 1 << (voucher.nonce & 0xff);
        uint256 bitmap = voucherNonceBitmap[msg.sender][word];
        if ((bitmap & mask) != 0) revert VoucherNonceUsed(msg.sender, voucher.nonce);

        if (voucher.extraApyBps > maxExtraApyBps) revert VoucherExtraApyTooHigh(voucher.extraApyBps, maxExtraApyBps);
        if (voucher.extraLimitTotal > maxExtraLimitTotal) {
            revert VoucherExtraLimitTotalTooHigh(voucher.extraLimitTotal, maxExtraLimitTotal);
        }
        if (voucher.extraLimitPerCell > maxExtraLimitPerCell) {
            revert VoucherExtraLimitPerCellTooHigh(voucher.extraLimitPerCell, maxExtraLimitPerCell);
        }

        // ECDSA only: the signer is always an EOA. tryRecover, so a malformed signature reverts with the same
        // InvalidVoucherSignature as a wrong one instead of an ECDSA library error. `signer` is non-zero
        // (checked above), so the address(0) that a failed recovery returns can never match.
        {
            (address recovered,,) = ECDSA.tryRecover(getVoucherDigest(voucher), signature);
            if (recovered != signer) revert InvalidVoucherSignature();
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

        // Part of this stake paid for out of the voucher's bonus budget, i.e. what sits above the wallet's
        // controller limit. Metered below, once the deposit number is known.
        uint256 bonusNow;
        {
            (uint256 allowed, uint256 used) = ILimitController(controller).getAllowedAndUsed(msg.sender, phase, period);

            // `used` is the wallet's WHOLE open stake in this cell (this contract plus legacy). The part of it that
            // was paid for out of the bonus budget is already charged to the meter below; counting it against
            // `allowed` as well would fill both pools with the same tokens, so a VIP holding a bonus-funded
            // deposit would be refused base stake it is entitled to, and closing a base-funded deposit would not
            // give the base room back. Take the metered part out first. Legacy stake is never in the meter, so it
            // keeps shrinking baseRoom, which is right: it is base stake.
            // The meter and `used` must describe the SAME cell -- both are keyed (phase, period). If this meter
            // is ever re-scoped wider (per period across phases, say), this subtraction floors at 0 while the
            // cell already holds base stake, and the wallet gets its whole base allowance again at every phase
            // change. Saturating is defensive here, not reachable: bonus counted in this cell is part of this
            // cell's `used` and both fall together on close, so the meter can never exceed `used`.
            uint256 spentCell = walletBonusUsedInCell[phase][period][msg.sender];
            uint256 baseUsed = used > spentCell ? used - spentCell : 0;
            uint256 baseRoom = baseUsed >= allowed ? 0 : allowed - baseUsed;

            // No wallet-block check here, deliberately. Zero means one thing everywhere in the LimitController:
            // no BASE allowance. That is exactly what LimitController.setWalletLimit's NatSpec ("a limit of 0
            // blocks the wallet") and DeployV050.s.sol's wallet-limit comment describe, and both are correct --
            // for base staking, where `getRemaining` really does return 0. Neither is talking about vouchers.
            // The voucher's budget is INDEPENDENT headroom stacked on top of `allowed`, so a wallet on 0 can
            // still stake its bonus. Blocking a wallet is a separate switch with its own meaning:
            // `walletBlocked`, checked at the top of this function.
            uint256 spentTotal = walletBonusUsed[msg.sender];
            uint256 totalLeft = voucher.extraLimitTotal > spentTotal ? voucher.extraLimitTotal - spentTotal : 0;
            uint256 cellLeft = voucher.extraLimitPerCell > spentCell ? voucher.extraLimitPerCell - spentCell : 0;
            uint256 bonusLeft = totalLeft < cellLeft ? totalLeft : cellLeft;

            // Saturating: `allowed` is an unconstrained uint256 and type(uint256).max is what an operator types
            // for "unlimited"; a plain add would panic-revert every stake on that cell.
            //
            // DEPENDS ON PackedDeposit.amount BEING uint128 -- if you are widening it, read this.
            // Saturating makes `headroom` larger than baseRoom + bonusLeft, so in principle `bonusNow` below
            // could exceed `bonusLeft` and over-charge the meter past the voucher's budget. It cannot today:
            // `bonusLeft` is bounded by the uint128 maxExtraLimitTotal / maxExtraLimitPerCell ceilings, so this
            // branch only fires when baseRoom > 2^256 - 2^128, while `tokenAmount` can never reach 2^128 (a
            // larger one reverts downstream at SafeCast.toUint128 in the deposit push). Saturation therefore
            // implies tokenAmount < baseRoom, hence bonusNow == 0. Widen the deposit amount past uint128 and
            // the over-charge becomes reachable -- nothing at the packing site will tell you that.
            uint256 headroom = baseRoom > type(uint256).max - bonusLeft ? type(uint256).max : baseRoom + bonusLeft;
            if (tokenAmount > headroom) revert StakingLimitExceeded(msg.sender, phase, period, tokenAmount, headroom);
            bonusNow = tokenAmount > baseRoom ? tokenAmount - baseRoom : 0;
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

        if (bonusNow != 0) {
            walletBonusUsed[msg.sender] += bonusNow;
            walletBonusUsedInCell[phase][period][msg.sender] += bonusNow;
            depositBonusUsed[msg.sender][depositNumber] = bonusNow;
            emit BonusConsumed(msg.sender, phase, period, depositNumber, bonusNow);
        }

        emit Stake(
            msg.sender, phase, period, effectiveApyBps, voucher.extraApyBps, tokenAmount, depositNumber, voucher.nonce
        );

        _receiveToken(tokenAmount);
    }
}
