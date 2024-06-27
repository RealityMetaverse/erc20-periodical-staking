// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";

abstract contract ReadFunctions is ComplianceCheck {
    // ======================================
    // =            Program Data            =
    // ======================================
    function getProgramData()
        external
        view
        returns (uint256, uint256[] memory, uint256[][] memory, uint256[][] memory, uint256[][] memory)
    {
        uint256[] memory _stakingPeriodList = stakingPeriodList;

        uint256[][] memory phasePeriodTargets = new uint256[][](stakingPhaseCount);
        uint256[][] memory phasePeriodAPYs = new uint256[][](stakingPhaseCount);
        uint256[][] memory phasePeriodStaked = new uint256[][](stakingPhaseCount);

        for (uint256 phase = 0; phase < stakingPhaseCount; phase++) {
            phasePeriodTargets[phase] = new uint256[](_stakingPeriodList.length);
            phasePeriodAPYs[phase] = new uint256[](_stakingPeriodList.length);
            phasePeriodStaked[phase] = new uint256[](_stakingPeriodList.length);
            for (uint256 periodIndex = 0; periodIndex < _stakingPeriodList.length; periodIndex++) {
                phasePeriodTargets[phase][periodIndex] =
                    getPhasePeriodData(PhasePeriodDataType.STAKING_TARGET, phase, _stakingPeriodList[periodIndex]);
                phasePeriodAPYs[phase][periodIndex] =
                    getPhasePeriodData(PhasePeriodDataType.APY, phase, _stakingPeriodList[periodIndex]);
                phasePeriodStaked[phase][periodIndex] =
                    getPhasePeriodData(PhasePeriodDataType.STAKED, phase, _stakingPeriodList[periodIndex]);
            }
        }
        return (currentStakingPhase, _stakingPeriodList, phasePeriodTargets, phasePeriodAPYs, phasePeriodStaked);
    }

    function getStakingPeriods() external view returns (uint256[] memory) {
        return stakingPeriodList;
    }

    function getPhasePeriodData(PhasePeriodDataType dataType, uint256 phase, uint256 period)
        public
        view
        returns (uint256)
    {
        return phasePeriodDataList[dataType][phase][period];
    }

    function getTotalData(DataType dataType) external view returns (uint256) {
        return totalDataList[dataType];
    }

    function getAllPhasePeriodData(PhasePeriodDataType dataType) external view returns (uint256[][] memory) {
        uint256 _stakingPhaseCount = stakingPhaseCount;
        uint256[] memory _stakingPeriodList = stakingPeriodList;

        uint256[][] memory phasePeriodData = new uint256[][](_stakingPhaseCount);
        for (uint256 phase = 0; phase < _stakingPhaseCount; phase++) {
            for (uint256 periodIndex = 0; periodIndex < _stakingPeriodList.length; periodIndex++) {
                phasePeriodData[phase][periodIndex] =
                    getPhasePeriodData(dataType, phase, _stakingPeriodList[periodIndex]);
            }
        }
        return phasePeriodData;
    }

    function checkTotalClaimableData() external view returns (uint256, uint256, uint256) {
        uint256 totalClaimableStaking;
        uint256 totalClaimablePeriodicalReward;
        uint256 totalClaimableIndefiniteReward;

        for (uint256 stakerNo = 0; stakerNo < stakerAddressList.length; stakerNo++) {
            address userAddress = stakerAddressList[stakerNo];
            (uint256 claimableStaking, uint256 claimablePeriodicalReward, uint256 claimableIndefiniteReward) =
                checkClaimableDataFor(userAddress);

            totalClaimableStaking += claimableStaking;
            totalClaimablePeriodicalReward += claimablePeriodicalReward;
            totalClaimableIndefiniteReward += claimableIndefiniteReward;
        }

        return (totalClaimableStaking, totalClaimablePeriodicalReward, totalClaimableIndefiniteReward);
    }

    // ======================================
    // =             User Data             =
    // ======================================
    function checkDepositCountOfAddress(address userAddress) public view returns (uint256) {
        return stakerDepositList[userAddress].length;
    }

    function getDeposit(address userAddress, uint256 depositNumber) public view returns (TokenDeposit memory) {
        TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
        DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
        if (depositStatus == DepositStatus.INDEFINITE) {
            uint256 reward = _calculateIndefiniteDepositReward(targetDeposit);
            return TokenDeposit(
                targetDeposit.stakingPhase,
                targetDeposit.stakingPeriod,
                targetDeposit.stakingStartDate,
                targetDeposit.stakingEndDate,
                targetDeposit.withdrawalDate,
                targetDeposit.amount,
                targetDeposit.APY,
                reward
            );
        } else {
            return targetDeposit;
        }
    }

    function getDepositsInRangeBy(address userAddress, uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (TokenDeposit[] memory)
    {
        TokenDeposit[] memory userDepositsInRange = new TokenDeposit[](toIndex - fromIndex);

        for (uint256 i = fromIndex; i < toIndex; i++) {
            userDepositsInRange[i - fromIndex] = getDeposit(userAddress, i);
        }

        return userDepositsInRange;
    }

    function getUserData(DataType dataType, address userAddress) external view returns (uint256) {
        return userDataList[dataType][userAddress];
    }

    function checkClaimableDataFor(address userAddress) public view returns (uint256, uint256, uint256) {
        uint256 claimableStaking;
        uint256 claimablePeriodicalReward;
        uint256 claimableIndefiniteReward;

        uint256 userDepositCount = checkDepositCountOfAddress(userAddress);
        for (
            uint256 depositNumber = stakerActiveDepositStartIndex[userAddress];
            depositNumber < userDepositCount;
            depositNumber++
        ) {
            DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
            TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];

            if (depositStatus == DepositStatus.READY_TO_CLAIM) {
                claimableStaking += targetDeposit.amount;
                claimablePeriodicalReward += targetDeposit.rewardGenerated;
            } else if (depositStatus == DepositStatus.INDEFINITE) {
                claimableIndefiniteReward += _calculateIndefiniteDepositReward(targetDeposit);
            }
        }

        return (claimableStaking, claimablePeriodicalReward, claimableIndefiniteReward);
    }

    // ======================================
    // =           Other functions          =
    // ======================================
    function calculateReward(uint256 depositAmount, uint256 depositAPY, uint256 stakingPeriod)
        public
        pure
        returns (uint256)
    {
        return (
            ((depositAmount * ((FIXED_POINT_PRECISION * depositAPY / 365) * stakingPeriod) / 100))
                / FIXED_POINT_PRECISION
        );
    }

    function _calculateIndefiniteDepositReward(TokenDeposit memory targetDeposit) internal view returns (uint256) {
        uint256 timePassed = block.timestamp - targetDeposit.stakingStartDate;
        uint256 daysPassed = timePassed / (1 days);

        return calculateReward(targetDeposit.amount, targetDeposit.APY, daysPassed) - targetDeposit.rewardGenerated;
    }
}
