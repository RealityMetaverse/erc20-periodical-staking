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

    function transferOwnership(address userAddress) external onlyContractOwner {
        if (userAddress == address(0)) revert ZeroAddressProvided();
        contractOwner = userAddress;

        emit TransferOwnership(msg.sender, userAddress);
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

    function popStakingPhase() external onlyContractOwner {
        uint256 lastStakingPhase = stakingPhaseCount - 1;

        for (uint256 periodIndex = 0; periodIndex < stakingPeriodList.length; periodIndex++) {
            uint256 stakingPeriod = stakingPeriodList[periodIndex];
            _clearPhasePeriodData(lastStakingPhase, stakingPeriod);
            _clearPhasePeriodUserData(lastStakingPhase, stakingPeriod);
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

    function removeStakingPeriod(uint256 stakingPeriod) external onlyContractOwner {
        if (checkIfStakingPeriodExists(stakingPeriod)) {
            for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
                _clearPhasePeriodData(phase, stakingPeriod);
                _clearPhasePeriodUserData(phase, stakingPeriod);
            }

            stakingPeriodList.removeElementByIndex(stakingPeriodList.findElementIndex(stakingPeriod));
        } else {
            revert StakingPeriodDoesNotExist(stakingPeriod);
        }

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

    /// @dev Remove all user-scoped data tied to a specific phase/period pair across every DataType.
    function _clearPhasePeriodUserData(uint256 stakingPhase, uint256 stakingPeriod) internal {
        uint256 dataTypeCount = uint256(type(Types.DataType).max) + 1;
        uint256 stakerCount = stakerAddressList.length;

        for (uint256 i = 0; i < dataTypeCount; i++) {
            for (uint256 j = 0; j < stakerCount; j++) {
                delete userPhasePeriodDataList[Types.DataType(i)][stakingPhase][stakingPeriod][stakerAddressList[j]];
            }
        }
    }

    /// @dev Remove all phase/period data across every PhasePeriodDataType.
    function _clearPhasePeriodData(uint256 stakingPhase, uint256 stakingPeriod) internal {
        uint256 dataTypeCount = uint256(type(Types.PhasePeriodDataType).max) + 1;
        for (uint256 i = 0; i < dataTypeCount; i++) {
            delete phasePeriodDataList[Types.PhasePeriodDataType(i)][stakingPhase][stakingPeriod];
        }
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
    function collectReward(uint256 tokenAmount) external nonReentrant onlyContractOwner {
        _checkIfEnoughFundsInRewardPool(tokenAmount, true);
        rewardPool -= tokenAmount;

        emit CollectReward(msg.sender, tokenAmount);
        _sendToken(msg.sender, tokenAmount);
    }

    function provideReward(uint256 tokenAmount) external nonReentrant onlyAdmins {
        userDataList[Types.DataType.REWARD_PROVIDED][msg.sender] += tokenAmount;
        totalDataList[Types.DataType.REWARD_PROVIDED] += tokenAmount;
        rewardPool += tokenAmount;

        emit ProvideReward(msg.sender, tokenAmount);
        _receiveToken(tokenAmount);
    }
}
