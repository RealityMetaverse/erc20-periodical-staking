// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ReadFunctions.sol";
import "./WriteFunctions.sol";
import "../../../common/Types.sol";

/// @notice Freeze, unfreeze and seize open deposits.
/// @dev A frozen deposit cannot be claimed or withdrawn (batch claims skip it). Seizing closes a frozen deposit and
///      sends only its principal to the treasury; freezing and seizing never pay out of the reward pool.
///      Batch functions are atomic: any invalid entry reverts the whole batch.
abstract contract EnforcementFunctions is ReadFunctions, WriteFunctions {
    // ======================================
    // =               Freeze               =
    // ======================================
    /// @notice Freeze an open deposit. Admins and the owner.
    function freezeDeposit(address wallet, uint256 depositNumber) external onlyAdmins {
        _freeze(wallet, depositNumber);
    }

    function freezeDeposits(address[] calldata wallets, uint256[] calldata depositNumbers) external onlyAdmins {
        uint256 len = _checkBatchLengths(wallets, depositNumbers);
        for (uint256 i = 0; i < len;) {
            _freeze(wallets[i], depositNumbers[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unfreeze a frozen deposit. Admins and the owner.
    function unfreezeDeposit(address wallet, uint256 depositNumber) external onlyAdmins {
        _unfreeze(wallet, depositNumber);
    }

    function unfreezeDeposits(address[] calldata wallets, uint256[] calldata depositNumbers) external onlyAdmins {
        uint256 len = _checkBatchLengths(wallets, depositNumbers);
        for (uint256 i = 0; i < len;) {
            _unfreeze(wallets[i], depositNumbers[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Whether a deposit is frozen. Reverts DepositDoesNotExist for an unknown deposit.
    function isDepositFrozen(address wallet, uint256 depositNumber) external view returns (bool) {
        _checkDepositExistenceFor(wallet, depositNumber);
        return (stakerDepositList[wallet][depositNumber].flags & FLAG_FROZEN) != 0;
    }

    // ======================================
    // =                Seize               =
    // ======================================
    /// @notice Seize a frozen deposit to the treasury. Owner only.
    /// @dev Only the principal goes to the treasury. A periodical deposit's reserved reward is released back to
    ///      the pool; an indefinite deposit's unpaid accrued reward stays in the pool.
    function seizeDeposit(address wallet, uint256 depositNumber) external nonReentrant onlyContractOwner {
        address to = treasury;
        if (to == address(0)) revert TreasuryNotSet();
        _sendToken(to, _seize(wallet, depositNumber, to));
    }

    function seizeDeposits(address[] calldata wallets, uint256[] calldata depositNumbers)
        external
        nonReentrant
        onlyContractOwner
    {
        address to = treasury;
        if (to == address(0)) revert TreasuryNotSet();
        uint256 len = _checkBatchLengths(wallets, depositNumbers);
        uint256 total = 0;
        for (uint256 i = 0; i < len;) {
            total += _seize(wallets[i], depositNumbers[i], to);
            unchecked {
                ++i;
            }
        }
        if (total != 0) _sendToken(to, total);
    }

    // ======================================
    // =              Internal              =
    // ======================================
    function _checkBatchLengths(address[] calldata wallets, uint256[] calldata depositNumbers)
        private
        pure
        returns (uint256 len)
    {
        len = wallets.length;
        if (len != depositNumbers.length) revert LengthMismatch(len, depositNumbers.length);
    }

    function _freeze(address wallet, uint256 depositNumber) private {
        _checkDepositExistenceFor(wallet, depositNumber);
        PackedDeposit storage d = stakerDepositList[wallet][depositNumber];
        DepositStatus s = _status(d);
        if (s != DepositStatus.TIME_LEFT && s != DepositStatus.READY_TO_CLAIM && s != DepositStatus.INDEFINITE) {
            revert DepositNotOpen(wallet, depositNumber);
        }
        uint8 flags = d.flags;
        if ((flags & FLAG_FROZEN) != 0) revert DepositFrozen(wallet, depositNumber);
        d.flags = flags | FLAG_FROZEN;

        emit FreezeDeposit(wallet, depositNumber, msg.sender);
    }

    function _unfreeze(address wallet, uint256 depositNumber) private {
        _checkDepositExistenceFor(wallet, depositNumber);
        PackedDeposit storage d = stakerDepositList[wallet][depositNumber];
        uint8 flags = d.flags;
        if ((flags & FLAG_FROZEN) == 0) revert DepositNotFrozen(wallet, depositNumber);
        d.flags = flags & ~FLAG_FROZEN;

        emit UnfreezeDeposit(wallet, depositNumber, msg.sender);
    }

    /// @dev Closes a frozen deposit like a principal-only withdrawal (STAKING cells, REWARD_EXPECTED, WITHDRAWAL
    ///      totals, cursor) and returns the principal. Frozen implies open, because
    ///      claim and withdraw are blocked while frozen and seizing replaces the flags with FLAG_SEIZED.
    function _seize(address wallet, uint256 depositNumber, address to) private returns (uint256) {
        _checkDepositExistenceFor(wallet, depositNumber);
        PackedDeposit storage d = stakerDepositList[wallet][depositNumber];
        if ((d.flags & FLAG_FROZEN) == 0) revert DepositNotFrozen(wallet, depositNumber);

        uint256 principal = d.amount;

        // Periodical: release the reward reserved at stake time back to the pool, like an early withdrawal.
        // Indefinite: nothing is reserved and the unpaid accrued reward simply stays in the pool.
        if (_status(d) != DepositStatus.INDEFINITE) {
            uint256 reserved = d.rewardGenerated;
            userDataList[Types.DataType.REWARD_EXPECTED][wallet] -= reserved;
            totalDataList[Types.DataType.REWARD_EXPECTED] -= reserved;
            d.rewardGenerated = 0;
        }

        d.withdrawalDate = SafeCast.toUint40(block.timestamp);
        d.flags = FLAG_SEIZED;

        _updateAllDataAfterAction(Types.DataType.WITHDRAWAL, wallet, d.stakingPhase, d.stakingPeriod, principal, 0);
        _updateActiveDepositStartIndex(wallet);

        emit SeizeDeposit(wallet, depositNumber, to, principal);
        return principal;
    }
}
