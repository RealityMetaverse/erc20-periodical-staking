// SPDX-License-Identifier: MIT
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ERC20PeriodicalStaking} from "../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {LimitController} from "../src/contracts/LimitController.sol";
import {Types} from "../src/common/Types.sol";

/// @notice The read surface of a deployed v0.2.4 staking contract (the "S2" VIP staking contract of a network).
interface ILegacyStakingV024 {
    function STAKING_TOKEN() external view returns (address);
    function contractOwner() external view returns (address);
    function contractAdmins(address) external view returns (bool);
    function minimumDeposit() external view returns (uint256);
    function currentStakingPhase() external view returns (uint256);
    function stakingPhaseCount() external view returns (uint256);
    function getStakingPeriods() external view returns (uint256[] memory);
    function getPhasePeriodData(uint8 dataType, uint256 phase, uint256 period) external view returns (uint256);
    function checkActionAvailability(uint8 action) external view returns (bool);
    function limitController() external view returns (address);
    function requirementChecker() external view returns (address);
    function whitelistEnabled() external view returns (bool);
    function rewardPool() external view returns (uint256);
    function getUserPhasePeriodData(uint8 dataType, address user, uint256 phase, uint256 period)
        external
        view
        returns (uint256);
}

/// @notice The read surface of the LimitController a v0.2.4 contract points to (pre-v0.3.0 build: no
///         hasWalletLimit, a wallet limit of 0 means "use the default").
interface ILegacyLimitControllerV024 {
    function owner() external view returns (address);
    function stakingContract() external view returns (address);
    function defaultPhasePeriodLimit(uint256 phase, uint256 period) external view returns (uint256);
    function walletPhasePeriodLimit(address wallet, uint256 phase, uint256 period) external view returns (uint256);
}

/// @notice The RequirementCheckerV2 getters used to print the manual list update.
interface IRequirementCheckerV2Read {
    function owner() external view returns (address);
    function periodicalStakingContractCount() external view returns (uint256);
    function periodicalStakingContracts(uint256 index) external view returns (address);
}

/// @dev Cheatcodes supported by the forge binary but missing from the forge-std copy vendored under
///      lib/openzeppelin-contracts. Same HEVM address, same selectors.
interface IVmExtra {
    function envExists(string calldata name) external view returns (bool);
    function split(string calldata input, string calldata delimiter) external pure returns (string[] memory);
    function trim(string calldata input) external pure returns (string memory);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
}

