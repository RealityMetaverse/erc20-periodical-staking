// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {RequirementCheckerV2Test} from "../../requirement-checker-v2/RequirementCheckerV2.t.sol";
import {RequirementChecker} from "../../../src/contracts/requirement-checker/RequirementChecker.sol";
import {RequirementCheckerV2} from "../../../src/contracts/requirement-checker/v2/RequirementCheckerV2.sol";
import {MockERC1155} from "../../shared/mocks/MockERC1155.sol";

/// @dev Configurable fake "V1" exposing the getters cloneConfigFrom reads. Lets a test feed V2 a source
///      config the real V1 setters may not produce (zero worthToken, duplicate entries).
contract FakeV1 {
    address public worthToken;
    uint256 public defaultRequiredWorth;
    address[] public stakingContracts;
    address[] public periodicalStakingContracts;
    address[] public erc1155Contracts;
    mapping(address => uint256[]) public erc1155TrackedIds;
    mapping(address => mapping(uint256 => uint256)) public erc1155IdWorth;

    constructor(address _worthToken) {
        worthToken = _worthToken;
    }

    function pushStaking(address a) external { stakingContracts.push(a); }
    function pushPeriodical(address a) external { periodicalStakingContracts.push(a); }

    function pushErc1155(address token, uint256[] calldata ids, uint256 worth) external {
        erc1155Contracts.push(token);
        erc1155TrackedIds[token] = ids;
        for (uint256 i = 0; i < ids.length; i++) erc1155IdWorth[token][ids[i]] = worth;
    }

    function stakingContractCount() external view returns (uint256) { return stakingContracts.length; }
    function periodicalStakingContractCount() external view returns (uint256) { return periodicalStakingContracts.length; }
    function erc1155ContractCount() external view returns (uint256) { return erc1155Contracts.length; }
}

