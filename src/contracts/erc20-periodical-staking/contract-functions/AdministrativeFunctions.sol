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

    function setMiniumumDeposit(uint256 newMinimumDeposit) external onlyContractOwner {
        if (newMinimumDeposit == 0) revert InvalidMinimumDeposit(newMinimumDeposit, 1);
        minimumDeposit = newMinimumDeposit;

        emit UpdateMinimumDeposit(newMinimumDeposit);
    }

    function changeActionAvailability(Types.DataType action, bool changeTo) external onlyContractOwner {
        actionAvailabilityStatuses[action] = changeTo;
        emit UpdateActionAvailability(action, changeTo);
    }

    // ======================================
    // =       Phase Period Management      =
    // ======================================
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
        for (uint256 i = 0; i < stakingPeriodCount; i++) {
            if (apyForEachStakingPeriod[i] == 0) revert InvalidAPY(0, 1);
            phasePeriodDataList[Types.PhasePeriodDataType.APY][newStakingPhaseIndex][stakingPeriodList[i]] =
                apyForEachStakingPeriod[i];
            phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][newStakingPhaseIndex][stakingPeriodList[i]] =
                targetForEachStakingPeriod[i];
        }

        stakingPhaseCount += 1;

        emit AddStakingPhase(newStakingPhaseIndex);
    }

    /// @notice Remove the last staking phase's configuration (APY and target for every period).
    /// @dev Accounting (STAKED, user/total data, rewardPool) is never touched: deposits opened on the
    ///      removed phase stay claimable and withdrawable. Gas is O(periods), independent of staker count.
    function popStakingPhase() external onlyContractOwner {
        if (stakingPhaseCount == 0) revert NoStakingPhasesAddedYet();
        uint256 lastStakingPhase = stakingPhaseCount - 1;

        uint256 periodCount = stakingPeriodList.length;
        for (uint256 periodIndex = 0; periodIndex < periodCount; periodIndex++) {
            _clearPhasePeriodConfig(lastStakingPhase, stakingPeriodList[periodIndex]);
        }

        stakingPhaseCount -= 1;
        if (currentStakingPhase != 0 && currentStakingPhase == stakingPhaseCount) currentStakingPhase -= 1;

        emit RemoveStakingPhase(lastStakingPhase);
    }

    function addStakingPeriod(
        uint256 newStakingPeriod,
        uint256[] memory apyForEachStakingPhase,
        uint256[] memory targetForEachStakingPhase
    ) external onlyContractOwner {
        if (checkIfStakingPeriodExists(newStakingPeriod)) revert StakingPeriodExists(newStakingPeriod);

        if (apyForEachStakingPhase.length != stakingPhaseCount || targetForEachStakingPhase.length != stakingPhaseCount)
        {
            revert LengthMismatch(
                stakingPhaseCount,
                apyForEachStakingPhase.length != stakingPhaseCount
                    ? apyForEachStakingPhase.length
                    : targetForEachStakingPhase.length
            );
        }
        stakingPeriodList.push(newStakingPeriod);
        stakingPeriodList.sortStorage();

        for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
            if (apyForEachStakingPhase[phase] == 0) revert InvalidAPY(0, 1);
            phasePeriodDataList[Types.PhasePeriodDataType.APY][phase][newStakingPeriod] = apyForEachStakingPhase[phase];
            phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][phase][newStakingPeriod] =
                targetForEachStakingPhase[phase];
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
        for (uint256 phase = 0; phase < phaseCount; phase++) {
            _clearPhasePeriodConfig(phase, stakingPeriod);
        }

        stakingPeriodList.removeElementByIndex(periodIndex);

        emit RemoveStakingPeriod(stakingPeriod);
    }

    function setPhasePeriodData(
        Types.PhasePeriodDataType dataType,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 newValue
    ) external onlyContractOwner {
        if (dataType == Types.PhasePeriodDataType.STAKED) revert InvalidDataType();
        if (dataType == Types.PhasePeriodDataType.APY && newValue == 0) revert InvalidAPY(newValue, 1);
        _checkIfStakingPhasePeriodExists(stakingPhase, stakingPeriod);
        phasePeriodDataList[dataType][stakingPhase][stakingPeriod] = newValue;

        emit UpdatePhasePeriodData(dataType, stakingPhase, stakingPeriod, newValue);
    }

    function changeStakingPhase(uint256 phaseToSwitch) external onlyContractOwner {
        if (stakingPhaseCount == 0) revert NoStakingPhasesAddedYet();
        if (phaseToSwitch >= stakingPhaseCount) revert StakingPhaseDoesNotExist(phaseToSwitch);
        currentStakingPhase = phaseToSwitch;

        emit ChangeStakingPhase(phaseToSwitch);
    }

    /// @dev Delete only the configuration cells (APY, STAKING_TARGET) of a phase/period pair.
    ///      STAKED is accounting and must survive removal (see the v0.2.4 incident in README).
    function _clearPhasePeriodConfig(uint256 stakingPhase, uint256 stakingPeriod) internal {
        delete phasePeriodDataList[Types.PhasePeriodDataType.APY][stakingPhase][stakingPeriod];
        delete phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][stakingPhase][stakingPeriod];
    }

    // ======================================
    // =           Whitelist Control        =
    // ======================================
    /// @notice Enable or disable the staking whitelist.
    /// @dev When disabled, anyone can stake. When enabled, only whitelisted addresses can stake.
    function setWhitelistEnabled(bool enabled) external onlyContractOwner {
        whitelistEnabled = enabled;
        emit UpdateWhitelistStatus(enabled);
    }

    /// @notice Add or remove an address from the staking whitelist.
    function setWhitelistAddress(address userAddress, bool allowed) external onlyContractOwner {
        _setWhitelistAddress(userAddress, allowed);
    }

    /// @notice Batch add or remove multiple addresses from the staking whitelist.
    /// @param userAddresses List of addresses to update.
    /// @param allowed Whitelist status to apply to all provided addresses.
    function setWhitelistAddresses(address[] calldata userAddresses, bool allowed) external onlyContractOwner {
        uint256 length = userAddresses.length;
        for (uint256 i = 0; i < length; i++) {
            _setWhitelistAddress(userAddresses[i], allowed);
        }
    }

    /// @dev Internal helper to update whitelist mapping and emit event.
    function _setWhitelistAddress(address userAddress, bool allowed) internal {
        if (userAddress == address(0)) revert ZeroAddressProvided();
        isWhitelisted[userAddress] = allowed;
        emit UpdateWhitelist(userAddress, allowed);
    }

    // ======================================
    // =        Staking Limit Control       =
    // ======================================
    /// @notice Set the limit controller contract address; zero disables limit checks.
    /// @param controllerAddress The address of the LimitController contract or zero to disable
    function setLimitController(address controllerAddress) external onlyContractOwner {
        limitController = controllerAddress;
        emit UpdateLimitController(controllerAddress);
    }

    // ======================================
    // =        Requirement Control         =
    // ======================================
    /// @notice Set the external requirement checker contract address; zero disables requirement checks.
    /// @param checkerAddress The address of the RequirementChecker contract or zero to disable
    function setRequirementChecker(address checkerAddress) external onlyContractOwner {
        requirementChecker = checkerAddress;
        emit UpdateRequirementChecker(checkerAddress);
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
