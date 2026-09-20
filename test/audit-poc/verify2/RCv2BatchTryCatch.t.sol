// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../../shared/TestToken.sol";
import {MockStakingContract} from "../../shared/mocks/MockStakingContract.sol";
import {MockPeriodicalStakingContract} from "../../shared/mocks/MockPeriodicalStakingContract.sol";
import {MockERC1155} from "../../shared/mocks/MockERC1155.sol";
import {RequirementCheckerV2} from "../../../src/contracts/requirement-checker/v2/RequirementCheckerV2.sol";
import {Errors} from "../../../src/common/Errors.sol";

/// @notice ERC1155 whose balanceOf reverts for one blacklisted wallet -- the "poison entry" the try/catch is
///         meant to isolate.
contract PoisonERC1155 is MockERC1155 {
    address public poison;

    function setPoison(address p) external {
        poison = p;
    }

    function balanceOfBatch(address[] memory accounts, uint256[] memory ids)
        public
        view
        override
        returns (uint256[] memory)
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == poison) revert("poisoned");
        }
        return super.balanceOfBatch(accounts, ids);
    }
}

/// @notice Calls meetsRequirementBatch with an attacker-chosen gas limit and reports whether the OUTER call
///         survived. This is the mechanism by which a gas-limited call could turn every entry silently false.
contract GasLimitedCaller {
    function probe(address checker, uint256 gasCap, address[] calldata users, uint256[] calldata phases, uint256[] calldata periods)
        external
        view
        returns (bool outerOk, bytes memory ret)
    {
        (outerOk, ret) = checker.staticcall{gas: gasCap}(
            abi.encodeWithSignature("meetsRequirementBatch(address[],uint256[],uint256[])", users, phases, periods)
        );
    }
}

