// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../common/Errors.sol";
import "../interfaces/IPeriodicalStakingContract.sol";
import "../interfaces/IStakingContract.sol";

/// @title RequirementChecker
/// @notice Aggregates a user's worth from several staking contracts, ERC20 balance, and ERC1155 NFTs.
contract RequirementChecker is Ownable, Errors {
    event DefaultRequiredWorthUpdated(uint256 newDefaultRequiredWorth);
    event RequiredWorthPhasePeriodSet(uint256 indexed phase, uint256 indexed period, uint256 requiredWorth);
    event StakingContractsUpdated(address[] newContracts);
    event PeriodicalStakingContractsUpdated(address[] newContracts);
    event ERC1155ConfigUpdated(address indexed token, uint256[] ids, uint256[] worths);
    event ERC1155ContractRemoved(address indexed token);

    uint256 public defaultRequiredWorth;

    /// @notice Mapping: phase => period => required worth amount
    mapping(uint256 phase => mapping(uint256 period => uint256 requiredWorth)) public requiredWorthPhasePeriod;

    IERC20 public immutable worthToken;

    // Staking contracts with pool-based staking that expose checkStakedAmountBy
    address[] public stakingContracts;
    // Periodical staking contracts that expose userDataList
    address[] public periodicalStakingContracts;

    // ERC1155 contracts and worth per token id
    address[] public erc1155Contracts;
    mapping(address contractAddress => mapping(uint256 nftId => uint256 worth)) public erc1155IdWorth;
    mapping(address => uint256[]) public erc1155TrackedIds;

    /// @param _worthToken ERC20 token used to measure worth
    /// @param _stakingContracts List of pool-based staking contracts
    /// @param _periodicalStakingContracts List of periodical staking contracts
    /// @param _defaultRequiredWorth Minimum worth required to pass the check
    constructor(
        address _worthToken,
        address[] memory _stakingContracts,
        address[] memory _periodicalStakingContracts,
        uint256 _defaultRequiredWorth
    ) Ownable(msg.sender) {
        if (_worthToken == address(0)) revert ZeroAddressProvided();

        worthToken = IERC20(_worthToken);
        _setStakingContracts(_stakingContracts);
        _setPeriodicalStakingContracts(_periodicalStakingContracts);
        defaultRequiredWorth = _defaultRequiredWorth;
    }

    // ======================================
    // =       Administrative Functions     =
    // ======================================
    function setDefaultRequiredWorth(uint256 newDefaultRequiredWorth) external onlyOwner {
        defaultRequiredWorth = newDefaultRequiredWorth;
        emit DefaultRequiredWorthUpdated(newDefaultRequiredWorth);
    }

    /// @notice Set required worth for a specific phase period
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param newRequiredWorth The required worth amount (0 means no requirement for this phase/period)
    function setRequiredWorthPhasePeriod(uint256 phase, uint256 period, uint256 newRequiredWorth) external onlyOwner {
        _setRequiredWorthPhasePeriod(phase, period, newRequiredWorth);
    }

    /// @notice Batch set required worth for multiple phase/period combinations
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @param requiredWorths Array of required worth amounts corresponding to each phase/period combination
    function setRequiredWorthPhasePeriodBatch(
        uint256[] calldata phases,
        uint256[] calldata periods,
        uint256[] calldata requiredWorths
    ) external onlyOwner {
        if (phases.length != periods.length || phases.length != requiredWorths.length) {
            revert LengthMismatch(
                phases.length, periods.length != phases.length ? periods.length : requiredWorths.length
            );
        }
        for (uint256 i = 0; i < phases.length; i++) {
            _setRequiredWorthPhasePeriod(phases[i], periods[i], requiredWorths[i]);
        }
    }

    function setStakingContracts(address[] calldata newContracts) external onlyOwner {
        _setStakingContracts(newContracts);
    }

    function setPeriodicalStakingContracts(address[] calldata newContracts) external onlyOwner {
        _setPeriodicalStakingContracts(newContracts);
    }

    function setERC1155Configs(address token, uint256[] calldata ids, uint256[] calldata worths) external onlyOwner {
        if (token == address(0)) revert ZeroAddressProvided();
        if (ids.length == 0) revert EmptyIdsArray();
        if (ids.length != worths.length) revert LengthMismatch(ids.length, worths.length);
        if (erc1155TrackedIds[token].length == 0) {
            erc1155Contracts.push(token);
        }
        erc1155TrackedIds[token] = ids;
        for (uint256 i = 0; i < ids.length; i++) {
            erc1155IdWorth[token][ids[i]] = worths[i];
        }
        emit ERC1155ConfigUpdated(token, ids, worths);
    }

    function removeERC1155Contract(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddressProvided();

        // Find the token in the array
        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < erc1155Contracts.length; i++) {
            if (erc1155Contracts[i] == token) {
                index = i;
                break;
            }
        }

        if (index == type(uint256).max) revert ERC1155ContractNotFound(token);

        // Clean up worth mappings for all tracked IDs
        uint256[] memory trackedIds = erc1155TrackedIds[token];
        for (uint256 i = 0; i < trackedIds.length; i++) {
            delete erc1155IdWorth[token][trackedIds[i]];
        }

        // Clean up tracked IDs
        delete erc1155TrackedIds[token];

        // Remove from array by swapping with last element and popping
        erc1155Contracts[index] = erc1155Contracts[erc1155Contracts.length - 1];
        erc1155Contracts.pop();

        emit ERC1155ContractRemoved(token);
    }

    // ======================================
    // =         Public Functions           =
    // ======================================
    function stakingContractCount() external view returns (uint256) {
        return stakingContracts.length;
    }

    function periodicalStakingContractCount() external view returns (uint256) {
        return periodicalStakingContracts.length;
    }

    function erc1155ContractCount() external view returns (uint256) {
        return erc1155Contracts.length;
    }

    function meetsDefaultRequirement(address user) public view returns (bool) {
        return getTotalWorth(user) >= defaultRequiredWorth;
    }

    /// @notice Returns whether a user meets the worth requirement for a phase period
    /// @param user The user address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return Whether the user meets the requirement
    function meetsRequirement(address user, uint256 phase, uint256 period) public view returns (bool) {
        uint256 required = getRequiredWorth(phase, period);
        if (required == 0) {
            // No requirement for this phase/period, always return true
            return true;
        }
        return getTotalWorth(user) >= required;
    }

    /// @notice Batch check whether multiple (user, phase, period) combinations meet the worth requirement
    /// @param users Array of user addresses
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return results Array of booleans indicating whether each combination meets the requirement
    function meetsRequirementBatch(address[] calldata users, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (bool[] memory results)
    {
        uint256 len = users.length;
        if (len != phases.length || len != periods.length) {
            revert LengthMismatch(len, phases.length != len ? phases.length : periods.length);
        }

        results = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            results[i] = meetsRequirement(users[i], phases[i], periods[i]);
        }
    }

    /// @notice Returns the aggregated worth of a user across all tracked sources for a phase period
    /// @param user The user address
    /// @return The total worth
    function getTotalWorth(address user) public view returns (uint256) {
        (uint256 erc20Balance, uint256 stakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth) =
            worthBreakdown(user);
        return erc20Balance + stakingWorth + periodicalStakingWorth + nftWorth;
    }

    /// @notice Get the required worth for a phase period
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return The required worth amount
    /// @dev Returns the phase/period specific requirement if set (non-zero), otherwise returns the default requiredWorth
    function getRequiredWorth(uint256 phase, uint256 period) public view returns (uint256) {
        uint256 phasePeriodRequired = requiredWorthPhasePeriod[phase][period];
        if (phasePeriodRequired != 0) {
            // Phase/period specific requirement is set, use it
            return phasePeriodRequired;
        } else {
            // Phase/period specific requirement not set (0), use default
            return defaultRequiredWorth;
        }
    }

    /// @notice Batch get required worth for multiple phase/period combinations
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return requiredWorths Array of required worth amounts corresponding to each phase/period combination
    function getRequiredWorthBatch(uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory requiredWorths)
    {
        uint256 len = phases.length;
        if (len != periods.length) revert LengthMismatch(len, periods.length);

        requiredWorths = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            requiredWorths[i] = getRequiredWorth(phases[i], periods[i]);
        }
    }

    /// @notice Returns a breakdown of the user's worth across sources
    function worthBreakdown(address user)
        public
        view
        returns (uint256 erc20Balance, uint256 stakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth)
    {
        stakingWorth = totalStaked(user);
        periodicalStakingWorth = totalPeriodicalStaked(user);
        erc20Balance = worthToken.balanceOf(user);
        nftWorth = totalERC1155Worth(user);
    }

    function totalStaked(address user) public view returns (uint256 total) {
        uint256 contractsLength = stakingContracts.length;
        for (uint256 i = 0; i < contractsLength; i++) {
            IStakingContract staking = IStakingContract(stakingContracts[i]);
            uint256 poolCount = staking.checkPoolCount();
            for (uint256 poolId = 0; poolId < poolCount; poolId++) {
                total += staking.checkStakedAmountBy(user, poolId);
            }
        }
    }

    function totalPeriodicalStaked(address user) public view returns (uint256 total) {
        uint256 contractsLength = periodicalStakingContracts.length;
        uint8 dataTypeStaking = 0; // DataType.STAKING constant (0)
        for (uint256 i = 0; i < contractsLength; i++) {
            IPeriodicalStakingContract staking = IPeriodicalStakingContract(periodicalStakingContracts[i]);
            total += staking.userDataList(dataTypeStaking, user);
        }
    }

    function totalERC1155Worth(address user) public view returns (uint256 total) {
        uint256 len = erc1155Contracts.length;
        for (uint256 i = 0; i < len; i++) {
            address token = erc1155Contracts[i];
            uint256[] memory ids = erc1155TrackedIds[token];
            uint256 idsLen = ids.length;
            if (idsLen == 0) continue;

            address[] memory owners = new address[](idsLen);
            for (uint256 j = 0; j < idsLen; j++) {
                owners[j] = user;
            }

            uint256[] memory balances = IERC1155(token).balanceOfBatch(owners, ids);
            for (uint256 j = 0; j < idsLen; j++) {
                total += balances[j] * erc1155IdWorth[token][ids[j]];
            }
        }
    }

    // ======================================
    // =         Internal Functions         =
    // ======================================
    function _setRequiredWorthPhasePeriod(uint256 phase, uint256 period, uint256 requiredWorth) private {
        requiredWorthPhasePeriod[phase][period] = requiredWorth;
        emit RequiredWorthPhasePeriodSet(phase, period, requiredWorth);
    }

    /// @dev Internal helper to validate and set staking contracts array
    function _setStakingContracts(address[] memory newContracts) private {
        for (uint256 i = 0; i < newContracts.length; i++) {
            if (newContracts[i] == address(0)) revert ZeroAddressProvided();
        }
        stakingContracts = newContracts;
        emit StakingContractsUpdated(newContracts);
    }

    /// @dev Internal helper to validate and set periodical staking contracts array
    function _setPeriodicalStakingContracts(address[] memory newContracts) private {
        for (uint256 i = 0; i < newContracts.length; i++) {
            if (newContracts[i] == address(0)) revert ZeroAddressProvided();
        }
        periodicalStakingContracts = newContracts;
        emit PeriodicalStakingContractsUpdated(newContracts);
    }
}
