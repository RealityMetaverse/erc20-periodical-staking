// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";

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

    function changeActionAvailability(DataType action, bool changeTo) external onlyContractOwner {
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
        ) revert ArrayLengthDoesntMatch(stakingPeriodCount);

        uint256 newStakingPhaseIndex = stakingPhaseCount;
        for (uint256 i = 0; i < stakingPeriodCount; i++) {
            if (apyForEachStakingPeriod[i] == 0) revert InvalidAPY(0, 1);
            phasePeriodDataList[PhasePeriodDataType.APY][newStakingPhaseIndex][stakingPeriodList[i]] =
                apyForEachStakingPeriod[i];
            phasePeriodDataList[PhasePeriodDataType.STAKING_TARGET][newStakingPhaseIndex][stakingPeriodList[i]] =
                targetForEachStakingPeriod[i];
        }

        stakingPhaseCount += 1;

        emit AddStakingPhase(newStakingPhaseIndex);
    }

    function popStakingPhase() external onlyContractOwner {
        uint256 lastStakingPhase = stakingPhaseCount - 1;

        for (uint256 periodIndex = 0; periodIndex < stakingPeriodList.length; periodIndex++) {
            delete phasePeriodDataList[PhasePeriodDataType.STAKING_TARGET][lastStakingPhase][stakingPeriodList[periodIndex]];
            delete phasePeriodDataList[PhasePeriodDataType.APY][lastStakingPhase][stakingPeriodList[periodIndex]];
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
            revert ArrayLengthDoesntMatch(stakingPhaseCount);
        }
        stakingPeriodList.push(newStakingPeriod);
        stakingPeriodList.sortStorage();

        for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
            if (apyForEachStakingPhase[phase] == 0) revert InvalidAPY(0, 1);
            phasePeriodDataList[PhasePeriodDataType.APY][phase][newStakingPeriod] = apyForEachStakingPhase[phase];
            phasePeriodDataList[PhasePeriodDataType.STAKING_TARGET][phase][newStakingPeriod] =
                targetForEachStakingPhase[phase];
        }

        emit AddStakingPeriod(newStakingPeriod);
    }

    function removeStakingPeriod(uint256 stakingPeriod) external onlyContractOwner {
        if (checkIfStakingPeriodExists(stakingPeriod)) {
            for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
                delete phasePeriodDataList[PhasePeriodDataType.STAKING_TARGET][phase][stakingPeriod];
                delete phasePeriodDataList[PhasePeriodDataType.APY][phase][stakingPeriod];
            }

            stakingPeriodList.removeElementByIndex(stakingPeriodList.findElementIndex(stakingPeriod));
        } else {
            revert StakingPeriodDoesNotExist(stakingPeriod);
        }

        emit RemoveStakingPeriod(stakingPeriod);
    }

    function setPhasePeriodData(
        PhasePeriodDataType dataType,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 newValue
    ) external onlyContractOwner {
        if (dataType == PhasePeriodDataType.STAKED) revert InvalidDataType();
        if (dataType == PhasePeriodDataType.APY && newValue == 0) revert InvalidAPY(newValue, 1);
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
        userDataList[DataType.REWARD_PROVIDED][msg.sender] += tokenAmount;
        totalDataList[DataType.REWARD_PROVIDED] += tokenAmount;
        rewardPool += tokenAmount;

        emit ProvideReward(msg.sender, tokenAmount);
        _receiveToken(tokenAmount);
    }
}
