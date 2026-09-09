// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IRequirementChecker {
    function meetsRequirement(address user, uint256 phase, uint256 period) external view returns (bool);

    function meetsRequirementBatch(address[] calldata users, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (bool[] memory results);

    function getTotalWorth(address user) external view returns (uint256);

    function worthBreakdown(address user)
        external
        view
        returns (uint256 erc20Balance, uint256 poolStakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth);

    function getRequiredWorth(uint256 phase, uint256 period) external view returns (uint256);

    function getRequiredWorthBatch(uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory requiredWorths);

    // ===== V2 additions =====
    function getRawTotalWorth(address user) external view returns (uint256);

    function rawWorthBreakdown(address user)
        external
        view
        returns (uint256 erc20Balance, uint256 poolStakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth);

    function getAppliedOffsetsWorth(address user) external view returns (int256);

    /// @notice Returns the wallet's total worth excluding ERC1155 NFT contribution (ERC20 + staking + periodical).
    function getTokenWorth(address user) external view returns (uint256);

    /// @notice Returns the raw (offset-ignoring) total worth excluding ERC1155 NFT contribution.
    function getRawTokenWorth(address user) external view returns (uint256);
}
