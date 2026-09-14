// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../ComplianceCheck.sol";
import "../../../common/Types.sol";

abstract contract ReadFunctions is ComplianceCheck {
    // ======================================
    // =            Program Data            =
    // ======================================
    /// @return currentPhase The current staking phase
    /// @return periods The configured staking periods (days)
    /// @return targets Staking target per [phase][periodIndex]
    /// @return apysBps Base APY per [phase][periodIndex], in bps (10_000 = 100%)
    /// @return staked Total staked per [phase][periodIndex]
    function getProgramData()
        public
        view
        returns (
            uint256 currentPhase,
            uint256[] memory periods,
            uint256[][] memory targets,
            uint256[][] memory apysBps,
            uint256[][] memory staked
        )
    {
        (targets, apysBps, staked) = getPhasePeriodCombinedData();
        return (currentStakingPhase, stakingPeriodList, targets, apysBps, staked);
    }

    /// @notice getProgramData plus the user's controller limits and remaining amounts (legacy stake included,
    ///         voucher extras not included).
    function getProgramDataWithUserData(address userAddress)
        external
        view
        returns (
            uint256 currentPhase,
            uint256[] memory periods,
            uint256[][] memory targets,
            uint256[][] memory apysBps,
            uint256[][] memory staked,
            uint256[][] memory limits,
            uint256[][] memory remaining
        )
    {
        (targets, apysBps, staked) = getPhasePeriodCombinedData();
        (limits, remaining) = getPhasePeriodUserData(userAddress);
        return (currentStakingPhase, stakingPeriodList, targets, apysBps, staked, limits, remaining);
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
        uint256[] memory periods = stakingPeriodList;
        uint256 stakingPeriodListLength = periods.length;

        uint256[][] memory phasePeriodTargets = new uint256[][](_stakingPhaseCount);
        uint256[][] memory phasePeriodAPYs = new uint256[][](_stakingPhaseCount);
        uint256[][] memory phasePeriodStaked = new uint256[][](_stakingPhaseCount);

        for (uint256 phase = 0; phase < _stakingPhaseCount;) {
            phasePeriodTargets[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodAPYs[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodStaked[phase] = new uint256[](stakingPeriodListLength);

            for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                uint256 period = periods[periodIndex];
                phasePeriodTargets[phase][periodIndex] =
                    phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][phase][period];
                phasePeriodStaked[phase][periodIndex] =
                    phasePeriodDataList[Types.PhasePeriodDataType.STAKED][phase][period];
                phasePeriodAPYs[phase][periodIndex] = phasePeriodDataList[Types.PhasePeriodDataType.APY][phase][period];

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

    /// @notice The user's controller limit and remaining amount per [phase][periodIndex].
    /// @dev Both come from the LimitController and include legacy-contract stake; voucher extras are not included.
    ///      Zero-filled when userAddress or limitController is address(0). Reverts if the controller reverts or
    ///      returns arrays of the wrong length.
    function getPhasePeriodUserData(address userAddress)
        public
        view
        returns (uint256[][] memory phasePeriodLimits, uint256[][] memory phasePeriodRemainingAmountForUser)
    {
        uint256 _stakingPhaseCount = stakingPhaseCount;
        uint256[] memory periods = stakingPeriodList;
        uint256 stakingPeriodListLength = periods.length;
        address controller = limitController;

        phasePeriodLimits = new uint256[][](_stakingPhaseCount);
        phasePeriodRemainingAmountForUser = new uint256[][](_stakingPhaseCount);

        bool query = userAddress != address(0) && controller != address(0);
        uint256[] memory batchLimits;
        uint256[] memory batchRemaining;

        if (query) {
            uint256 totalCombinations = _stakingPhaseCount * stakingPeriodListLength;
            address[] memory wallets = new address[](totalCombinations);
            uint256[] memory phases = new uint256[](totalCombinations);
            uint256[] memory periodsFlat = new uint256[](totalCombinations);

            uint256 idx;
            for (uint256 phase = 0; phase < _stakingPhaseCount;) {
                for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                    wallets[idx] = userAddress;
                    phases[idx] = phase;
                    periodsFlat[idx] = periods[periodIndex];
                    unchecked {
                        ++idx;
                        ++periodIndex;
                    }
                }
                unchecked {
                    ++phase;
                }
            }

            batchLimits = ILimitController(controller).getAllowedBatch(wallets, phases, periodsFlat);
            batchRemaining = ILimitController(controller).getRemainingBatch(wallets, phases, periodsFlat);
            if (batchLimits.length != totalCombinations) revert LengthMismatch(totalCombinations, batchLimits.length);
            if (batchRemaining.length != totalCombinations) {
                revert LengthMismatch(totalCombinations, batchRemaining.length);
            }
        }

        uint256 batchIdx;
        for (uint256 phase = 0; phase < _stakingPhaseCount;) {
            phasePeriodLimits[phase] = new uint256[](stakingPeriodListLength);
            phasePeriodRemainingAmountForUser[phase] = new uint256[](stakingPeriodListLength);

            if (query) {
                for (uint256 periodIndex = 0; periodIndex < stakingPeriodListLength;) {
                    phasePeriodLimits[phase][periodIndex] = batchLimits[batchIdx];
                    phasePeriodRemainingAmountForUser[phase][periodIndex] = batchRemaining[batchIdx];
                    unchecked {
                        ++batchIdx;
                        ++periodIndex;
                    }
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
        for (uint256 phase = 0; phase < _stakingPhaseCount;) {
            phasePeriodData[phase] = new uint256[](_stakingPeriodList.length);
            for (uint256 periodIndex = 0; periodIndex < _stakingPeriodList.length;) {
                phasePeriodData[phase][periodIndex] =
                    getPhasePeriodData(dataType, phase, _stakingPeriodList[periodIndex]);
                unchecked {
                    ++periodIndex;
                }
            }
            unchecked {
                ++phase;
            }
        }
        return phasePeriodData;
    }

    /// @notice Reward the pool must still be able to pay for every configured periodical cell to fill.
    /// @dev Sum over every (phase < stakingPhaseCount, period in stakingPeriodList, period != 0) of
    ///      `calculateReward(target - staked, baseApyBps, period)` (0 when the cell is already at or above
    ///      target). Voucher extra APY is not included. Stakes are never blocked by pool state; this is an ops
    ///      view so the pool can be funded before deposits mature (a matured periodical claim reverts
    ///      `NotEnoughFundsInRewardPool` while the pool is short).
    function getRewardRequiredForTargets() public view returns (uint256 required) {
        uint256 phaseCount = stakingPhaseCount;
        uint256[] memory periods = stakingPeriodList;
        uint256 periodCount = periods.length;

        for (uint256 phase = 0; phase < phaseCount;) {
            for (uint256 periodIndex = 0; periodIndex < periodCount;) {
                uint256 period = periods[periodIndex];
                if (period != 0) {
                    uint256 target = phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][phase][period];
                    uint256 staked = phasePeriodDataList[Types.PhasePeriodDataType.STAKED][phase][period];
                    if (target > staked) {
                        uint256 apy = phasePeriodDataList[Types.PhasePeriodDataType.APY][phase][period];
                        required += calculateReward(target - staked, apy, period);
                    }
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

    /// @notice Extra reward-pool funding needed so that every already-open periodical deposit AND every
    ///         open target, once filled, can be paid at maturity.
    /// @dev `deficit = max(0, totalDataList[REWARD_EXPECTED] - rewardPool)` is what already-open deposits are
    ///      missing today; `required` is what the remaining target capacity would add.
    /// @return shortfall `max(0, getRewardRequiredForTargets() + deficit - getCollectableReward())`
    function getRewardPoolShortfall() external view returns (uint256 shortfall) {
        uint256 required = getRewardRequiredForTargets();
        uint256 reserved = totalDataList[Types.DataType.REWARD_EXPECTED];
        uint256 pool = rewardPool;
        uint256 deficit = reserved > pool ? reserved - pool : 0;
        uint256 collectable = pool > reserved ? pool - reserved : 0;
        uint256 needed = required + deficit;
        return needed > collectable ? needed - collectable : 0;
    }

    function checkTotalClaimableData() external view returns (uint256, uint256, uint256) {
        uint256 totalClaimableStaking;
        uint256 totalClaimablePeriodicalReward;
        uint256 totalClaimableIndefiniteReward;

        uint256 stakerCount = stakerAddressList.length;
        for (uint256 stakerNo = 0; stakerNo < stakerCount;) {
            address userAddress = stakerAddressList[stakerNo];
            (uint256 claimableStaking, uint256 claimablePeriodicalReward, uint256 claimableIndefiniteReward) =
                checkClaimableDataFor(userAddress);

            totalClaimableStaking += claimableStaking;
            totalClaimablePeriodicalReward += claimablePeriodicalReward;
            totalClaimableIndefiniteReward += claimableIndefiniteReward;
            unchecked {
                ++stakerNo;
            }
        }

        return (totalClaimableStaking, totalClaimablePeriodicalReward, totalClaimableIndefiniteReward);
    }

    // ======================================
    // =             User Data             =
    // ======================================
    function checkDepositCountOfAddress(address userAddress) public view returns (uint256) {
        return stakerDepositList[userAddress].length;
    }

    /// @notice Whether a voucher nonce has been used by `wallet`.
    function isVoucherNonceUsed(address wallet, uint256 nonce) external view returns (bool) {
        return (voucherNonceBitmap[wallet][nonce >> 8] & (1 << (nonce & 0xff))) != 0;
    }

    /// @notice Get a deposit. For INDEFINITE deposits `rewardGenerated` is the currently claimable reward.
    ///         `APY` is the deposit's effective APY in bps.
    /// @dev Reverts DepositDoesNotExist instead of panicking on an out-of-range index.
    function getDeposit(address userAddress, uint256 depositNumber) public view returns (TokenDeposit memory) {
        DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
        PackedDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
        TokenDeposit memory depositView = _toView(targetDeposit);
        if (depositStatus == DepositStatus.INDEFINITE) {
            depositView.rewardGenerated = _calculateIndefiniteDepositReward(targetDeposit);
        }
        return depositView;
    }

    /// @notice Get deposits [fromIndex, toIndex) of a user.
    /// @dev Reverts InvalidRange when fromIndex > toIndex or toIndex exceeds the deposit count.
    function getDepositsInRangeBy(address userAddress, uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (TokenDeposit[] memory)
    {
        if (fromIndex > toIndex || toIndex > stakerDepositList[userAddress].length) {
            revert InvalidRange(fromIndex, toIndex);
        }
        TokenDeposit[] memory userDepositsInRange = new TokenDeposit[](toIndex - fromIndex);

        for (uint256 i = fromIndex; i < toIndex;) {
            userDepositsInRange[i - fromIndex] = getDeposit(userAddress, i);
            unchecked {
                ++i;
            }
        }

        return userDepositsInRange;
    }

    function getUserData(Types.DataType dataType, address userAddress) external view returns (uint256) {
        return userDataList[dataType][userAddress];
    }

    /// @notice Stake a user holds in (stakingPhase, stakingPeriod). Only STAKING is tracked per phase/period;
    ///         any other data type reverts InvalidDataType. Unknown phases/periods read 0.
    function getUserPhasePeriodData(
        Types.DataType dataType,
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod
    ) public view returns (uint256) {
        if (dataType != Types.DataType.STAKING) revert InvalidDataType();
        return userPhasePeriodStaked[stakingPhase][stakingPeriod][userAddress];
    }

    /// @notice Batch get user phase period data for multiple combinations (STAKING only)
    /// @param dataType The data type; must be STAKING
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
        if (dataType != Types.DataType.STAKING) revert InvalidDataType();
        uint256 len = userAddresses.length;
        if (len != stakingPhases.length || len != stakingPeriods.length) {
            revert LengthMismatch(len, stakingPhases.length != len ? stakingPhases.length : stakingPeriods.length);
        }

        values = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            values[i] = userPhasePeriodStaked[stakingPhases[i]][stakingPeriods[i]][userAddresses[i]];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice What claimAll would pay the user right now, ignoring pool shortfalls. Frozen deposits are skipped.
    function checkClaimableDataFor(address userAddress) public view returns (uint256, uint256, uint256) {
        uint256 claimableStaking;
        uint256 claimablePeriodicalReward;
        uint256 claimableIndefiniteReward;

        PackedDeposit[] storage deposits = stakerDepositList[userAddress];
        uint256 userDepositCount = deposits.length;
        for (uint256 depositNumber = stakerActiveDepositStartIndex[userAddress]; depositNumber < userDepositCount;) {
            PackedDeposit storage targetDeposit = deposits[depositNumber];

            if ((targetDeposit.flags & FLAG_FROZEN) == 0) {
                DepositStatus depositStatus = _status(targetDeposit);
                if (depositStatus == DepositStatus.READY_TO_CLAIM) {
                    claimableStaking += targetDeposit.amount;
                    claimablePeriodicalReward += targetDeposit.rewardGenerated;
                } else if (depositStatus == DepositStatus.INDEFINITE) {
                    claimableIndefiniteReward += _calculateIndefiniteDepositReward(targetDeposit);
                }
            }
            unchecked {
                ++depositNumber;
            }
        }

        return (claimableStaking, claimablePeriodicalReward, claimableIndefiniteReward);
    }

    // ======================================
    // =           Other functions          =
    // ======================================
    /// @notice Reward for `depositAmount` at `apyBps` (10_000 = 100%) over `stakingPeriodDays` days.
    /// @dev One division at the end (single truncation); mulDiv is 512-bit so amount x rate cannot overflow.
    ///      Example: calculateReward(1000e18, 225, 365) == 22.5e18.
    function calculateReward(uint256 depositAmount, uint256 apyBps, uint256 stakingPeriodDays)
        public
        pure
        returns (uint256)
    {
        return Math.mulDiv(depositAmount, apyBps * stakingPeriodDays, BPS_DENOMINATOR * DAYS_PER_YEAR);
    }

    /// @dev Saturating: if the accrued total is smaller than what was already paid (rewardGenerated), the
    ///      claimable reward is 0 rather than an underflow that locks the deposit.
    function _calculateIndefiniteDepositReward(PackedDeposit memory targetDeposit) internal view returns (uint256) {
        uint256 daysPassed = (block.timestamp - targetDeposit.stakingStartDate) / 1 days;
        uint256 accrued = calculateReward(targetDeposit.amount, targetDeposit.apyBps, daysPassed);
        return accrued > targetDeposit.rewardGenerated ? accrued - targetDeposit.rewardGenerated : 0;
    }
}
