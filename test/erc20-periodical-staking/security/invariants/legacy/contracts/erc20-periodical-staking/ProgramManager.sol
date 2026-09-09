// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./ArrayLibrary.sol";
import "../../common/Errors.sol";
import "../../common/Types.sol";

contract ProgramManager is Errors {
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

    IERC20Metadata public immutable STAKING_TOKEN;
    uint256 internal constant FIXED_POINT_PRECISION = 10 ** 18;

    uint256 public minimumDeposit;
    // Program token balance for paying rewards
    uint256 public rewardPool;

    // Whitelist control for staking
    bool public whitelistEnabled;
    mapping(address => bool) public isWhitelisted;

    /// @dev if set to address(0), staking limit is disabled
    address public limitController;

    /// @dev if set to address(0), requirement checker is disabled
    address public requirementChecker;

    uint256 public currentStakingPhase;
    uint256 public stakingPhaseCount;
    // Staking periods are in days
    uint256[] public stakingPeriodList;
    address[] internal stakerAddressList;

    mapping(address => TokenDeposit[]) internal stakerDepositList;
    mapping(address => uint256) public stakerActiveDepositStartIndex;
    mapping(Types.PhasePeriodDataType => mapping(uint256 phase => mapping(uint256 period => uint256))) public
        phasePeriodDataList;
    mapping(Types.DataType => mapping(address => uint256)) public userDataList;
    mapping(Types.DataType => mapping(uint256 phase => mapping(uint256 period => mapping(address user => uint256))))
        public userPhasePeriodDataList;
    mapping(Types.DataType => uint256) public totalDataList;
    mapping(Types.DataType => bool) internal actionAvailabilityStatuses;

    constructor(IERC20Metadata tokenAddress) {
        if (address(tokenAddress) == address(0)) revert ZeroAddressProvided();
        STAKING_TOKEN = tokenAddress;
        minimumDeposit = 100;

        actionAvailabilityStatuses[Types.DataType.STAKING] = true;
        actionAvailabilityStatuses[Types.DataType.WITHDRAWAL] = true;
        actionAvailabilityStatuses[Types.DataType.CLAIM] = true;
    }
}
