// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {DeployV050} from "../../script/DeployV050.s.sol";
import {LimitController} from "../../src/contracts/LimitController.sol";

interface IVmSkipWL {
    function skip(bool skipTest) external;
}

/// @notice The v0.2.4-era LimitController surface this test uses (write + getAllowed).
interface ILegacyLimitControllerWL {
    function owner() external view returns (address);
    function setWalletLimits(address[] calldata wallets, uint256 phase, uint256 period, uint256[] calldata limits)
        external;
    function walletPhasePeriodLimit(address wallet, uint256 phase, uint256 period) external view returns (uint256);
    function getAllowed(address wallet, uint256 phase, uint256 period) external view returns (uint256);
}

/// @notice WALLET_LIMITS_FILE end to end on a fork: the source controller's owner sets wallet limits, the script
///         loads a CRLF CSV fixture of them, deploys, and the new controller must allow exactly what the old one does.
/// @dev Opt-in like DeployV050Fork.t.sol (FORK_RPC_URL / POLYGON_RPC_URL, optional FORK_BLOCK). The fixture only
///      uses phase 0 / period 0, the one cell configured on both Polygon and Amoy.
contract DeployV050ForkWalletLimitsTest is Test {
    IVmSkipWL private constant VM_SKIP = IVmSkipWL(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant FIXTURE = "test/v050/fixtures/wallet-limits-crlf.csv";
    string internal constant FIXTURE_MISMATCH = "test/v050/fixtures/wallet-limits-mismatch.csv";

    // Rows of FIXTURE, in file order. W2 is the limit-0 row (never set on chain).
    address internal constant W1 = 0x000000000000000000000000000000000000a001;
    address internal constant W2 = 0x000000000000000000000000000000000000A002;
    address internal constant W3 = 0x000000000000000000000000000000000000a003;
    address internal constant W4 = 0x000000000000000000000000000000000000A004;
    uint256 internal constant L1 = 5_000e18;
    uint256 internal constant L3 = 123_456_789;
    uint256 internal constant L4 = 1;

    bool internal forkOn;
    DeployV050 internal script;
    DeployV050.OldConfig internal old;
    ILegacyLimitControllerWL internal oldController;

    modifier onlyFork() {
        if (!forkOn) {
            console2.log("DeployV050ForkWalletLimitsTest skipped: set FORK_RPC_URL (or POLYGON_RPC_URL)");
            VM_SKIP.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", vm.envOr("POLYGON_RPC_URL", string("")));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forkOn = true;

        script = new DeployV050();
        address source = vm.envOr("SOURCE_STAKING", script.sourceStakingFor(block.chainid));
        require(source != address(0), "no source staking contract for this chain; set SOURCE_STAKING");
        old = script.readOldConfig(source);
        require(old.limitController != address(0), "source has no LimitController");
        oldController = ILegacyLimitControllerWL(old.limitController);

        // Fork-local: the old controller's owner sets the fixture's non-zero limits.
        address[] memory wallets = new address[](3);
        uint256[] memory limits = new uint256[](3);
        (wallets[0], wallets[1], wallets[2]) = (W1, W3, W4);
        (limits[0], limits[1], limits[2]) = (L1, L3, L4);
        vm.prank(oldController.owner());
        oldController.setWalletLimits(wallets, 0, 0, limits);
    }

    function test_fork_walletLimitsFileCopiedExactly() external onlyFork {
        assertTrue(_contains(bytes(vm.readFile(FIXTURE)), "\r\n"), "fixture lost its CRLF line endings");

        DeployV050.WalletLimitRow[] memory rows = script.loadWalletLimits(FIXTURE, old);
        assertEq(rows.length, 3, "limit-0 row dropped, header/comment/blank skipped");

        (, DeployV050.Deployment memory d) = script.deployFrom(_params(old.staking), rows);
        LimitController c = d.controller;

        address[4] memory all = [W1, W2, W3, W4];
        for (uint256 i = 0; i < all.length; i++) {
            assertEq(c.getAllowed(all[i], 0, 0), oldController.getAllowed(all[i], 0, 0), "getAllowed new == old");
        }
        assertEq(c.getAllowed(W1, 0, 0), L1, "W1 limit");
        assertEq(c.getAllowed(W3, 0, 0), L3, "W3 limit");
        assertEq(c.getAllowed(W4, 0, 0), L4, "W4 limit");
        assertTrue(c.hasWalletLimit(W1, 0, 0) && c.hasWalletLimit(W3, 0, 0) && c.hasWalletLimit(W4, 0, 0), "set rows");
        assertEq(oldController.walletPhasePeriodLimit(W2, 0, 0), 0, "W2 has no limit on the source");
        assertFalse(c.hasWalletLimit(W2, 0, 0), "limit-0 row must not become a 'blocked' wallet limit");
        assertEq(c.getAllowed(W2, 0, 0), c.defaultPhasePeriodLimit(0, 0), "W2 falls back to the copied default");
    }

    function test_fork_walletLimitsFileMismatchReverts() external onlyFork {
        vm.expectRevert(
            bytes(
                string.concat(
                    "DeployV050: wallet limit line 2 does not match the source controller (on-chain ",
                    vm.toString(L1),
                    ")"
                )
            )
        );
        script.loadWalletLimits(FIXTURE_MISMATCH, old);
    }

    function _params(address source) internal returns (DeployV050.Params memory p) {
        p = DeployV050.Params({
            sourceStaking: source,
            requirementCheckerV2: script.requirementCheckerV2For(block.chainid),
            voucherSigner: makeAddr("voucherSigner"),
            treasury: makeAddr("treasury"),
            maxExtraApyBps: 500,
            maxExtraLimitTotal: 50_000e18,
            maxExtraLimitPerCell: 50_000e18,
            maxVoucherValidity: 1 days,
            newOwner: address(0),
            admins: new address[](0),
            openStaking: false,
            rewardTopUp: 0,
            walletLimitsFile: FIXTURE,
            resumeStaking: address(0),
            resumeController: address(0),
            allowSharedRoles: false
        });
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
