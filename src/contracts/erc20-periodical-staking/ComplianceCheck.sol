// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessControl.sol";
import "../../interfaces/ILimitController.sol";
import "../../common/Events.sol";
import "../../common/Types.sol";

abstract contract ComplianceCheck is AccessControl, Events, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20Metadata;
    using ArrayLibrary for uint256[];

    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimitTotal,uint256 extraLimitPerCell,uint256 issuedAt,uint256 validUntil,uint256 epoch,uint256 nonce)"
    );

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

    /// @notice EIP-712 digest the voucher signer must sign for `v`.
    function getVoucherDigest(Types.StakeVoucher calldata v) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH,
                    v.wallet,
                    v.phase,
                    v.period,
                    v.extraApyBps,
                    v.extraLimitTotal,
                    v.extraLimitPerCell,
                    v.issuedAt,
                    v.validUntil,
                    v.epoch,
                    v.nonce
                )
            )
        );
    }

    function _checkDepositExistence(uint256 depositNumber) private view {
        _checkDepositExistenceFor(msg.sender, depositNumber);
    }

    /// @dev Reverts with DepositDoesNotExist instead of an opaque out-of-bounds panic.
    function _checkDepositExistenceFor(address userAddress, uint256 depositNumber) internal view {
        if (depositNumber >= stakerDepositList[userAddress].length) {
            revert DepositDoesNotExist(depositNumber);
        }
    }

    /// @notice Reward pool amount not committed to open periodical deposits (0 when the pool is short).
    function getCollectableReward() public view returns (uint256) {
        uint256 reserved = totalDataList[Types.DataType.REWARD_EXPECTED];
        return rewardPool > reserved ? rewardPool - reserved : 0;
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

    /// @dev Status of an existing deposit. A seized deposit is closed regardless of its dates.
    function _status(PackedDeposit storage d) internal view returns (DepositStatus) {
        if ((d.flags & FLAG_SEIZED) != 0) return DepositStatus.SEIZED;
        uint256 endDate = d.stakingEndDate;
        uint256 withdrawalDate = d.withdrawalDate;
        if (withdrawalDate == 0) {
            if (endDate == 0) return DepositStatus.INDEFINITE;
            return block.timestamp >= endDate ? DepositStatus.READY_TO_CLAIM : DepositStatus.TIME_LEFT;
        }
        return withdrawalDate < endDate ? DepositStatus.WITHDRAWN : DepositStatus.CLAIMED;
    }

    function checkDepositStatus(address userAddress, uint256 depositNumber) public view returns (DepositStatus) {
        _checkDepositExistenceFor(userAddress, depositNumber);
        return _status(stakerDepositList[userAddress][depositNumber]);
    }

    /// @notice Whether STAKING / WITHDRAWAL / CLAIM is open; false for any other data type.
    function checkActionAvailability(Types.DataType action) public view returns (bool) {
        if (action == Types.DataType.STAKING) return stakingOpen;
        if (action == Types.DataType.WITHDRAWAL) return withdrawalOpen;
        if (action == Types.DataType.CLAIM) return claimOpen;
        return false;
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

    // ======================================
    // =    Token Management Functions      =
    // ======================================
    /// @dev Strict accounting: the balance delta must equal tokenAmount exactly.
    ///      Fee-on-transfer and rebasing tokens are unsupported by design.
    function _receiveToken(uint256 tokenAmount) internal {
        uint256 balanceBefore = STAKING_TOKEN.balanceOf(address(this));
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 received = STAKING_TOKEN.balanceOf(address(this)) - balanceBefore;
        if (received != tokenAmount) revert UnexpectedTokenAmount(tokenAmount, received);
    }

    function _sendToken(address toAddress, uint256 tokenAmount) internal {
        STAKING_TOKEN.safeTransfer(toAddress, tokenAmount);
    }
}
