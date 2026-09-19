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
    /// @notice Version of this contract's source, for off-chain compatibility checks.
    /// @dev Read this at startup and refuse to run when it disagrees with the ABI you were built against. The
    ///      voucher struct changed shape in 0.5.0 (7 fields -> 8), so a backend signing 0.5.0 vouchers against a
    ///      live 0.4.0 contract produces a valid signature over the wrong digest: every stake reverts
    ///      InvalidVoucherSignature, which reads like a key problem rather than a version problem.
    ///      `constant`, so it costs no storage and no deployment step can forget to set it.
    ///      NOT the EIP-712 domain version, which stays "1" -- that exists to scope signatures to a domain, not
    ///      to describe a release, and bumping it would invalidate signing code for no benefit.
    string public constant VERSION = "0.5.0";

    constructor(address tokenAddress)
        ProgramManager(IERC20Metadata(tokenAddress))
        EIP712("ERC20PeriodicalStaking", "1")
    {
        contractOwner = msg.sender;
    }
}
