// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./AuxiliaryLibraries.sol";

contract ProgramManager {
    // ======================================
    // =          State Variables           =
    // ======================================
    using ArrayLibrary for uint256[];

    /**
     *   - Each user can make infinite amount of deposits
     *   - A user's data for each deposit is kept seperately in stakerDepositList[userAddress]
     */
    struct TokenDeposit {
        uint256 stakingPhase;
        uint256 stakingPeriod;
        uint256 stakingStartDate;
        uint256 stakingEndDate;
        uint256 claimOrWithdrawalDate;
        uint256 amount;
        uint256 APY;
        uint256 rewardGenerated;
    }

    enum DepositStatus {
        WITHDRAWN,
        CLAIMED,
        TIME_LEFT,
        READY_TO_CLAIM,
        INDEFINITE
    }

    enum DataType {
        STAKING_TARGET,
        APY,
        STAKED,
        PERIODICAL_STAKED,
        PERIODICAL_WITHDRAWN,
        PERIODICAL_STAKING_CLAIMED,
        PERIODICAL_REWARD_EXPECTED,
        PERIODICAL_REWARD_CLAIMED,
        INDEFINITE_STAKED,
        INDEFINITE_WITHDRAWN,
        INDEFINITE_REWARD_CLAIMED,
        FUNDS_COLLECTED,
        FUNDS_RESTORED
    }


    IERC20Metadata public immutable STAKING_TOKEN;
    uint256 internal constant FIXED_POINT_PRECISION = 10 ** 18;

    uint256 public minimumDeposit;
    // Program token balance for paying rewards
    uint256 public rewardPool;
    
    bool public isStakingOpen;
    bool public isWithdrawalOpen;
    bool public isClaimOpen;

    uint256 currentStakingPhase;
    uint256 stakingPhaseCount;
    // Staking periods are in days
    uint256[] stakingPeriodList;
    address[] stakerAddressList;
    
    // The list of users who donated/provided tokens to the rewardPool
    mapping(address => uint256) internal rewardProviderList;
    mapping(address => TokenDeposit[]) stakerDepositList;
    mapping(address => uint256) stakerActiveDepositStartIndex;
    mapping(DataType => mapping(uint256 => mapping(uint256 => uint256))) phasePeriodDataList;
    mapping(DataType => mapping(address => uint256)) userDataList;
    mapping(DataType => uint256) totalDataList;


    /**
     * @dev
     *     - Exception raised when 0 is provided as pool minimum deposit
     *     - Exception raised when 0 is provided as APY
     *
     */
    error InvalidArgumentValue(string argument, uint256 minValue);
    /// @dev Exception raised if an array has a repetitve element
    error ArrayHasRepetitiveElement(string arrayName);
    /// @dev Exception raised if the length of an array does not match the expected length
    error ArrayLengthDoesntMatch(string arrayName, uint256 expectedLength);
    
    constructor(
        IERC20Metadata _stakingToken,
        uint256 _stakingPhaseCount,
        uint256[] memory stakingPeriods,
        uint256[][] memory phasePeriodAPYs,
        uint256[][] memory phasePeriodStakingTargets
        ) {
        if (stakingPeriods.hasRepetitions()) revert ArrayHasRepetitiveElement("stakingPeriods");
        if (phasePeriodAPYs.length != _stakingPhaseCount) revert ArrayLengthDoesntMatch("phasePeriodAPYs", _stakingPhaseCount);
        if (phasePeriodStakingTargets.length != _stakingPhaseCount) revert ArrayLengthDoesntMatch("phasePeriodStakingTargets", _stakingPhaseCount);

        stakingPeriods.sortMemory();

        for (uint256 phase = 0; phase < _stakingPhaseCount; phase++) {
            if (phasePeriodAPYs[phase].length != stakingPeriods.length) revert ArrayLengthDoesntMatch(string.concat("phasePeriodAPYs[",Strings.toString(phase),"]"), stakingPeriods.length);
            if (phasePeriodStakingTargets[phase].length != stakingPeriods.length) revert ArrayLengthDoesntMatch(string.concat("phasePeriodStakingTargets[",Strings.toString(phase),"]"), stakingPeriods.length);

            for (uint256 period = 0; period < stakingPeriods.length; period++) {
                if (phasePeriodAPYs[phase][period] == 0) revert InvalidArgumentValue("APY", 1);
                phasePeriodDataList[DataType.APY][phase][stakingPeriods[period]] = phasePeriodAPYs[phase][period];
                phasePeriodDataList[DataType.STAKING_TARGET][phase][stakingPeriods[period]] = phasePeriodStakingTargets[phase][period];
            }
        }

        STAKING_TOKEN = _stakingToken;
        minimumDeposit = 1;

        isStakingOpen = true;
        isWithdrawalOpen = true;
        isClaimOpen = true;

        stakingPhaseCount = _stakingPhaseCount;
        stakingPeriodList = stakingPeriods;
    }
}