/// @title DeployV050
/// @notice Deploys ERC20PeriodicalStaking v0.5.0 + LimitController as a like-for-like successor of the network's
///         own v0.2.4 contract: the program config (periods, phases, APYs, targets, current phase, minimum deposit)
///         and the controller defaults are READ FROM CHAIN, applied, then re-read and require()d equal.
/// @dev The source contract is resolved per chain: SOURCE_STAKING env wins, otherwise `sourceStakingFor(chainid)`;
///      an unknown chain without the env reverts. Nothing is invented: what v0.2.4 does not expose is logged and
///      left to the operator. Staking stays CLOSED unless OPEN_STAKING=true.
///      See README "Deploying v0.5.0 with DeployV050.s.sol".
contract DeployV050 is Script {
    IVmExtra private constant VMX = IVmExtra(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint8 private constant PPD_TARGET = 0; // Types.PhasePeriodDataType.STAKING_TARGET
    uint8 private constant PPD_APY = 1; // Types.PhasePeriodDataType.APY
    uint8 private constant ACTION_STAKING = 0;
    uint8 private constant ACTION_WITHDRAWAL = 1;
    uint8 private constant ACTION_CLAIM = 2;
    /// @dev v0.2.4 APYs are whole percent, v0.5.0 APYs are bps.
    uint256 private constant PCT_TO_BPS = 100;
    /// @dev forge's default script sender, i.e. no --sender was given.
    address private constant FORGE_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    /// @dev Mirrors of the staking contract's config-time bounds (AdministrativeFunctions MAX_APY_BPS and
    ///      MAX_PERIOD_DAYS, both internal there). Above them the contract reverts ValueTooHigh mid-deployment.
    uint256 private constant MAX_APY_BPS = 1_000_000;
    uint256 private constant MAX_PERIOD_DAYS = 36_500;
    /// @dev Hand-off stages a two-step contract can legitimately be in (see `_checkOwnership`). Both the staking
    ///      contract and the LimitController must be at the SAME one: a mixed state means one acceptOwnership()
    ///      was forgotten.
    uint8 private constant STAGE_NOMINATED = 0;
    uint8 private constant STAGE_ACCEPTED = 1;

    struct Params {
        address sourceStaking;
        address requirementCheckerV2; // only for the printed manual step; address(0) = unknown
        address voucherSigner;
        address treasury;
        uint256 maxExtraApyBps;
        uint256 maxExtraLimitTotal; // ceiling on a voucher's GLOBAL bonus budget (one per wallet, spans all phases)
        uint256 maxExtraLimitPerCell; // per-(phase, period) bonus ceiling a voucher may carry
        uint256 maxVoucherValidity; // seconds; furthest ahead of now a voucher validUntil may sit
        address newOwner; // address(0) = keep the deployer
        address[] admins;
        bool openStaking;
        uint256 rewardTopUp; // 0 = do not fund
        string walletLimitsFile; // "" = no per-wallet limits
        address resumeStaking; // address(0) = deploy a new staking contract
        address resumeController; // address(0) = deploy a new LimitController
        bool allowSharedRoles; // false = one address holding two roles fails the preflight (see _preflightRoles)
    }

    struct OldConfig {
        address staking;
        address token;
        address owner;
        uint256 minimumDeposit;
        uint256 currentPhase;
        uint256 phaseCount;
        uint256[] periods;
        uint256[][] apyPct; // [phase][periodIndex]
        uint256[][] targets; // [phase][periodIndex]
        bool stakingOpen;
        bool withdrawalOpen;
        bool claimOpen;
        address limitController;
        address limitControllerTarget; // the controller's own stakingContract()
        address requirementChecker;
        bool whitelistEnabled;
        uint256 rewardPool;
        uint256[][] defaultLimits; // [phase][periodIndex], from the source's LimitController
    }

    struct WalletLimitRow {
        address wallet;
        uint256 phase;
        uint256 period;
        uint256 limit;
    }

    struct Deployment {
        ERC20PeriodicalStaking staking;
        LimitController controller;
    }

    // ======================================
    // =        Per-network addresses       =
    // ======================================

    /// @notice The network's previous (v0.2.4) VIP staking contract, the source of the copy. address(0) = unknown.
    /// @dev Keys follow the backend network config (`PERIODIC_STAKING_2` in pawnshop/networks/<chainid>.json).
    function sourceStakingFor(uint256 chainId) public pure returns (address) {
        if (chainId == 137) return 0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F; // Polygon
        if (chainId == 80002) return 0x0d8ab209583050A9959322229A7c314c66e40E6f; // Amoy (product owner decision)
        return address(0);
    }

    /// @notice The network's RequirementCheckerV2 (`REQUIREMENT_CHECKER_V2` in the backend network config).
    function requirementCheckerV2For(uint256 chainId) public pure returns (address) {
        if (chainId == 137) return 0x716ff1f64cC2B7c96ba9DDADfc08bB703F8bcA59; // Polygon
        // Amoy: the worth-aggregating RCv2 the backend reads, NOT the source's own requirementChecker() (0xE751…).
        if (chainId == 80002) return 0x3D55e53835e90149BCe416881b4b677EB107d4e3;
        return address(0);
    }

    // ======================================
    // =            Entry points            =
    // ======================================

    /// @notice forge script entry point. Broadcasts only when forge is run with --broadcast.
    function run() external returns (Deployment memory d) {
        Params memory p = paramsFromEnv();
        OldConfig memory o = readOldConfig(p.sourceStaking);
        WalletLimitRow[] memory rows = loadWalletLimits(p.walletLimitsFile, o);
        // VERIFY_ONLY=true: no deployment and no broadcast, only the self-check against what is on chain.
        if (envSet("VERIFY_ONLY") && vm.envBool("VERIFY_ONLY")) {
            _requireEnv("VERIFY_STAKING");
            _requireEnv("VERIFY_CONTROLLER");
            _requireEnv("DEPLOYER_ADDRESS");
            return verifyOnly(
                o, p, rows, vm.envAddress("VERIFY_STAKING"), vm.envAddress("VERIFY_CONTROLLER"), vm.envAddress("DEPLOYER_ADDRESS")
            );
        }
        // PRIVATE_KEY is the discouraged fallback signer. It is read from the environment so the wrapper never has
        // to put it on forge's command line. Keystore runs leave it empty and sign with --account/--sender.
        uint256 key = _envUintOr("PRIVATE_KEY", 0);
        address deployer = msg.sender;
        if (key != 0) {
            deployer = vm.addr(key);
            require(
                msg.sender == FORGE_DEFAULT_SENDER || msg.sender == deployer,
                "DeployV050: PRIVATE_KEY does not belong to --sender (DEPLOYER_ADDRESS)"
            );
        }

        _logOld(o, p, deployer);
        _preflight(o, p, deployer);

        // Every transaction lands in a later block, so this is a safe lower bound for the backend's DEPLOYMENT_BLOCK.
        uint256 blockBeforeDeploy = block.number;
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        d = _deployAndConfigure(o, p, rows);
        vm.stopBroadcast();

        verifyDeployment(o, p, rows, d, deployer);
        _logManualSteps(o, p, d, blockBeforeDeploy);
    }

    /// @notice Same deployment without broadcasting (the calling contract context owns the result). For fork tests.
    /// @dev Ownership lands on this script contract; pass `newOwner` to hand it on.
    function deployFrom(Params memory p, WalletLimitRow[] memory rows)
        external
        returns (OldConfig memory o, Deployment memory d)
    {
        o = readOldConfig(p.sourceStaking);
        _logOld(o, p, address(this));
        _preflight(o, p, address(this));
        d = _deployAndConfigure(o, p, rows);
        verifyDeployment(o, p, rows, d, address(this));
    }

    /// @notice Verify-only mode (VERIFY_ONLY=true): runs the self-check against contracts ALREADY ON CHAIN. Sends
    ///         nothing. The mandatory step after a broadcast: run()'s own self-check reads the simulation's state,
    ///         not what the network actually mined.
    /// @dev `p` must be the parameters the deployment was broadcast with. Ownership may already have been
    ///      accepted by NEW_OWNER, so both hand-off stages pass (see `_checkOwnership`). The role check runs
    ///      again; the balance and resume preflights do not apply to a finished deployment.
    function verifyOnly(
        OldConfig memory o,
        Params memory p,
        WalletLimitRow[] memory rows,
        address stakingAddr,
        address controllerAddr,
        address deployer
    ) public view returns (Deployment memory d) {
        require(stakingAddr.code.length > 0, "DeployV050: VERIFY_STAKING has no code on this chain");
        require(controllerAddr.code.length > 0, "DeployV050: VERIFY_CONTROLLER has no code on this chain");
        require(deployer != address(0), "DeployV050: DEPLOYER_ADDRESS must be non-zero");
        d.staking = ERC20PeriodicalStaking(stakingAddr);
        d.controller = LimitController(controllerAddr);

        _logOld(o, p, deployer);
        console2.log("");
        console2.log("=== VERIFY-ONLY: no transaction is sent, the checks below read the chain ===");
        console2.log("staking               ", stakingAddr);
        console2.log("limit controller      ", controllerAddr);
        _preflightRoles(o, p, deployer);
        _verify(o, p, rows, d, deployer, true);
    }

    // ======================================
    // =               Inputs               =
    // ======================================

    /// @notice Reads and validates the environment. Required: VOUCHER_SIGNER, TREASURY, MAX_EXTRA_APY_BPS,
    ///         MAX_EXTRA_LIMIT_TOTAL, MAX_EXTRA_LIMIT_PER_CELL, MAX_VOUCHER_VALIDITY. Optional: SOURCE_STAKING, REQUIREMENT_CHECKER_V2,
    ///         NEW_OWNER, ADMINS, OPEN_STAKING,
    ///         REWARD_TOP_UP, WALLET_LIMITS_FILE, RESUME_STAKING, RESUME_CONTROLLER, ALLOW_SHARED_ROLES. run() also
    ///         reads PRIVATE_KEY, and VERIFY_ONLY with VERIFY_STAKING, VERIFY_CONTROLLER and DEPLOYER_ADDRESS.
    /// @dev An empty value means "unset, use the default" for every variable (see `envSet`), so the wrapper can
    ///      export all of them explicitly and a root .env cannot fill the gaps.
    function paramsFromEnv() public view returns (Params memory p) {
        _requireEnv("VOUCHER_SIGNER");
        _requireEnv("TREASURY");
        _requireEnv("MAX_EXTRA_APY_BPS");
        _requireEnv("MAX_EXTRA_LIMIT_TOTAL");
        _requireEnv("MAX_EXTRA_LIMIT_PER_CELL");
        _requireEnv("MAX_VOUCHER_VALIDITY");

        p.sourceStaking = resolveSourceStaking();
        p.requirementCheckerV2 = _envAddressOr("REQUIREMENT_CHECKER_V2", requirementCheckerV2For(block.chainid));
        p.voucherSigner = vm.envAddress("VOUCHER_SIGNER");
        p.treasury = vm.envAddress("TREASURY");
        p.maxExtraApyBps = vm.envUint("MAX_EXTRA_APY_BPS");
        p.maxExtraLimitTotal = vm.envUint("MAX_EXTRA_LIMIT_TOTAL");
        p.maxExtraLimitPerCell = vm.envUint("MAX_EXTRA_LIMIT_PER_CELL");
        p.maxVoucherValidity = vm.envUint("MAX_VOUCHER_VALIDITY");
        p.newOwner = _envAddressOr("NEW_OWNER", address(0));
        p.admins = envSet("ADMINS") ? vm.envAddress("ADMINS", ",") : new address[](0);
        p.openStaking = envSet("OPEN_STAKING") ? vm.envBool("OPEN_STAKING") : false;
        p.rewardTopUp = _envUintOr("REWARD_TOP_UP", 0);
        p.walletLimitsFile = VMX.envOr("WALLET_LIMITS_FILE", "");
        p.resumeStaking = _envAddressOr("RESUME_STAKING", address(0));
        p.resumeController = _envAddressOr("RESUME_CONTROLLER", address(0));
        p.allowSharedRoles = envSet("ALLOW_SHARED_ROLES") ? vm.envBool("ALLOW_SHARED_ROLES") : false;
        require(
            p.resumeController == address(0) || p.resumeStaking != address(0),
            "DeployV050: RESUME_CONTROLLER without RESUME_STAKING"
        );
    }

    /// @notice True when the variable exists AND is non-empty. Empty counts as unset.
    function envSet(string memory name) public view returns (bool) {
        return bytes(VMX.envOr(name, "")).length != 0;
    }

    /// @notice SOURCE_STAKING env if set (non-empty), otherwise this chain's table entry; reverts when neither is known.
    function resolveSourceStaking() public view returns (address source) {
        source = _envAddressOr("SOURCE_STAKING", sourceStakingFor(block.chainid));
        require(
            source != address(0),
            string.concat(
                "DeployV050: no source staking contract known for chain ",
                vm.toString(block.chainid),
                "; set SOURCE_STAKING to that network's v0.2.4 contract"
            )
        );
    }

    /// @notice Reads everything v0.2.4 exposes about its program and its LimitController's defaults.
    /// @dev Refuses anything that is not v0.2.4-shaped: a v0.3.0+ contract has pendingOwner(), and a v0.4.0+ one
    ///      stores bps, so the percent->bps conversion would be wrong.
    function readOldConfig(address source) public view returns (OldConfig memory o) {
        require(source.code.length > 0, "DeployV050: source staking contract has no code on this chain");
        (bool hasPendingOwner,) = source.staticcall(abi.encodeWithSignature("pendingOwner()"));
        (bool hasWhitelist,) = source.staticcall(abi.encodeWithSignature("whitelistEnabled()"));
        require(!hasPendingOwner && hasWhitelist, "DeployV050: source is not a v0.2.4 ERC20PeriodicalStaking");
        // The new LimitController reads the legacy contract through the batch getter too.
        (bool hasBatch,) = source.staticcall(
            abi.encodeWithSignature(
                "getUserPhasePeriodDataBatch(uint8,address[],uint256[],uint256[])",
                uint8(0),
                new address[](0),
                new uint256[](0),
                new uint256[](0)
            )
        );
        require(hasBatch, "DeployV050: source lacks getUserPhasePeriodDataBatch (LimitController legacy reads)");

        ILegacyStakingV024 old = ILegacyStakingV024(source);
        o.staking = source;
        o.token = old.STAKING_TOKEN();
        o.owner = old.contractOwner();
        o.minimumDeposit = old.minimumDeposit();
        o.currentPhase = old.currentStakingPhase();
        o.phaseCount = old.stakingPhaseCount();
        o.periods = old.getStakingPeriods();
        o.stakingOpen = old.checkActionAvailability(ACTION_STAKING);
        o.withdrawalOpen = old.checkActionAvailability(ACTION_WITHDRAWAL);
        o.claimOpen = old.checkActionAvailability(ACTION_CLAIM);
        o.limitController = old.limitController();
        o.requirementChecker = old.requirementChecker();
        o.whitelistEnabled = old.whitelistEnabled();
        o.rewardPool = old.rewardPool();
        if (o.limitController != address(0)) {
            o.limitControllerTarget = ILegacyLimitControllerV024(o.limitController).stakingContract();
        }

        uint256 n = o.periods.length;
        o.apyPct = new uint256[][](o.phaseCount);
        o.targets = new uint256[][](o.phaseCount);
        o.defaultLimits = new uint256[][](o.phaseCount);
        for (uint256 ph = 0; ph < o.phaseCount; ++ph) {
            o.apyPct[ph] = new uint256[](n);
            o.targets[ph] = new uint256[](n);
            o.defaultLimits[ph] = new uint256[](n);
            for (uint256 i = 0; i < n; ++i) {
                o.apyPct[ph][i] = old.getPhasePeriodData(PPD_APY, ph, o.periods[i]);
                o.targets[ph][i] = old.getPhasePeriodData(PPD_TARGET, ph, o.periods[i]);
                if (o.limitController != address(0)) {
                    o.defaultLimits[ph][i] =
                        ILegacyLimitControllerV024(o.limitController).defaultPhasePeriodLimit(ph, o.periods[i]);
                }
            }
        }
    }

    /// @notice Optional per-wallet limits. The v0.2.4-era LimitController keeps them in a mapping with no
    ///         enumeration, so they cannot be discovered on-chain; supply them as CSV lines `wallet,phase,period,limit`
    ///         (limit in token wei; blank lines, `#` comments and a `wallet,...` header are ignored).
    /// @dev Every row must equal the source controller's on-chain value (catches typos and stale exports). Rows with
    ///      limit 0 are dropped: on the old controller 0 means "no wallet limit, use the default", while on the new
    ///      one setWalletLimit(…, 0) REMOVES THE WALLET'S BASE ALLOWANCE (hasWalletLimit). Copying them would leave
    ///      those wallets with no base room. It is not a block -- a voucher bonus still stakes on top of a 0 limit,
    ///      and blocking a wallet outright is walletBlocked on the staking contract.
    function loadWalletLimits(string memory path, OldConfig memory o)
        public
        view
        returns (WalletLimitRow[] memory rows)
    {
        if (bytes(path).length == 0) return new WalletLimitRow[](0);
        require(o.limitController != address(0), "DeployV050: wallet limits given but the source has no LimitController");

        string[] memory lines = VMX.split(vm.readFile(path), "\n");
        WalletLimitRow[] memory tmp = new WalletLimitRow[](lines.length);
        uint256 count;
        for (uint256 i = 0; i < lines.length; ++i) {
            string memory line = VMX.trim(lines[i]);
            bytes memory b = bytes(line);
            if (b.length == 0 || b[0] == "#" || b[0] == "w" || b[0] == "W") continue;

            string[] memory f = VMX.split(line, ",");
            require(f.length == 4, string.concat("DeployV050: bad wallet limit line ", vm.toString(i + 1)));
            WalletLimitRow memory r = WalletLimitRow({
                wallet: vm.parseAddress(VMX.trim(f[0])),
                phase: vm.parseUint(VMX.trim(f[1])),
                period: vm.parseUint(VMX.trim(f[2])),
                limit: vm.parseUint(VMX.trim(f[3]))
            });
            uint256 onChain =
                ILegacyLimitControllerV024(o.limitController).walletPhasePeriodLimit(r.wallet, r.phase, r.period);
            require(
                onChain == r.limit,
                string.concat(
                    "DeployV050: wallet limit line ",
                    vm.toString(i + 1),
                    " does not match the source controller (on-chain ",
                    vm.toString(onChain),
                    ")"
                )
            );
            if (r.limit == 0) {
                console2.log("  wallet limit dropped (0 = default on v0.2.4):", r.wallet, r.phase, r.period);
                continue;
            }
            tmp[count++] = r;
        }
        rows = new WalletLimitRow[](count);
        for (uint256 i = 0; i < count; ++i) {
            rows[i] = tmp[i];
        }
        console2.log("Wallet limits loaded from file:", count);
    }

    // ======================================
    // =          Deploy + configure        =
    // ======================================

    function _preflight(OldConfig memory o, Params memory p, address deployer) internal view {
        require(p.voucherSigner != address(0), "DeployV050: VOUCHER_SIGNER must be non-zero");
        require(p.treasury != address(0), "DeployV050: TREASURY must be non-zero");
        require(p.maxExtraApyBps <= type(uint32).max, "DeployV050: MAX_EXTRA_APY_BPS exceeds uint32");
        // setMaxExtraApyBps reverts ValueTooHigh above this; say so before anything is deployed.
        require(
            p.maxExtraApyBps <= MAX_APY_BPS, "DeployV050: MAX_EXTRA_APY_BPS exceeds 1000000 bps (v0.5.0 rejects it)"
        );
        require(p.maxExtraLimitTotal <= type(uint128).max, "DeployV050: MAX_EXTRA_LIMIT_TOTAL exceeds uint128");
        require(
            p.maxExtraLimitPerCell <= type(uint128).max, "DeployV050: MAX_EXTRA_LIMIT_PER_CELL exceeds uint128"
        );
        // A zero per-cell ceiling disables the voucher bonus entirely: every voucher carrying a non-zero
        // extraLimitPerCell reverts VoucherExtraLimitPerCellTooHigh. Stop here rather than let it surface later
        // as user-facing reverts. Set both to 0 to deploy with the bonus deliberately off.
        require(
            p.maxExtraLimitPerCell != 0 || p.maxExtraLimitTotal == 0,
            "DeployV050: MAX_EXTRA_LIMIT_PER_CELL is 0 while MAX_EXTRA_LIMIT_TOTAL is not, bonus would be disabled"
        );
        // 0 is rejected on-chain too (it would revert every stake); fail before spending gas to find that out.
        require(p.maxVoucherValidity != 0, "DeployV050: MAX_VOUCHER_VALIDITY must be non-zero");
        require(p.maxVoucherValidity <= type(uint32).max, "DeployV050: MAX_VOUCHER_VALIDITY exceeds uint32");
        require(p.newOwner != deployer, "DeployV050: NEW_OWNER equals the deployer, leave it unset");
        require(o.token != address(0), "DeployV050: source contract returned no token");
        require(o.phaseCount > 0 && o.periods.length > 0, "DeployV050: source contract has no program configured");
        require(o.minimumDeposit > 0 && o.minimumDeposit <= type(uint128).max, "DeployV050: minimum deposit out of range");
        // addStakingPeriod reverts ValueTooHigh for a longer period; v0.2.4 had no such bound.
        for (uint256 i = 0; i < o.periods.length; ++i) {
            require(
                o.periods[i] <= MAX_PERIOD_DAYS, "DeployV050: source period exceeds 36500 days (v0.5.0 rejects it)"
            );
        }
        for (uint256 ph = 0; ph < o.phaseCount; ++ph) {
            for (uint256 i = 0; i < o.periods.length; ++i) {
                uint256 pct = o.apyPct[ph][i];
                require(pct != 0, "DeployV050: source APY cell is 0 (v0.5.0 rejects 0)");
                // A deposit stores base + extra APY in a uint32: fail here, not at the first stake. The
                // tighter config-time bound below makes this the message for absurd source values only.
                require(
                    pct <= (type(uint32).max - p.maxExtraApyBps) / PCT_TO_BPS,
                    "DeployV050: APY pct * 100 + MAX_EXTRA_APY_BPS overflows uint32"
                );
                // pushStakingPhase / addStakingPeriod revert ValueTooHigh above this.
                require(
                    pct <= MAX_APY_BPS / PCT_TO_BPS,
                    "DeployV050: source APY pct * 100 exceeds 1000000 bps (v0.5.0 rejects it)"
                );
            }
        }
        if (p.rewardTopUp > 0) {
            require(
                IERC20(o.token).balanceOf(deployer) >= p.rewardTopUp, "DeployV050: deployer balance below REWARD_TOP_UP"
            );
        }
        _preflightRoles(o, p, deployer);
        _preflightResume(o, p, deployer);
    }

    /// @dev One key per role. A voucher signer that is also the deployer, the owner, the treasury or an admin turns
    ///      a leaked backend signing key into an ownership or funds problem; a treasury that is the token or a
    ///      staking contract strands every seized deposit. ALLOW_SHARED_ROLES=true downgrades each clash to a
    ///      warning (testnets). The NEW contracts' addresses are checked in verifyDeployment.
    function _preflightRoles(OldConfig memory o, Params memory p, address deployer) internal view {
        _roleClash(p, p.voucherSigner == deployer, "VOUCHER_SIGNER equals the deployer");
        _roleClash(p, p.voucherSigner == p.newOwner, "VOUCHER_SIGNER equals NEW_OWNER");
        _roleClash(p, p.voucherSigner == p.treasury, "VOUCHER_SIGNER equals TREASURY");
        for (uint256 i = 0; i < p.admins.length; ++i) {
            _roleClash(p, p.voucherSigner == p.admins[i], "VOUCHER_SIGNER equals an address in ADMINS");
        }
        _roleClash(p, p.treasury == o.token, "TREASURY equals the staking token");
        _roleClash(p, p.treasury == o.staking, "TREASURY equals the source staking contract");
        _roleClash(
            p, p.resumeStaking != address(0) && p.treasury == p.resumeStaking, "TREASURY equals RESUME_STAKING"
        );
        // A contract admin can freeze and seize deposits; the treasury is where seized funds land. One key that
        // holds both roles can take the funds AND receive them, with no second party in the way.
        for (uint256 i = 0; i < p.admins.length; ++i) {
            _roleClash(p, p.treasury == p.admins[i], "TREASURY equals an address in ADMINS");
        }
        // The owner can already move everything; making it the seizure destination removes the last separation.
        _roleClash(p, p.newOwner != address(0) && p.treasury == p.newOwner, "TREASURY equals NEW_OWNER");
        // Duplicates are harmless on chain (addContractAdmin is idempotent) but always mean the operator's list
        // is not what they think it is, so say so out loud. Never fatal, so ALLOW_SHARED_ROLES is not consulted.
        for (uint256 i = 0; i < p.admins.length; ++i) {
            for (uint256 j = i + 1; j < p.admins.length; ++j) {
                if (p.admins[i] == p.admins[j]) {
                    console2.log("!!!!!!!! WARNING: ADMINS lists the same address more than once:", p.admins[i]);
                }
            }
        }
    }

    function _roleClash(Params memory p, bool clash, string memory what) private view {
        if (!clash) return;
        require(
            p.allowSharedRoles,
            string.concat("DeployV050: ", what, " (one address per role; ALLOW_SHARED_ROLES=true overrides)")
        );
        console2.log("!!!!!!!! WARNING: shared role accepted because ALLOW_SHARED_ROLES=true:", what);
    }

    /// @dev A resume must attach to contracts this deployer still owns and that belong to this source, otherwise
    ///      the "skip what is already done" guards would read a stranger's state.
    function _preflightResume(OldConfig memory o, Params memory p, address deployer) internal view {
        if (p.resumeStaking != address(0)) {
            require(p.resumeStaking.code.length > 0, "DeployV050: RESUME_STAKING has no code on this chain");
            ERC20PeriodicalStaking s = ERC20PeriodicalStaking(p.resumeStaking);
            require(address(s.STAKING_TOKEN()) == o.token, "DeployV050: RESUME_STAKING has a different staking token");
            require(s.contractOwner() == deployer, "DeployV050: RESUME_STAKING is not owned by the deployer");
            require(
                s.stakingPhaseCount() <= o.phaseCount, "DeployV050: RESUME_STAKING has more phases than the source"
            );
        }
        if (p.resumeController != address(0)) {
            require(p.resumeController.code.length > 0, "DeployV050: RESUME_CONTROLLER has no code on this chain");
            LimitController c = LimitController(p.resumeController);
            require(
                address(c.stakingContract()) == p.resumeStaking,
                "DeployV050: RESUME_CONTROLLER was built for another staking contract"
            );
            require(c.owner() == deployer, "DeployV050: RESUME_CONTROLLER is not owned by the deployer");
        }
    }

    /// @notice Deploys what is missing and writes only what is not already correct.
    /// @dev Every step is guarded by a read of the target contract, which makes the whole function idempotent:
    ///      after a broadcast that died partway, re-running it with RESUME_STAKING (and RESUME_CONTROLLER)
    ///      sends exactly the transactions that are still missing and ends in the same verified state. On a
    ///      fresh deployment every guard is trivially true, so the transaction list is unchanged.
    function _deployAndConfigure(OldConfig memory o, Params memory p, WalletLimitRow[] memory rows)
        internal
        returns (Deployment memory d)
    {
        // 1. Staking contract, closed to stakes immediately (v0.5.0 constructor opens all three actions).
        if (p.resumeStaking != address(0)) {
            d.staking = ERC20PeriodicalStaking(p.resumeStaking);
            console2.log("RESUME: reusing the staking contract at", address(d.staking));
        } else {
            d.staking = new ERC20PeriodicalStaking(o.token);
        }
        if (d.staking.checkActionAvailability(Types.DataType.STAKING) != p.openStaking) {
            d.staking.changeActionAvailability(Types.DataType.STAKING, p.openStaking);
        }

        // 2. LimitController: defaults, wallet limits, legacy contract (= the source).
        if (p.resumeController != address(0)) {
            d.controller = LimitController(p.resumeController);
            console2.log("RESUME: reusing the LimitController at", address(d.controller));
        } else {
            d.controller = new LimitController(address(d.staking));
        }
        _applyDefaultLimits(d.controller, o);
        _applyWalletLimits(d.controller, rows);
        if (address(d.controller.legacyStakingContract()) != o.staking) {
            d.controller.setLegacyStakingContract(o.staking);
        }

        // 3. Staking: controller, voucher, caps, treasury, then periods before phases, then the current phase.
        if (d.staking.limitController() != address(d.controller)) d.staking.setLimitController(address(d.controller));
        if (d.staking.voucherSigner() != p.voucherSigner) d.staking.setVoucherSigner(p.voucherSigner);
        if (d.staking.maxExtraApyBps() != p.maxExtraApyBps) d.staking.setMaxExtraApyBps(p.maxExtraApyBps);
        if (d.staking.maxExtraLimitTotal() != p.maxExtraLimitTotal) d.staking.setMaxExtraLimitTotal(p.maxExtraLimitTotal);
        if (d.staking.maxExtraLimitPerCell() != p.maxExtraLimitPerCell) {
            d.staking.setMaxExtraLimitPerCell(p.maxExtraLimitPerCell);
        }
        if (d.staking.maxVoucherValidity() != p.maxVoucherValidity) {
            d.staking.setMaxVoucherValidity(p.maxVoucherValidity);
        }
        if (d.staking.treasury() != p.treasury) d.staking.setTreasury(p.treasury);

        _addMissingPeriods(d.staking, o);
        _pushMissingPhases(d.staking, o);

        if (d.staking.currentStakingPhase() != o.currentPhase) d.staking.changeStakingPhase(o.currentPhase);
        if (d.staking.minimumDeposit() != o.minimumDeposit) d.staking.setMiniumumDeposit(o.minimumDeposit);

        for (uint256 i = 0; i < p.admins.length; ++i) {
            if (!d.staking.contractAdmins(p.admins[i])) d.staking.addContractAdmin(p.admins[i]);
        }

        // 4. Opt-in reward funding only. A resume must never fund twice, so a non-empty pool is left alone.
        if (p.rewardTopUp > 0) {
            uint256 pool = d.staking.rewardPool();
            if (pool == 0) {
                IERC20(o.token).approve(address(d.staking), p.rewardTopUp);
                d.staking.provideReward(p.rewardTopUp);
            } else {
                console2.log("RESUME: reward pool already funded, REWARD_TOP_UP skipped. Pool:", pool);
            }
        }

        // 5. Ownership last. Both contracts are two-step: this only nominates NEW_OWNER, who must acceptOwnership()
        //    on the staking contract AND on the LimitController. The deployer stays owner of both until then.
        if (p.newOwner != address(0)) {
            if (d.staking.pendingOwner() != p.newOwner) d.staking.transferOwnership(p.newOwner);
            if (d.controller.pendingOwner() != p.newOwner) d.controller.transferOwnership(p.newOwner);
        }
    }

    /// @dev Adds only the periods the contract does not have yet.
    ///      With no phase pushed yet the per-phase arrays must be empty; on a resume where phases already exist
    ///      they must carry one entry per existing phase or addStakingPeriod reverts LengthMismatch. Adding the
    ///      period fills its cells for every phase that exists, and _pushMissingPhases fills the rest, so the two
    ///      orders converge on the same configuration.
    function _addMissingPeriods(ERC20PeriodicalStaking s, OldConfig memory o) internal {
        uint256 existingPhases = s.stakingPhaseCount();
        require(existingPhases <= o.phaseCount, "DeployV050: target has more phases than the source");
        for (uint256 i = 0; i < o.periods.length; ++i) {
            if (s.checkIfStakingPeriodExists(o.periods[i])) continue;
            uint256[] memory apy = new uint256[](existingPhases);
            uint256[] memory target = new uint256[](existingPhases);
            for (uint256 ph = 0; ph < existingPhases; ++ph) {
                apy[ph] = o.apyPct[ph][i] * PCT_TO_BPS;
                target[ph] = o.targets[ph][i];
            }
            s.addStakingPeriod(o.periods[i], apy, target);
        }
    }

    /// @dev Pushes only the phases beyond the ones the contract already has.
    function _pushMissingPhases(ERC20PeriodicalStaking s, OldConfig memory o) internal {
        uint256 n = o.periods.length;
        for (uint256 ph = s.stakingPhaseCount(); ph < o.phaseCount; ++ph) {
            uint256[] memory bps = new uint256[](n);
            for (uint256 i = 0; i < n; ++i) {
                bps[i] = o.apyPct[ph][i] * PCT_TO_BPS;
            }
            s.pushStakingPhase(bps, o.targets[ph]);
        }
    }

    /// @dev Only the cells that do not already hold the source value are written, so a resume against a controller
    ///      whose defaults already landed sends no transaction at all (a fresh controller reads 0 everywhere, so
    ///      every non-zero source default is written exactly as before).
    function _applyDefaultLimits(LimitController c, OldConfig memory o) internal {
        uint256 n = o.periods.length;
        uint256 count;
        for (uint256 ph = 0; ph < o.phaseCount; ++ph) {
            for (uint256 i = 0; i < n; ++i) {
                if (c.defaultPhasePeriodLimit(ph, o.periods[i]) != o.defaultLimits[ph][i]) ++count;
            }
        }
        if (count == 0) return;
        uint256[] memory phases = new uint256[](count);
        uint256[] memory periods = new uint256[](count);
        uint256[] memory limits = new uint256[](count);
        uint256 k;
        for (uint256 ph = 0; ph < o.phaseCount; ++ph) {
            for (uint256 i = 0; i < n; ++i) {
                if (c.defaultPhasePeriodLimit(ph, o.periods[i]) == o.defaultLimits[ph][i]) continue;
                phases[k] = ph;
                periods[k] = o.periods[i];
                limits[k] = o.defaultLimits[ph][i];
                ++k;
            }
        }
        c.setDefaultLimits(phases, periods, limits);
    }

    /// @dev One setWalletLimits call per run of consecutive rows sharing (phase, period). Rows the controller
    ///      already holds are dropped first, so a resume only writes what is missing.
    function _applyWalletLimits(LimitController c, WalletLimitRow[] memory rows) internal {
        WalletLimitRow[] memory todo = new WalletLimitRow[](rows.length);
        uint256 count;
        for (uint256 i = 0; i < rows.length; ++i) {
            WalletLimitRow memory r = rows[i];
            if (c.hasWalletLimit(r.wallet, r.phase, r.period) && c.walletPhasePeriodLimit(r.wallet, r.phase, r.period) == r.limit) {
                continue;
            }
            todo[count++] = r;
        }

        uint256 start;
        while (start < count) {
            uint256 end = start + 1;
            while (end < count && todo[end].phase == todo[start].phase && todo[end].period == todo[start].period) {
                ++end;
            }
            address[] memory wallets = new address[](end - start);
            uint256[] memory limits = new uint256[](end - start);
            for (uint256 i = start; i < end; ++i) {
                wallets[i - start] = todo[i].wallet;
                limits[i - start] = todo[i].limit;
            }
            c.setWalletLimits(wallets, todo[start].phase, todo[start].period, limits);
            start = end;
        }
    }

    // ======================================
    // =             Self-check             =
    // ======================================

    /// @notice Re-reads every copied value from the NEW contracts and requires it equals the source; logs old -> new.
    function verifyDeployment(
        OldConfig memory o,
        Params memory p,
        WalletLimitRow[] memory rows,
        Deployment memory d,
        address deployer
    ) public view {
        _verify(o, p, rows, d, deployer, false);
    }

    /// @dev `live` = verify-only mode, reading a finished deployment from the chain: NEW_OWNER may have accepted
    ///      already, and the reward pool is judged against REWARD_TOP_UP.
    function _verify(
        OldConfig memory o,
        Params memory p,
        WalletLimitRow[] memory rows,
        Deployment memory d,
        address deployer,
        bool live
    ) internal view {
        ERC20PeriodicalStaking s = d.staking;
        LimitController c = d.controller;
        uint256 unit = 10 ** uint256(IERC20Metadata(o.token).decimals());

        console2.log("");
        console2.log("=== Self-check: new contracts re-read (old -> new) ===");
        require(address(s.STAKING_TOKEN()) == o.token, "check: token");
        require(s.limitController() == address(c), "check: staking.limitController");
        require(address(c.stakingContract()) == address(s), "check: controller.stakingContract");
        require(address(c.legacyStakingContract()) == o.staking, "check: controller.legacyStakingContract");
        require(s.voucherSigner() == p.voucherSigner, "check: voucherSigner");
        require(s.treasury() == p.treasury, "check: treasury");
        require(s.maxExtraApyBps() == p.maxExtraApyBps, "check: maxExtraApyBps");
        require(s.maxExtraLimitTotal() == p.maxExtraLimitTotal, "check: maxExtraLimitTotal");
        require(s.maxExtraLimitPerCell() == p.maxExtraLimitPerCell, "check: maxExtraLimitPerCell");
        require(s.maxVoucherValidity() == p.maxVoucherValidity, "check: maxVoucherValidity");
        require(s.stakingPhaseCount() == o.phaseCount, "check: stakingPhaseCount");
        require(s.currentStakingPhase() == o.currentPhase, "check: currentStakingPhase");
        require(s.minimumDeposit() == o.minimumDeposit, "check: minimumDeposit");
        // Action availability is the one group of settings ops is EXPECTED to change after the deploy: the
        // documented hand-off ends with changeActionAvailability(STAKING, true). Comparing it against the env
        // file is right at deploy time (nothing has touched the contract yet) and wrong for ever afterwards - a
        // hard failure there would make verify-only useless on every healthy deployment. So: strict in the
        // post-deploy self-check, informational in verify-only.
        _checkAvailability(
            s.checkActionAvailability(Types.DataType.STAKING), p.openStaking, live, "STAKING", "OPEN_STAKING"
        );
        _checkAvailability(s.checkActionAvailability(Types.DataType.WITHDRAWAL), true, live, "WITHDRAWAL", "true");
        _checkAvailability(s.checkActionAvailability(Types.DataType.CLAIM), true, live, "CLAIM", "true");
        // setTreasury rejects the staking contract itself; the controller's address only exists after deployment.
        require(p.treasury != address(s), "check: treasury is the new staking contract");
        require(p.treasury != address(c), "check: treasury is the new LimitController");
        uint8 stakingStage =
            _checkOwnership(s.contractOwner(), s.pendingOwner(), p.newOwner, deployer, live, "check: staking ownership");
        uint8 controllerStage =
            _checkOwnership(c.owner(), c.pendingOwner(), p.newOwner, deployer, live, "check: controller ownership");
        // Both contracts are two-step, so the hand-off is only finished when BOTH have been accepted. Judging
        // them one at a time lets a deployment where NEW_OWNER accepted the staking contract and forgot the
        // controller pass verification - which is precisely the mistake the two-step change makes possible.
        if (stakingStage != controllerStage) {
            console2.log("staking contract  ", address(s), stakingStage == STAGE_ACCEPTED ? "ACCEPTED by NEW_OWNER" : "still PENDING");
            console2.log("LimitController   ", address(c), controllerStage == STAGE_ACCEPTED ? "ACCEPTED by NEW_OWNER" : "still PENDING");
            console2.log("NEW_OWNER         ", p.newOwner);
            revert(
                "check: half-finished hand-off - NEW_OWNER accepted ONE contract, not both. Call acceptOwnership() on the other (see the two lines above) and re-run --verify-only"
            );
        }
        // The pool must actually cover what the env file says was funded. `!= 0` let 1 wei stand in for any
        // REWARD_TOP_UP. On a live deployment whose rewards have since been paid out, set REWARD_TOP_UP=0 in the
        // env file for verify-only runs: in that mode it is an expectation about the chain, not an instruction.
        if (p.rewardTopUp > 0) {
            require(s.rewardPool() != 0, "check: REWARD_TOP_UP requested but the reward pool is 0");
            if (s.rewardPool() < p.rewardTopUp) {
                console2.log("reward pool (wei)     ", s.rewardPool());
                console2.log("REWARD_TOP_UP (wei)   ", p.rewardTopUp);
                console2.log("shortfall (wei)       ", p.rewardTopUp - s.rewardPool());
            }
            require(
                s.rewardPool() >= p.rewardTopUp,
                "check: reward pool is BELOW REWARD_TOP_UP (see the shortfall above). Fund it, or set REWARD_TOP_UP=0 for verify-only once rewards have been paid out"
            );
        }

        uint256[] memory newPeriods = s.getStakingPeriods();
        require(newPeriods.length == o.periods.length, "check: period count");
        console2.log("token                 ", o.token);
        console2.log("legacy contract       ", address(c.legacyStakingContract()));
        console2.log("phases                ", o.phaseCount, "->", s.stakingPhaseCount());
        console2.log("current phase         ", o.currentPhase, "->", s.currentStakingPhase());
        console2.log("minimum deposit (wei) ", o.minimumDeposit, "->", s.minimumDeposit());
        console2.log("staking open          ", _b(o.stakingOpen), "->", _b(p.openStaking));
        console2.log("withdrawal open       ", _b(o.withdrawalOpen), "-> true");
        console2.log("claim open            ", _b(o.claimOpen), "-> true");

        for (uint256 ph = 0; ph < o.phaseCount; ++ph) {
            for (uint256 i = 0; i < o.periods.length; ++i) {
                uint256 period = o.periods[i];
                require(newPeriods[i] == period, "check: period list");
                uint256 apyBps = s.phasePeriodDataList(Types.PhasePeriodDataType.APY, ph, period);
                uint256 target = s.phasePeriodDataList(Types.PhasePeriodDataType.STAKING_TARGET, ph, period);
                uint256 dflt = c.defaultPhasePeriodLimit(ph, period);
                require(apyBps == o.apyPct[ph][i] * PCT_TO_BPS, "check: APY bps");
                require(target == o.targets[ph][i], "check: staking target");
                require(dflt == o.defaultLimits[ph][i], "check: default limit");
                console2.log(
                    string.concat(
                        "phase ", vm.toString(ph), " period ", vm.toString(period), "d: APY ",
                        vm.toString(o.apyPct[ph][i]), "% -> ", vm.toString(apyBps), " bps | target ",
                        _tok(o.targets[ph][i], unit), " -> ", _tok(target, unit)
                    )
                );
                console2.log(
                    string.concat(
                        "                   default limit ", _tok(o.defaultLimits[ph][i], unit), " -> ", _tok(dflt, unit)
                    )
                );
            }
        }

        for (uint256 i = 0; i < rows.length; ++i) {
            WalletLimitRow memory r = rows[i];
            require(c.hasWalletLimit(r.wallet, r.phase, r.period), "check: hasWalletLimit");
            require(c.walletPhasePeriodLimit(r.wallet, r.phase, r.period) == r.limit, "check: wallet limit");
        }
        console2.log("wallet limits copied  ", rows.length);

        for (uint256 i = 0; i < p.admins.length; ++i) {
            require(s.contractAdmins(p.admins[i]), "check: admin");
            console2.log(
                "admin                 ",
                p.admins[i],
                ILegacyStakingV024(o.staking).contractAdmins(p.admins[i]) ? "(admin on source too)" : "(NOT admin on source)"
            );
        }
        console2.log("reward pool           ", _tok(o.rewardPool, unit), "(source) ->", _tok(s.rewardPool(), unit));
        console2.log("  REWARD_TOP_UP       ", _tok(p.rewardTopUp, unit));
        if (live && s.rewardPool() < p.rewardTopUp) {
            console2.log("  WARNING: the pool is below REWARD_TOP_UP (rewards already paid out, or a resume skipped funding)");
        }
        console2.log(live ? "Verify-only passed: the chain state matches." : "Self-check passed.");
    }

    /// @dev Right after the deployment: the deployer owns, NEW_OWNER (or nobody) is pending. In verify-only mode
    ///      the completed hand-off passes too: NEW_OWNER owns and nothing is pending. Returns WHICH of the two
    ///      stages this contract is at, so the caller can require both contracts to be at the same one.
    function _checkOwnership(
        address currentOwner,
        address pending,
        address newOwner,
        address deployer,
        bool live,
        string memory what
    ) private pure returns (uint8 stage) {
        bool nominated = currentOwner == deployer && pending == newOwner;
        bool accepted = live && newOwner != address(0) && currentOwner == newOwner && pending == address(0);
        require(nominated || accepted, what);
        return accepted ? STAGE_ACCEPTED : STAGE_NOMINATED;
    }

    /// @dev Strict at deploy time (nothing has touched the contract yet), informational in verify-only: see the
    ///      call site. `expectedSource` names the setting the expectation came from, for the log line.
    function _checkAvailability(
        bool actual,
        bool expected,
        bool live,
        string memory action,
        string memory expectedSource
    ) private view {
        if (actual == expected) return;
        if (!live) revert(string.concat("check: ", action, " availability"));
        console2.log(
            string.concat(
                "  NOTE: ",
                action,
                " availability is ",
                actual ? "true" : "false",
                " on chain, the env file expects ",
                expected ? "true" : "false",
                " (",
                expectedSource,
                "). Admin-mutable and expected to change after the hand-off, so this is informational only."
            )
        );
    }

    // ======================================
    // =              Logging               =
    // ======================================

    function _logOld(OldConfig memory o, Params memory p, address deployer) internal view {
        console2.log("=== DeployV050: source (v0.2.4) ===");
        console2.log("chain id              ", block.chainid);
        console2.log("source staking        ", o.staking);
        console2.log(
            "  resolved from       ",
            o.staking == sourceStakingFor(block.chainid) ? "per-chain table" : "SOURCE_STAKING override"
        );
        console2.log("source owner          ", o.owner);
        console2.log("source limit ctrl     ", o.limitController);
        if (o.limitController != address(0)) {
            console2.log("  controller owner    ", ILegacyLimitControllerV024(o.limitController).owner());
            console2.log("  controller target   ", o.limitControllerTarget);
            if (o.limitControllerTarget != o.staking) {
                console2.log("  WARNING: the source's controller was built for ANOTHER staking contract; its defaults");
                console2.log("           are copied as configured, but the source never enforced them for itself");
            }
        } else {
            console2.log("  WARNING: no controller on the source, defaults copied as 0 (stakes need wallet limits/extra)");
        }
        console2.log("RequirementCheckerV2  ", p.requirementCheckerV2);
        console2.log("deployer (sender)     ", deployer);
        console2.log("voucher signer        ", p.voucherSigner);
        console2.log("treasury              ", p.treasury);
        console2.log("max extra APY (bps)   ", p.maxExtraApyBps);
        console2.log("max extra limit (wei) ", p.maxExtraLimitTotal);
        console2.log("max extra limit/cell  ", p.maxExtraLimitPerCell);
        console2.log("max voucher validity  ", p.maxVoucherValidity);
        console2.log("new owner             ", p.newOwner);
        console2.log("admins                ", p.admins.length);
        for (uint256 i = 0; i < p.admins.length; ++i) {
            console2.log("  admin               ", p.admins[i]);
        }
        console2.log("open staking          ", _b(p.openStaking));
        console2.log("reward top-up (wei)   ", p.rewardTopUp);
        console2.log(
            "wallet limits file    ", bytes(p.walletLimitsFile).length == 0 ? "(none)" : p.walletLimitsFile
        );
        if (p.resumeStaking != address(0)) {
            console2.log("RESUME staking        ", p.resumeStaking);
            console2.log("RESUME controller     ", p.resumeController);
            console2.log("  ^ RESUME mode: only the missing transactions are sent, the self-check still runs in full");
        }
        console2.log("^ resolved settings: they must match the deploy-v050.sh banner; stop if they do not");
        console2.log("");
        console2.log("Not copied (v0.2.4 does not expose it, or v0.4.0 removed it):");
        console2.log("  - contract admins: mapping, not enumerable -> pass ADMINS");
        console2.log("  - per-wallet limits: mapping, not enumerable -> pass WALLET_LIMITS_FILE");
        console2.log("  - controller defaults for (phase, period) cells outside the current config (e.g. removed periods)");
        console2.log("  - requirementChecker (removed in v0.4.0, eligibility is in the voucher):", o.requirementChecker);
        console2.log("  - whitelistEnabled (removed in v0.4.0):", _b(o.whitelistEnabled));
        console2.log("  - reward pool / deposits / accounting (never migrated; source stake counts via the legacy link)");
    }

    function _logManualSteps(OldConfig memory o, Params memory p, Deployment memory d, uint256 blockBeforeDeploy)
        internal
        view
    {
        console2.log("");
        console2.log("=== Deployed ===");
        console2.log("ERC20PeriodicalStaking v0.5.0 ", address(d.staking));
        console2.log("LimitController                ", address(d.controller));
        console2.log("");
        console2.log("=== MANUAL steps (other owners / deliberate decisions) ===");
        _logRequirementCheckerStep(o, p, d);
        console2.log("2. Fund the reward pool: token.approve(staking, amount) + provideReward(amount) (owner or admin)");
        console2.log(string.concat("3. Backend pawnshop/networks/", vm.toString(block.chainid), ".json:"));
        console2.log(string.concat("   CONTRACTS.PERIODIC_STAKING_V050.ADDRESS = ", vm.toString(address(d.staking))));
        console2.log(
            string.concat(
                "   CONTRACTS.PERIODIC_STAKING_V050.DEPLOYMENT_BLOCK = ",
                vm.toString(blockBeforeDeploy),
                "   (safe lower bound: the block before the first transaction)"
            )
        );
        console2.log(
            string.concat(
                "   Exact block: the blockNumber of the receipt whose contractAddress is the staking contract in broadcast/DeployV050.s.sol/",
                vm.toString(block.chainid),
                "/run-latest.json (after --broadcast)"
            )
        );
        console2.log("   NOTE: only a backend build that reads PERIODIC_STAKING_V050 picks this up. Older builds read");
        console2.log("   PERIODIC_STAKING_V040, silently ignore a V050 block and keep signing for the old contract.");
        console2.log("4. Deploy the StakingLens for this staking contract and give its address to the frontend. The frontend");
        console2.log("   reads getProgramDataWithUserData, getDepositsInRangeBy and getBonusUsageBatch from the lens; without");
        console2.log("   it the staking page shows no data. From the repo root (subshell, so RPC_URL stays out of your shell):");
        console2.log(
            string.concat(
                "   ( set -a; . deploy/v050/<network>.env; set +a; STAKING=",
                vm.toString(address(d.staking)),
                " forge script script/DeployLens.s.sol --rpc-url deploy-v050 --account <KEYSTORE_ACCOUNT> --sender <DEPLOYER_ADDRESS> --broadcast --slow )"
            )
        );
        console2.log("   Add --verify when ETHERSCAN_API_KEY is set in that env file.");
        console2.log("5. Source owner", o.owner);
        console2.log("   changeActionAvailability(0 /*STAKING*/, false) on", o.staking);
        if (p.newOwner != address(0)) {
            console2.log("");
            console2.log("6. !!! TWO acceptOwnership() CALLS ARE REQUIRED - BOTH CONTRACTS ARE TWO-STEP !!!");
            console2.log("   Until BOTH land, the deployer still owns whichever one was missed, and NEW_OWNER cannot");
            console2.log("   change its settings. NEW_OWNER is", p.newOwner);
            console2.log("   6a. acceptOwnership() on the staking contract ", address(d.staking));
            console2.log("   6b. acceptOwnership() on the LimitController  ", address(d.controller));
            console2.log("   Then re-run ./script/deploy-v050.sh <network> --verify-only: it FAILS on a");
            console2.log("   half-finished hand-off, so it is the check that 6a and 6b both landed.");
            console2.log("");
        }
        if (!p.openStaking) {
            console2.log("7. When ready: changeActionAvailability(0 /*STAKING*/, true) on the new staking contract");
        }
    }

    /// @dev Reads the live periodical list from this chain's RequirementCheckerV2 and prints the full replacement.
    function _logRequirementCheckerStep(OldConfig memory o, Params memory p, Deployment memory d) internal view {
        address rc = p.requirementCheckerV2;
        if (rc == address(0) || rc.code.length == 0) {
            console2.log("1. RequirementCheckerV2 unknown on this chain (set REQUIREMENT_CHECKER_V2): as its owner call");
            console2.log("   setPeriodicalStakingContracts(<current list> + new staking), then check the count");
            return;
        }
        IRequirementCheckerV2Read checker = IRequirementCheckerV2Read(rc);
        uint256 count;
        try checker.periodicalStakingContractCount() returns (uint256 c) {
            count = c;
        } catch {
            console2.log("1. Could not read RequirementCheckerV2", rc, "- add the new contract to its periodical list");
            return;
        }
        string memory list = "[";
        bool sourceListed;
        for (uint256 i = 0; i < count; ++i) {
            address entry = checker.periodicalStakingContracts(i);
            if (entry == o.staking) sourceListed = true;
            list = string.concat(list, vm.toString(entry), ",");
        }
        list = string.concat(list, vm.toString(address(d.staking)), "]");
        console2.log("1. RequirementCheckerV2", rc);
        console2.log("   owner", checker.owner());
        console2.log(string.concat("   setPeriodicalStakingContracts(", list, ")"));
        console2.log(
            string.concat(
                "   then check periodicalStakingContractCount() == ",
                vm.toString(count + 1),
                " and periodicalStakingContracts(",
                vm.toString(count),
                ") == new staking"
            )
        );
        if (!sourceListed) console2.log("   NOTE: the source contract is not in this checker's current list");
    }

    function _requireEnv(string memory name) internal view {
        require(envSet(name), string.concat("DeployV050: missing required env var ", name));
    }

    function _envAddressOr(string memory name, address defaultValue) internal view returns (address) {
        return envSet(name) ? vm.envAddress(name) : defaultValue;
    }

    function _envUintOr(string memory name, uint256 defaultValue) internal view returns (uint256) {
        return envSet(name) ? vm.envUint(name) : defaultValue;
    }

    function _b(bool v) private pure returns (string memory) {
        return v ? "true" : "false";
    }

    /// @dev "1000000 tokens" when whole, otherwise the raw wei amount.
    function _tok(uint256 amount, uint256 unit) private pure returns (string memory) {
        if (amount % unit == 0) return string.concat(vm.toString(amount / unit), " tokens");
        return string.concat(vm.toString(amount), " wei");
    }
}
