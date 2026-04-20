// SPDX-License-Identifier: BUSL-1.1
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./AdministrativeFunctions.sol";
import {IRequirementCheckerV1Config} from "../V1Config.sol";

abstract contract CloneFunctions is AdministrativeFunctions {
    /// @notice Clone on-chain enumerable config from a V1 RequirementChecker instance.
    /// @dev Copies worthToken, staking arrays, periodical staking arrays, ERC1155 config
    ///      (contracts, tracked ids, per-id worths), and defaultRequiredWorth. Does NOT copy
    ///      phase/period requirements (use clonePhasePeriodRequirements for that). Overwrites
    ///      V2's current state — safe to call repeatedly.
    /// @param v1 The V1 RequirementChecker address to clone from.
    function cloneConfigFrom(address v1) external onlyOwner {
        if (v1 == address(0)) revert ZeroAddressProvided();

        IRequirementCheckerV1Config src = IRequirementCheckerV1Config(v1);

        // 1. Worth token
        address newToken = src.worthToken();
        worthToken = IERC20(newToken);
        emit WorthTokenUpdated(newToken);

        // 2. Staking contracts
        uint256 nStaking = src.stakingContractCount();
        address[] memory staking = new address[](nStaking);
        for (uint256 i = 0; i < nStaking; i++) {
            staking[i] = src.stakingContracts(i);
        }
        _setPoolStakingContracts(staking);

        // 3. Periodical staking contracts
        uint256 nPeriodical = src.periodicalStakingContractCount();
        address[] memory periodical = new address[](nPeriodical);
        for (uint256 i = 0; i < nPeriodical; i++) {
            periodical[i] = src.periodicalStakingContracts(i);
        }
        _setPeriodicalStakingContracts(periodical);

        // 4. ERC1155 config: for each source contract, count its tracked ids by probing the
        //    array getter until it reverts (V1 exposes no length accessor), then allocate an
        //    exact-size ids/worths pair and delegate to _setERC1155Configs.
        uint256 nErc1155 = src.erc1155ContractCount();
        for (uint256 i = 0; i < nErc1155; i++) {
            address tokenAddr = src.erc1155Contracts(i);

            uint256 idCount;
            while (true) {
                try src.erc1155TrackedIds(tokenAddr, idCount) returns (uint256) {
                    idCount++;
                } catch {
                    break;
                }
            }
            if (idCount == 0) continue;

            uint256[] memory ids = new uint256[](idCount);
            uint256[] memory worths = new uint256[](idCount);
            for (uint256 j = 0; j < idCount; j++) {
                ids[j] = src.erc1155TrackedIds(tokenAddr, j);
                worths[j] = src.erc1155IdWorth(tokenAddr, ids[j]);
            }
            _setERC1155Configs(tokenAddr, ids, worths);
        }

        // 5. Default required worth
        uint256 dflt = src.defaultRequiredWorth();
        defaultRequiredWorth = dflt;
        emit DefaultRequiredWorthUpdated(dflt);

        emit ConfigClonedFrom(v1);
    }

    /// @notice Copy a specific set of (phase, period) requirement thresholds from a V1 RequirementChecker.
    /// @dev V1's requiredWorthPhasePeriod mapping is not enumerable on-chain; admin must supply the
    ///      (phase, period) pairs off-chain (typically by scanning V1's RequiredPhasePeriodWorthSet event log).
    ///      Each pair triggers a RequiredPhasePeriodWorthSet emission mirroring the per-pair setter.
    /// @param v1 The V1 RequirementChecker address to clone from.
    /// @param phases Array of phases.
    /// @param periods Array of periods paired by index with phases.
    function clonePhasePeriodRequirements(
        address v1,
        uint256[] calldata phases,
        uint256[] calldata periods
    ) external onlyOwner {
        if (v1 == address(0)) revert ZeroAddressProvided();
        if (phases.length != periods.length) revert LengthMismatch(phases.length, periods.length);

        IRequirementCheckerV1Config src = IRequirementCheckerV1Config(v1);
        for (uint256 i = 0; i < phases.length; i++) {
            uint256 reqWorth = src.requiredWorthPhasePeriod(phases[i], periods[i]);
            _setRequiredWorthPhasePeriod(phases[i], periods[i], reqWorth);
        }
        emit PhasePeriodRequirementsClonedFrom(v1, phases, periods);
    }

}
