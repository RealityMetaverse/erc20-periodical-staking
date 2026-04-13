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
/// @author Heydar Badirli
contract LimitController is ILimitController, Ownable, Errors {
    // ======================================
    // =          State Variables           =
    // ======================================

    /// @notice The staking contract to query for staked amounts
    IPeriodicalStakingContract public stakingContract;

    /// @notice Mapping: wallet => phase => period => limit amount
    mapping(address walletAddress => mapping(uint256 phase => mapping(uint256 period => uint256 limit))) public
        walletPhasePeriodLimit;

    /// @notice Mapping: phase => period => default limit amount
    mapping(uint256 phase => mapping(uint256 period => uint256 limit)) public defaultPhasePeriodLimit;

    /// @notice DataType.STAKING constant (0)
    uint8 private constant DATA_TYPE_STAKING = 0;

    // ======================================
    // =              Events                =
    // ======================================
    event StakingContractSet(address indexed stakingContract);
    event WalletLimitSet(address indexed wallet, uint256 phase, uint256 period, uint256 limit);
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
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param limit The maximum amount the wallet can stake (0 means no staking allowed)
    function setWalletLimit(address wallet, uint256 phase, uint256 period, uint256 limit) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddressProvided();
        walletPhasePeriodLimit[wallet][phase][period] = limit;
        emit WalletLimitSet(wallet, phase, period, limit);
    }

    /// @notice Batch set staking limits for multiple wallets
    /// @param wallets Array of wallet addresses
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param limits Array of limits corresponding to each wallet
    function setWalletLimits(address[] calldata wallets, uint256 phase, uint256 period, uint256[] calldata limits)
        external
        onlyOwner
    {
        if (wallets.length != limits.length) revert LengthMismatch(wallets.length, limits.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == address(0)) revert ZeroAddressProvided();
            walletPhasePeriodLimit[wallets[i]][phase][period] = limits[i];
            emit WalletLimitSet(wallets[i], phase, period, limits[i]);
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

    // ======================================
    // =         Public Functions           =
    // ======================================

    /// @notice Get the maximum allowed stake for a wallet in a phase period
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return allowed The maximum amount the wallet can stake
    /// @dev Returns the wallet-specific limit if set (non-zero), otherwise returns the default limit for the phase/period
    function getAllowed(address wallet, uint256 phase, uint256 period) external view returns (uint256 allowed) {
        uint256 walletLimit = walletPhasePeriodLimit[wallet][phase][period];
        if (walletLimit != 0) {
            // Wallet-specific limit is set, use it
            allowed = walletLimit;
        } else {
            // Wallet-specific limit not set (0), use default
            allowed = defaultPhasePeriodLimit[phase][period];
        }
    }

    /// @notice Get the remaining allowed stake for a wallet in a phase period
    /// @param wallet The wallet address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return remaining The remaining amount the wallet can stake
    /// @dev Reads the actual staked amount from the staking contract
    function getRemaining(address wallet, uint256 phase, uint256 period) external view returns (uint256 remaining) {
        uint256 allowed = this.getAllowed(wallet, phase, period);

        // Read the actual staked amount from the staking contract
        uint256 staked = stakingContract.getUserPhasePeriodData(DATA_TYPE_STAKING, wallet, phase, period);

        if (staked >= allowed) {
            remaining = 0;
        } else {
            remaining = allowed - staked;
        }
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
            uint256 walletLimit = walletPhasePeriodLimit[wallets[i]][phases[i]][periods[i]];
            uint256 allowed;
            if (walletLimit != 0) {
                // Wallet-specific limit is set, use it
                allowed = walletLimit;
            } else {
                // Wallet-specific limit not set (0), use default
                allowed = defaultPhasePeriodLimit[phases[i]][periods[i]];
            }
            uint256 staked = stakedAmounts[i];

            if (staked >= allowed) {
                remainings[i] = 0;
            } else {
                remainings[i] = allowed - staked;
            }

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
            uint256 walletLimit = walletPhasePeriodLimit[wallets[i]][phases[i]][periods[i]];
            if (walletLimit != 0) {
                allowed[i] = walletLimit;
            } else {
                allowed[i] = defaultPhasePeriodLimit[phases[i]][periods[i]];
            }

            unchecked {
                ++i;
            }
        }
    }
}
