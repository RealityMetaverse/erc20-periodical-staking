// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPeriodicalStakingContract.sol";
import "../interfaces/ILimitController.sol";
import "../common/Errors.sol";

/// @title Limit Controller
/// @notice Controls how much a wallet is allowed to stake in a phase period
/// @notice Reads staked amounts directly from the staking contract
/// @dev Limits are concurrent, not lifetime: they are compared against the amount currently staked in the
///      cell (`userPhasePeriodDataList[STAKING]`), which shrinks when deposits are withdrawn or claimed.
///      A wallet-specific limit, once set, is authoritative even when it is 0 ("no staking allowed");
///      use clearWalletLimit to fall back to the phase/period default again.
/// @author Heydar Badirli
contract LimitController is ILimitController, Ownable, Errors {
    // ======================================
    // =          State Variables           =
    // ======================================

    /// @notice The staking contract to query for staked amounts
    IPeriodicalStakingContract public stakingContract;

    /// @notice Mapping: wallet => phase => period => limit amount (only meaningful when hasWalletLimit is true)
    mapping(address walletAddress => mapping(uint256 phase => mapping(uint256 period => uint256 limit))) public
        walletPhasePeriodLimit;

    /// @notice Mapping: wallet => phase => period => whether a wallet-specific limit is set
    /// @dev Distinguishes an explicit limit of 0 (blocked) from "not set" (use the default).
    mapping(address walletAddress => mapping(uint256 phase => mapping(uint256 period => bool isSet))) public
        hasWalletLimit;

    /// @notice Mapping: phase => period => default limit amount
    mapping(uint256 phase => mapping(uint256 period => uint256 limit)) public defaultPhasePeriodLimit;

    /// @notice DataType.STAKING constant (0)
    uint8 private constant DATA_TYPE_STAKING = 0;

    // ======================================
    // =              Events                =
    // ======================================
    event StakingContractSet(address indexed stakingContract);
    event WalletLimitSet(address indexed wallet, uint256 phase, uint256 period, uint256 limit);
    event WalletLimitCleared(address indexed wallet, uint256 phase, uint256 period);
    event DefaultLimitSet(uint256 indexed phase, uint256 indexed period, uint256 limit);

    // ======================================
    // =         Constructor                =
    // ======================================
    /// @param _stakingContract The address of the ERC20PeriodicalStaking contract
    constructor(address _stakingContract) Ownable(msg.sender) {
        if (_stakingContract == address(0)) revert ZeroAddressProvided();
        stakingContract = IPeriodicalStakingContract(_stakingContract);
        emit StakingContractSet(_stakingContract);
    }

    // ======================================
    // =       Administrative Functions     =
    // ======================================
    /// @notice Set the staking contract address
    /// @param _stakingContract The address of the ERC20PeriodicalStaking contract
    function setStakingContract(address _stakingContract) external onlyOwner {
        if (_stakingContract == address(0)) revert ZeroAddressProvided();
        stakingContract = IPeriodicalStakingContract(_stakingContract);
        emit StakingContractSet(_stakingContract);
    }

    /// @notice Set staking limit for a specific wallet in a phase period
    /// @dev Marks the wallet limit as set, so a limit of 0 blocks the wallet instead of falling back to the
    ///      default. Use clearWalletLimit to restore the default.
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param limit The maximum amount the wallet can stake (0 means no staking allowed)
    function setWalletLimit(address wallet, uint256 phase, uint256 period, uint256 limit) external onlyOwner {
        _setWalletLimit(wallet, phase, period, limit);
    }

    /// @notice Batch set staking limits for multiple wallets
    /// @param wallets Array of wallet addresses
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param limits Array of limits corresponding to each wallet (0 means no staking allowed)
    function setWalletLimits(address[] calldata wallets, uint256 phase, uint256 period, uint256[] calldata limits)
        external
        onlyOwner
    {
        if (wallets.length != limits.length) revert LengthMismatch(wallets.length, limits.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            _setWalletLimit(wallets[i], phase, period, limits[i]);
        }
    }

    /// @notice Remove a wallet-specific limit so the wallet falls back to the phase/period default
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    function clearWalletLimit(address wallet, uint256 phase, uint256 period) external onlyOwner {
        _clearWalletLimit(wallet, phase, period);
    }

    /// @notice Batch remove wallet-specific limits for multiple wallets in a phase period
    /// @param wallets Array of wallet addresses
    /// @param phase The staking phase
    /// @param period The staking period
    function clearWalletLimits(address[] calldata wallets, uint256 phase, uint256 period) external onlyOwner {
        for (uint256 i = 0; i < wallets.length; i++) {
            _clearWalletLimit(wallets[i], phase, period);
        }
    }

    /// @notice Set default staking limit for a phase period
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param limit The default maximum amount wallets can stake (0 means no staking allowed by default)
    function setDefaultLimit(uint256 phase, uint256 period, uint256 limit) external onlyOwner {
        defaultPhasePeriodLimit[phase][period] = limit;
        emit DefaultLimitSet(phase, period, limit);
    }

    /// @notice Batch set default staking limits for multiple phase/period combinations
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @param limits Array of default limits corresponding to each phase/period combination
    function setDefaultLimits(uint256[] calldata phases, uint256[] calldata periods, uint256[] calldata limits)
        external
        onlyOwner
    {
        if (phases.length != periods.length || phases.length != limits.length) {
            revert LengthMismatch(phases.length, periods.length != phases.length ? periods.length : limits.length);
        }
        for (uint256 i = 0; i < phases.length; i++) {
            defaultPhasePeriodLimit[phases[i]][periods[i]] = limits[i];
            emit DefaultLimitSet(phases[i], periods[i], limits[i]);
        }
    }

    function _setWalletLimit(address wallet, uint256 phase, uint256 period, uint256 limit) private {
        if (wallet == address(0)) revert ZeroAddressProvided();
        walletPhasePeriodLimit[wallet][phase][period] = limit;
        hasWalletLimit[wallet][phase][period] = true;
        emit WalletLimitSet(wallet, phase, period, limit);
    }

    function _clearWalletLimit(address wallet, uint256 phase, uint256 period) private {
        if (wallet == address(0)) revert ZeroAddressProvided();
        delete walletPhasePeriodLimit[wallet][phase][period];
        delete hasWalletLimit[wallet][phase][period];
        emit WalletLimitCleared(wallet, phase, period);
    }

    // ======================================
    // =         Public Functions           =
    // ======================================

    /// @notice Get the maximum allowed stake for a wallet in a phase period
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return allowed The maximum amount the wallet can stake
    /// @dev Returns the wallet-specific limit when one is set (hasWalletLimit, even if it is 0), otherwise the
    ///      default limit for the phase/period
    function getAllowed(address wallet, uint256 phase, uint256 period) external view returns (uint256 allowed) {
        return _getAllowed(wallet, phase, period);
    }

    /// @notice Get the remaining allowed stake for a wallet in a phase period
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return remaining The remaining amount the wallet can stake
    /// @dev Reads the actual staked amount from the staking contract
    function getRemaining(address wallet, uint256 phase, uint256 period) external view returns (uint256 remaining) {
        uint256 allowed = _getAllowed(wallet, phase, period);

        // Read the actual staked amount from the staking contract
        uint256 staked = stakingContract.getUserPhasePeriodData(DATA_TYPE_STAKING, wallet, phase, period);

        remaining = staked >= allowed ? 0 : allowed - staked;
    }

    /// @notice Batch get remaining allowed stakes for multiple wallet/phase/period combinations
    /// @param wallets Array of wallet addresses
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return remainings Array of remaining amounts each wallet can stake
    /// @dev More gas efficient than calling getRemaining multiple times
    function getRemainingBatch(address[] calldata wallets, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory remainings)
    {
        uint256 len = wallets.length;
        if (len != phases.length || len != periods.length) {
            revert LengthMismatch(len, phases.length != len ? phases.length : periods.length);
        }

        remainings = new uint256[](len);

        // Batch fetch all staked amounts in one call
        uint256[] memory stakedAmounts =
            stakingContract.getUserPhasePeriodDataBatch(DATA_TYPE_STAKING, wallets, phases, periods);

        for (uint256 i = 0; i < len;) {
            uint256 allowed = _getAllowed(wallets[i], phases[i], periods[i]);
            uint256 staked = stakedAmounts[i];

            remainings[i] = staked >= allowed ? 0 : allowed - staked;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Batch get maximum allowed stakes for multiple wallet/phase/period combinations
    /// @param wallets Array of wallet addresses
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return allowed Array of maximum amounts each wallet can stake
    function getAllowedBatch(address[] calldata wallets, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory allowed)
    {
        uint256 len = wallets.length;
        if (len != phases.length || len != periods.length) {
            revert LengthMismatch(len, phases.length != len ? phases.length : periods.length);
        }

        allowed = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            allowed[i] = _getAllowed(wallets[i], phases[i], periods[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Single source of truth for the limit resolution order: explicit wallet limit, else default.
    function _getAllowed(address wallet, uint256 phase, uint256 period) private view returns (uint256) {
        if (hasWalletLimit[wallet][phase][period]) {
            return walletPhasePeriodLimit[wallet][phase][period];
        }
        return defaultPhasePeriodLimit[phase][period];
    }
}
