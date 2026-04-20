// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessControl.sol";
import "../../interfaces/ILimitController.sol";
import "../../interfaces/IRequirementChecker.sol";
import "../../common/Events.sol";
import "../../common/Types.sol";

abstract contract ComplianceCheck is AccessControl, Events, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;
    using ArrayLibrary for uint256[];

    // ======================================
    // =             Functions              =
    // ======================================
    function getPhasePeriodData(Types.PhasePeriodDataType dataType, uint256 phase, uint256 period)
        public
        view
        returns (uint256)
    {
        return phasePeriodDataList[dataType][phase][period];
    }

    function _checkDepositExistence(uint256 depositNumber) private view {
        if (!(depositNumber < (stakerDepositList[msg.sender].length))) {
            revert DepositDoesNotExist(depositNumber);
        }
    }

    function _checkIfTargetReached(uint256 stakingPhase, uint256 stakingPeriod, uint256 amountToStake) internal view {
        uint256 stakingTarget =
            phasePeriodDataList[Types.PhasePeriodDataType.STAKING_TARGET][stakingPhase][stakingPeriod];
        uint256 totalStaked = phasePeriodDataList[Types.PhasePeriodDataType.STAKED][stakingPhase][stakingPeriod];

        if ((amountToStake + totalStaked) > stakingTarget) {
            revert AmountExceedsTarget(stakingPhase, stakingPeriod, stakingTarget);
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

    function checkActionAvailability(Types.DataType action) public view returns (bool) {
        return actionAvailabilityStatuses[action];
    }

    function _checkIfUserMeetsRequirements(
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        bool ifRevertExpected
    ) internal view returns (bool) {
        if (requirementChecker != address(0)) {
            IRequirementChecker checker = IRequirementChecker(requirementChecker);
            if (!checker.meetsRequirement(userAddress, stakingPhase, stakingPeriod)) {
                if (ifRevertExpected) {
                    uint256 totalWorth = checker.getTotalWorth(userAddress);
                    uint256 requiredWorth = checker.getRequiredWorth(stakingPhase, stakingPeriod);
                    revert RequirementNotMet(requiredWorth, totalWorth);
                } else {
                    return false;
                }
            }
        }
        return true;
    }

    function checkIfUserMeetsRequirements(address userAddress, uint256 stakingPhase, uint256 stakingPeriod)
        public
        view
        returns (bool)
    {
        return _checkIfUserMeetsRequirements(userAddress, stakingPhase, stakingPeriod, false);
    }

    function _checkIfUserExceedsLimit(
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 tokenAmount,
        bool ifRevertExpected
    ) private view returns (bool, uint256) {
        if (limitController != address(0)) {
            ILimitController controller = ILimitController(limitController);
            uint256 remaining = controller.getRemaining(userAddress, stakingPhase, stakingPeriod);
            if (remaining < tokenAmount) {
                if (ifRevertExpected) {
                    revert StakingLimitExceeded(userAddress, stakingPhase, stakingPeriod, tokenAmount, remaining);
                } else {
                    return (true, remaining);
                }
            } else {
                return (false, remaining);
            }
        }

        uint256 stakingTarget =
            getPhasePeriodData(Types.PhasePeriodDataType.STAKING_TARGET, stakingPhase, stakingPeriod);
        uint256 totalStaked = getPhasePeriodData(Types.PhasePeriodDataType.STAKED, stakingPhase, stakingPeriod);
        if (totalStaked >= stakingTarget) {
            return (false, 0);
        }
        return (false, stakingTarget - totalStaked);
    }

    function checkIfUserExceedsLimit(
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 tokenAmount
    ) public view returns (bool, uint256) {
        return _checkIfUserExceedsLimit(userAddress, stakingPhase, stakingPeriod, tokenAmount, false);
    }

    function _checkIfLegitStakeRequest(uint256 stakingPhase, uint256 stakingPeriod, uint256 tokenAmount)
        internal
        view
    {
        // If whitelist is enabled, only whitelisted addresses can stake
        if (whitelistEnabled && !isWhitelisted[msg.sender]) {
            revert NotWhitelisted(msg.sender);
        }

        // If requirement checker is set, check if the sender meets the requirement
        _checkIfUserMeetsRequirements(msg.sender, stakingPhase, stakingPeriod, true);

        if (tokenAmount < minimumDeposit) revert InsufficientDeposit(tokenAmount, minimumDeposit);

        if (stakingPhase != currentStakingPhase) revert IncorrectStakingPhase(stakingPhase, currentStakingPhase);
        _checkIfStakingPhasePeriodExists(stakingPhase, stakingPeriod);

        _checkIfTargetReached(stakingPhase, stakingPeriod, tokenAmount);

        // If staking limit is enabled, call LimitController to check remaining allowance before staking
        _checkIfUserExceedsLimit(msg.sender, stakingPhase, stakingPeriod, tokenAmount, true);
    }

    // ======================================
    // =             Modifiers              =
    // ======================================
    modifier ifAvailable(Types.DataType action) {
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
    // =    Token Management Functions      =
    // ======================================
    function _receiveToken(uint256 tokenAmount) internal {
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), tokenAmount);
    }

    function _sendToken(address toAddress, uint256 tokenAmount) internal {
        STAKING_TOKEN.safeTransfer(toAddress, tokenAmount);
    }
}
