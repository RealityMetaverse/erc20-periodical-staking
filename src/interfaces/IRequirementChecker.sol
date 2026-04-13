// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IRequirementChecker {
    function meetsRequirement(address user, uint256 phase, uint256 period) external view returns (bool);

    function meetsRequirementBatch(address[] calldata users, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (bool[] memory results);

    function getTotalWorth(address user) external view returns (uint256);

    function worthBreakdown(address user, uint256 phase, uint256 period)
        external
        view
        returns (uint256 erc20Balance, uint256 stakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth);

    function getRequiredWorth(uint256 phase, uint256 period) external view returns (uint256);

    function getRequiredWorthBatch(uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory requiredWorths);
}