/// @notice Audit regression tests for RequirementCheckerV2. Each `test_fixed<N>_` test started life as a PoC that
///         PASSED while asserting the buggy behaviour; it now asserts the FIXED behaviour. `test_limitation11_`
///         (documented limitation) and `test_refuted27c_` (claim refuted) keep asserting the original behaviour.
contract RCv2AuditPoC is RequirementCheckerV2Test {
    int256 constant MAX_OFFSET = int256(type(int128).max);

    // ---------------------------------------------------------------- #11
    /// Finding #11 - DOCUMENTED LIMITATION, not fixed on-chain: worth is a spot balance read, so the same NFTs
    /// qualify two wallets sequentially. NatSpec on meetsRequirement / getTotalWorth tells consumers (the
    /// backend) to apply their own holding-period / snapshot controls. This test pins the behaviour.
    function test_limitation11_sameNftsQualifyTwoWallets() public {
        nft.mint(alice, 2, 4); // 4 * 250 = 1000 == DEFAULT_REQ
        assertTrue(v2.meetsRequirement(alice, 1, 1));
        assertFalse(v2.meetsRequirement(bob, 1, 1));

        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 2, 4, "");

        assertTrue(v2.meetsRequirement(bob, 1, 1)); // same 4 tokens, second wallet now passes
        assertFalse(v2.meetsRequirement(alice, 1, 1));
    }

    // ---------------------------------------------------------------- #26
    /// Finding #26 (NatSpec-only fix): 0 clears the override and falls back to defaultRequiredWorth; the
    /// documented way to exempt one cell while a default is set is a requirement of 1.
    function test_fixed26_zeroClearsOverride_oneExemptsCell() public {
        v2.setRequiredWorthPhasePeriod(5, 5, 0);
        assertEq(v2.getRequiredWorth(5, 5), DEFAULT_REQ); // not 0
        assertFalse(v2.meetsRequirement(bob, 5, 5)); // bob has nothing -> still gated

        // set -> clear also returns to the default, not to "no requirement"
        v2.setRequiredWorthPhasePeriod(5, 5, 5000);
        v2.setRequiredWorthPhasePeriod(5, 5, 0);
        assertEq(v2.getRequiredWorth(5, 5), DEFAULT_REQ);

        // documented exemption: 1 (any wallet with 1 unit of worth passes)
        v2.setRequiredWorthPhasePeriod(5, 5, 1);
        assertEq(v2.getRequiredWorth(5, 5), 1);
        token.transfer(bob, 1);
        assertTrue(v2.meetsRequirement(bob, 5, 5));
        assertFalse(v2.meetsRequirement(bob, 5, 6)); // other cells still use the default
    }

    // ---------------------------------------------------------------- #27a
    /// Finding #27(a) FIXED: an ERC1155 contract present in V2 but absent from V1 is wiped by cloneConfigFrom.
    function test_fixed27a_cloneClearsStaleErc1155Contract() public {
        MockERC1155 extra = new MockERC1155();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9;
        uint256[] memory worths = new uint256[](1);
        worths[0] = 1000;
        v2.setERC1155Configs(address(extra), ids, worths);
        extra.mint(bob, 9, 1);
        assertTrue(v2.meetsRequirement(bob, 1, 1));

        v2.cloneConfigFrom(address(v1));

        assertEq(v1.erc1155ContractCount(), 1);
        assertEq(v2.erc1155ContractCount(), 1); // mirrors V1
        assertEq(v2.erc1155Contracts(0), address(nft));
        assertEq(v2.erc1155IdWorth(address(extra), 9), 0);
        vm.expectRevert();
        v2.erc1155TrackedIds(address(extra), 0); // tracked-id list emptied
        assertFalse(v2.meetsRequirement(bob, 1, 1)); // no longer grants worth
        assertFalse(v1.meetsRequirement(bob, 1, 1));
    }

    /// Finding #27(a) FIXED: ids tracked by V2 but not by V1 for a contract both share are dropped too, and a
    /// source with no ERC1155 config at all leaves V2 with none.
    function test_fixed27a_cloneFromEmptySourceClearsEverything() public {
        FakeV1 fake = new FakeV1(address(token));
        v2.cloneConfigFrom(address(fake));
        assertEq(v2.erc1155ContractCount(), 0);
        assertEq(v2.erc1155IdWorth(address(nft), 1), 0);
        assertEq(v2.erc1155IdWorth(address(nft), 2), 0);
        vm.expectRevert();
        v2.erc1155TrackedIds(address(nft), 0);
    }

    /// Finding #27(a) FIXED: the `idCount == 0` path - a source that lists a contract with no tracked ids must
    /// not let V2's existing config for that contract survive.
    function test_fixed27a_cloneSourceContractWithoutIdsDoesNotKeepV2Config() public {
        FakeV1 fake = new FakeV1(address(token));
        fake.pushErc1155(address(nft), new uint256[](0), 0);
        nft.mint(bob, 2, 4);
        assertTrue(v2.meetsRequirement(bob, 1, 1));

        v2.cloneConfigFrom(address(fake));

        assertEq(v2.erc1155ContractCount(), 0);
        assertEq(v2.erc1155IdWorth(address(nft), 2), 0);
        assertEq(v2.totalERC1155Worth(bob), 0);
    }

    // ---------------------------------------------------------------- #27b
    /// Finding #27(b) FIXED: cloneConfigFrom rejects a zero worthToken, like setWorthToken and the constructor.
    function test_fixed27b_cloneRejectsZeroWorthToken() public {
        FakeV1 fake = new FakeV1(address(0));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.cloneConfigFrom(address(fake));
        assertEq(address(v2.worthToken()), address(token)); // unchanged
    }

    // ---------------------------------------------------------------- #27c
    /// Finding #27(c) REFUTED in practice (no code change, comment added in cloneConfigFrom): sweep the gas
    /// supplied to cloneConfigFrom. Every successful run copied ALL tracked ids; an OOG inside the probe never
    /// yields a silently truncated clone, because the 1/64 gas left after the catch cannot pay for the
    /// following SSTOREs.
    function test_refuted27c_gasSweepNeverTruncates() public {
        // V1 with 12 tracked ids
        uint256 n = 12;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory worths = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = 100 + i;
            worths[i] = 1 + i;
        }
        v1.setERC1155Configs(address(nft), ids, worths);

        uint256 successes;
        uint256 failures;
        uint256 truncated;
        uint256 snap = vm.snapshot();
        for (uint256 g = 20_000; g < 900_000; g += 397) {
            try v2.cloneConfigFrom{gas: g}(address(v1)) {
                successes++;
                bool full = true;
                try v2.erc1155TrackedIds(address(nft), n - 1) returns (uint256 last) {
                    if (last != 100 + n - 1) full = false;
                } catch {
                    full = false;
                }
                if (!full) truncated++;
            } catch {
                failures++;
            }
            vm.revertTo(snap);
        }
        assertGt(successes, 0);
        assertGt(failures, 0);
        assertEq(truncated, 0, "no truncated clone observed");
    }

    // ---------------------------------------------------------------- #28
    /// Finding #28 FIXED: duplicate ids are rejected instead of double counting.
    function test_fixed28_duplicateIdsRejected() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 7;
        ids[1] = 8;
        ids[2] = 7;
        uint256[] memory worths = new uint256[](3);
        worths[0] = 100;
        worths[1] = 50;
        worths[2] = 250;
        vm.expectRevert(abi.encodeWithSignature("DuplicateId(uint256)", 7));
        v2.setERC1155Configs(address(nft), ids, worths);

        // previous config untouched
        assertEq(v2.erc1155IdWorth(address(nft), 2), 250);
    }

    /// Finding #28 FIXED: a staking / periodical contract listed twice is rejected (constructor included).
    function test_fixed28_duplicateStakingContractsRejected() public {
        address[] memory pool = new address[](2);
        pool[0] = address(stakingA);
        pool[1] = address(stakingA);
        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(stakingA)));
        v2.setPoolStakingContracts(pool);

        address[] memory per = new address[](2);
        per[0] = address(periodicalA);
        per[1] = address(periodicalA);
        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(periodicalA)));
        v2.setPeriodicalStakingContracts(per);

        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(stakingA)));
        new RequirementCheckerV2(address(token), pool, new address[](0), DEFAULT_REQ);
        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(periodicalA)));
        new RequirementCheckerV2(address(token), new address[](0), per, DEFAULT_REQ);

        // the lists set in setUp are untouched
        assertEq(v2.poolStakingContractCount(), 2);
        assertEq(v2.periodicalStakingContractCount(), 1);
    }

    /// Finding #28 FIXED: cloneConfigFrom surfaces the same clear revert when the SOURCE holds duplicates.
    function test_fixed28_cloneRejectsDuplicatesInSource() public {
        FakeV1 dupPool = new FakeV1(address(token));
        dupPool.pushStaking(address(stakingA));
        dupPool.pushStaking(address(stakingA));
        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(stakingA)));
        v2.cloneConfigFrom(address(dupPool));

        FakeV1 dupPer = new FakeV1(address(token));
        dupPer.pushPeriodical(address(periodicalA));
        dupPer.pushPeriodical(address(periodicalA));
        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(periodicalA)));
        v2.cloneConfigFrom(address(dupPer));

        FakeV1 dupIds = new FakeV1(address(token));
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 7;
        dupIds.pushErc1155(address(nft), ids, 250);
        vm.expectRevert(abi.encodeWithSignature("DuplicateId(uint256)", 7));
        v2.cloneConfigFrom(address(dupIds));

        // a reverted clone leaves V2 exactly as it was
        assertEq(v2.poolStakingContractCount(), 2);
        assertEq(v2.erc1155ContractCount(), 1);
        assertEq(v2.erc1155IdWorth(address(nft), 2), 250);
    }

    /// Finding #28: a source listing the same ERC1155 CONTRACT twice is harmless - the second pass rewrites
    /// the same config and the contract is registered once.
    function test_fixed28_cloneSourceWithDuplicateErc1155ContractRegistersOnce() public {
        FakeV1 fake = new FakeV1(address(token));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        fake.pushErc1155(address(nft), ids, 250);
        fake.pushErc1155(address(nft), ids, 250);
        v2.cloneConfigFrom(address(fake));
        assertEq(v2.erc1155ContractCount(), 1);
        nft.mint(bob, 7, 1);
        assertEq(v2.totalERC1155Worth(bob), 250);
    }

    // ---------------------------------------------------------------- #29
    /// Finding #29 FIXED: every offset setter (single and batch) bounds |offset| to type(int128).max.
    function test_fixed29_offsetSettersAreBounded() public {
        int256 tooBig = MAX_OFFSET + 1;
        int256 tooSmall = -MAX_OFFSET - 1;
        bytes memory errBig = abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", tooBig, MAX_OFFSET);
        bytes memory errSmall = abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", tooSmall, MAX_OFFSET);
        bytes memory errMin =
            abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", type(int256).min, MAX_OFFSET);

        vm.expectRevert(errBig);
        v2.setErc20Offset(alice, tooBig);
        vm.expectRevert(errSmall);
        v2.setErc20Offset(alice, tooSmall);
        vm.expectRevert(errMin);
        v2.setErc20Offset(alice, type(int256).min);

        vm.expectRevert(errBig);
        v2.setPoolStakingOffset(alice, address(stakingA), tooBig);
        vm.expectRevert(errSmall);
        v2.setPoolStakingOffset(alice, address(stakingA), tooSmall);

        vm.expectRevert(errBig);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), tooBig);
        vm.expectRevert(errSmall);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), tooSmall);

        vm.expectRevert(errBig);
        v2.setNftCountOffset(alice, address(nft), 2, tooBig);
        vm.expectRevert(errSmall);
        v2.setNftCountOffset(alice, address(nft), 2, tooSmall);

        // batch path shares the bound
        address[] memory wallets = new address[](2);
        wallets[0] = bob;
        wallets[1] = alice;
        int256[] memory offsets = new int256[](2);
        offsets[0] = 1;
        offsets[1] = tooBig;
        vm.expectRevert(errBig);
        v2.setErc20OffsetBatch(wallets, offsets);

        // the bounds themselves are accepted
        v2.setErc20Offset(alice, MAX_OFFSET);
        v2.setErc20Offset(bob, -MAX_OFFSET);
        assertEq(v2.erc20Offset(alice), MAX_OFFSET);
        assertEq(v2.erc20Offset(bob), -MAX_OFFSET);
    }

    /// Finding #29 FIXED: the largest accepted offsets on every source no longer break that wallet's reads,
    /// and one wallet can no longer poison a meetsRequirementBatch call.
    function test_fixed29_maxOffsetsKeepReadsAndBatchAlive() public {
        token.transfer(alice, 1);
        nft.mint(alice, 2, 1);
        v2.setErc20Offset(alice, MAX_OFFSET);
        v2.setPoolStakingOffset(alice, address(stakingA), MAX_OFFSET);
        v2.setPoolStakingOffset(alice, address(stakingB), MAX_OFFSET);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), MAX_OFFSET);
        v2.setNftCountOffset(alice, address(nft), 1, MAX_OFFSET);
        v2.setNftCountOffset(alice, address(nft), 2, MAX_OFFSET); // idWorth 250

        uint256 m = uint256(MAX_OFFSET);
        uint256 expected = (1 + m) + 2 * m + m + m * 100 + (1 + m) * 250;
        assertEq(v2.getTotalWorth(alice), expected);
        assertEq(v2.getAppliedOffsetsWorth(alice), int256(expected - 1 - 250));

        // fully negative: every source clamps at 0
        v2.setErc20Offset(alice, -MAX_OFFSET);
        v2.setNftCountOffset(alice, address(nft), 2, -MAX_OFFSET);
        v2.setNftCountOffset(alice, address(nft), 1, 0);
        v2.setPoolStakingOffset(alice, address(stakingA), -MAX_OFFSET);
        v2.setPoolStakingOffset(alice, address(stakingB), -MAX_OFFSET);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), -MAX_OFFSET);
        assertEq(v2.getTotalWorth(alice), 0);
        assertEq(v2.getAppliedOffsetsWorth(alice), -int256(1 + 250));

        v2.setErc20Offset(alice, MAX_OFFSET);
        address[] memory users = new address[](2);
        users[0] = bob;
        users[1] = alice;
        uint256[] memory z = new uint256[](2);
        bool[] memory res = v2.meetsRequirementBatch(users, z, z);
        assertFalse(res[0]);
        assertTrue(res[1]);
    }

    /// Finding #29 FIXED: a raw value >= 2^255 from an owner-configured contract no longer wraps negative and
    /// silently clamps to 0 - the offset-aware reads revert with SafeCast's typed error. Raw reads still work.
    function test_fixed29_absurdBalanceRevertsInsteadOfWrapping() public {
        uint256 absurd = uint256(1) << 255;
        bytes memory err = abi.encodeWithSignature("SafeCastOverflowedUintToInt(uint256)", absurd);

        periodicalA.setUserData(0, alice, absurd);
        assertEq(v2.rawTotalPeriodicalStaked(alice), absurd);
        vm.expectRevert(err);
        v2.totalPeriodicalStaked(alice);
        vm.expectRevert(err);
        v2.getTotalWorth(alice);
        vm.expectRevert(err);
        v2.getTokenWorth(alice);
        vm.expectRevert(err);
        v2.getAppliedOffsetsWorth(alice);
        periodicalA.setUserData(0, alice, 0);

        stakingA.setStaked(alice, 0, absurd);
        vm.expectRevert(err);
        v2.totalPoolStaked(alice);
        vm.expectRevert(err);
        v2.getAppliedOffsetsWorth(alice);
        stakingA.setStaked(alice, 0, 0);

        nft.mint(alice, 1, absurd);
        vm.expectRevert(err);
        v2.totalERC1155Worth(alice);
        vm.expectRevert(err);
        v2.getAppliedOffsetsWorth(alice);

        // The single-wallet check still surfaces the typed error to whoever asked about that wallet.
        vm.expectRevert(err);
        v2.meetsRequirement(alice, 0, 0);

        // Batch semantics: each entry is isolated, so alice's failing read is reported as "does not meet the
        // requirement" and bob is still answered, instead of one wallet taking the whole batch down.
        address[] memory users = new address[](2);
        users[0] = bob;
        users[1] = alice;
        uint256[] memory z = new uint256[](2);
        bool[] memory res = v2.meetsRequirementBatch(users, z, z);
        assertEq(res.length, 2);
        assertEq(res[0], v2.meetsRequirement(bob, 0, 0), "bob is evaluated normally");
        assertFalse(res[1], "a reverting worth read must report as NOT meeting the requirement");
    }
}
