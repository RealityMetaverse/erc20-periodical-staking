// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./contract-functions/AdministrativeFunctions.sol";
import "./contract-functions/StakingFunctions.sol";
import "./contract-functions/WithdrawFunctions.sol";
import "./contract-functions/ClaimFunctions.sol";
import "./contract-functions/EnforcementFunctions.sol";

/// @title Periodical ERC20 Staking
/// @author Heydar Badirli
/// @notice Voucher-gated staking: set voucherSigner, limitController and treasury after deployment.
contract ERC20PeriodicalStaking is
    AdministrativeFunctions,
    StakingFunctions,
    WithdrawFunctions,
    ClaimFunctions,
    EnforcementFunctions
{
    constructor(address tokenAddress)
        ProgramManager(IERC20Metadata(tokenAddress))
        EIP712("ERC20PeriodicalStaking", "1")
    {
        contractOwner = msg.sender;
    }
}
