// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";

abstract contract claimOrWithdrawFunctions is ReadFunctions {
    // ======================================
    // =          Write Functions           =
    // ======================================
    function updateActiveDepositStartIndex(address userAddress) private {
        uint256 userDepositCount = stakerDepositList[userAddress].length;
        uint256 currentIndex = stakerActiveDepositStartIndex[userAddress];

        if (userDepositCount > 1 && currentIndex + 1 != userDepositCount) {
            for (uint256 depositNumber = currentIndex; depositNumber < userDepositCount; depositNumber++) {
                DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
                if(depositStatus == DepositStatus.TIME_LEFT || depositStatus == DepositStatus.READY_TO_CLAIM || depositStatus == DepositStatus.INDEFINITE){
                    stakerActiveDepositStartIndex[userAddress] = depositNumber;
                    return;
                }
            }
        }
    }

    // ======================================
    // = Claim / Withdraw Related Functions =
    // ======================================
    function withdrawDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifDepositExists(depositNumber)
    {
        if (!isWithdrawalOpen) revert NotOpen("Withdrawal");
        _checkIfEnoughFundsAvailable(stakerDepositList[msg.sender][depositNumber].amount);
        DepositStatus depositStatus = checkDepositStatus(msg.sender, depositNumber);
        
        if (depositStatus == DepositStatus.TIME_LEFT || depositStatus == DepositStatus.INDEFINITE) {
            TokenDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];
            uint256 amountToWithdraw = targetDeposit.amount;
            phasePeriodDataList[DataType.STAKED][targetDeposit.stakingPhase][targetDeposit.stakingPeriod] -= amountToWithdraw;
            targetDeposit.claimOrWithdrawalDate = block.timestamp;

            if (depositStatus == DepositStatus.TIME_LEFT) {
                uint256 expectedReward = targetDeposit.rewardGenerated;

                userDataList[DataType.PERIODICAL_STAKED][msg.sender] -= amountToWithdraw;
                userDataList[DataType.PERIODICAL_REWARD_EXPECTED][msg.sender] -= expectedReward;
                userDataList[DataType.PERIODICAL_WITHDRAWN][msg.sender] += amountToWithdraw;

                totalDataList[DataType.PERIODICAL_STAKED] -= amountToWithdraw;
                totalDataList[DataType.PERIODICAL_REWARD_EXPECTED] -= expectedReward;
                totalDataList[DataType.PERIODICAL_WITHDRAWN] += amountToWithdraw;

                emit WithdrawPeriodical(msg.sender, depositNumber, amountToWithdraw, expectedReward);
            } else {
                uint256 depositReward = _calculateIndefiniteDepositReward(targetDeposit);
                _checkIfEnoughFundsInRewardPool(depositReward, true);

                rewardPool -= depositReward;
                targetDeposit.rewardGenerated += depositReward;

                userDataList[DataType.INDEFINITE_STAKED][msg.sender] -= amountToWithdraw;
                userDataList[DataType.INDEFINITE_WITHDRAWN][msg.sender] += amountToWithdraw;
                userDataList[DataType.INDEFINITE_REWARD_CLAIMED][msg.sender] += depositReward;

                totalDataList[DataType.INDEFINITE_STAKED] -= amountToWithdraw;
                totalDataList[DataType.INDEFINITE_WITHDRAWN] += amountToWithdraw;
                totalDataList[DataType.INDEFINITE_REWARD_CLAIMED] += depositReward;

                emit WithdrawIndefinite(msg.sender, depositNumber, amountToWithdraw, depositReward);
                amountToWithdraw += depositReward;
            }
            
            updateActiveDepositStartIndex(msg.sender);
            _sendToken(msg.sender, amountToWithdraw);
        } else revert("Deposit not withdrawable");
    }

    function _claimDeposit(uint256 depositNumber, bool isBatchClaim) private {        
        DepositStatus depositStatus = checkDepositStatus(msg.sender, depositNumber);
        TokenDeposit storage targetDeposit = stakerDepositList[msg.sender][depositNumber];

        uint256 amountToClaim;
        uint256 depositReward;

        if(depositStatus == DepositStatus.READY_TO_CLAIM) {
            amountToClaim = targetDeposit.amount;
            _checkIfEnoughFundsAvailable(amountToClaim);
            phasePeriodDataList[DataType.STAKED][targetDeposit.stakingPhase][targetDeposit.stakingPeriod] -= amountToClaim;

            depositReward = targetDeposit.rewardGenerated;

            userDataList[DataType.PERIODICAL_STAKED][msg.sender] -= amountToClaim;
            userDataList[DataType.PERIODICAL_REWARD_EXPECTED][msg.sender] -= depositReward;
            userDataList[DataType.PERIODICAL_STAKING_CLAIMED][msg.sender] += amountToClaim;

            totalDataList[DataType.PERIODICAL_STAKED] -= amountToClaim;
            totalDataList[DataType.PERIODICAL_REWARD_EXPECTED] -= depositReward;
            totalDataList[DataType.PERIODICAL_STAKING_CLAIMED] += amountToClaim;

            emit ClaimPeriodical(msg.sender, depositNumber, amountToClaim, depositReward);
            amountToClaim += depositReward;
        } else if(depositStatus == DepositStatus.INDEFINITE) {
            depositReward = _calculateIndefiniteDepositReward(targetDeposit);
            targetDeposit.rewardGenerated += depositReward;

            userDataList[DataType.INDEFINITE_REWARD_CLAIMED][msg.sender] += depositReward;
            totalDataList[DataType.INDEFINITE_REWARD_CLAIMED] += depositReward;

            amountToClaim = depositReward;
            emit ClaimIndefinite(msg.sender, depositNumber, depositReward);
        } else {
            if(isBatchClaim) return;
            else revert("Deposit not claimable");
        }

        if(!_checkIfEnoughFundsInRewardPool(depositReward, false)){
            if(isBatchClaim) return;
            else revert NotEnoughFundsInRewardPool(depositReward, rewardPool);
        }
        rewardPool -= depositReward;

        // Can be optimized
        updateActiveDepositStartIndex(msg.sender);
        _sendToken(msg.sender, amountToClaim);
    }

    function claimDeposit(uint256 depositNumber)
        external
        nonReentrant
        ifDepositExists(depositNumber)
    {
        if (!isClaimOpen) revert NotOpen("Claim");
        _claimDeposit(depositNumber, false);
    }

    function claimAll()
        external
        nonReentrant
    {
        if (!isClaimOpen) revert NotOpen("Claim");
        uint256 userDepositCount = stakerDepositList[msg.sender].length;

        for (uint256 depositNumber = stakerActiveDepositStartIndex[msg.sender]; depositNumber < userDepositCount; depositNumber++) {
            _claimDeposit(depositNumber, true);
        }
    }
}
