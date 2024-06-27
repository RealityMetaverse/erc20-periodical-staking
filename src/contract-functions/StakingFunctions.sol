// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";

abstract contract StakingFunctions is ReadFunctions, WriteFunctions {
    function safeStake(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount, uint256 expectedAPY)
        external
        nonReentrant
        ifAvailable(DataType.STAKING)
        ifLegitStakeRequest(stakingPhase, stakingPeriod, tokenAmount)
    {
        TokenDeposit[] storage targetDepositList = stakerDepositList[msg.sender];
        if (targetDepositList.length == 0) stakerAddressList.push(msg.sender);

        uint256 apyToSet = phasePeriodDataList[PhasePeriodDataType.APY][stakingPhase][stakingPeriod];
        if (expectedAPY != apyToSet) revert PhasePeriodAPYChanged(stakingPhase, stakingPeriod, apyToSet);
        uint256 depositAPY = apyToSet;

        uint256 depositEndDate = 0;
        uint256 rewardGenerated = 0;

        if (stakingPeriod != 0) {
            depositEndDate = block.timestamp + (stakingPeriod * (1 days));
            rewardGenerated = calculateReward(tokenAmount, depositAPY, stakingPeriod);

            userDataList[DataType.REWARD_EXPECTED][msg.sender] += rewardGenerated;
            totalDataList[DataType.REWARD_EXPECTED] += rewardGenerated;
        }

        _updateAllDataAfterAction(DataType.STAKING, stakingPhase, stakingPeriod, tokenAmount, rewardGenerated);

        targetDepositList.push(
            TokenDeposit(
                currentStakingPhase,
                stakingPeriod,
                block.timestamp,
                depositEndDate,
                0,
                tokenAmount,
                depositAPY,
                rewardGenerated
            )
        );

        emit Stake(
            msg.sender,
            currentStakingPhase,
            stakingPeriod,
            depositAPY,
            tokenAmount,
            stakerDepositList[msg.sender].length - 1
        );

        _receiveToken(tokenAmount);
    }
}
