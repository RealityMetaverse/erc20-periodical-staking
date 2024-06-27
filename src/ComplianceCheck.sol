// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessControl.sol";

abstract contract ComplianceCheck is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;
    using ArrayLibrary for uint256[];

    // ======================================
    // =              Errors                =
    // ======================================
    error NotOpen(DataType action);
    error NoStakingPhasesAddedYet();
    error IncorrectStakingPhase(uint256 expectedPhase, uint256 currentPhase);
    error StakingPhaseDoesNotExist(uint256 stakingPhase);
    error StakingPeriodExists(uint256 stakingPeriod);
    error StakingPeriodDoesNotExist(uint256 stakingPeriod);
    error DepositDoesNotExist(uint256 depositNumber);
    error AmountExceedsTarget(uint256 stakingPhase, uint256 stakingPeriod, uint256 stakingTarget);
    error InsufficentDeposit(uint256 _tokenSent, uint256 _requiredAmount);
    error PhasePeriodAPYChanged(uint256 stakingPhase, uint256 stakingPeriod, uint256 currentAPY);
    error NotEnoughFundsInRewardPool(uint256 requestedAmount, uint256 availableAmount);
    error NoRewardToClaim(uint256 depositNumber);
    error InvalidAPY(uint256 providedValue, uint256 minValue);
    error InvalidMinimumDeposit(uint256 providedValue, uint256 minValue);
    error InvalidDataType();
    error NotWithdrawable(uint256 depositNumber);
    error NotClaimable(uint256 depositNumber);
    error ArrayLengthDoesntMatch(uint256 expectedLength);
    error ZeroAddressProvided();

    // ======================================
    // =             Functions              =
    // ======================================
    function _checkDepositExistence(uint256 depositNumber) private view {
        if (!(depositNumber < (stakerDepositList[msg.sender].length))) {
            revert DepositDoesNotExist(depositNumber);
        }
    }

    function _checkIfTargetReached(uint256 stakingPhase, uint256 stakinPeriod, uint256 amountToStake) internal view {
        uint256 stakingTarget = phasePeriodDataList[PhasePeriodDataType.STAKING_TARGET][stakingPhase][stakinPeriod];
        uint256 totalStaked = phasePeriodDataList[PhasePeriodDataType.STAKED][stakingPhase][stakinPeriod];

        if ((amountToStake + totalStaked) > stakingTarget) {
            revert AmountExceedsTarget(stakingPhase, stakinPeriod, stakingTarget);
        }
    }

    function _checkIfEnoughFundsInRewardPool(uint256 amountToCheck, bool mustRevert) internal view returns (bool) {
        if (amountToCheck > rewardPool) {
            if (mustRevert) revert NotEnoughFundsInRewardPool(amountToCheck, rewardPool);
            else return false;
        } else {
            return true;
        }
    }

    function checkIfStakingPhaseExists(uint256 stakingPhase) public view returns (bool) {
        if (stakingPhase < stakingPhaseCount) return true;
        return false;
    }

    function checkIfStakingPeriodExists(uint256 stakingPeriod) public view returns (bool) {
        if (stakingPeriodList.length == stakingPeriodList.findElementIndex(stakingPeriod)) return false;
        else return true;
    }

    function _checkIfStakingPhasePeriodExists(uint256 stakingPhase, uint256 stakingPeriod) internal view {
        if (!checkIfStakingPhaseExists(stakingPhase)) revert StakingPhaseDoesNotExist(stakingPhase);
        if (!checkIfStakingPeriodExists(stakingPeriod)) revert StakingPeriodDoesNotExist(stakingPeriod);
    }

    function checkDepositStatus(address userAddress, uint256 depositNumber) public view returns (DepositStatus) {
        TokenDeposit memory targetDeposit = stakerDepositList[userAddress][depositNumber];
        if (targetDeposit.withdrawalDate == 0) {
            return (targetDeposit.stakingEndDate == 0)
                ? DepositStatus.INDEFINITE
                : (
                    (block.timestamp >= targetDeposit.stakingEndDate)
                        ? DepositStatus.READY_TO_CLAIM
                        : DepositStatus.TIME_LEFT
                );
        }
        return (targetDeposit.withdrawalDate < targetDeposit.stakingEndDate)
            ? DepositStatus.WITHDRAWN
            : DepositStatus.CLAIMED;
    }

    function checkActionAvailability(DataType action) public view returns (bool) {
        uint8 enumIndex = uint8(action);
        if (enumIndex > 2) revert InvalidDataType();

        return actionAvailabilityStatuses[action];
    }

    function _checkIfLegitStakeRequest(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount)
        internal
        view
    {
        if (tokenAmount < minimumDeposit) revert InsufficentDeposit(tokenAmount, minimumDeposit);

        if (stakingPhase != currentStakingPhase) revert IncorrectStakingPhase(stakingPhase, currentStakingPhase);
        _checkIfStakingPhasePeriodExists(stakingPhase, stakingPeriod);

        _checkIfTargetReached(stakingPhase, stakingPeriod, tokenAmount);
    }

    // ======================================
    // =             Modifiers              =
    // ======================================
    modifier ifAvailable(DataType action) {
        if (!checkActionAvailability(action)) revert NotOpen(action);
        _;
    }

    modifier ifDepositExists(uint256 depositNumber) {
        _checkDepositExistence(depositNumber);
        _;
    }

    modifier ifLegitStakeRequest(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount) {
        _checkIfLegitStakeRequest(stakingPhase, stakingPeriod, tokenAmount);
        _;
    }

    // ======================================
    // =              Events                =
    // ======================================
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
    event Withdraw(address indexed by, uint256 indexed depositNumber, uint256 stakedAmount);
    event Claim(address indexed by, uint256 indexed depositNumber, uint256 reward);

    event ProvideReward(address indexed by, uint256 tokenAmount);
    event CollectReward(address indexed by, uint256 tokenAmount);

    event UpdatePhasePeriodData(
        PhasePeriodDataType indexed dataType,
        uint256 indexed stakingPhase,
        uint256 indexed stakingPeriod,
        uint256 newValue
    );

    event UpdateMinimumDeposit(uint256 newMinimumDeposit);
    event UpdateActionAvailability(DataType action, bool isOpen);

    event AddStakingPhase(uint256 indexed newStakingPhase);
    event RemoveStakingPhase(uint256 indexed stakingPhase);
    event ChangeStakingPhase(uint256 indexed to);

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
