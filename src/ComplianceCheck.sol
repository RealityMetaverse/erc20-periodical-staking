// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessControl.sol";

abstract contract ComplianceCheck is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    // ======================================
    // =              Errors                =
    // ======================================
    error NotOpen(string _action);
    error NoStakingPhasesAddedYet();
    error StakingPeriodExists(uint256 stakingPeriod);
    error StakingPhaseDoesNotExist(uint256 stakingPhase);
    error StakingPeriodDoesNotExist(uint256 stakingPeriod);
    error DepositDoesNotExist(uint256 depositNumber);
    error AmountExceedsTarget(uint256 stakingPhase, uint256 stakingPeriod, uint256 stakingTarget);
    error RestorationExceedsCollected(uint256 _tokenSent, uint256 _RemainingAmountToRestore);
    error InsufficentDeposit(uint256 _tokenSent, uint256 _requiredAmount);
    error NotEnoughFunds(uint256 requestedAmount, uint256 availableAmount);
    error NotEnoughFundsInRewardPool(uint256 requestedAmount, uint256 availableAmount);    
    error IncorrectStakingPhase(uint256 expectedPhase, uint256 currentPhase);

    // ======================================
    // =             Functions              =
    // ======================================
    function _checkDepositExistence(uint256 depositNumber) private view {
        if (!(depositNumber < (stakerDepositList[msg.sender].length))) {
            revert DepositDoesNotExist(depositNumber);
        }
    }

    function _checkIfTargetReached(uint256 stakingPhase, uint256 stakinPeriod, uint256 amountToStake) internal view {
        uint256 stakingTarget = phasePeriodDataList[DataType.STAKING_TARGET][stakingPhase][stakinPeriod];
        uint256 totalStaked = phasePeriodDataList[DataType.STAKED][stakingPhase][stakinPeriod];

        if ((amountToStake + totalStaked) > totalStaked) revert AmountExceedsTarget(stakingPhase, stakinPeriod, stakingTarget);
    }

    function _checkIfEnoughFundsAvailable(uint256 amountToCheck) internal view {
        uint256 fundAvailableToClaim = totalDataList[DataType.PERIODICAL_STAKED] + totalDataList[DataType.INDEFINITE_STAKED] - (totalDataList[DataType.FUNDS_COLLECTED] - totalDataList[DataType.FUNDS_RESTORED]);
        if (amountToCheck > fundAvailableToClaim) revert NotEnoughFunds(amountToCheck, fundAvailableToClaim);
        
    }

    function _checkIfEnoughFundsInRewardPool(uint256 amountToCheck, bool mustRevert) internal view returns(bool) {
        if (amountToCheck > rewardPool) {
            if(mustRevert) revert NotEnoughFundsInRewardPool(amountToCheck, rewardPool);
            else return false;
        } else return true;
    }

    function _checkIfStakingPhaseExists(uint256 stakingPhase) internal view returns (bool) {
        if (stakingPhase < stakingPhaseCount) return true;
        return false;
    }

    function _checkIfStakingPeriodExists(uint256 stakingPeriod) internal view returns (bool) {
        if (phasePeriodDataList[DataType.APY][0][stakingPeriod] != 0) return true;
        return false;
    }

    function checkDepositStatus(address userAddress, uint256 depositNumber) public view returns (DepositStatus) {
        TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
        if (targetDeposit.claimOrWithdrawalDate == 0){
            if (targetDeposit.stakingEndDate == 0) return DepositStatus.INDEFINITE;
            
            if (block.timestamp >= targetDeposit.stakingEndDate) return DepositStatus.READY_TO_CLAIM;
            else return DepositStatus.TIME_LEFT;
        }
        else if (targetDeposit.claimOrWithdrawalDate < targetDeposit.stakingEndDate) return DepositStatus.WITHDRAWN;
        else if (targetDeposit.claimOrWithdrawalDate >= targetDeposit.stakingEndDate) return DepositStatus.CLAIMED;
    }

    // ======================================
    // =             Modifiers              =
    // ======================================
    modifier ifDepositExists(uint256 depositNumber) {
        _checkDepositExistence(depositNumber);
        _;
    }

    /// @dev Checks if the deposit amount is higher the minimum required amount, raises exception if not
    modifier enoughTokenSent(uint256 tokenSent, uint256 _minimumDeposit) {
        if (tokenSent < _minimumDeposit) {
            revert InsufficentDeposit(tokenSent, _minimumDeposit);
        }
        _;
    }


    // ======================================
    // =              Events                =
    // ======================================
    event CreateProgram(
        address stakingTokenAddress,
        uint256 _stakingPhaseCount,
        uint256[] stakingPeriods,
        uint256[][] phasePeriodAPYs,
        uint256[][] phasePeriodStakingTargets
    );

    event TransferOwnership(address from, address to);

    event AddContractAdmin(address indexed user);
    event RemoveContractAdmin(address indexed user);

    event Stake(
        address indexed by,
        uint256 indexed stakingPhase,
        uint256 indexed stakingPeriod,
        uint256 APY,
        uint256 tokenAmount,
        uint256 depositNumber
    );
    event WithdrawPeriodical(
        address indexed by, uint256 depositNumber, uint256 stakedAmount, uint256 rewardLost
    );
    event WithdrawIndefinite(
        address indexed by, uint256 depositNumber, uint256 stakedAmount, uint256 rewardClaimed
    );

    event ClaimPeriodical(
        address indexed by, uint256 depositNumber, uint256 stakedAmount, uint256 reward
    );
    event ClaimIndefinite(
        address indexed by, uint256 depositNumber, uint256 reward
    );

    event CollectFunds(address indexed by, uint256 tokenAmount);
    event RestoreFunds(address indexed by, uint256 tokenAmount);

    event ProvideReward(address indexed by, uint256 tokenAmount);
    event CollectReward(address indexed by, uint256 tokenAmount);

    event UpdateStakingTarget(uint256 indexed stakingPhase, uint256 indexed stakingPeriod, uint256 newStakingTarget);
    event UpdateMinimumDeposit(uint256 newMinimumDeposit);
    event UpdateAPY(uint256 indexed stakingPhase, uint256 indexed stakingPeriod, uint256 newAPY);

    event UpdateStakingStatus(address indexed by, bool isOpen);
    event UpdateWithdrawalStatus(address indexed by, bool isOpen);
    event UpdateClaimStatus(address indexed by, bool isOpen);

    event AddStakingPhase(uint256 indexed newStakingPhase);
    event RemoveStakingPhase(uint256 indexed stakingPhase);

    event AddStakingPeriod(uint256 indexed newStakingPeriod);
    event RemoveStakingPeriod(uint256 indexed stakingPeriod);

    // ======================================
    // =    Token Management Functions      =
    // ======================================
    function _receiveToken(uint256 tokenAmount) internal {
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), tokenAmount);
    }

    function _sendToken(address toAddress, uint256 tokenAmount) internal {
        STAKING_TOKEN.safeTransfer(toAddress, tokenAmount);
    }
}
