// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ERC20PeriodicalStaking} from "../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {StakingLens} from "../src/contracts/erc20-periodical-staking/StakingLens.sol";

/// @notice Deploys the read-only StakingLens for one already-deployed ERC20PeriodicalStaking.
/// @dev Separate from DeployV050.s.sol on purpose: the lens has no owner, no storage and no privileges, so it
///      is not part of the staking deployment's configuration and can be deployed (or redeployed) by any
///      account at any time. Env: STAKING = the staking contract address.
///
///      The `deploy-v050` rpc alias resolves ${RPC_URL}, which lives in deploy/v050/<network>.env and not in your
///      shell. Load that file in a subshell so the URL (it may hold a provider key) does not stay in the session:
///
///      ( set -a; . deploy/v050/<network>.env; set +a; STAKING=0x... \
///          forge script script/DeployLens.s.sol --rpc-url deploy-v050 --sender <DEPLOYER_ADDRESS> )             # simulate
///      ( set -a; . deploy/v050/<network>.env; set +a; STAKING=0x... \
///          forge script script/DeployLens.s.sol --rpc-url deploy-v050 --account <KEYSTORE_ACCOUNT> \
///          --sender <DEPLOYER_ADDRESS> --broadcast --slow )                                                     # send
///      Add --verify when ETHERSCAN_API_KEY is set in that env file.
contract DeployLens is Script {
    function run() external returns (StakingLens lens) {
        address staking = vm.envAddress("STAKING");
        require(staking.code.length != 0, "DeployLens: STAKING has no code on this network");
        // Fails here, before any transaction, when STAKING is not a v0.5.0+ staking contract.
        string memory version = ERC20PeriodicalStaking(staking).VERSION();

        vm.startBroadcast();
        lens = new StakingLens(ERC20PeriodicalStaking(staking));
        vm.stopBroadcast();

        require(address(lens.STAKING()) == staking, "DeployLens: lens points at the wrong contract");
        // One real read through the lens, so a broken deployment is caught now and not by the frontend.
        lens.getRewardPoolShortfall();

        console2.log("ERC20PeriodicalStaking", staking, "VERSION", version);
        console2.log("StakingLens           ", address(lens));
    }
}
