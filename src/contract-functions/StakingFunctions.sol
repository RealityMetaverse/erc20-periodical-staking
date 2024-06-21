// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";

abstract contract StakingFunctions is ReadFunctions {
    function safeStake(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount)
        external
        nonReentrant
    {
        if (!isStakingOpen) revert NotOpen("Staking");
        if (tokenAmount < minimumDeposit) revert InsufficentDeposit(tokenAmount, minimumDeposit);
        _checkIfTargetReached(stakingPhase, stakingPeriod, tokenAmount);

        if (stakingPhase != currentStakingPhase) revert IncorrectStakingPhase(stakingPhase, currentStakingPhase);
        if (!_checkIfStakingPhaseExists(stakingPhase)) revert StakingPhaseDoesNotExist(stakingPhase);
        if (!_checkIfStakingPeriodExists(stakingPeriod)) revert StakingPeriodDoesNotExist(stakingPeriod);

        TokenDeposit[] storage targetDepositList = stakerDepositList[msg.sender];
        if (targetDepositList.length == 0) stakerAddressList.push(msg.sender);

        uint256 depositEndDate = 0;
        uint256 rewardGenerated = 0;
        uint256 depositAPY = phasePeriodDataList[DataType.APY][stakingPhase][stakingPeriod];
        
        if (stakingPeriod != 0){
            depositEndDate = block.timestamp + (stakingPeriod * (1 days));
            rewardGenerated = calculateReward(tokenAmount, depositAPY, stakingPeriod);

            userDataList[DataType.PERIODICAL_STAKED][msg.sender] += tokenAmount;
            userDataList[DataType.PERIODICAL_REWARD_EXPECTED][msg.sender] += rewardGenerated;

            totalDataList[DataType.PERIODICAL_STAKED] += tokenAmount;
            totalDataList[DataType.PERIODICAL_REWARD_EXPECTED] += rewardGenerated;
        }
        else {
            userDataList[DataType.INDEFINITE_STAKED][msg.sender] += tokenAmount;
            totalDataList[DataType.INDEFINITE_STAKED] += tokenAmount;
        }

        phasePeriodDataList[DataType.STAKED][stakingPhase][stakingPeriod] += tokenAmount;
        
        targetDepositList.push(
            TokenDeposit(
                currentStakingPhase, stakingPeriod, block.timestamp, depositEndDate, 0, tokenAmount, depositAPY, rewardGenerated
            )
        );

        emit Stake(
            msg.sender, currentStakingPhase, stakingPeriod, depositAPY, tokenAmount, stakerDepositList[msg.sender].length - 1
        );
        _receiveToken(tokenAmount);
    }
}
