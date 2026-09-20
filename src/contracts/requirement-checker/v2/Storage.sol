// SPDX-License-Identifier: BUSL-1.1
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../common/Errors.sol";

/// @dev Ownership is two-step (Ownable2Step): transferOwnership only nominates a pending owner, who must then
///      call acceptOwnership. renounceOwnership is disabled (see AdministrativeFunctions).
abstract contract Storage is Ownable2Step, Errors {
    // DuplicateAddress, DuplicateId, OffsetOutOfBounds and RenounceOwnershipDisabled live in
    // src/common/Errors.sol with every other error, so one ABI built from that file decodes them all.

    /// @notice Largest magnitude accepted for any admin offset. Far above any real token amount or NFT count,
    ///         yet small enough that `balance + offset` cannot overflow for any realistic balance.
    int256 public constant MAX_ABS_OFFSET = int256(type(int128).max);

    event DefaultRequiredWorthUpdated(uint256 newDefaultRequiredWorth);
    event RequiredPhasePeriodWorthSet(uint256 indexed phase, uint256 indexed period, uint256 requiredWorth);
    event PoolStakingContractsUpdated(address[] newContracts);
    event PeriodicalStakingContractsUpdated(address[] newContracts);
    event ERC1155ConfigUpdated(address indexed token, uint256[] ids, uint256[] worths);
    event ERC1155ContractRemoved(address indexed token);
    event WorthTokenUpdated(address indexed newToken);
    event ERC20OffsetSet(address indexed wallet, int256 offset);
    event PoolStakingOffsetSet(address indexed wallet, address indexed poolStakingContract, int256 offset);
    event PeriodicalStakingOffsetSet(
        address indexed wallet, address indexed periodicalStakingContract, int256 offset
    );
    event NFTCountOffsetSet(
        address indexed wallet, address indexed token, uint256 id, int256 offset
    );
    event ConfigClonedFrom(address indexed v1);
    event PhasePeriodRequirementsClonedFrom(address indexed v1, uint256[] phases, uint256[] periods);

    uint256 public defaultRequiredWorth;

    /// @notice Mapping: phase => period => required worth amount
    mapping(uint256 phase => mapping(uint256 period => uint256 requiredWorth)) public requiredWorthPhasePeriod;

    /// @notice A (phase, period) key that has had a non-zero requiredWorth stored.
    ///         Populated only when `_setRequiredWorthPhasePeriod` writes a non-zero value
    ///         for a previously-untracked pair; never removed.
    struct PhasePeriodKey {
        uint256 phase;
        uint256 period;
    }

    /// @notice Enumerable list of (phase, period) keys that have ever had a non-zero override.
    ///         Used by cloneConfigFrom to migrate thresholds to a future contract in one call.
    PhasePeriodKey[] public phasePeriodKeys;

    /// @dev Dedupe flag so a key is only appended to phasePeriodKeys once.
    mapping(uint256 phase => mapping(uint256 period => bool tracked)) internal _phasePeriodKeyTracked;

    IERC20 public worthToken;

    address[] public poolStakingContracts;
    address[] public periodicalStakingContracts;

    address[] public erc1155Contracts;
    mapping(address contractAddress => mapping(uint256 nftId => uint256 worth)) public erc1155IdWorth;
    mapping(address => uint256[]) public erc1155TrackedIds;

    mapping(address wallet => int256 offset) public erc20Offset;
    mapping(address wallet => mapping(address poolStakingContract => int256 offset)) public poolStakingOffset;
    mapping(address wallet => mapping(address periodicalStakingContract => int256 offset))
        public periodicalStakingOffset;
    mapping(
        address wallet => mapping(address token => mapping(uint256 id => int256 countOffset))
    ) public nftCountOffset;
}
