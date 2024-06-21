// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./contract-functions/AdministrativeFunctions.sol";
import "./contract-functions/StakingFunctions.sol";
import "./contract-functions/claimOrWithdrawFunctions.sol";

/// @title Periodical ERC20 Staking
/// @author Heydar Badirli
contract ERC20Staking is AdministrativeFunctions, StakingFunctions, claimOrWithdrawFunctions {
    constructor(
        address tokenAddress,
        uint256 _stakingPhaseCount,
        uint256[] memory stakingPeriods,
        uint256[][] memory phasePeriodAPYs,
        uint256[][] memory phasePeriodStakingTargets
        ) ProgramManager(
            IERC20Metadata(tokenAddress),
            _stakingPhaseCount,
            stakingPeriods,
            phasePeriodAPYs,
            phasePeriodStakingTargets
        ) {
            
        contractOwner = msg.sender;

        emit CreateProgram(
        tokenAddress,
        _stakingPhaseCount,
        stakingPeriods,
        phasePeriodAPYs,
        phasePeriodStakingTargets
        );
    }
}