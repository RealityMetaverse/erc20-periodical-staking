// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";
import "../../../common/Types.sol";

abstract contract ReadFunctions is ComplianceCheck {
    // ======================================
    // =            Program Data            =
    // ======================================
    function getProgramData()
        public
        view
        returns (
            uint256,
            uint256[] memory,
            uint256[][] memory,
            uint256[][] memory,
            uint256[][] memory,
            uint256[][] memory
        )
    {
        (
            uint256[][] memory phasePeriodTargets,
            uint256[][] memory phasePeriodAPYs,
            uint256[][] memory phasePeriodStaked
        ) = getPhasePeriodCombinedData();
        uint256[][] memory phasePeriodRequiredWorth = getPhasePeriodRequiredWorth();

        return (
            currentStakingPhase,
            stakingPeriodList,
            phasePeriodTargets,
            phasePeriodAPYs,
            phasePeriodStaked,
            phasePeriodRequiredWorth
        );
    }

    function getProgramDataWithUserData(address userAddress)
        external
        view
        returns (
            uint256,
            uint256[] memory,
            uint256[][] memory,
            uint256[][] memory,
            uint256[][] memory,
            uint256[][] memory,
            uint256[][] memory,
            uint256[][] memory,
            bool[][] memory
        )
    {
        (uint256[][] memory targets, uint256[][] memory apys, uint256[][] memory staked) = getPhasePeriodCombinedData();
        (uint256[][] memory limits, uint256[][] memory remaining, bool[][] memory eligibilities) =
            getPhasePeriodUserData(userAddress);
        uint256[][] memory requiredWorth = getPhasePeriodRequiredWorth();

        return (
            currentStakingPhase,
            stakingPeriodList,
            targets,
            apys,
            staked,
            requiredWorth,
            limits,
            remaining,
            eligibilities
        );
    }

    function getStakingPeriods() external view returns (uint256[] memory) {
        return stakingPeriodList;
    }

    function getPhasePeriodCombinedData()
        public
        view
        returns (uint256[][] memory, uint256[][] memory, uint256[][] memory)
    {
        uint256 _stakingPhaseCount = stakingPhaseCount;
        uint256 stakingPeriodListLength = stakingPeriodList.length;

        uint256[][] memory phasePeriodTargets = new uint256[][](_stakingPhaseCount);
        uint256[][] memory phasePeriodAPYs = new uint256[][](_stakingPhaseCount);
        uint256[][] memory phasePeriodStaked = new uint256[][](_stakingPhaseCount);

        for (uint256 phase = 0; phase < _stakingPhaseCount;) {
            phasePeriodTargets[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodAPYs[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodStaked[phase] = new uint256[](stakingPeriodListLength);

            for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                uint256 period = stakingPeriodList[periodIndex];
                uint256 target = getPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, phase, period);
                uint256 staked = getPhasePeriodData(Types.PhasePeriodDataType.STAKED, phase, period);
                uint256 apy = getPhasePeriodData(Types.PhasePeriodDataType.APY, phase, period);

                phasePeriodTargets[phase][periodIndex] = target;
                phasePeriodStaked[phase][periodIndex] = staked;
                phasePeriodAPYs[phase][periodIndex] = apy;

                unchecked {
                    ++periodIndex;
                }
            }
            unchecked {
                ++phase;
            }
        }

        return (phasePeriodTargets, phasePeriodAPYs, phasePeriodStaked);
    }

    /// @notice Returns required worth per phase/period from RequirementChecker when set; otherwise zeros.
    function getPhasePeriodRequiredWorth() public view returns (uint256[][] memory phasePeriodRequiredWorth) {
        uint256 _stakingPhaseCount = stakingPhaseCount;
        uint256 stakingPeriodListLength = stakingPeriodList.length;

        phasePeriodRequiredWorth = new uint256[][](_stakingPhaseCount);

        if (requirementChecker != address(0)) {
            uint256 totalCombinations = _stakingPhaseCount * stakingPeriodListLength;
            uint256[] memory phases = new uint256[](totalCombinations);
            uint256[] memory periods = new uint256[](totalCombinations);
            uint256 idx;
            for (uint256 phase = 0; phase < _stakingPhaseCount;) {
                for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                    phases[idx] = phase;
                    periods[idx] = stakingPeriodList[periodIndex];
                    unchecked {
                        ++idx;
                        ++periodIndex;
                    }
                }
                unchecked {
                    ++phase;
                }
            }
            uint256[] memory batchRequiredWorth =
                IRequirementChecker(requirementChecker).getRequiredWorthBatch(phases, periods);
            uint256 batchIdx;
            for (uint256 phase = 0; phase < _stakingPhaseCount;) {
                phasePeriodRequiredWorth[phase] = new uint256[](stakingPeriodListLength);
                for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                    phasePeriodRequiredWorth[phase][periodIndex] = batchRequiredWorth[batchIdx];
                    unchecked {
                        ++batchIdx;
                        ++periodIndex;
                    }
                }
                unchecked {
                    ++phase;
                }
            }
        } else {
            for (uint256 phase = 0; phase < _stakingPhaseCount;) {
                phasePeriodRequiredWorth[phase] = new uint256[](stakingPeriodListLength);
                unchecked {
                    ++phase;
                }
            }
        }
    }

    function getPhasePeriodUserData(address userAddress)
        public
        view
        returns (
            uint256[][] memory phasePeriodLimits,
            uint256[][] memory phasePeriodRemainingAmountForUser,
            bool[][] memory phasePeriodEligibilities
        )
    {
        uint256 _stakingPhaseCount = stakingPhaseCount;
        uint256 stakingPeriodListLength = stakingPeriodList.length;

        phasePeriodLimits = new uint256[][](_stakingPhaseCount);
        phasePeriodRemainingAmountForUser = new uint256[][](_stakingPhaseCount);
        phasePeriodEligibilities = new bool[][](_stakingPhaseCount);

        // Batch fetch remaining amounts, limits if limit controller is set, and eligibilities.
        // Initialize to empty so when limitController/requirementChecker is not set we use fallback logic.
        uint256[] memory batchRemaining = new uint256[](0);
        uint256[] memory batchLimits = new uint256[](0);
        bool[] memory batchEligibilities = new bool[](0);
        if (userAddress != address(0) && (limitController != address(0) || requirementChecker != address(0))) {
            uint256 totalCombinations = _stakingPhaseCount * stakingPeriodListLength;
            address[] memory wallets = new address[](totalCombinations);
            uint256[] memory phases = new uint256[](totalCombinations);
            uint256[] memory periods = new uint256[](totalCombinations);

            uint256 idx;
            for (uint256 phase = 0; phase < _stakingPhaseCount;) {
                for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                    wallets[idx] = userAddress;
                    phases[idx] = phase;
                    periods[idx] = stakingPeriodList[periodIndex];
                    unchecked {
                        ++idx;
                        ++periodIndex;
                    }
                }
                unchecked {
                    ++phase;
                }
            }

            if (limitController != address(0)) {
                batchRemaining = ILimitController(limitController).getRemainingBatch(wallets, phases, periods);
                batchLimits = ILimitController(limitController).getAllowedBatch(wallets, phases, periods);
            }
            if (requirementChecker != address(0)) {
                batchEligibilities =
                    IRequirementChecker(requirementChecker).meetsRequirementBatch(wallets, phases, periods);
            }
        }

        uint256 batchRemainingIdx;
        uint256 batchLimitsIdx;
        uint256 batchEligibilitiesIdx;
        for (uint256 phase = 0; phase < _stakingPhaseCount;) {
            phasePeriodLimits[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodRemainingAmountForUser[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodEligibilities[phase] = new bool[](stakingPeriodListLength);

            for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                uint256 period = stakingPeriodList[periodIndex];
                uint256 target = getPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, phase, period);
                uint256 staked = getPhasePeriodData(Types.PhasePeriodDataType.STAKED, phase, period);

                // Use batch result if available, otherwise calculate from target/staked
                if (batchRemaining.length > 0) {
                    phasePeriodRemainingAmountForUser[phase][periodIndex] = batchRemaining[batchRemainingIdx];
                    unchecked {
                        ++batchRemainingIdx;
                    }
                } else if (userAddress != address(0)) {
                    phasePeriodRemainingAmountForUser[phase][periodIndex] = staked >= target ? 0 : target - staked;
                }

                if (batchLimits.length > 0) {
                    phasePeriodLimits[phase][periodIndex] = batchLimits[batchLimitsIdx];
                    unchecked {
                        ++batchLimitsIdx;
                    }
                } else if (userAddress != address(0)) {
                    phasePeriodLimits[phase][periodIndex] = type(uint256).max;
                }

                if (batchEligibilities.length > 0) {
                    phasePeriodEligibilities[phase][periodIndex] = batchEligibilities[batchEligibilitiesIdx];
                    unchecked {
                        ++batchEligibilitiesIdx;
                    }
                } else if (userAddress != address(0)) {
                    phasePeriodEligibilities[phase][periodIndex] =
                        _checkIfUserMeetsRequirements(userAddress, phase, period, false);
                }

                unchecked {
                    ++periodIndex;
                }
            }
            unchecked {
                ++phase;
            }
        }
    }

    function getTotalData(Types.DataType dataType) external view returns (uint256) {
        return totalDataList[dataType];
    }

    function getPhasePeriodDataAll(Types.PhasePeriodDataType dataType) external view returns (uint256[][] memory) {
        uint256 _stakingPhaseCount = stakingPhaseCount;
        uint256[] memory _stakingPeriodList = stakingPeriodList;

        uint256[][] memory phasePeriodData = new uint256[][](_stakingPhaseCount);
        for (uint256 phase = 0; phase < _stakingPhaseCount; phase++) {
            phasePeriodData[phase] = new uint256[](_stakingPeriodList.length);
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

    function getUserData(Types.DataType dataType, address userAddress) external view returns (uint256) {
        return userDataList[dataType][userAddress];
    }

    function getUserPhasePeriodData(
        Types.DataType dataType,
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod
    ) public view returns (uint256) {
        return userPhasePeriodDataList[dataType][stakingPhase][stakingPeriod][userAddress];
    }

    /// @notice Batch get user phase period data for multiple combinations
    /// @param dataType The data type (STAKING, WITHDRAWAL, etc.)
    /// @param userAddresses Array of user addresses
    /// @param stakingPhases Array of staking phases
    /// @param stakingPeriods Array of staking periods
    /// @return values Array of data values
    function getUserPhasePeriodDataBatch(
        Types.DataType dataType,
        address[] calldata userAddresses,
        uint256[] calldata stakingPhases,
        uint256[] calldata stakingPeriods
    ) external view returns (uint256[] memory values) {
        uint256 len = userAddresses.length;
        if (len != stakingPhases.length || len != stakingPeriods.length) {
            revert LengthMismatch(len, stakingPhases.length != len ? stakingPhases.length : stakingPeriods.length);
        }

        values = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            values[i] = getUserPhasePeriodData(dataType, userAddresses[i], stakingPhases[i], stakingPeriods[i]);
            unchecked {
                ++i;
            }
        }
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
