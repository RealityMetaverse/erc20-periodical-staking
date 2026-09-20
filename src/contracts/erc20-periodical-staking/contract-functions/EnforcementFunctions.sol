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
    /// @dev Send freezes through a PRIVATE relay / private mempool. A freeze seen in the public mempool can be
    ///      front-run by its target with withdrawDeposit or claimDeposit, and the freeze then reverts
    ///      DepositNotOpen. The same applies to the batch form.
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

    /// @notice Unfreeze a frozen deposit. Owner only.
    /// @dev Freezing is onlyAdmins, unfreezing is not: an unfreeze hands the funds back to the wallet, and one
    ///      landed by any single admin just before the owner's seize would make the seize revert
    ///      DepositNotFrozen while the target withdraws. Releasing a hold is the owner's decision, like seize.
    function unfreezeDeposit(address wallet, uint256 depositNumber) external onlyContractOwner {
        _unfreeze(wallet, depositNumber);
    }

    /// @notice Batch form of unfreezeDeposit. Owner only.
    function unfreezeDeposits(address[] calldata wallets, uint256[] calldata depositNumbers)
        external
        onlyContractOwner
    {
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
    // =            Wallet Block            =
    // ======================================
    /// @notice Bar a wallet from opening new stakes, or restore it. Admins and the owner.
    /// @dev Stakes ONLY. A blocked wallet keeps every exit: withdraw, withdrawDepositPartial, claim, claimAll,
    ///      claimRange all work exactly as before, and its open deposits keep accruing. A block must never trap
    ///      funds -- if you are here to "tighten" it into a lock, that is a different feature with a different
    ///      risk profile, and freeze/seize already cover holding a specific deposit.
    ///      onlyAdmins, matching freeze rather than seize: a block is reversible and takes nobody's money, and
    ///      it is a security response where waiting on the owner key may be too slow. Seize moves funds, so it
    ///      stays owner-only.
    ///      A block stops ONE KNOWN wallet, and holds even when a voucher for it was issued outside the
    ///      backend's blocklist. It does NOT contain a leaked voucher SIGNING KEY: the key holder signs for a
    ///      fresh wallet nobody has blocked yet. The levers for a key compromise are closeStaking (any admin),
    ///      then bumpVoucherEpoch and setVoucherSigner (owner).
    function setWalletBlocked(address wallet, bool blocked) external onlyAdmins {
        _setWalletBlocked(wallet, blocked);
    }

    /// @notice Block or unblock many wallets in one transaction. Admins and the owner.
    /// @dev All wallets get the same `blocked` value. Unbounded loop: the caller chooses the batch size. An
    ///      empty batch reverts EmptyBatch.
    function setWalletsBlocked(address[] calldata wallets, bool blocked) external onlyAdmins {
        uint256 len = wallets.length;
        if (len == 0) revert EmptyBatch();
        for (uint256 i = 0; i < len;) {
            _setWalletBlocked(wallets[i], blocked);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Writes and emits unconditionally, so an ops replay is idempotent and always leaves a log line.
    function _setWalletBlocked(address wallet, bool blocked) private {
        if (wallet == address(0)) revert ZeroAddressProvided();
        walletBlocked[wallet] = blocked;
        emit UpdateWalletBlocked(wallet, blocked);
    }

    // ======================================
    // =                Seize               =
    // ======================================
    /// @notice Seize a frozen deposit to the treasury. Owner only.
    /// @dev Only the principal goes to the treasury. A periodical deposit's reserved reward is released back to
    ///      the pool; an indefinite deposit's unpaid accrued reward stays in the pool.
    ///      A seize is booked like a principal-only withdrawal, so it raises the wallet's and the total
    ///      WITHDRAWAL counters although the wallet received nothing: indexers must tell a seize from a
    ///      withdrawal by the SeizeDeposit event / DepositStatus.SEIZED, never by those counters.
    ///      If the token refuses to pay the treasury (blacklist), the seize reverts until setTreasury changes it.
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
        uint256 len = _checkBatchLengths(wallets, depositNumbers);
        address to = treasury;
        if (to == address(0)) revert TreasuryNotSet();
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
    /// @dev Shared by the freeze / unfreeze / seize batches. Mismatched lengths are reported first, so a caller
    ///      that passed no wallets but some deposit numbers is told the real problem; a genuinely empty batch
    ///      then reverts EmptyBatch rather than succeeding without a trace, since it is always an ops mistake
    ///      (a filter that matched nothing).
    function _checkBatchLengths(address[] calldata wallets, uint256[] calldata depositNumbers)
        private
        pure
        returns (uint256 len)
    {
        len = wallets.length;
        if (len != depositNumbers.length) revert LengthMismatch(len, depositNumbers.length);
        if (len == 0) revert EmptyBatch();
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
    ///      ACCOUNTING: the principal is booked under the wallet's and the total WITHDRAWAL counters, the same
    ///      ones a real withdrawal uses, although the treasury -- not the wallet -- received it. Indexers and
    ///      reports must key on the SeizeDeposit event / FLAG_SEIZED (DepositStatus.SEIZED), not on WITHDRAWAL.
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
        // Seizing closes the deposit, so its bonus returns to the wallet's budget. `wallet`, not msg.sender:
        // the caller here is the owner, not the staker.
        _releaseBonus(wallet, depositNumber, d.stakingPhase, d.stakingPeriod);
        _updateActiveDepositStartIndex(wallet);

        emit SeizeDeposit(wallet, depositNumber, to, principal);
        return principal;
    }
}
