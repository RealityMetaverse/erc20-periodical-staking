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
    /// @notice Highest total extra limit (bonus budget) a voucher may carry, across all phases.
    uint128 public maxExtraLimitTotal;

    // Slot D
    /// @notice Highest per-cell extra limit a voucher may carry. Hard ceiling on blast radius in any one cell.
    /// @dev Slot C (minimumDeposit + maxExtraLimitTotal) is already full, and every other slot is packed deliberately,
    ///      so this takes a fresh slot rather than disturbing an existing one. This is a new deployment, not an
    ///      upgrade, so there is no layout to preserve. maxVoucherValidity shares this slot; see its note below
    ///      for the running byte count.
    uint128 public maxExtraLimitPerCell;
    /// @notice Furthest ahead of now a voucher's `validUntil` may sit, in seconds. Never 0: the constructor
    ///         defaults it to 1800 and the setter rejects 0, so this protection cannot be switched off.
    /// @dev Shares slot D with maxExtraLimitPerCell: 16 + 4 = 20 of 32 bytes used, 12 still free. uint32 of
    ///      seconds is ~136 years, far beyond any sane voucher lifetime.
    uint32 public maxVoucherValidity;

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

    /// @notice Wallets barred from opening NEW stakes. Does not touch existing deposits.
    /// @dev A block stops staking ONLY. Withdraw, claim, and every other exit stay open to a blocked wallet --
    ///      a block must never trap funds. Do not "tighten" this into a lock.
    ///      This exists because it is the only lever that still works when the voucher SIGNING KEY is
    ///      compromised: the attacker signs their own vouchers, so the backend's issuance blocklist is useless,
    ///      and the limit controller cannot tell the attacker's stake from a legitimate one.
    mapping(address wallet => bool) public walletBlocked;

    // ======================================
    // =        Voucher Bonus Metering      =
    // ======================================
    /// @dev Bonus consumed by a wallet, i.e. how much of the voucher's `extraLimitTotal` it currently holds
    ///      open. ONE budget for the wallet across EVERY phase: advancing the phase does not refill it.
    ///      CONCURRENT, not lifetime: closing a deposit returns its bonus here, exactly as the LimitController's
    ///      own limits free up when stake leaves. So a wallet can spend its 50,000 many times over the life of
    ///      the program, but never hold more than 50,000 of bonus open at once.
    mapping(address wallet => uint256) internal walletBonusUsed;
    /// @dev Bonus consumed by a wallet within one CELL, against `extraLimitPerCell`. A cell is (phase, period):
    ///      the same period in a different phase is a different cell with its own cap, exactly as the
    ///      LimitController keys `allowed` and `used`.
    ///      The asymmetry with walletBonusUsed -- total global, cell per (phase, period) -- is the product
    ///      model, not an oversight. It also makes this the right number to subtract from the controller's
    ///      `used`, which describes the same cell. Do not re-scope one without the other: a meter keyed more
    ///      widely than `used` floors that subtraction at 0 while the cell already holds base stake, and hands
    ///      the wallet its whole base allowance again at every phase change.
    mapping(uint256 phase => mapping(uint256 period => mapping(address wallet => uint256))) internal
        walletBonusUsedInCell;
    /// @dev Bonus attributable to one deposit, so closing it releases exactly what it consumed.
    mapping(address wallet => mapping(uint256 depositNumber => uint256)) internal depositBonusUsed;

    constructor(IERC20Metadata tokenAddress) {
        if (address(tokenAddress) == address(0)) revert ZeroAddressProvided();
        STAKING_TOKEN = tokenAddress;
        minimumDeposit = 100;
        // Never leave this at 0: setMaxVoucherValidity rejects 0 because it makes every stake revert, so the
        // contract must not be born in the one state its own setter forbids. 1800 is the maximum the backend's
        // own validity_seconds can be configured to (bounded 60-1800 in staking_voucher/constants.py), so this
        // default can never reject a voucher the backend is able to sign, and never allows a window wider than
        // the backend's own ceiling. The deploy script still requires MAX_VOUCHER_VALIDITY explicitly and
        // asserts it afterwards. This is a safety net for a deployment made outside that script -- a fork test,
        // a local anvil run, a hand deploy -- NOT the operational value. Ops sets that.
        maxVoucherValidity = 1800;

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
