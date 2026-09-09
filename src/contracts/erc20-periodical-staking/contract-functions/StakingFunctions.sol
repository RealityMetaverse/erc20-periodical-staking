// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

abstract contract StakingFunctions is ReadFunctions, WriteFunctions {
    /// @notice Open a deposit on (stakingPhase, stakingPeriod).
    /// @dev No reward-pool check is performed at stake time. Periodical deposits (period != 0)
    ///      add their full reward to `totalDataList[REWARD_EXPECTED]`, which `collectReward` can never take from
    ///      the pool; if the pool is short when the deposit matures, `claimDeposit` reverts
    ///      `NotEnoughFundsInRewardPool` until the owner tops up (no loss). Indefinite deposits (period 0)
    ///      are not reserved and are paid only from `getCollectableReward()`.
    /// @param stakingPhase Must equal currentStakingPhase
    /// @param stakingPeriod Period in days; 0 for an indefinite deposit
    /// @param tokenAmount Amount to stake (caller must have approved the contract)
    /// @param expectedAPY Must equal the configured APY (front-running guard)
    function safeStake(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount, uint256 expectedAPY)
        external
        nonReentrant
        ifAvailable(Types.DataType.STAKING)
        ifLegitStakeRequest(stakingPhase, stakingPeriod, tokenAmount)
    {
        TokenDeposit[] storage targetDepositList = stakerDepositList[msg.sender];
        if (targetDepositList.length == 0) stakerAddressList.push(msg.sender);

        uint256 apyToSet = phasePeriodDataList[Types.PhasePeriodDataType.APY][stakingPhase][stakingPeriod];
        if (expectedAPY != apyToSet) revert PhasePeriodAPYChanged(stakingPhase, stakingPeriod, apyToSet);
        uint256 depositAPY = apyToSet;

        uint256 depositEndDate = 0;
        uint256 rewardGenerated = 0;

        if (stakingPeriod != 0) {
            depositEndDate = block.timestamp + (stakingPeriod * (1 days));
            rewardGenerated = calculateReward(tokenAmount, depositAPY, stakingPeriod);

            userDataList[Types.DataType.REWARD_EXPECTED][msg.sender] += rewardGenerated;
            totalDataList[Types.DataType.REWARD_EXPECTED] += rewardGenerated;
            userPhasePeriodDataList[Types.DataType.REWARD_EXPECTED][stakingPhase][stakingPeriod][msg.sender] +=
                rewardGenerated;
        }

        _updateAllDataAfterAction(Types.DataType.STAKING, stakingPhase, stakingPeriod, tokenAmount, rewardGenerated);

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
