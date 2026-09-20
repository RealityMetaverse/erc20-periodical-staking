// SPDX-License-Identifier: BUSL-1.1
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./CloneFunctions.sol";
import "../../../../interfaces/IStakingContract.sol";
import "../../../../interfaces/IPeriodicalStakingContract.sol";

/// @dev UNBOUNDED VIEW LOOPS: every worth read below iterates poolStakingContracts (x each contract's pool
///      count), periodicalStakingContracts, and erc1155Contracts (x each contract's tracked ids), making one
///      or more external calls per entry; the *Batch reads multiply that by the batch length. None of these
///      lists is capped on-chain. Their sizes are owner-controlled and MUST stay small if any on-chain
///      consumer ever calls these functions inside a transaction, otherwise that consumer can run out of gas.
///      Off-chain eth_call consumers are only limited by the node's call gas cap.
/// @dev SIGNED MATH: raw uint256 amounts are converted with SafeCast.toInt256 before an offset is applied,
///      so an absurd value (>= 2^255) returned by a configured contract reverts with
///      SafeCastOverflowedUintToInt instead of wrapping negative and silently clamping to 0. Offsets are
///      bounded to +/- MAX_ABS_OFFSET by the setters, so the ADDITION `raw + offset` itself cannot overflow
///      for any realistic balance. The raw* reads never cast and are unaffected.
/// @dev THESE READS CAN REVERT, and a bounded offset is not enough to prevent it. `erc1155IdWorth` is NOT
///      capped, so `adjustedCount * idWorth` in totalERC1155Worth / rawTotalERC1155Worth /
///      getAppliedOffsetsWorth can still panic 0x11 with an accepted offset and a large owner-set id worth;
///      an ERC1155 balance at or above 2^255 (any wallet's own doing on an openly mintable token) trips
///      SafeCast; and any configured external contract can revert on its own. Single-wallet reads
///      (meetsRequirement, getTotalWorth, worthBreakdown, ...) surface that revert to the caller by design.
///      meetsRequirementBatch is the one exception: it isolates each entry and reports a failing read as
///      `false`. Keep id worths and thresholds in sane units and the arithmetic never comes close.
abstract contract ReadFunctions is CloneFunctions {
    // ======================================
    // =         Public Functions           =
    // ======================================
    function poolStakingContractCount() external view returns (uint256) {
        return poolStakingContracts.length;
    }

    function periodicalStakingContractCount() external view returns (uint256) {
        return periodicalStakingContracts.length;
    }

    function erc1155ContractCount() external view returns (uint256) {
        return erc1155Contracts.length;
    }

    /// @notice Number of (phase, period) pairs that have ever been assigned a non-zero required worth.
    /// @return Length of the phasePeriodKeys array.
    function phasePeriodKeysCount() external view returns (uint256) {
        return phasePeriodKeys.length;
    }

    function meetsDefaultRequirement(address user) public view returns (bool) {
        return getTotalWorth(user) >= defaultRequiredWorth;
    }

    /// @notice Returns whether a user meets the worth requirement for a phase period
    /// @dev Worth is a SPOT read of current balances (see getTotalWorth) and is NOT sybil-resistant: the same
    ///      assets can be moved between wallets between two checks and qualify each wallet in turn. Consumers
    ///      (the backend) must apply their own holding-period / snapshot controls.
    /// @param user The user address
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return Whether the user meets the requirement
    function meetsRequirement(address user, uint256 phase, uint256 period) public view returns (bool) {
        uint256 required = getRequiredWorth(phase, period);
        if (required == 0) return true;
        return getTotalWorth(user) >= required;
    }

    /// @notice Batch check whether multiple (user, phase, period) combinations meet the worth requirement
    /// @dev PER-ENTRY ISOLATED: each entry is evaluated through a staticcall to this contract's own
    ///      `meetsRequirement`, wrapped in try/catch. An entry whose worth read reverts -- a configured
    ///      contract reverting, an absurd balance tripping SafeCastOverflowedUintToInt, or a
    ///      `count * idWorth` overflow panicking -- is reported as `false` (does NOT meet the requirement)
    ///      instead of taking the whole batch down with it. That matters because an ERC1155 with open
    ///      minting lets any unprivileged wallet give itself a balance that reverts the read, which would
    ///      otherwise brick every batch that wallet appears in. `false` is the safe direction: a wallet is
    ///      never admitted because its read failed. Single-wallet `meetsRequirement` / `getTotalWorth` still
    ///      revert, so an operator debugging one wallet sees the real reason.
    ///      Only the length check reverts the whole call. Cost grows with batch length x configured list
    ///      sizes (see the contract-level note on unbounded view loops), plus one staticcall per entry.
    /// @param users Array of user addresses
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return results Array of booleans indicating whether each combination meets the requirement
    function meetsRequirementBatch(address[] calldata users, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (bool[] memory results)
    {
        uint256 len = users.length;
        if (len != phases.length || len != periods.length) {
            revert LengthMismatch(len, phases.length != len ? phases.length : periods.length);
        }
        results = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            // Self-staticcall so one bad entry's revert is caught instead of aborting the batch.
            try this.meetsRequirement(users[i], phases[i], periods[i]) returns (bool ok) {
                results[i] = ok;
            } catch {
                results[i] = false;
            }
        }
    }

    /// @notice Returns the aggregated worth of a user across all tracked sources for a phase period
    /// @dev SPOT balance read at the current block — no snapshot, no holding period. It is NOT
    ///      sybil-resistant: worthToken balances and ERC1155 NFTs can be moved between wallets between
    ///      checks, so the same assets can be counted for several wallets sequentially. Consumers (the backend) must apply their own holding-period / snapshot controls.
    ///      Iterates owner-controlled, uncapped lists (see the contract-level note on unbounded view loops).
    /// @param user The user address
    /// @return The total worth
    function getTotalWorth(address user) public view returns (uint256) {
        (uint256 erc20Balance, uint256 poolStakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth) =
            worthBreakdown(user);
        return erc20Balance + poolStakingWorth + periodicalStakingWorth + nftWorth;
    }

    /// @notice Returns the wallet's total worth excluding ERC1155 NFT contribution.
    /// @dev Walks only the ERC20, staking, and periodical branches — never iterates ERC1155
    ///      contracts. Offsets are applied to each source per the per-entity clamp rules.
    /// @param user The user address.
    /// @return Adjusted token worth (worth-token units, NFTs excluded).
    function getTokenWorth(address user) public view returns (uint256) {
        int256 adjErc20 = SafeCast.toInt256(worthToken.balanceOf(user)) + erc20Offset[user];
        uint256 erc20Balance = adjErc20 > 0 ? uint256(adjErc20) : 0;
        return erc20Balance + totalPoolStaked(user) + totalPeriodicalStaked(user);
    }

    /// @notice Get the required worth for a phase period
    /// @param phase The staking phase
    /// @param period The staking period
    /// @return The required worth amount
    /// @dev Returns the phase/period specific requirement if set (non-zero), otherwise returns the default requiredWorth
    function getRequiredWorth(uint256 phase, uint256 period) public view returns (uint256) {
        uint256 phasePeriodRequired = requiredWorthPhasePeriod[phase][period];
        return phasePeriodRequired != 0 ? phasePeriodRequired : defaultRequiredWorth;
    }

    /// @notice Batch get required worth for multiple phase/period combinations
    /// @param phases Array of staking phases
    /// @param periods Array of staking periods
    /// @return requiredWorths Array of required worth amounts corresponding to each phase/period combination
    function getRequiredWorthBatch(uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (uint256[] memory requiredWorths)
    {
        uint256 len = phases.length;
        if (len != periods.length) revert LengthMismatch(len, periods.length);
        requiredWorths = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            requiredWorths[i] = getRequiredWorth(phases[i], periods[i]);
        }
    }

    /// @notice Returns a breakdown of the user's worth across sources
    function worthBreakdown(address user)
        public
        view
        returns (uint256 erc20Balance, uint256 poolStakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth)
    {
        poolStakingWorth = totalPoolStaked(user);
        periodicalStakingWorth = totalPeriodicalStaked(user);
        int256 adjErc20 = SafeCast.toInt256(worthToken.balanceOf(user)) + erc20Offset[user];
        erc20Balance = adjErc20 > 0 ? uint256(adjErc20) : 0;
        nftWorth = totalERC1155Worth(user);
    }

    /// @notice Effective staked total across all pool-based staking contracts, per-contract offset applied
    ///         and clamped at 0.
    /// @dev Unbounded: loops poolStakingContracts x each contract's checkPoolCount(), one external call per
    ///      pool. Both sizes are owner-controlled (see the contract-level note).
    function totalPoolStaked(address user) public view returns (uint256 total) {
        uint256 contractsLength = poolStakingContracts.length;
        for (uint256 i = 0; i < contractsLength; i++) {
            address sc = poolStakingContracts[i];
            IStakingContract staking = IStakingContract(sc);
            uint256 poolCount = staking.checkPoolCount();
            uint256 rawContract;
            for (uint256 poolId = 0; poolId < poolCount; poolId++) {
                rawContract += staking.checkStakedAmountBy(user, poolId);
            }
            int256 adj = SafeCast.toInt256(rawContract) + poolStakingOffset[user][sc];
            if (adj > 0) total += uint256(adj);
        }
    }

    /// @notice Effective periodical-staked total, per-contract offset applied and clamped at 0.
    /// @dev Unbounded: one external call per entry of the owner-controlled periodicalStakingContracts list.
    function totalPeriodicalStaked(address user) public view returns (uint256 total) {
        uint256 contractsLength = periodicalStakingContracts.length;
        uint8 dataTypeStaking = 0;
        for (uint256 i = 0; i < contractsLength; i++) {
            address pc = periodicalStakingContracts[i];
            uint256 raw = IPeriodicalStakingContract(pc).userDataList(dataTypeStaking, user);
            int256 adj = SafeCast.toInt256(raw) + periodicalStakingOffset[user][pc];
            if (adj > 0) total += uint256(adj);
        }
    }

    /// @notice Total effective staked amount across both pool-based and periodical staking, with offsets applied.
    /// @param user The user address.
    /// @return Sum of totalPoolStaked(user) + totalPeriodicalStaked(user).
    function totalStaked(address user) public view returns (uint256) {
        return totalPoolStaked(user) + totalPeriodicalStaked(user);
    }

    /// @notice Effective ERC1155 worth: per (contract, id) the count offset is applied, clamped at 0, then
    ///         multiplied by the id's worth.
    /// @dev Unbounded: one balanceOfBatch per entry of the owner-controlled erc1155Contracts list, sized by
    ///      that contract's tracked ids (also owner-controlled).
    function totalERC1155Worth(address user) public view returns (uint256 total) {
        uint256 len = erc1155Contracts.length;
        for (uint256 i = 0; i < len; i++) {
            address token = erc1155Contracts[i];
            uint256[] memory ids = erc1155TrackedIds[token];
            uint256 idsLen = ids.length;
            if (idsLen == 0) continue;

            address[] memory owners = new address[](idsLen);
            for (uint256 j = 0; j < idsLen; j++) {
                owners[j] = user;
            }
            uint256[] memory balances = IERC1155(token).balanceOfBatch(owners, ids);
            for (uint256 j = 0; j < idsLen; j++) {
                int256 adj = SafeCast.toInt256(balances[j]) + nftCountOffset[user][token][ids[j]];
                if (adj > 0) {
                    total += uint256(adj) * erc1155IdWorth[token][ids[j]];
                }
            }
        }
    }

    /// @notice Returns the wallet's total worth without applying any admin offsets.
    /// @param user The user address.
    /// @return The raw total worth (worth-token units).
    function getRawTotalWorth(address user) public view returns (uint256) {
        (uint256 erc20Balance, uint256 poolStakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth) =
            rawWorthBreakdown(user);
        return erc20Balance + poolStakingWorth + periodicalStakingWorth + nftWorth;
    }

    /// @notice Returns the wallet's raw total worth excluding ERC1155 NFT contribution.
    /// @dev Ignores all admin offsets and never iterates ERC1155 contracts. Useful for
    ///      reconciling on-chain reality vs. adjusted values.
    /// @param user The user address.
    /// @return Raw token worth (worth-token units, NFTs excluded).
    function getRawTokenWorth(address user) public view returns (uint256) {
        return worthToken.balanceOf(user) + rawTotalPoolStaked(user) + rawTotalPeriodicalStaked(user);
    }

    /// @notice Per-source breakdown of the wallet's raw worth (ignoring all admin offsets).
    /// @param user The user address.
    /// @return erc20Balance Raw ERC20 worthToken balance.
    /// @return poolStakingWorth Raw total staked across all pool-based staking contracts.
    /// @return periodicalStakingWorth Raw total staked across all periodical staking contracts.
    /// @return nftWorth Raw ERC1155 worth across all tracked (contract, id) pairs.
    function rawWorthBreakdown(address user)
        public
        view
        returns (uint256 erc20Balance, uint256 poolStakingWorth, uint256 periodicalStakingWorth, uint256 nftWorth)
    {
        poolStakingWorth = rawTotalPoolStaked(user);
        periodicalStakingWorth = rawTotalPeriodicalStaked(user);
        erc20Balance = worthToken.balanceOf(user);
        nftWorth = rawTotalERC1155Worth(user);
    }

    /// @notice Raw staked total across all pool-based staking contracts (ignores offsets).
    /// @param user The user address.
    /// @return total Sum of staked amounts across every pool of every staking contract.
    function rawTotalPoolStaked(address user) public view returns (uint256 total) {
        uint256 contractsLength = poolStakingContracts.length;
        for (uint256 i = 0; i < contractsLength; i++) {
            address sc = poolStakingContracts[i];
            IStakingContract staking = IStakingContract(sc);
            uint256 poolCount = staking.checkPoolCount();
            for (uint256 poolId = 0; poolId < poolCount; poolId++) {
                total += staking.checkStakedAmountBy(user, poolId);
            }
        }
    }

    /// @notice Raw periodical-staked total across all periodical staking contracts (ignores offsets).
    /// @param user The user address.
    /// @return total Sum of `userDataList(STAKING, user)` across every periodical staking contract.
    function rawTotalPeriodicalStaked(address user) public view returns (uint256 total) {
        uint256 contractsLength = periodicalStakingContracts.length;
        uint8 dataTypeStaking = 0;
        for (uint256 i = 0; i < contractsLength; i++) {
            total += IPeriodicalStakingContract(periodicalStakingContracts[i]).userDataList(dataTypeStaking, user);
        }
    }

    /// @notice Total raw staked amount across both pool-based and periodical staking (ignores offsets).
    /// @param user The user address.
    /// @return Sum of rawTotalPoolStaked(user) + rawTotalPeriodicalStaked(user).
    function rawTotalStaked(address user) public view returns (uint256) {
        return rawTotalPoolStaked(user) + rawTotalPeriodicalStaked(user);
    }

    /// @notice Raw ERC1155 worth contribution across all tracked (contract, id) pairs (ignores offsets).
    /// @param user The user address.
    /// @return total Sum of `balance * idWorth` over every tracked pair.
    function rawTotalERC1155Worth(address user) public view returns (uint256 total) {
        uint256 len = erc1155Contracts.length;
        for (uint256 i = 0; i < len; i++) {
            address token = erc1155Contracts[i];
            uint256[] memory ids = erc1155TrackedIds[token];
            uint256 idsLen = ids.length;
            if (idsLen == 0) continue;

            address[] memory owners = new address[](idsLen);
            for (uint256 j = 0; j < idsLen; j++) {
                owners[j] = user;
            }
            uint256[] memory balances = IERC1155(token).balanceOfBatch(owners, ids);
            for (uint256 j = 0; j < idsLen; j++) {
                total += balances[j] * erc1155IdWorth[token][ids[j]];
            }
        }
    }

    /// @notice Net admin-offset delta actually applied to the wallet's total worth, after per-source clamping.
    /// @dev Walks every source (ERC20, staking, periodical staking, ERC1155) exactly once and
    ///      accumulates the signed per-entity delta (`adjusted - raw`). Positive means net boost;
    ///      negative means net penalty. Reflects clamping: if a negative offset was large enough
    ///      to clamp a source to 0, the delta for that entity is `-raw`, not the raw offset value.
    /// @param user The user address.
    /// @return delta The signed delta in worth-token units.
    function getAppliedOffsetsWorth(address user) public view returns (int256 delta) {
        // ERC20
        {
            int256 raw = SafeCast.toInt256(worthToken.balanceOf(user));
            int256 adj = raw + erc20Offset[user];
            if (adj < 0) adj = 0;
            delta += adj - raw;
        }

        // Staking contracts (signed delta per contract, clamped at 0 before diffing)
        uint256 n = poolStakingContracts.length;
        for (uint256 i = 0; i < n; i++) {
            address sc = poolStakingContracts[i];
            IStakingContract staking = IStakingContract(sc);
            uint256 poolCount = staking.checkPoolCount();
            uint256 rawC;
            for (uint256 p = 0; p < poolCount; p++) {
                rawC += staking.checkStakedAmountBy(user, p);
            }
            int256 rawCSigned = SafeCast.toInt256(rawC);
            int256 adjC = rawCSigned + poolStakingOffset[user][sc];
            if (adjC < 0) adjC = 0;
            delta += adjC - rawCSigned;
        }

        // Periodical staking contracts
        n = periodicalStakingContracts.length;
        uint8 dataTypeStaking = 0;
        for (uint256 i = 0; i < n; i++) {
            address pc = periodicalStakingContracts[i];
            int256 rawP = SafeCast.toInt256(IPeriodicalStakingContract(pc).userDataList(dataTypeStaking, user));
            int256 adjP = rawP + periodicalStakingOffset[user][pc];
            if (adjP < 0) adjP = 0;
            delta += adjP - rawP;
        }

        // ERC1155: delta per (token, id) is (adjCount - rawCount) * idWorth, with adjCount clamped at 0
        n = erc1155Contracts.length;
        for (uint256 i = 0; i < n; i++) {
            address token = erc1155Contracts[i];
            uint256[] memory ids = erc1155TrackedIds[token];
            uint256 idsLen = ids.length;
            if (idsLen == 0) continue;
            address[] memory owners = new address[](idsLen);
            for (uint256 j = 0; j < idsLen; j++) {
                owners[j] = user;
            }
            uint256[] memory balances = IERC1155(token).balanceOfBatch(owners, ids);
            for (uint256 j = 0; j < idsLen; j++) {
                uint256 idWorth = erc1155IdWorth[token][ids[j]];
                if (idWorth == 0) continue;
                int256 rawCount = SafeCast.toInt256(balances[j]);
                int256 adjCount = rawCount + nftCountOffset[user][token][ids[j]];
                if (adjCount < 0) adjCount = 0;
                delta += (adjCount - rawCount) * SafeCast.toInt256(idWorth);
            }
        }
    }
}
