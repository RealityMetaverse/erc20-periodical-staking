// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./TestSetUp.t.sol";
import "../src/ProgramManager.sol";

contract ReadFunctions is TestSetUp {
    function _getTotalStaked() internal view returns (uint256) {
        return stakingContract.getTotalData(ProgramManager.DataType.STAKING);
    }

    function _getTotalWithdrawn() internal view returns (uint256) {
        return stakingContract.getTotalData(ProgramManager.DataType.WITHDRAWAL);
    }

    function _getTotalRewardExpected() internal view returns (uint256) {
        return stakingContract.getTotalData(ProgramManager.DataType.REWARD_EXPECTED);
    }

    function _getTotalStakedBy(address userAddress) internal view returns (uint256) {
        return stakingContract.getUserData(ProgramManager.DataType.STAKING, userAddress);
    }

    function _getTotalWithdrawnBy(address userAddress) internal view returns (uint256) {
        return stakingContract.getUserData(ProgramManager.DataType.WITHDRAWAL, userAddress);
    }

    function _getTotalClaimedBy(address userAddress) internal view returns (uint256) {
        return stakingContract.getUserData(ProgramManager.DataType.CLAIM, userAddress);
    }

    function _getTotalRewardExpectedBy(address userAddress) internal view returns (uint256) {
        return stakingContract.getUserData(ProgramManager.DataType.REWARD_EXPECTED, userAddress);
    }

    function _getUserDepositCount(address userAddress) internal view returns (uint256) {
        return stakingContract.checkDepositCountOfAddress(userAddress);
    }

    function _getTokenBalance(address userAddress) internal view returns (uint256) {
        return myToken.balanceOf(userAddress);
    }

    function _getPhasePeriodStakingTarget(uint256 stakingPhase, uint256 stakingPeriod)
        internal
        view
        returns (uint256)
    {
        return stakingContract.phasePeriodDataList(
            ProgramManager.PhasePeriodDataType.STAKING_TARGET, stakingPhase, stakingPeriod
        );
    }

    function _getPhasePeriodAPY(uint256 stakingPhase, uint256 stakingPeriod) internal view returns (uint256) {
        return stakingContract.phasePeriodDataList(ProgramManager.PhasePeriodDataType.APY, stakingPhase, stakingPeriod);
    }

    function _getPhasePeriodStakingStaked(uint256 stakingPhase, uint256 stakingPeriod)
        internal
        view
        returns (uint256)
    {
        return
            stakingContract.phasePeriodDataList(ProgramManager.PhasePeriodDataType.STAKED, stakingPhase, stakingPeriod);
    }

    function _getCurrentData(address userAddress, uint256 stakingPhase, uint256 stakingPeriod)
        internal
        view
        returns (uint256[] memory)
    {
        uint256[] memory data = new uint256[](10);
        data[0] = _getTotalStaked();
        data[1] = _getTokenBalance(userAddress);
        data[2] = _getTotalStakedBy(userAddress);
        data[3] = _getTokenBalance(address(stakingContract));
        data[4] = _getPhasePeriodStakingStaked(stakingPhase, stakingPeriod);
        data[5] = _getTotalWithdrawn();
        data[6] = _getTotalWithdrawnBy(userAddress);
        data[7] = _getTotalClaimedBy(userAddress);
        data[8] = _getTotalRewardExpected();
        data[9] = _getTotalRewardExpectedBy(userAddress);
        return data;
    }
}
