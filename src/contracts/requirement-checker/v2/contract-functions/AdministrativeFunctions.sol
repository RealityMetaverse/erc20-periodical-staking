// SPDX-License-Identifier: BUSL-1.1
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../Storage.sol";

abstract contract AdministrativeFunctions is Storage {
    /// @notice Disabled. Ownership can only move through the two-step transferOwnership / acceptOwnership flow.
    /// @dev Always reverts with RenounceOwnershipDisabled, for every caller.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function setDefaultRequiredWorth(uint256 newDefaultRequiredWorth) external onlyOwner {
        defaultRequiredWorth = newDefaultRequiredWorth;
        emit DefaultRequiredWorthUpdated(newDefaultRequiredWorth);
    }

    /// @notice Set required worth for a specific phase period
    /// @dev 0 does NOT mean "no requirement": it clears the override, so the cell falls back to
    ///      defaultRequiredWorth (see getRequiredWorth).
    ///      THERE IS NO PER-CELL EXEMPTION while defaultRequiredWorth is non-zero. meetsRequirement short-
    ///      circuits to true only when the RESOLVED requirement is 0, and a resolved 0 is unreachable for a
    ///      single cell: storing 0 here just re-exposes the non-zero default. 1 is the smallest reachable
    ///      threshold, and it is a real threshold, not an exemption -- `worth >= 1` still fails for a wallet
    ///      with zero worth. The only way to exempt is to set defaultRequiredWorth to 0 (and leave, or clear,
    ///      the cell's override), which exempts every cell that has no non-zero override.
    /// @param phase The staking phase
    /// @param period The staking period
    /// @param newRequiredWorth The required worth amount (0 clears the override and falls back to
    ///        defaultRequiredWorth; 1 is the lowest non-zero threshold, which a zero-worth wallet still fails)
    function setRequiredWorthPhasePeriod(uint256 phase, uint256 period, uint256 newRequiredWorth) external onlyOwner {
        _setRequiredWorthPhasePeriod(phase, period, newRequiredWorth);
    }

    /// @notice Batch set required worth for multiple phase/period combinations
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @param requiredWorths Array of required worth amounts corresponding to each phase/period combination
    ///        (same semantics as setRequiredWorthPhasePeriod: 0 clears the override and falls back to
    ///        defaultRequiredWorth; 1 is the lowest non-zero threshold, not an exemption -- a zero-worth
    ///        wallet still fails it. Only defaultRequiredWorth == 0 exempts.)
    function setRequiredWorthPhasePeriodBatch(
        uint256[] calldata phases,
        uint256[] calldata periods,
        uint256[] calldata requiredWorths
    ) external onlyOwner {
        if (phases.length != periods.length || phases.length != requiredWorths.length) {
            revert LengthMismatch(
                phases.length, periods.length != phases.length ? periods.length : requiredWorths.length
            );
        }
        for (uint256 i = 0; i < phases.length; i++) {
            _setRequiredWorthPhasePeriod(phases[i], periods[i], requiredWorths[i]);
        }
    }

    function setPoolStakingContracts(address[] calldata newContracts) external onlyOwner {
        _setPoolStakingContracts(newContracts);
    }

    function setPeriodicalStakingContracts(address[] calldata newContracts) external onlyOwner {
        _setPeriodicalStakingContracts(newContracts);
    }

    function setERC1155Configs(address token, uint256[] calldata ids, uint256[] calldata worths) external onlyOwner {
        _setERC1155Configs(token, ids, worths);
    }

    function removeERC1155Contract(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddressProvided();

        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < erc1155Contracts.length; i++) {
            if (erc1155Contracts[i] == token) {
                index = i;
                break;
            }
        }
        if (index == type(uint256).max) revert ERC1155ContractNotFound(token);

        _removeERC1155ContractAt(index);
    }

    /// @notice Update the worthToken used for ERC20 balance measurements and worth denomination.
    /// @dev Changing the worthToken does not rescale existing thresholds, offsets, or ERC1155 per-id worths.
    /// @param newToken The new ERC20 token address (must be non-zero).
    function setWorthToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert ZeroAddressProvided();
        // A codeless address is rejected too: balanceOf would revert on every read, and because
        // meetsRequirementBatch isolates each entry that failure surfaces as a successful all-false batch --
        // indistinguishable to a caller from "nobody qualifies". Catch the misconfiguration at write time.
        if (newToken.code.length == 0) revert NotAContract(newToken);
        worthToken = IERC20(newToken);
        emit WorthTokenUpdated(newToken);
    }

    /// @notice Set the signed ERC20 worth offset for a wallet. Applied to the worthToken balance and clamped at 0.
    /// @param wallet The wallet whose perceived ERC20 balance is being adjusted.
    /// @param offset Signed amount (worth-token units) added to the real balance; may be negative.
    function setErc20Offset(address wallet, int256 offset) external onlyOwner {
        _setErc20Offset(wallet, offset);
    }

    /// @notice Batch set ERC20 worth offsets for multiple wallets.
    /// @param wallets Array of wallet addresses.
    /// @param offsets Array of signed offsets matching wallets by index.
    function setErc20OffsetBatch(address[] calldata wallets, int256[] calldata offsets) external onlyOwner {
        if (wallets.length != offsets.length) revert LengthMismatch(wallets.length, offsets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            _setErc20Offset(wallets[i], offsets[i]);
        }
    }

    /// @notice Set the signed staking worth offset for a wallet on a specific pool staking contract.
    /// @param wallet The wallet whose perceived staking amount is being adjusted.
    /// @param poolStakingContract The pool staking contract whose contribution is being offset.
    /// @param offset Signed amount (worth-token units) added to the real staked total; may be negative.
    function setPoolStakingOffset(address wallet, address poolStakingContract, int256 offset) external onlyOwner {
        _setPoolStakingOffset(wallet, poolStakingContract, offset);
    }

    /// @notice Batch set pool staking offsets across multiple (wallet, poolStakingContract) pairs.
    /// @param wallets Array of wallet addresses.
    /// @param poolStakingContracts_ Array of pool-staking-contract addresses paired by index with wallets.
    /// @param offsets Array of signed offsets.
    function setPoolStakingOffsetBatch(
        address[] calldata wallets,
        address[] calldata poolStakingContracts_,
        int256[] calldata offsets
    ) external onlyOwner {
        uint256 len = wallets.length;
        if (len != poolStakingContracts_.length || len != offsets.length) {
            revert LengthMismatch(len, poolStakingContracts_.length != len ? poolStakingContracts_.length : offsets.length);
        }
        for (uint256 i = 0; i < len; i++) {
            _setPoolStakingOffset(wallets[i], poolStakingContracts_[i], offsets[i]);
        }
    }

    /// @notice Set the signed periodical-staking worth offset for a wallet on a specific periodical staking contract.
    /// @param wallet The wallet whose perceived periodical-staked amount is being adjusted.
    /// @param periodicalStakingContract The periodical staking contract whose contribution is being offset.
    /// @param offset Signed amount (worth-token units) added to the real periodical-staked total; may be negative.
    function setPeriodicalStakingOffset(
        address wallet, address periodicalStakingContract, int256 offset
    ) external onlyOwner {
        _setPeriodicalStakingOffset(wallet, periodicalStakingContract, offset);
    }

    /// @notice Batch set periodical-staking offsets across multiple (wallet, periodicalStakingContract) pairs.
    /// @param wallets Array of wallet addresses.
    /// @param periodicalStakingContracts_ Array of periodical-staking-contract addresses paired by index with wallets.
    /// @param offsets Array of signed offsets.
    function setPeriodicalStakingOffsetBatch(
        address[] calldata wallets,
        address[] calldata periodicalStakingContracts_,
        int256[] calldata offsets
    ) external onlyOwner {
        uint256 len = wallets.length;
        if (len != periodicalStakingContracts_.length || len != offsets.length) {
            revert LengthMismatch(len, periodicalStakingContracts_.length != len ? periodicalStakingContracts_.length : offsets.length);
        }
        for (uint256 i = 0; i < len; i++) {
            _setPeriodicalStakingOffset(wallets[i], periodicalStakingContracts_[i], offsets[i]);
        }
    }

    /// @notice Set the signed ERC1155 count offset for a wallet on a specific (token, id) pair.
    /// @dev The offset is in NFT count units. Clamped at 0 before multiplication by the per-id worth at read time.
    /// @param wallet The wallet whose perceived NFT count is being adjusted.
    /// @param token The ERC1155 contract address.
    /// @param id The token id within that contract.
    /// @param offset Signed count added to the real balance; may be negative.
    function setNftCountOffset(address wallet, address token, uint256 id, int256 offset) external onlyOwner {
        _setNftCountOffset(wallet, token, id, offset);
    }

    /// @notice Batch set ERC1155 count offsets across multiple (wallet, token, id) triples.
    /// @param wallets Array of wallet addresses.
    /// @param tokens Array of ERC1155 contract addresses.
    /// @param ids Array of token ids.
    /// @param offsets Array of signed count offsets.
    function setNftCountOffsetBatch(
        address[] calldata wallets,
        address[] calldata tokens,
        uint256[] calldata ids,
        int256[] calldata offsets
    ) external onlyOwner {
        uint256 len = wallets.length;
        if (len != tokens.length || len != ids.length || len != offsets.length) {
            uint256 actual;
            if (tokens.length != len) actual = tokens.length;
            else if (ids.length != len) actual = ids.length;
            else actual = offsets.length;
            revert LengthMismatch(len, actual);
        }
        for (uint256 i = 0; i < len; i++) {
            _setNftCountOffset(wallets[i], tokens[i], ids[i], offsets[i]);
        }
    }

    // ======================================
    // =         Internal Functions         =
    // ======================================
    /// @dev Shared bound for every offset setter. With |offset| <= type(int128).max the signed ADDITIONS in
    ///      ReadFunctions (`raw + offset`) cannot overflow for any realistic balance.
    ///      It does NOT make the reads revert-proof: `erc1155IdWorth` is uncapped, so a bounded, accepted
    ///      NFT count offset multiplied by a large owner-set id worth still panics 0x11 in totalERC1155Worth
    ///      and getAppliedOffsetsWorth. Single-wallet reads propagate that revert; meetsRequirementBatch
    ///      isolates the entry and reports `false`. Keep id worths in sane units.
    function _checkOffset(int256 offset) private pure {
        if (offset > MAX_ABS_OFFSET || offset < -MAX_ABS_OFFSET) revert OffsetOutOfBounds(offset, MAX_ABS_OFFSET);
    }

    function _setErc20Offset(address wallet, int256 offset) private {
        if (wallet == address(0)) revert ZeroAddressProvided();
        _checkOffset(offset);
        erc20Offset[wallet] = offset;
        emit ERC20OffsetSet(wallet, offset);
    }

    function _setPoolStakingOffset(address wallet, address poolStakingContract, int256 offset) private {
        if (wallet == address(0) || poolStakingContract == address(0)) revert ZeroAddressProvided();
        _checkOffset(offset);
        poolStakingOffset[wallet][poolStakingContract] = offset;
        emit PoolStakingOffsetSet(wallet, poolStakingContract, offset);
    }

    function _setPeriodicalStakingOffset(
        address wallet, address periodicalStakingContract, int256 offset
    ) private {
        if (wallet == address(0) || periodicalStakingContract == address(0)) revert ZeroAddressProvided();
        _checkOffset(offset);
        periodicalStakingOffset[wallet][periodicalStakingContract] = offset;
        emit PeriodicalStakingOffsetSet(wallet, periodicalStakingContract, offset);
    }

    function _setNftCountOffset(address wallet, address token, uint256 id, int256 offset) private {
        if (wallet == address(0) || token == address(0)) revert ZeroAddressProvided();
        _checkOffset(offset);
        nftCountOffset[wallet][token][id] = offset;
        emit NFTCountOffsetSet(wallet, token, id, offset);
    }

    function _setRequiredWorthPhasePeriod(uint256 phase, uint256 period, uint256 requiredWorth) internal {
        bool tracked = _phasePeriodKeyTracked[phase][period];
        if (requiredWorth == 0 && tracked) {
            // Zero-clear on a tracked key — drop the orphan from the enumerable list.
            _phasePeriodKeyTracked[phase][period] = false;
            _removePhasePeriodKey(phase, period);
        } else if (requiredWorth != 0 && !tracked) {
            _phasePeriodKeyTracked[phase][period] = true;
            phasePeriodKeys.push(PhasePeriodKey(phase, period));
        }
        requiredWorthPhasePeriod[phase][period] = requiredWorth;
        emit RequiredPhasePeriodWorthSet(phase, period, requiredWorth);
    }

    /// @dev Internal helper to validate (non-zero, no duplicates) and set pool staking contracts array
    function _setPoolStakingContracts(address[] memory newContracts) internal {
        _validateContractList(newContracts);
        poolStakingContracts = newContracts;
        emit PoolStakingContractsUpdated(newContracts);
    }

    /// @dev Internal helper to validate (non-zero, no duplicates) and set periodical staking contracts array
    function _setPeriodicalStakingContracts(address[] memory newContracts) internal {
        _validateContractList(newContracts);
        periodicalStakingContracts = newContracts;
        emit PeriodicalStakingContractsUpdated(newContracts);
    }

    /// @dev Reverts on a zero address or on an address listed twice (a duplicate would be summed once per
    ///      occurrence by the worth reads). O(n^2) pairwise scan; these lists are small and owner-controlled.
    function _validateContractList(address[] memory list) private pure {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == address(0)) revert ZeroAddressProvided();
            for (uint256 j = 0; j < i; j++) {
                if (list[j] == list[i]) revert DuplicateAddress(list[i]);
            }
        }
    }

    /// @dev Shared write path for ERC1155 config. Validates inputs, clears stale worth entries
    ///      from the previous tracked-ids list so ids dropped by this call do not leave orphaned
    ///      non-zero slots, adds the token to erc1155Contracts on first registration, stores the
    ///      new ids and worths, and emits ERC1155ConfigUpdated. Rejects an id listed twice: it would be
    ///      double counted at read time, with the last worth winning for both entries (O(n^2) scan; id lists
    ///      are small and owner-controlled).
    function _setERC1155Configs(address token, uint256[] memory ids, uint256[] memory worths) internal {
        if (token == address(0)) revert ZeroAddressProvided();
        if (ids.length == 0) revert EmptyIdsArray();
        if (ids.length != worths.length) revert LengthMismatch(ids.length, worths.length);
        for (uint256 i = 1; i < ids.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (ids[j] == ids[i]) revert DuplicateId(ids[i]);
            }
        }

        uint256[] memory previousIds = erc1155TrackedIds[token];
        for (uint256 j = 0; j < previousIds.length; j++) {
            delete erc1155IdWorth[token][previousIds[j]];
        }

        if (previousIds.length == 0) {
            erc1155Contracts.push(token);
        }
        erc1155TrackedIds[token] = ids;
        for (uint256 i = 0; i < ids.length; i++) {
            erc1155IdWorth[token][ids[i]] = worths[i];
        }
        emit ERC1155ConfigUpdated(token, ids, worths);
    }

    /// @dev Drops the ERC1155 contract at `index`: clears every tracked id's worth, the tracked-ids list, and
    ///      swap-with-last + pops it out of erc1155Contracts. Emits ERC1155ContractRemoved.
    function _removeERC1155ContractAt(uint256 index) private {
        address token = erc1155Contracts[index];

        uint256[] memory trackedIds = erc1155TrackedIds[token];
        for (uint256 i = 0; i < trackedIds.length; i++) {
            delete erc1155IdWorth[token][trackedIds[i]];
        }
        delete erc1155TrackedIds[token];

        erc1155Contracts[index] = erc1155Contracts[erc1155Contracts.length - 1];
        erc1155Contracts.pop();

        emit ERC1155ContractRemoved(token);
    }

    /// @dev Removes every registered ERC1155 contract (same per-contract cleanup and event as
    ///      removeERC1155Contract). Used by cloneConfigFrom so the clone mirrors its source exactly.
    function _clearERC1155Configs() internal {
        for (uint256 i = erc1155Contracts.length; i > 0; i--) {
            _removeERC1155ContractAt(i - 1);
        }
    }

    /// @dev Swap-with-last + pop to drop a (phase, period) pair from the enumerable index.
    ///      Linear search by pair; list size should stay small in practice.
    function _removePhasePeriodKey(uint256 phase, uint256 period) private {
        uint256 len = phasePeriodKeys.length;
        for (uint256 i = 0; i < len; i++) {
            if (phasePeriodKeys[i].phase == phase && phasePeriodKeys[i].period == period) {
                phasePeriodKeys[i] = phasePeriodKeys[len - 1];
                phasePeriodKeys.pop();
                return;
            }
        }
    }
}
