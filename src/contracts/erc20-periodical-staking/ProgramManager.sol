// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
     *   - TokenDeposit is the external view type (unchanged ABI); storage uses the 2-slot PackedDeposit
     */
    struct TokenDeposit {
        uint256 stakingPhase;
        uint256 stakingPeriod;
        uint256 stakingStartDate;
        uint256 stakingEndDate;
        uint256 withdrawalDate;
        uint256 amount;
        /// @dev Effective APY in bps (10_000 = 100%)
        uint256 APY;
        uint256 rewardGenerated;
    }

    struct PackedDeposit {
        // slot 0: everything the status and frozen checks need
        uint128 amount;
        uint40 stakingStartDate;
        uint40 stakingEndDate;
        uint40 withdrawalDate;
        uint8 flags; // FLAG_FROZEN | FLAG_SEIZED
        // slot 1
        uint128 rewardGenerated;
        uint32 stakingPhase;
        uint32 stakingPeriod;
        uint32 apyBps; // base + voucher extra, fixed for the deposit's life
    }

    enum DepositStatus {
        WITHDRAWN,
        CLAIMED,
        TIME_LEFT,
        READY_TO_CLAIM,
        INDEFINITE,
        SEIZED
    }

    IERC20Metadata public immutable STAKING_TOKEN;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant DAYS_PER_YEAR = 365;
    uint8 internal constant FLAG_FROZEN = 1;
    uint8 internal constant FLAG_SEIZED = 2;

    // Slot A (stake path)
    /// @notice Address whose signature authorises stake vouchers; address(0) disables staking.
    address public voucherSigner;
    /// @notice Highest extra APY (bps) a voucher may carry.
    uint32 public maxExtraApyBps;
    uint32 public currentStakingPhase;
    uint32 public stakingPhaseCount;

    // Slot B (stake/claim/withdraw path)
    /// @dev Required for staking; address(0) makes stakeWithVoucher revert LimitControllerNotSet.
    address public limitController;
    bool internal stakingOpen;
    bool internal withdrawalOpen;
    bool internal claimOpen;

    // Slot C
    uint128 public minimumDeposit;
    /// @notice Highest extra limit a voucher may carry.
    uint128 public maxExtraLimit;

    /// @notice Receiver of seized deposits.
    address public treasury;
    // Program token balance for paying rewards
    uint256 public rewardPool;
    // Staking periods are in days
    uint256[] public stakingPeriodList;
    address[] internal stakerAddressList;

    mapping(address => PackedDeposit[]) internal stakerDepositList;
    mapping(address => uint256) public stakerActiveDepositStartIndex;
    /// @dev APY cells hold bps (10_000 = 100%)
    mapping(Types.PhasePeriodDataType => mapping(uint256 phase => mapping(uint256 period => uint256))) public
        phasePeriodDataList;
    mapping(Types.DataType => mapping(address => uint256)) public userDataList;
    mapping(uint256 phase => mapping(uint256 period => mapping(address user => uint256))) internal
        userPhasePeriodStaked;
    mapping(Types.DataType => uint256) public totalDataList;
    mapping(address wallet => mapping(uint256 word => uint256 bitmap)) internal voucherNonceBitmap;

    constructor(IERC20Metadata tokenAddress) {
        if (address(tokenAddress) == address(0)) revert ZeroAddressProvided();
        STAKING_TOKEN = tokenAddress;
        minimumDeposit = 100;

        stakingOpen = true;
        withdrawalOpen = true;
        claimOpen = true;
    }

    /// @dev Widening copy of a stored deposit into the external view type.
    function _toView(PackedDeposit memory d) internal pure returns (TokenDeposit memory) {
        return TokenDeposit(
            d.stakingPhase,
            d.stakingPeriod,
            d.stakingStartDate,
            d.stakingEndDate,
            d.withdrawalDate,
            d.amount,
            d.apyBps,
            d.rewardGenerated
        );
    }
}
