// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../ComplianceCheck.sol";

abstract contract AdministrativeFunctions is ComplianceCheck {
    // ======================================
    // =     Program Parameter Setters      =
    // ======================================
    using ArrayLibrary for uint256[];

    function transferOwnership(address userAddress) external onlyContractOwner {
        require(userAddress != address(0), "new contract owner cannot be zero");
        require(userAddress != msg.sender, "Same with current owner");
        contractOwner = userAddress;

        emit TransferOwnership(msg.sender, userAddress);
    }

    function addContractAdmin(address userAddress) external onlyContractOwner {
        require(userAddress != msg.sender, "Owner can not be an admin");
        contractAdmins[userAddress] = true;

        emit AddContractAdmin(userAddress);
    }

    function removeContractAdmin(address userAddress) external onlyContractOwner {
        contractAdmins[userAddress] = false;

        emit RemoveContractAdmin(userAddress);
    }

    function pushStakingPhase(uint256[] memory apyForEachStakingPeriod, uint256[] memory targetForEachStakingPeriod)
        external
        onlyContractOwner
    {
        uint256 stakingPeriodCount = stakingPeriodList.length;
        if (apyForEachStakingPeriod.length != stakingPeriodCount) revert ArrayLengthDoesntMatch("apyForEachStakingPeriod", stakingPeriodCount);
        if (targetForEachStakingPeriod.length != stakingPeriodCount) revert ArrayLengthDoesntMatch("targetForEachStakingPeriod", stakingPeriodCount);

        uint256 newStakingPhaseIndex = stakingPhaseCount;
        for (uint256 i = 0; i < stakingPeriodCount; i++) {
            if (apyForEachStakingPeriod[i] == 0) revert InvalidArgumentValue("APY", 1);
            phasePeriodDataList[DataType.APY][newStakingPhaseIndex][stakingPeriodList[i]] = apyForEachStakingPeriod[i];
            phasePeriodDataList[DataType.STAKING_TARGET][newStakingPhaseIndex][stakingPeriodList[i]] = targetForEachStakingPeriod[i];
        }
        
        stakingPhaseCount += 1;

        emit AddStakingPhase(
            newStakingPhaseIndex
        );
    }

    function popStakingPhase() external onlyContractOwner {
        uint256 lastStakingPhase = stakingPhaseCount - 1;

        for (uint256 periodIndex = 0; periodIndex < stakingPeriodList.length; periodIndex++) {
            delete phasePeriodDataList[DataType.APY][lastStakingPhase][stakingPeriodList[periodIndex]];
            delete phasePeriodDataList[DataType.STAKING_TARGET][lastStakingPhase][stakingPeriodList[periodIndex]];
        }

        stakingPhaseCount -= 1;
        if (currentStakingPhase != 0 && currentStakingPhase == stakingPhaseCount) currentStakingPhase -= 1;
        
        emit RemoveStakingPhase(
            lastStakingPhase
        );
    }

    function addStakingPeriod(uint256 newStakingPeriod, uint256[] memory apyForEachStakingPhase, uint256[] memory targetForEachStakingPhase)
        external
        onlyContractOwner
    {
        if (stakingPhaseCount == 0) revert NoStakingPhasesAddedYet();
        if (_checkIfStakingPeriodExists(newStakingPeriod)) revert StakingPeriodExists(newStakingPeriod);

        if (apyForEachStakingPhase.length != stakingPhaseCount) revert ArrayLengthDoesntMatch("apyForEachStakingPhase", stakingPhaseCount);
        if (targetForEachStakingPhase.length != stakingPhaseCount) revert ArrayLengthDoesntMatch("targetForEachStakingPhase", stakingPhaseCount);

        stakingPeriodList.push(newStakingPeriod);
        stakingPeriodList.sortStorage();

        for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
            if (apyForEachStakingPhase[phase] == 0) revert InvalidArgumentValue("APY", 1);
            phasePeriodDataList[DataType.APY][phase][newStakingPeriod] = apyForEachStakingPhase[phase];
            phasePeriodDataList[DataType.STAKING_TARGET][phase][newStakingPeriod] = targetForEachStakingPhase[phase];
        }

        emit AddStakingPeriod(newStakingPeriod);
    }

    function removeStakingPeriod(uint256 stakingPeriod) external onlyContractOwner {
        if (_checkIfStakingPeriodExists(stakingPeriod)) {
            for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
                delete phasePeriodDataList[DataType.APY][phase][stakingPeriod];
                delete phasePeriodDataList[DataType.STAKING_TARGET][phase][stakingPeriod];
            }

            stakingPeriodList.removeElementByIndex(
                stakingPeriodList.findElementIndex(stakingPeriod)
            );
        } else revert StakingPeriodDoesNotExist(stakingPeriod);

        emit RemoveStakingPeriod(stakingPeriod);
    }

    function setStakingTarget(uint256 stakingPhase, uint256 stakingPeriod, uint256 newStakingTarget)
        external
        onlyContractOwner
    {
        if(!_checkIfStakingPhaseExists(stakingPhase)) revert StakingPhaseDoesNotExist(stakingPhase);
        if (!_checkIfStakingPeriodExists(stakingPeriod)) revert StakingPeriodDoesNotExist(stakingPeriod);
        phasePeriodDataList[DataType.STAKING_TARGET][stakingPhase][stakingPeriod] = newStakingTarget;

        emit UpdateStakingTarget(stakingPhase, stakingPeriod, newStakingTarget);
    }

    function setAPY(uint256 stakingPhase, uint256 stakingPeriod, uint256 newAPY)
        public
        onlyContractOwner
    {
        if (!_checkIfStakingPhaseExists(stakingPhase)) revert StakingPhaseDoesNotExist(stakingPhase);
        if (!_checkIfStakingPeriodExists(stakingPeriod)) revert StakingPeriodDoesNotExist(stakingPeriod);

        if (newAPY == 0) revert InvalidArgumentValue("APY", 1);

        phasePeriodDataList[DataType.APY][stakingPhase][stakingPeriod] = newAPY;
        emit UpdateAPY(stakingPhase, stakingPeriod, newAPY);
    }

    function setMiniumumDeposit(uint256 newMinimumDeposit)
        external
        onlyContractOwner
    {
        if (newMinimumDeposit == 0) revert InvalidArgumentValue("Minimum Deposit", 1);
        minimumDeposit = newMinimumDeposit;

        emit UpdateMinimumDeposit(newMinimumDeposit);
    }

    function changeAvailabilityStatus(uint256 parameterToChange, bool valueToAssign)
        external
        onlyContractOwner
    {
        require(parameterToChange < 3, "Invalid Parameter");

        if (parameterToChange == 0) {
            isStakingOpen = valueToAssign;

            emit UpdateStakingStatus(msg.sender, valueToAssign);
        } else if (parameterToChange == 1) {
            isWithdrawalOpen = valueToAssign;

            emit UpdateWithdrawalStatus(msg.sender, valueToAssign);
        } else if (parameterToChange == 2) {
            isClaimOpen = valueToAssign;

            emit UpdateClaimStatus(msg.sender, valueToAssign);
        }
    }

    function changeStakingPhase(uint256 phaseToSwitch) external onlyContractOwner {
        if (stakingPhaseCount == 0) revert NoStakingPhasesAddedYet();
        if (phaseToSwitch >= stakingPhaseCount) revert StakingPhaseDoesNotExist(phaseToSwitch);
        currentStakingPhase = phaseToSwitch;
    }

    // ======================================
    // =     FUND MANAGEMENT FUNCTIONS      =
    // ======================================
    /// @dev Collects staked funds
    function collectFunds(uint256 tokenAmount)
        external
        nonReentrant
        onlyContractOwner
    {
        _checkIfEnoughFundsAvailable(tokenAmount);
        totalDataList[DataType.FUNDS_COLLECTED] += tokenAmount;

        emit CollectFunds(msg.sender, tokenAmount);
        _sendToken(msg.sender, tokenAmount);
    }

    /// @dev Restores funds collected
    function restoreFunds(uint256 tokenAmount) external nonReentrant onlyAdmins {
        uint256 remainingFundsToRestore =
            totalDataList[DataType.FUNDS_COLLECTED] - totalDataList[DataType.FUNDS_RESTORED];

        if (tokenAmount > remainingFundsToRestore) revert RestorationExceedsCollected(tokenAmount, remainingFundsToRestore);

        userDataList[DataType.FUNDS_RESTORED][msg.sender] += tokenAmount;
        totalDataList[DataType.FUNDS_RESTORED] += tokenAmount;

        emit RestoreFunds(msg.sender, tokenAmount);
        _receiveToken(tokenAmount);
    }

    function collectRewardPoolFunds(uint256 tokenAmount)
        external
        nonReentrant
        onlyContractOwner
    {
        _checkIfEnoughFundsInRewardPool(tokenAmount, true);
        rewardPool -= tokenAmount;

        emit CollectReward(msg.sender, tokenAmount);
        _sendToken(msg.sender, tokenAmount);
    }

    function provideReward(uint256 tokenAmount) external nonReentrant onlyAdmins {
        rewardProviderList[msg.sender] += tokenAmount;
        rewardPool += tokenAmount;

        emit ProvideReward(msg.sender, tokenAmount);
        _receiveToken(tokenAmount);
    }
}
