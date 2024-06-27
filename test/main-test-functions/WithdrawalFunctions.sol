// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../AuxiliaryFunctions.sol";

contract WithdrawalFunctions is AuxiliaryFunctions {
    function _withdrawTokens(uint256 _depositNo) internal {
        stakingContract.withdrawDeposit(_depositNo);
    }

    function _withdrawTokenWithTest(address userAddress, uint256 _depositNo, bool ifRevertExpected) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        if (ifRevertExpected) {
            vm.expectRevert();
            _withdrawTokens(_depositNo);
        } else {
            ProgramManager.TokenDeposit memory targetDeposit = stakingContract.getDeposit(userAddress, _depositNo);

            uint256 stakingPhase = targetDeposit.stakingPhase;
            uint256 stakingPeriod = targetDeposit.stakingPeriod;

            uint256 rewardGenerated = (stakingPeriod == 0) ? targetDeposit.rewardGenerated : 0;
            uint256 rewardExpected = (stakingPeriod == 0) ? 0 : targetDeposit.rewardGenerated;

            uint256[] memory currentData = _getCurrentData(userAddress, stakingPhase, stakingPeriod);

            _withdrawTokens(_depositNo);

            console.log(targetDeposit.rewardGenerated);

            uint256[] memory expectedData = new uint256[](10);
            expectedData[0] = currentData[0] - targetDeposit.amount;
            expectedData[1] = currentData[1] + targetDeposit.amount + rewardGenerated;
            expectedData[2] = currentData[2] - targetDeposit.amount;
            expectedData[3] = currentData[3] - targetDeposit.amount - rewardGenerated;
            expectedData[4] = currentData[4] - targetDeposit.amount;
            expectedData[5] = currentData[5] + targetDeposit.amount;
            expectedData[6] = currentData[6] + targetDeposit.amount;
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
            assertEq(targetDeposit.withdrawalDate, block.timestamp);

            rewardGenerated = 0;

            if (stakingPeriod == 0) {
                uint256 daysPassed = (block.timestamp - targetDeposit.stakingStartDate) / (1 days);
                rewardGenerated = stakingContract.calculateReward(targetDeposit.amount, targetDeposit.APY, daysPassed);
            }

            assertEq(rewardGenerated, targetDeposit.rewardGenerated);
        }

        if (userAddress != address(this)) vm.stopPrank();
    }
}
