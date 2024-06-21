// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "../ComplianceCheck.sol";

abstract contract ReadFunctions is ComplianceCheck {
    // ======================================
    // =  Functoins to check program data   =
    // ======================================
    function checkRewardProvidedBy(address userAddress) external view returns (uint256) {
        return rewardProviderList[userAddress];
    }

    function checkStakingTarget(uint256 stakingPhase, uint256 stakingPeriod) external view returns (uint256) {
        return phasePeriodDataList[DataType.STAKING_TARGET][stakingPhase][stakingPeriod];
    }

    function checkAPY(uint256 stakingPhase, uint256 stakingPeriod)
        external
        view
        returns (uint256)
    {
        return phasePeriodDataList[DataType.APY][stakingPhase][stakingPeriod];
    }

    /// @dev Total data requests
    // Periodical
    function checkTotalPeriodicalStaked() public view returns (uint256) {
        return totalDataList[DataType.PERIODICAL_STAKED];
    }

    function checkTotalPeriodicalWithdrawn() external view returns (uint256) {
        return totalDataList[DataType.PERIODICAL_WITHDRAWN];
    }

    function checkTotalPeriodicalStakingClaimed() external view returns (uint256) {
        return totalDataList[DataType.PERIODICAL_STAKING_CLAIMED];
    }

    function checkTotalPeriodicalRewardExpected() external view returns (uint256) {
        return totalDataList[DataType.PERIODICAL_REWARD_EXPECTED];
    }

    function checkTotalPeriodicalRewardClaimed() external view returns (uint256) {
        return totalDataList[DataType.PERIODICAL_REWARD_CLAIMED];
    }

    function checkTotalClaimablePeriodicalReward() external view returns (uint256) {
        uint256 totalClaimablePeriodicalReward = 0;

        for (uint256 stakerNo = 0; stakerNo < stakerAddressList.length; stakerNo++) {
            address userAddress = stakerAddressList[stakerNo];

            totalClaimablePeriodicalReward += checkClaimablePeriodicalRewardFor(userAddress);
        }

        return totalClaimablePeriodicalReward;
    }

    function checkTotalClaimableStaking() external view returns (uint256) {
        uint256 totalClaimableStaking = 0;

        for (uint256 stakerNo = 0; stakerNo < stakerAddressList.length; stakerNo++) {
            address userAddress = stakerAddressList[stakerNo];

            totalClaimableStaking += checkClaimableStakingFor(userAddress);
        }

        return totalClaimableStaking;
    }

    // Indefinite
    function checkTotalIndefiniteStaked() public view returns (uint256) {
        return totalDataList[DataType.INDEFINITE_STAKED];
    }

    function checkTotalIndefiniteWithdrawn() external view returns (uint256) {
        return totalDataList[DataType.INDEFINITE_WITHDRAWN];
    }

    function checkTotalClaimableIndefiniteReward() external view returns (uint256) {
        uint256 totalClaimableIndefiniteReward = 0;

        for (uint256 stakerNo = 0; stakerNo < stakerAddressList.length; stakerNo++) {
            address userAddress = stakerAddressList[stakerNo];

            totalClaimableIndefiniteReward += checkClaimableIndefiniteRewardFor(userAddress);
        }

        return totalClaimableIndefiniteReward;
    }

    function checkTotalIndefiniteRewardClaimed() external view returns (uint256) {
        return totalDataList[DataType.INDEFINITE_REWARD_CLAIMED];
    }

    // Combined
    function checkTotalStaked() external view returns(uint256) {
        return totalDataList[DataType.PERIODICAL_STAKED] + totalDataList[DataType.INDEFINITE_STAKED];
    }

    function checkPhasePeriodStaked(uint256 stakingPhase, uint256 stakingPeriod) external view returns(uint256) {
        return phasePeriodDataList[DataType.STAKED][stakingPhase][stakingPeriod];
    }

    function checkTotalWithdrawn() external view returns(uint256) {
        return totalDataList[DataType.PERIODICAL_WITHDRAWN] + totalDataList[DataType.INDEFINITE_WITHDRAWN];
    }

    function checkTotalRewardClaimed() external view returns(uint256) {
        return totalDataList[DataType.PERIODICAL_REWARD_CLAIMED] + totalDataList[DataType.INDEFINITE_REWARD_CLAIMED];
    }

    // Funds
    function checkTotalFundCollected() external view returns (uint256) {
        return totalDataList[DataType.FUNDS_COLLECTED];
    }

    function checkTotalFundRestored() external view returns (uint256) {
        return totalDataList[DataType.FUNDS_RESTORED];
    }

    // ======================================
    // =    Functions to check user data    =
    // ======================================
    // Deposits
    function checkDepositCountOfAddress(address userAddress)
        public
        view
        returns (uint256)
    {
        return stakerDepositList[userAddress].length;
    }

    function getDeposit(address userAddress, uint256 depositNumber) external view returns(TokenDeposit memory){
        return stakerDepositList[userAddress][depositNumber];
    }

    function getAllDepositsBy(address userAddress)
        external
        view
        returns (TokenDeposit[] memory)
    {
        return stakerDepositList[userAddress];
    }

    function getDepositsInRangeBy(address userAddress, uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (TokenDeposit[] memory)
    {
        TokenDeposit[] memory userDepositsInRange = new TokenDeposit[](toIndex - fromIndex);

        uint256 iterator;
        for (uint256 i = fromIndex; i < toIndex; i++) {
            userDepositsInRange[iterator] = stakerDepositList[userAddress][i];
            iterator++;
        }

        return userDepositsInRange;
    }

    // Periodical
    function checkPeriodicalStakedBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.PERIODICAL_STAKED][userAddress];
    }

    function checkPeriodicalWithdrawnBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.PERIODICAL_WITHDRAWN][userAddress];
    }

    function checkClaimedPeriodicalStakingBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.PERIODICAL_STAKING_CLAIMED][userAddress];
    }

    function checkExpectedPeriodicalRewardBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.PERIODICAL_REWARD_EXPECTED][userAddress];
    }

    function checkPeriodicalRewardClaimedBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.PERIODICAL_REWARD_CLAIMED][userAddress];
    }

    function checkClaimablePeriodicalRewardFor(address userAddress)
        public
        view
        returns (uint256)
    {
        uint256 claimablePeriodicalReward = 0;
        uint256 userDepositCount = checkDepositCountOfAddress(userAddress);

        for (uint256 depositNumber = stakerActiveDepositStartIndex[userAddress]; depositNumber < userDepositCount; depositNumber++) {
            DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
            if (depositStatus == DepositStatus.READY_TO_CLAIM){
                TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
                claimablePeriodicalReward += targetDeposit.rewardGenerated;
            }
        }

        return claimablePeriodicalReward;
    }

    function checkClaimableStakingFor(address userAddress)
        public
        view
        returns (uint256)
    {
        uint256 claimableStaking = 0;
        uint256 userDepositCount = checkDepositCountOfAddress(userAddress);

        for (uint256 depositNumber = stakerActiveDepositStartIndex[userAddress]; depositNumber < userDepositCount; depositNumber++) {
            DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
            if (depositStatus == DepositStatus.READY_TO_CLAIM){
                TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
                claimableStaking += targetDeposit.amount;
            }
        }

        return claimableStaking;
    }

    // Indefinite
    function checkIndefiniteStakedBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.INDEFINITE_STAKED][userAddress];
    }

    function checkIndefiniteWithdrawnBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.INDEFINITE_WITHDRAWN][userAddress];
    }

    function checkIndefiniteRewardClaimedBy(address userAddress)
        external
        view
        returns (uint256)
    {
        return userDataList[DataType.INDEFINITE_REWARD_CLAIMED][userAddress];
    }

    function checkClaimableIndefiniteRewardFor(address userAddress)
        public
        view
        returns (uint256)
    {
        uint256 claimableIndefiniteReward = 0;
        uint256 userDepositCount = checkDepositCountOfAddress(userAddress);

        for (uint256 depositNumber = stakerActiveDepositStartIndex[userAddress]; depositNumber < userDepositCount; depositNumber++) {
            DepositStatus depositStatus = checkDepositStatus(userAddress, depositNumber);
            if (depositStatus == DepositStatus.INDEFINITE){
                TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
                claimableIndefiniteReward += _calculateIndefiniteDepositReward(targetDeposit);
            }
        }

        return claimableIndefiniteReward;
    }

    // Combined
    function checkTotalStakedBy(address userAddress)
        external
        view
        returns (uint256)
    {
        
        return userDataList[DataType.PERIODICAL_STAKED][userAddress] + userDataList[DataType.INDEFINITE_STAKED][userAddress];
    }

    function checkTotalWithdrawnBy(address userAddress)
        external
        view
        returns (uint256)
    {
        
        return userDataList[DataType.PERIODICAL_WITHDRAWN][userAddress] + userDataList[DataType.INDEFINITE_WITHDRAWN][userAddress];
    }

    function checkTotalRewardClaimedBy(address userAddress)
        external
        view
        returns (uint256)
    {
        
        return userDataList[DataType.PERIODICAL_REWARD_CLAIMED][userAddress] + userDataList[DataType.INDEFINITE_REWARD_CLAIMED][userAddress];
    }

    // Funds
    function checkRestoredFundsBy(address userAddress)
        external
        view
        returns (uint256)
    {
        
        return userDataList[DataType.FUNDS_RESTORED][userAddress];
    }

    // ======================================
    // =           Other functions          =
    // ======================================
    function calculateReward(uint256 depositAmount, uint256 depositAPY, uint256 stakingPeriod)
        public
        pure
        returns (uint256)
    {
        return (((depositAmount * ((FIXED_POINT_PRECISION * depositAPY / 365) * stakingPeriod) / 100)) / FIXED_POINT_PRECISION);
    }

    function _calculateIndefiniteDepositReward(TokenDeposit memory targetDeposit) internal view returns(uint256) {
        uint256 timePassed = block.timestamp - targetDeposit.stakingStartDate;
        uint256 daysPassed = timePassed / (1 days);

        return calculateReward(targetDeposit.amount, targetDeposit.APY, daysPassed) - targetDeposit.rewardGenerated;
    }
}
