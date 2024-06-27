// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./ArrayLibrary.sol";

contract ProgramManager {
    // ======================================
    // =          State Variables           =
    // ======================================
    /**
     *   - Each user can make infinite amount of deposits
     *   - A user's data for each deposit is kept seperately in stakerDepositList[userAddress]
     */
    struct TokenDeposit {
        uint256 stakingPhase;
        uint256 stakingPeriod;
        uint256 stakingStartDate;
        uint256 stakingEndDate;
        uint256 withdrawalDate;
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
        STAKING,
        WITHDRAWAL,
        CLAIM,
        REWARD_EXPECTED,
        REWARD_PROVIDED,
        REWARD_COLLECTED
    }

    enum PhasePeriodDataType {
        STAKING_TARGET,
        APY,
        STAKED
    }

    IERC20Metadata public immutable STAKING_TOKEN;
    uint256 internal constant FIXED_POINT_PRECISION = 10 ** 18;

    uint256 public minimumDeposit;
    // Program token balance for paying rewards
    uint256 public rewardPool;

    uint256 public currentStakingPhase;
    uint256 public stakingPhaseCount;
    // Staking periods are in days
    uint256[] public stakingPeriodList;
    address[] internal stakerAddressList;

    mapping(address => TokenDeposit[]) internal stakerDepositList;
    mapping(address => uint256) public stakerActiveDepositStartIndex;
    mapping(PhasePeriodDataType => mapping(uint256 => mapping(uint256 => uint256))) public phasePeriodDataList;
    mapping(DataType => mapping(address => uint256)) public userDataList;
    mapping(DataType => uint256) public totalDataList;
    mapping(DataType => bool) internal actionAvailabilityStatuses;

    constructor(IERC20Metadata tokenAddress) {
        STAKING_TOKEN = tokenAddress;
        minimumDeposit = 100;

        actionAvailabilityStatuses[DataType.STAKING] = true;
        actionAvailabilityStatuses[DataType.WITHDRAWAL] = true;
        actionAvailabilityStatuses[DataType.CLAIM] = true;
    }
}
