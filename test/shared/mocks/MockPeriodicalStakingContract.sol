// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../../src/interfaces/IPeriodicalStakingContract.sol";

contract MockPeriodicalStakingContract is IPeriodicalStakingContract {
    mapping(uint8 => mapping(address => uint256)) internal _userData;

    function setUserData(uint8 dataType, address user, uint256 amount) external {
        _userData[dataType][user] = amount;
    }

    function userDataList(uint8 dataType, address user) external view returns (uint256) {
        return _userData[dataType][user];
    }

    /// @dev Stub: not used by RequirementCheckerV2 aggregation, present only to satisfy the interface.
    function getUserPhasePeriodData(uint8, address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @dev Stub: not used by RequirementCheckerV2 aggregation, present only to satisfy the interface.
    function getUserPhasePeriodDataBatch(
        uint8,
        address[] calldata userAddresses,
        uint256[] calldata,
        uint256[] calldata
    ) external pure returns (uint256[] memory values) {
        values = new uint256[](userAddresses.length);
    }
}
