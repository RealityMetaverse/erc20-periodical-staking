// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";
import "../../../common/Types.sol";

abstract contract AdministrativeFunctions is ComplianceCheck {
    // ======================================
    // =         Program Management         =
    // ======================================
    using ArrayLibrary for uint256[];
    using SafeERC20 for IERC20;

    /// @notice Propose a new owner. Ownership only moves once the proposed address calls acceptOwnership.
    /// @dev Two-step transfer: a mistyped address cannot brick administration. Passing address(0) cancels
    ///      a pending proposal.
    /// @param userAddress The proposed new owner (or address(0) to cancel)
    function transferOwnership(address userAddress) external onlyContractOwner {
        pendingOwner = userAddress;

        emit OwnershipTransferStarted(msg.sender, userAddress);
    }

    /// @notice Complete an ownership transfer proposed via transferOwnership.
    /// @dev Only the pending owner may call. Clears pendingOwner.
    function acceptOwnership() external {
        address newOwner = pendingOwner;
        if (newOwner == address(0) || msg.sender != newOwner) revert NotPendingOwner(msg.sender, newOwner);

        address previousOwner = contractOwner;
        contractOwner = newOwner;
        pendingOwner = address(0);

        emit TransferOwnership(previousOwner, newOwner);
    }

    function addContractAdmin(address userAddress) external onlyContractOwner {
        if (userAddress == address(0)) revert ZeroAddressProvided();
        contractAdmins[userAddress] = true;

        emit AddContractAdmin(userAddress);
    }

    function removeContractAdmin(address userAddress) external onlyContractOwner {
        contractAdmins[userAddress] = false;

        emit RemoveContractAdmin(userAddress);
    }

    /// @notice Set the smallest amount a single stake may be. 0 is rejected.
    /// @dev The name is misspelled ("Miniumum") ON PURPOSE: it is the selector v0.2.4 shipped with and the ops
    ///      tooling calls. Kept for ABI compatibility -- do not "fix" it, a correctly spelled setter does not exist.
    function setMiniumumDeposit(uint256 newMinimumDeposit) external onlyContractOwner {
        if (newMinimumDeposit == 0) revert InvalidMinimumDeposit(newMinimumDeposit, 1);
        minimumDeposit = SafeCast.toUint128(newMinimumDeposit);

        emit UpdateMinimumDeposit(newMinimumDeposit);
    }

    /// @notice Open or close STAKING, WITHDRAWAL or CLAIM. Any other data type reverts InvalidDataType.
    function changeActionAvailability(Types.DataType action, bool changeTo) external onlyContractOwner {
        if (action == Types.DataType.STAKING) stakingOpen = changeTo;
        else if (action == Types.DataType.WITHDRAWAL) withdrawalOpen = changeTo;
        else if (action == Types.DataType.CLAIM) claimOpen = changeTo;
        else revert InvalidDataType();

        emit UpdateActionAvailability(action, changeTo);
    }

    /// @notice Close staking. Admins and the owner. Emits the same UpdateActionAvailability(STAKING, false) as
    ///         the owner path.
    /// @dev One-way on purpose: an admin can only CLOSE, and only STAKING. Reopening stays owner-only
    ///      (changeActionAvailability), and withdrawals and claims are not reachable from here, so this can
    ///      never trap funds. It is the fast response to a leaked voucher signing key, where waiting on the
    ///      owner key may be too slow. Idempotent: closing twice writes and emits again.
    function closeStaking() external onlyAdmins {
        stakingOpen = false;

        emit UpdateActionAvailability(Types.DataType.STAKING, false);
    }

    // ======================================
    // =       Phase Period Management      =
    // ======================================
    /// @dev Hard upper bounds on what may enter the configuration. Without them a typo is accepted silently and
    ///      only shows up later as a SafeCast revert on every stake in the cell: base + extra APY must fit the
    ///      deposit's uint32 apyBps (1_000_000 + 1_000_000 does), and now + period must fit its uint40 end date.
    uint256 internal constant MAX_APY_BPS = 1_000_000; // 10_000%
    uint256 internal constant MAX_PERIOD_DAYS = 36_500; // ~100 years

    /// @dev Shared validator for every place a base APY or a staking period enters the configuration
    ///      (pushStakingPhase, addStakingPeriod, setPhasePeriodData). APY 0 is rejected because APY != 0 is how
    ///      stakeWithVoucher recognises a configured cell.
    function _checkApyAndPeriod(uint256 apyBps, uint256 stakingPeriod) private pure {
        if (apyBps == 0) revert InvalidAPY(0, 1);
        if (apyBps > MAX_APY_BPS) revert ValueTooHigh(apyBps, MAX_APY_BPS);
        if (stakingPeriod > MAX_PERIOD_DAYS) revert ValueTooHigh(stakingPeriod, MAX_PERIOD_DAYS);
    }

    /// @param apyForEachStakingPeriod Base APY per period, in bps (10_000 = 100%); 0 and anything above
    ///        1_000_000 are rejected
    function pushStakingPhase(uint256[] memory apyForEachStakingPeriod, uint256[] memory targetForEachStakingPeriod)
        external
        onlyContractOwner
    {
        uint256 stakingPeriodCount = stakingPeriodList.length;
        if (
            apyForEachStakingPeriod.length != stakingPeriodCount
                || targetForEachStakingPeriod.length != stakingPeriodCount
        ) {
            revert LengthMismatch(
                stakingPeriodCount,
                apyForEachStakingPeriod.length != stakingPeriodCount
                    ? apyForEachStakingPeriod.length
                    : targetForEachStakingPeriod.length
            );
        }

        uint256 newStakingPhaseIndex = stakingPhaseCount;
        for (uint256 i = 0; i < stakingPeriodCount;) {
            // Periods already in stakingPeriodList were bounded when they were added.
            _checkApyAndPeriod(apyForEachStakingPeriod[i], 0);
            phasePeriodDataList[Types.PhasePeriodDataType.APY][newStakingPhaseIndex][stakingPeriodList[i]] =
                apyForEachStakingPeriod[i];
            phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][newStakingPhaseIndex][stakingPeriodList[i]] =
                targetForEachStakingPeriod[i];
            unchecked {
                ++i;
            }
        }

        stakingPhaseCount = SafeCast.toUint32(newStakingPhaseIndex + 1);

        emit AddStakingPhase(newStakingPhaseIndex);
    }

    /// @notice Remove the last staking phase's configuration (APY and target for every period).
    /// @dev Accounting (STAKED, user/total data, rewardPool) is never touched: deposits opened on the
    ///      removed phase stay claimable and withdrawable. Gas is O(periods), independent of staker count.
    ///      WARNING: popping the phase that is CURRENT rolls currentStakingPhase back by one, which RE-OPENS the
    ///      previous phase for new stakes at its own APYs and targets (ChangeStakingPhase is emitted for it). If
    ///      that is not intended, close staking first or push the replacement phase and switch to it before
    ///      popping.
    function popStakingPhase() external onlyContractOwner {
        uint256 phaseCount = stakingPhaseCount;
        if (phaseCount == 0) revert NoStakingPhasesAddedYet();
        uint256 lastStakingPhase = phaseCount - 1;

        uint256 periodCount = stakingPeriodList.length;
        for (uint256 periodIndex = 0; periodIndex < periodCount;) {
            _clearPhasePeriodConfig(lastStakingPhase, stakingPeriodList[periodIndex]);
            unchecked {
                ++periodIndex;
            }
        }

        stakingPhaseCount = uint32(lastStakingPhase);

        emit RemoveStakingPhase(lastStakingPhase);

        uint256 currentPhase = currentStakingPhase;
        if (currentPhase != 0 && currentPhase == lastStakingPhase) {
            unchecked {
                --currentPhase;
            }
            currentStakingPhase = uint32(currentPhase);
            emit ChangeStakingPhase(currentPhase);
        }
    }

    /// @param newStakingPeriod Period in days (0 = indefinite); anything above 36_500 is rejected
    /// @param apyForEachStakingPhase Base APY per phase, in bps (10_000 = 100%); 0 and anything above
    ///        1_000_000 are rejected
    function addStakingPeriod(
        uint256 newStakingPeriod,
        uint256[] memory apyForEachStakingPhase,
        uint256[] memory targetForEachStakingPhase
    ) external onlyContractOwner {
        if (checkIfStakingPeriodExists(newStakingPeriod)) revert StakingPeriodExists(newStakingPeriod);
        // Up front, not only in the loop below: with no phases pushed yet the loop never runs.
        _checkApyAndPeriod(1, newStakingPeriod);

        uint256 phaseCount = stakingPhaseCount;
        if (apyForEachStakingPhase.length != phaseCount || targetForEachStakingPhase.length != phaseCount) {
            revert LengthMismatch(
                phaseCount,
                apyForEachStakingPhase.length != phaseCount
                    ? apyForEachStakingPhase.length
                    : targetForEachStakingPhase.length
            );
        }
        stakingPeriodList.push(newStakingPeriod);
        stakingPeriodList.sortStorage();

        for (uint256 phase = 0; phase < phaseCount;) {
            _checkApyAndPeriod(apyForEachStakingPhase[phase], 0);
            phasePeriodDataList[Types.PhasePeriodDataType.APY][phase][newStakingPeriod] = apyForEachStakingPhase[phase];
            phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][phase][newStakingPeriod] =
                targetForEachStakingPhase[phase];
            unchecked {
                ++phase;
            }
        }

        emit AddStakingPeriod(newStakingPeriod);
    }

    /// @notice Remove a staking period's configuration (APY and target for every phase).
    /// @dev Accounting (STAKED, user/total data, rewardPool) is never touched: deposits opened on the
    ///      removed period stay claimable and withdrawable, and if the period is re-added the tokens still
    ///      staked there keep counting toward the new target. Gas is O(phases), independent of staker count.
    /// @param stakingPeriod The period (in days) to remove
    function removeStakingPeriod(uint256 stakingPeriod) external onlyContractOwner {
        uint256 periodIndex = stakingPeriodList.findElementIndex(stakingPeriod);
        if (periodIndex == stakingPeriodList.length) revert StakingPeriodDoesNotExist(stakingPeriod);

        uint256 phaseCount = stakingPhaseCount;
        for (uint256 phase = 0; phase < phaseCount;) {
            _clearPhasePeriodConfig(phase, stakingPeriod);
            unchecked {
                ++phase;
            }
        }

        stakingPeriodList.removeElementByIndex(periodIndex);

        emit RemoveStakingPeriod(stakingPeriod);
    }

    /// @dev APY values are bps (10_000 = 100%); APY 0 and anything above 1_000_000 are rejected.
    function setPhasePeriodData(
        Types.PhasePeriodDataType dataType,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 newValue
    ) external onlyContractOwner {
        if (dataType == Types.PhasePeriodDataType.STAKED) revert InvalidDataType();
        if (dataType == Types.PhasePeriodDataType.APY) _checkApyAndPeriod(newValue, 0);
        _checkIfStakingPhasePeriodExists(stakingPhase, stakingPeriod);
        phasePeriodDataList[dataType][stakingPhase][stakingPeriod] = newValue;

        emit UpdatePhasePeriodData(dataType, stakingPhase, stakingPeriod, newValue);
    }

    function changeStakingPhase(uint256 phaseToSwitch) external onlyContractOwner {
        uint256 phaseCount = stakingPhaseCount;
        if (phaseCount == 0) revert NoStakingPhasesAddedYet();
        if (phaseToSwitch >= phaseCount) revert StakingPhaseDoesNotExist(phaseToSwitch);
        currentStakingPhase = uint32(phaseToSwitch);

        emit ChangeStakingPhase(phaseToSwitch);
    }

    /// @dev Delete only the configuration cells (APY, STAKING_TARGET) of a phase/period pair.
    ///      STAKED is accounting and must survive removal (see the v0.2.4 incident in README).
    function _clearPhasePeriodConfig(uint256 stakingPhase, uint256 stakingPeriod) internal {
        delete phasePeriodDataList[Types.PhasePeriodDataType.APY][stakingPhase][stakingPeriod];
        delete phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][stakingPhase][stakingPeriod];
    }

    // ======================================
    // =      Voucher, Limit & Treasury     =
    // ======================================
    /// @notice Set the voucher signer; address(0) disables staking (stakeWithVoucher reverts VoucherSignerNotSet).
    /// @dev Must be an EOA: signatures are checked with plain ECDSA recovery, so a contract signer (ERC-1271)
    ///      can never produce a valid voucher. Recoverable -- set an EOA again.
    function setVoucherSigner(address signer) external onlyContractOwner {
        voucherSigner = signer;
        emit UpdateVoucherSigner(signer);
    }

    /// @notice Void every outstanding voucher: increments voucherEpoch, and a voucher is only accepted while
    ///         its signed `epoch` equals voucherEpoch.
    /// @dev The response to vouchers that must not be honoured any more (bad batch, suspected leak). It does
    ///      not stop a leaked key on its own -- the key holder can sign for the new epoch -- so pair it with
    ///      setVoucherSigner. The backend must read voucherEpoch() and sign the new value afterwards.
    function bumpVoucherEpoch() external onlyContractOwner {
        uint64 newEpoch = voucherEpoch + 1;
        voucherEpoch = newEpoch;
        emit UpdateVoucherEpoch(newEpoch);
    }

    /// @notice Highest extra APY (bps) a voucher may carry. At most 1_000_000, the same bound as a base APY.
    function setMaxExtraApyBps(uint256 value) external onlyContractOwner {
        if (value > MAX_APY_BPS) revert ValueTooHigh(value, MAX_APY_BPS);
        maxExtraApyBps = uint32(value);
        emit UpdateMaxExtraApyBps(value);
    }

    /// @notice Highest extra limit a voucher may carry.
    /// @dev Lowering this below what wallets already hold open is silent and safe: open deposits keep the bonus
    ///      they were granted, and the remaining figures simply floor at 0 until enough is released. It caps NEW
    ///      vouchers, it does not claw back.
    function setMaxExtraLimitTotal(uint256 value) external onlyContractOwner {
        maxExtraLimitTotal = SafeCast.toUint128(value);
        emit UpdateMaxExtraLimitTotal(value);
    }

    /// @notice Highest per-cell extra limit a voucher may carry.
    /// @dev Same as setMaxExtraLimitTotal: lowering it caps new vouchers only and never claws back bonus already
    ///      held open.
    function setMaxExtraLimitPerCell(uint256 value) external onlyContractOwner {
        maxExtraLimitPerCell = SafeCast.toUint128(value);
        emit UpdateMaxExtraLimitPerCell(value);
    }

    /// @notice Longest signed lifetime a voucher may have (validUntil - issuedAt), in seconds.
    /// @dev Rejects 0: it would revert every stake, and it reads like "disabled" when it is the opposite. This
    ///      protection has no off switch -- lower it instead.
    function setMaxVoucherValidity(uint256 validitySeconds) external onlyContractOwner {
        if (validitySeconds == 0) revert ZeroAmountProvided();
        maxVoucherValidity = SafeCast.toUint32(validitySeconds);
        emit UpdateMaxVoucherValidity(validitySeconds);
    }

    /// @notice Set the receiver of seized deposits. address(0) and this contract are rejected.
    /// @dev This contract is rejected (InvalidTreasury) because principal "seized" to it would never leave, would
    ///      stop being reserved, and could then be taken out through rescueTokens.
    ///      A treasury the token refuses to pay (a blacklisted address, say) makes every seize revert until the
    ///      treasury is changed; nothing is lost, the deposits stay frozen meanwhile.
    function setTreasury(address newTreasury) external onlyContractOwner {
        if (newTreasury == address(0)) revert ZeroAddressProvided();
        if (newTreasury == address(this)) revert InvalidTreasury();
        treasury = newTreasury;
        emit UpdateTreasury(newTreasury);
    }

    /// @notice Set the limit controller contract address. Staking requires one: with address(0) stakeWithVoucher
    ///         reverts LimitControllerNotSet.
    /// @dev The bonus accounting trusts this contract's `getAllowedAndUsed`: `used` MUST include this staking
    ///      contract's own open stake. A controller that excludes it makes the bonus meter exceed `used`, so the
    ///      saturation in stakeWithVoucher stops being defensive and base room is handed back that the wallet
    ///      has already spent. Enforced as far as it can be on-chain: a non-zero controller must answer
    ///      stakingContract() with this address, otherwise the call reverts LimitControllerMismatch (or without
    ///      data, if the address does not implement stakingContract() at all). In LimitController that value is
    ///      immutable, so for that implementation the check is a permanent invariant, not a snapshot; for any
    ///      other ILimitController implementation it only proves the pairing at install time. Either way it
    ///      cannot prove the controller's `used` is honest.
    ///      Swapping controllers while wallets hold bonus open is safe: the meters live here, not in the
    ///      controller, and release saturates.
    /// @param controllerAddress The address of the LimitController contract, or address(0) to unset
    function setLimitController(address controllerAddress) external onlyContractOwner {
        if (controllerAddress != address(0)) {
            address target = address(ILimitController(controllerAddress).stakingContract());
            if (target != address(this)) revert LimitControllerMismatch(target);
        }
        limitController = controllerAddress;
        emit UpdateLimitController(controllerAddress);
    }

    // ======================================
    // =           Fund Management          =
    // ======================================
    /// @notice Withdraw uncommitted reward tokens from the pool.
    /// @dev Cannot reduce rewardPool below totalDataList[REWARD_EXPECTED], the reward already promised to
    ///      open periodical deposits. Records REWARD_COLLECTED for symmetry with REWARD_PROVIDED.
    /// @param tokenAmount Amount to collect
    function collectReward(uint256 tokenAmount) external nonReentrant onlyContractOwner {
        if (tokenAmount == 0) revert ZeroAmountProvided();
        uint256 collectable = getCollectableReward();
        if (tokenAmount > collectable) revert RewardPoolBelowReserved(tokenAmount, collectable);

        rewardPool -= tokenAmount;
        userDataList[Types.DataType.REWARD_COLLECTED][msg.sender] += tokenAmount;
        totalDataList[Types.DataType.REWARD_COLLECTED] += tokenAmount;

        emit CollectReward(msg.sender, tokenAmount);
        _sendToken(msg.sender, tokenAmount);
    }

    /// @notice Fund the reward pool.
    /// @param tokenAmount Amount to provide (caller must have approved the contract)
    function provideReward(uint256 tokenAmount) external nonReentrant onlyAdmins {
        if (tokenAmount == 0) revert ZeroAmountProvided();
        userDataList[Types.DataType.REWARD_PROVIDED][msg.sender] += tokenAmount;
        totalDataList[Types.DataType.REWARD_PROVIDED] += tokenAmount;
        rewardPool += tokenAmount;

        emit ProvideReward(msg.sender, tokenAmount);
        _receiveToken(tokenAmount);
    }

    /// @notice Recover tokens sent to the contract by mistake.
    /// @dev Any token other than STAKING_TOKEN can be rescued in full. For STAKING_TOKEN only the excess
    ///      over totalDataList[STAKING] + rewardPool (staked principal plus the reward pool) is rescuable,
    ///      so user funds and committed rewards can never be extracted through this path.
    /// @param token Token to rescue
    /// @param amount Amount to send to the owner
    function rescueTokens(address token, uint256 amount) external nonReentrant onlyContractOwner {
        if (token == address(0)) revert ZeroAddressProvided();
        if (amount == 0) revert ZeroAmountProvided();

        uint256 excess = IERC20(token).balanceOf(address(this));
        if (token == address(STAKING_TOKEN)) {
            uint256 reserved = totalDataList[Types.DataType.STAKING] + rewardPool;
            excess = excess > reserved ? excess - reserved : 0;
        }
        if (amount > excess) revert RescueAmountExceedsExcess(amount, excess);

        emit RescueTokens(token, msg.sender, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
