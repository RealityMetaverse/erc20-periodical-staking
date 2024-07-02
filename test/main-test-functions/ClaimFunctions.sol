// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../AuxiliaryFunctions.sol";

contract ClaimFunctions is AuxiliaryFunctions {
    function _claimTokens(uint256 _depositNo) internal {
        stakingContract.claimDeposit(_depositNo);
    }

    function _claimAll() internal {
        stakingContract.claimAll();
    }

    function _claimTokenWithTest(address userAddress, uint256 _depositNo, bool ifRevertExpected) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        if (ifRevertExpected) {
            vm.expectRevert();
            _claimTokens(_depositNo);
        } else {
            ProgramManager.TokenDeposit memory targetDeposit = stakingContract.getDeposit(userAddress, _depositNo);

            uint256 stakingPhase = targetDeposit.stakingPhase;
            uint256 stakingPeriod = targetDeposit.stakingPeriod;

            uint256 depositAmountToReceive = (stakingPeriod == 0) ? 0 : targetDeposit.amount;
            uint256 rewardExpected = (stakingPeriod == 0) ? 0 : targetDeposit.rewardGenerated;
            uint256 rewardGenerated = targetDeposit.rewardGenerated;

            uint256[] memory currentData = _getCurrentData(userAddress, stakingPhase, stakingPeriod);

            _claimTokens(_depositNo);

            uint256[] memory expectedData = new uint256[](10);
            expectedData[0] = currentData[0] - depositAmountToReceive;
            expectedData[1] = currentData[1] + depositAmountToReceive + rewardGenerated;
            expectedData[2] = currentData[2] - depositAmountToReceive;
            expectedData[3] = currentData[3] - depositAmountToReceive - rewardGenerated;
            expectedData[4] = currentData[4] - depositAmountToReceive;
            expectedData[5] = currentData[5] + depositAmountToReceive;
            expectedData[6] = currentData[6] + depositAmountToReceive;
            expectedData[7] = currentData[7] + rewardGenerated;
            expectedData[8] = currentData[8] - rewardExpected;
            expectedData[9] = currentData[9] - rewardExpected;

            currentData = _getCurrentData(userAddress, stakingPhase, stakingPeriod);

            assertEq(currentData[0], expectedData[0]);
            assertEq(currentData[1], expectedData[1]);
            assertEq(currentData[2], expectedData[2]);
            assertEq(currentData[3], expectedData[3]);
            assertEq(currentData[4], expectedData[4]);
            assertEq(currentData[5], expectedData[5]);
            assertEq(currentData[6], expectedData[6]);
            assertEq(currentData[7], expectedData[7]);
            assertEq(currentData[8], expectedData[8]);
            assertEq(currentData[9], expectedData[9]);

            targetDeposit = stakingContract.getDeposit(userAddress, _depositNo);
            uint256 withdrawalDate = (stakingPeriod == 0) ? 0 : block.timestamp;
            assertEq(targetDeposit.withdrawalDate, withdrawalDate);

            if (stakingPeriod == 0) rewardGenerated = 0;

            assertEq(rewardGenerated, targetDeposit.rewardGenerated);
        }

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _claimAllWithTest(address userAddress, bool ifRevertExpected) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        if (ifRevertExpected) {
            vm.expectRevert();
            _claimAll();
        } else {
            (uint256 claimableStaking, uint256 claimablePeriodicalReward, uint256 claimableIndefiniteReward) =
                stakingContract.checkTotalClaimableData();

            uint256[] memory currentData = _getCurrentData(userAddress, 0, 0);

            _claimAll();

            uint256[] memory expectedData = new uint256[](10);
            expectedData[0] = currentData[0] - claimableStaking;
            expectedData[1] = currentData[1] + claimableStaking + claimablePeriodicalReward + claimableIndefiniteReward;
            expectedData[2] = currentData[2] - claimableStaking;
            expectedData[3] = currentData[3] - claimableStaking - claimablePeriodicalReward - claimableIndefiniteReward;
            expectedData[5] = currentData[5] + claimableStaking;
            expectedData[6] = currentData[6] + claimableStaking;
            expectedData[7] = currentData[7] + claimablePeriodicalReward + claimableIndefiniteReward;

            currentData = _getCurrentData(userAddress, 0, 0);

            assertEq(currentData[0], expectedData[0]);
            assertEq(currentData[1], expectedData[1]);
            assertEq(currentData[2], expectedData[2]);
            assertEq(currentData[3], expectedData[3]);
            assertEq(currentData[5], expectedData[5]);
            assertEq(currentData[6], expectedData[6]);
            assertEq(currentData[7], expectedData[7]);
            assertEq(currentData[9], 0);
        }

        if (userAddress != address(this)) vm.stopPrank();
    }
}
