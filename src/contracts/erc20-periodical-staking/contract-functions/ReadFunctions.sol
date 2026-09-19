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

    function getTotalData(Types.DataType dataType) external view returns (uint256) {
        return totalDataList[dataType];
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

    /// @notice How much of a wallet's voucher bonus budget is currently held open.
    /// @dev The two figures have DIFFERENT scopes, on purpose. `usedTotal` is global: one budget covers every
    ///      phase, so advancing the phase does not reset it. `usedInCell` is per (phase, period), so the same
    ///      period in a new phase starts at 0 with its own cap. Both are concurrent, not lifetime -- closing a
    ///      deposit lowers them again. Subtract them from the voucher's extraLimitTotal / extraLimitPerCell to
    ///      get what the wallet can still stake above its controller limit.
    /// @return usedTotal Bonus held open across every cell, against extraLimitTotal
    /// @return usedInCell Bonus held open in (`phase`, `period`), against extraLimitPerCell
    function getBonusUsage(address wallet, uint256 phase, uint256 period)
        external
        view
        returns (uint256 usedTotal, uint256 usedInCell)
    {
        return (walletBonusUsed[wallet], walletBonusUsedInCell[phase][period][wallet]);
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