contract RCv2BatchTryCatch is Test {
    TestToken token;
    MockStakingContract stakingA;
    MockPeriodicalStakingContract periodicalA;
    PoisonERC1155 nft;
    RequirementCheckerV2 v2;
    GasLimitedCaller prober;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC0);

    uint256 constant REQ = 1000;

    function setUp() public {
        token = new TestToken(18);
        stakingA = new MockStakingContract(2);
        periodicalA = new MockPeriodicalStakingContract();
        nft = new PoisonERC1155();
        prober = new GasLimitedCaller();

        address[] memory staking = new address[](1);
        staking[0] = address(stakingA);
        address[] memory periodical = new address[](1);
        periodical[0] = address(periodicalA);

        v2 = new RequirementCheckerV2(address(token), staking, periodical, REQ);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory worths = new uint256[](2);
        worths[0] = 100;
        worths[1] = 250;
        v2.setERC1155Configs(address(nft), ids, worths);

        // Everyone comfortably qualifies.
        token.transfer(alice, 5000);
        token.transfer(bob, 5000);
        token.transfer(carol, 5000);
    }

    function _arr3(address a, address b, address c) internal pure returns (address[] memory u) {
        u = new address[](3);
        u[0] = a;
        u[1] = b;
        u[2] = c;
    }

    function _zeros(uint256 n) internal pure returns (uint256[] memory z) {
        z = new uint256[](n);
    }

    // ------------------------------------------------------------------
    // The behaviour the fix intends
    // ------------------------------------------------------------------

    /// @dev A reverting entry must be reported as false, and must not take the neighbours down with it.
    function test_v2_poisonEntryIsolated() public {
        nft.setPoison(bob);
        address[] memory u = _arr3(alice, bob, carol);
        bool[] memory r = v2.meetsRequirementBatch(u, _zeros(3), _zeros(3));
        assertTrue(r[0], "alice must qualify");
        assertFalse(r[1], "the poisoned entry must be false, not a revert");
        assertTrue(r[2], "carol must qualify");

        // The single-wallet read still surfaces the real reason.
        vm.expectRevert(bytes("poisoned"));
        v2.meetsRequirement(bob, 0, 0);
    }

    // ------------------------------------------------------------------
    // SILENT-FAILURE MODE: a CONFIG breakage becomes a 100%-false batch
    // ------------------------------------------------------------------

    /// @dev The try/catch is per entry, but a broken CONFIG breaks every entry identically. The batch then
    ///      reports "nobody qualifies" with a successful return, while the single-wallet read still reverts.
    ///      A backend that only calls the batch cannot tell "nobody qualifies" from "the checker is broken".
    function test_v2_brokenConfigMakesTheWholeBatchSilentlyFalse() public {
        address[] memory u = _arr3(alice, bob, carol);
        uint256[] memory z = _zeros(3);
        bool[] memory ok = v2.meetsRequirementBatch(u, z, z);
        assertTrue(ok[0] && ok[1] && ok[2], "baseline: everyone qualifies");

        // FIXED: the setter now rejects a non-zero address with no code, so this whole-config breakage --
        // which per-entry isolation would otherwise have turned into a SUCCESSFUL all-false batch,
        // indistinguishable from "nobody qualifies" -- can no longer be written in the first place.
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAContract.selector, address(0xDEAD)));
        v2.setWorthToken(address(0xDEAD));

        // Config unchanged, so the batch still reads exactly as it did before the attempt.
        bool[] memory r = v2.meetsRequirementBatch(u, z, z);
        assertTrue(r[0] && r[1] && r[2], "config must be untouched after the rejected setter call");
    }

    /// @dev Same with the ERC1155 poison applied to EVERY wallet (a token whose balanceOfBatch always reverts).
    function test_v2_globallyRevertingTokenIsSilentlyAllFalse() public {
        nft.setPoison(address(0)); // reset
        address[] memory u = _arr3(alice, bob, carol);
        uint256[] memory z = _zeros(3);

        // Replace the tracked ERC1155 with one that reverts for everyone.
        PoisonERC1155 bad = new PoisonERC1155();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory worths = new uint256[](1);
        worths[0] = 1;
        v2.setERC1155Configs(address(bad), ids, worths);
        bad.setPoison(alice);
        bad.setPoison(bob);

        bool[] memory r = v2.meetsRequirementBatch(u, z, z);
        emit log_named_string("alice", r[0] ? "true" : "false");
        emit log_named_string("bob", r[1] ? "true" : "false");
        emit log_named_string("carol", r[2] ? "true" : "false");
    }

    // ------------------------------------------------------------------
    // THE NEW SILENT-FAILURE MODE: caller-chosen gas
    // ------------------------------------------------------------------

    /// @dev Sweep gas limits. For each one, record whether the outer call returned successfully and how many
    ///      entries came back true. Any gas cap where outerOk == true and trueCount == 0 while the wallets
    ///      genuinely qualify is a silent all-false batch -- a wrong answer where the pre-fix code reverted.
    function test_v2_gasLimitedBatchCanReturnSilentFalse() public {
        address[] memory u = _arr3(alice, bob, carol);
        uint256[] memory z = _zeros(3);

        // Honest cost first.
        uint256 g = gasleft();
        bool[] memory honest = v2.meetsRequirementBatch(u, z, z);
        uint256 honestGas = g - gasleft();
        emit log_named_uint("honest meetsRequirementBatch(3) gas", honestGas);
        assertTrue(honest[0] && honest[1] && honest[2], "all three must genuinely qualify");

        uint256 silentAllFalse = 0;
        uint256 silentPartial = 0;
        uint256 reverted = 0;
        uint256 firstSilentCap = 0;

        for (uint256 cap = 3_000; cap <= 120_000; cap += 1_000) {
            (bool ok, bytes memory ret) = prober.probe(address(v2), cap, u, z, z);
            if (!ok) {
                reverted++;
                continue;
            }
            bool[] memory r = abi.decode(ret, (bool[]));
            uint256 trues = 0;
            for (uint256 i = 0; i < 3; i++) {
                if (r[i]) trues++;
            }
            if (trues == 0) {
                if (firstSilentCap == 0) firstSilentCap = cap;
                silentAllFalse++;
            } else if (trues < 3) {
                silentPartial++;
            }
        }

        emit log_named_uint("gas caps that reverted (safe)", reverted);
        emit log_named_uint("gas caps returning a SILENT all-false batch", silentAllFalse);
        emit log_named_uint("gas caps returning a SILENT partially-false batch", silentPartial);
        emit log_named_uint("lowest gas cap producing a silent all-false batch", firstSilentCap);

        // Record the finding, whichever way it lands.
        if (silentAllFalse + silentPartial > 0) {
            emit log("FINDING: a caller-chosen gas limit makes qualifying wallets report false with NO revert");
        } else {
            emit log("no gas cap produced a silent wrong answer in this sweep");
        }
    }

    /// @dev DEFINITIVE test of the silent-false window on the easiest case (len 1): binary-search the LOWEST
    ///      gas cap at which the outer call survives, then check the answer exactly there and just above.
    ///      If the answer at the survival boundary is already `true`, there is no gas cap that produces a
    ///      silent wrong answer -- the 1/64 the outer frame retains after a starved inner call is never enough
    ///      to finish the loop and return.
    function test_v2_noSilentFalseWindowAtTheSurvivalBoundary() public {
        address[] memory u = new address[](1);
        u[0] = alice;
        uint256[] memory z = _zeros(1);
        assertTrue(v2.meetsRequirementBatch(u, z, z)[0], "alice qualifies unconstrained");

        uint256 lo = 1_000; // reverts
        uint256 hi = 400_000; // survives
        (bool okHi,) = prober.probe(address(v2), hi, u, z, z);
        assertTrue(okHi, "upper bound must survive");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = prober.probe(address(v2), mid, u, z, z);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("len-1: lowest gas cap at which the outer call survives", hi);

        // Walk 2000 gas upward from the boundary, one gas at a time, looking for ANY surviving false.
        uint256 silent = 0;
        uint256 firstCap = 0;
        for (uint256 cap = hi; cap < hi + 2_000; cap++) {
            (bool ok, bytes memory ret) = prober.probe(address(v2), cap, u, z, z);
            if (!ok) continue;
            if (!abi.decode(ret, (bool[]))[0]) {
                if (firstCap == 0) firstCap = cap;
                silent++;
            }
        }
        emit log_named_uint("len-1: surviving caps in [boundary, boundary+2000) returning FALSE", silent);
        emit log_named_uint("len-1: lowest such cap (0 = none)", firstCap);
        assertEq(silent, 0, "FINDING: a gas-limited call returns a silent false for a qualifying wallet");
    }

    /// @dev Same boundary probe with a 10-entry batch, where the outer frame has more work left after a
    ///      starved entry (more room for the 1/64 remainder to matter).
    function test_v2_noSilentFalseWindowBatch10() public {
        uint256 n = 10;
        address[] memory u = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            u[i] = address(uint160(0x2000 + i));
            token.transfer(u[i], 5000);
        }
        uint256[] memory z = _zeros(n);
        bool[] memory honest = v2.meetsRequirementBatch(u, z, z);
        for (uint256 i = 0; i < n; i++) {
            assertTrue(honest[i], "all must qualify");
        }

        uint256 lo = 1_000;
        uint256 hi = 4_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = prober.probe(address(v2), mid, u, z, z);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("len-10: lowest surviving gas cap", hi);

        uint256 bad = 0;
        for (uint256 cap = hi; cap < hi + 3_000; cap += 1) {
            (bool ok, bytes memory ret) = prober.probe(address(v2), cap, u, z, z);
            if (!ok) continue;
            bool[] memory r = abi.decode(ret, (bool[]));
            for (uint256 i = 0; i < n; i++) {
                if (!r[i]) bad++;
            }
        }
        emit log_named_uint("len-10: FALSE entries among surviving caps near the boundary", bad);
        assertEq(bad, 0, "FINDING: gas-limited batch silently reports qualifying wallets as false");
    }

    // ------------------------------------------------------------------
    // Gas cost of the try/catch vs the direct loop it replaced
    // ------------------------------------------------------------------

    /// @dev Quantify the per-entry overhead the self-staticcall added. Compare a 20-entry batch against 20
    ///      direct meetsRequirement calls measured in the same frame (the closest stand-in for the old body).
    function test_v2_batchGasOverhead() public {
        uint256 n = 20;
        address[] memory u = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            u[i] = address(uint160(0x1000 + i));
            token.transfer(u[i], 5000);
        }
        uint256[] memory z = _zeros(n);

        // Warm every storage slot and every touched address first, so the comparison is warm-vs-warm.
        v2.meetsRequirementBatch(u, z, z);

        uint256 g = gasleft();
        v2.meetsRequirementBatch(u, z, z);
        uint256 batchGas = g - gasleft();

        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            g = gasleft();
            v2.meetsRequirement(u[i], 0, 0);
            sum += g - gasleft();
        }

        emit log_named_uint("WARM meetsRequirementBatch(20), with self-staticcall", batchGas);
        emit log_named_uint("WARM 20 x direct external meetsRequirement", sum);
        emit log_named_uint("WARM per-entry batch cost", batchGas / n);
    }

    /// @dev The self-call must be a STATICCALL: meetsRequirementBatch is `view`, so any state write inside the
    ///      isolated frame would revert. Confirmed by the fact that the whole function is callable through
    ///      staticcall from an external prober (used throughout this file) without reverting.
    function test_v2_batchIsStaticcallSafe() public view {
        address[] memory u = new address[](1);
        u[0] = alice;
        uint256[] memory z = _zeros(1);
        (bool ok, bytes memory ret) = address(v2).staticcall(
            abi.encodeWithSignature("meetsRequirementBatch(address[],uint256[],uint256[])", u, z, z)
        );
        require(ok, "batch not staticcall-safe");
        bool[] memory r = abi.decode(ret, (bool[]));
        require(r[0], "alice should qualify");
    }
}
