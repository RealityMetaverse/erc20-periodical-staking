// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../shared/TestToken.sol";
import {MockStakingContract} from "../shared/mocks/MockStakingContract.sol";
import {MockPeriodicalStakingContract} from "../shared/mocks/MockPeriodicalStakingContract.sol";
import {MockERC1155} from "../shared/mocks/MockERC1155.sol";
import {RequirementChecker} from "../../src/contracts/requirement-checker/RequirementChecker.sol";
import {RequirementCheckerV2} from "../../src/contracts/requirement-checker/v2/RequirementCheckerV2.sol";
import {IRequirementChecker} from "../../src/interfaces/IRequirementChecker.sol";

contract RequirementCheckerV2Test is Test {
    event WorthTokenUpdated(address indexed newToken);
    event ConfigClonedFrom(address indexed v1);
    event PhasePeriodRequirementsClonedFrom(address indexed v1, uint256[] phases, uint256[] periods);
    event RequiredPhasePeriodWorthSet(uint256 indexed phase, uint256 indexed period, uint256 requiredWorth);
    event ERC20OffsetSet(address indexed wallet, int256 offset);
    event PoolStakingOffsetSet(address indexed wallet, address indexed poolStakingContract, int256 offset);
    event PeriodicalStakingOffsetSet(
        address indexed wallet, address indexed periodicalStakingContract, int256 offset
    );
    event NFTCountOffsetSet(
        address indexed wallet, address indexed token, uint256 id, int256 offset
    );

    TestToken token;
    MockStakingContract stakingA;
    MockStakingContract stakingB;
    MockPeriodicalStakingContract periodicalA;
    MockERC1155 nft;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    RequirementChecker v1;
    RequirementCheckerV2 v2;

    uint256 constant DEFAULT_REQ = 1000;

    function setUp() public virtual {
        token = new TestToken(18);
        stakingA = new MockStakingContract(2);
        stakingB = new MockStakingContract(1);
        periodicalA = new MockPeriodicalStakingContract();
        nft = new MockERC1155();

        address[] memory staking = new address[](2);
        staking[0] = address(stakingA);
        staking[1] = address(stakingB);
        address[] memory periodical = new address[](1);
        periodical[0] = address(periodicalA);

        v1 = new RequirementChecker(address(token), staking, periodical, DEFAULT_REQ);
        v2 = new RequirementCheckerV2(address(token), staking, periodical, DEFAULT_REQ);

        // ERC1155 config: nft ids [1, 2] with worths [100, 250]
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory worths = new uint256[](2);
        worths[0] = 100;
        worths[1] = 250;
        v1.setERC1155Configs(address(nft), ids, worths);
        v2.setERC1155Configs(address(nft), ids, worths);
    }

    function _seedAliceBalances() internal {
        token.transfer(alice, 500);
        stakingA.setStaked(alice, 0, 100);
        stakingA.setStaked(alice, 1, 50);
        stakingB.setStaked(alice, 0, 30);
        periodicalA.setUserData(0, alice, 200);
        nft.mint(alice, 1, 2); // contributes 200
        nft.mint(alice, 2, 1); // contributes 250
    }

    function test_parity_worthBreakdown_matchesV1() public {
        _seedAliceBalances();
        (uint256 e1, uint256 s1, uint256 p1, uint256 n1) = v1.worthBreakdown(alice);
        (uint256 e2, uint256 s2, uint256 p2, uint256 n2) = v2.worthBreakdown(alice);
        assertEq(e1, e2, "erc20");
        assertEq(s1, s2, "staking");
        assertEq(p1, p2, "periodical");
        assertEq(n1, n2, "nft");
    }

    function test_parity_getTotalWorth_matchesV1() public {
        _seedAliceBalances();
        assertEq(v1.getTotalWorth(alice), v2.getTotalWorth(alice));
    }

    function test_parity_meetsRequirement_matchesV1() public {
        _seedAliceBalances();
        // real total = 500 + (100+50+30) + 200 + (200+250) = 1330 >= 1000
        assertTrue(v1.meetsDefaultRequirement(alice));
        assertTrue(v2.meetsDefaultRequirement(alice));
        assertEq(v1.meetsRequirement(alice, 1, 1), v2.meetsRequirement(alice, 1, 1));
    }

    function test_parity_meetsRequirement_phasePeriodSpecific() public {
        _seedAliceBalances(); // alice total worth = 1330
        // set a phase/period-specific requirement below her worth (passes)
        v1.setRequiredWorthPhasePeriod(2, 3, 1000);
        v2.setRequiredWorthPhasePeriod(2, 3, 1000);
        assertTrue(v1.meetsRequirement(alice, 2, 3));
        assertTrue(v2.meetsRequirement(alice, 2, 3));
        assertEq(v1.meetsRequirement(alice, 2, 3), v2.meetsRequirement(alice, 2, 3));

        // set a phase/period-specific requirement above her worth (fails)
        v1.setRequiredWorthPhasePeriod(2, 4, 2000);
        v2.setRequiredWorthPhasePeriod(2, 4, 2000);
        assertFalse(v1.meetsRequirement(alice, 2, 4));
        assertFalse(v2.meetsRequirement(alice, 2, 4));
        assertEq(v1.meetsRequirement(alice, 2, 4), v2.meetsRequirement(alice, 2, 4));
    }

    function test_worthToken_getterReturnsConstructorValue() public {
        assertEq(address(v2.worthToken()), address(token));
    }

    function test_v2_implementsNewInterface() public view {
        IRequirementChecker iface = IRequirementChecker(address(v2));
        iface.worthBreakdown(alice);
        iface.getRawTotalWorth(alice);
        iface.rawWorthBreakdown(alice);
        iface.getAppliedOffsetsWorth(alice);
        iface.getTokenWorth(alice);         // new
        iface.getRawTokenWorth(alice);      // new
    }

    function test_setWorthToken_owner_updatesAndEmits() public {
        TestToken newToken = new TestToken(18);
        vm.expectEmit(true, false, false, false, address(v2));
        emit WorthTokenUpdated(address(newToken));
        v2.setWorthToken(address(newToken));
        assertEq(address(v2.worthToken()), address(newToken));
    }

    function test_setWorthToken_zeroAddress_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setWorthToken(address(0));
    }

    function test_setWorthToken_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        v2.setWorthToken(address(token));
    }

    function test_setErc20Offset_owner_updatesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(v2));
        emit ERC20OffsetSet(alice, 100);
        v2.setErc20Offset(alice, 100);
        assertEq(v2.erc20Offset(alice), int256(100));
    }

    function test_setErc20Offset_zeroWallet_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setErc20Offset(address(0), 100);
    }

    function test_setErc20Offset_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        v2.setErc20Offset(alice, 100);
    }

    function test_erc20Offset_positive_addsToBreakdown() public {
        _seedAliceBalances(); // alice has 500 ERC20
        v2.setErc20Offset(alice, 300);
        (uint256 e,,,) = v2.worthBreakdown(alice);
        assertEq(e, 800);
    }

    function test_erc20Offset_negative_clampsAtZero() public {
        _seedAliceBalances(); // alice has 500 ERC20
        v2.setErc20Offset(alice, -1000);
        (uint256 e,,,) = v2.worthBreakdown(alice);
        assertEq(e, 0);
    }

    function test_erc20Offset_zero_restoresRaw() public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, 300);
        v2.setErc20Offset(alice, 0);
        (uint256 e,,,) = v2.worthBreakdown(alice);
        assertEq(e, 500);
        assertEq(v2.erc20Offset(alice), 0);
    }

    function test_setErc20OffsetBatch_applies() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        int256[] memory offsets = new int256[](2);
        offsets[0] = 50;
        offsets[1] = -5;
        v2.setErc20OffsetBatch(wallets, offsets);
        assertEq(v2.erc20Offset(alice), 50);
        assertEq(v2.erc20Offset(bob), -5);
    }

    function test_setErc20OffsetBatch_lengthMismatch_reverts() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        int256[] memory offsets = new int256[](1);
        offsets[0] = 50;
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        v2.setErc20OffsetBatch(wallets, offsets);
    }

    function test_erc20Offset_extremeNegative_clampsWithoutRevert() public {
        _seedAliceBalances(); // alice has 500 ERC20
        v2.setErc20Offset(alice, type(int256).min);
        (uint256 e,,,) = v2.worthBreakdown(alice);
        assertEq(e, 0);
    }

    function test_erc20Offset_extremePositive_overflows() public {
        // give bob a balance near 2^255 so int256 cast + positive offset overflows
        uint256 huge = uint256(type(int256).max);
        deal(address(token), bob, huge);
        v2.setErc20Offset(bob, type(int256).max);
        // int256(huge) + type(int256).max overflows; Solidity 0.8 reverts with Panic(0x11)
        vm.expectRevert();
        v2.worthBreakdown(bob);
    }

    function test_setPoolStakingOffset_owner_updatesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(v2));
        emit PoolStakingOffsetSet(alice, address(stakingA), -40);
        v2.setPoolStakingOffset(alice, address(stakingA), -40);
        assertEq(v2.poolStakingOffset(alice, address(stakingA)), -40);
    }

    function test_setPoolStakingOffset_zeroWallet_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setPoolStakingOffset(address(0), address(stakingA), 10);
    }

    function test_setPoolStakingOffset_zeroContract_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setPoolStakingOffset(alice, address(0), 10);
    }

    function test_poolStakingOffset_positive_addsToContractContribution() public {
        _seedAliceBalances(); // stakingA sum = 150, stakingB = 30
        v2.setPoolStakingOffset(alice, address(stakingA), 100);
        // staking total = (150 + 100) + 30 = 280
        (, uint256 s,,) = v2.worthBreakdown(alice);
        assertEq(s, 280);
    }

    function test_poolStakingOffset_negative_clampsPerContract() public {
        _seedAliceBalances(); // stakingA = 150, stakingB = 30
        v2.setPoolStakingOffset(alice, address(stakingA), -1000);
        // stakingA clamps to 0; stakingB unaffected
        (, uint256 s,,) = v2.worthBreakdown(alice);
        assertEq(s, 30);
        // Verify stakingB's offset mapping was not touched by the stakingA setter
        assertEq(v2.poolStakingOffset(alice, address(stakingB)), 0);
    }

    function test_poolStakingOffsetBatch_applies() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = alice;
        address[] memory poolStakingContracts_ = new address[](2);
        poolStakingContracts_[0] = address(stakingA);
        poolStakingContracts_[1] = address(stakingB);
        int256[] memory offsets = new int256[](2);
        offsets[0] = 20;
        offsets[1] = -5;
        v2.setPoolStakingOffsetBatch(wallets, poolStakingContracts_, offsets);
        assertEq(v2.poolStakingOffset(alice, address(stakingA)), 20);
        assertEq(v2.poolStakingOffset(alice, address(stakingB)), -5);
    }

    function test_poolStakingOffsetBatch_lengthMismatch_reverts() public {
        address[] memory wallets = new address[](2);
        address[] memory poolStakingContracts_ = new address[](1);
        int256[] memory offsets = new int256[](2);
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        v2.setPoolStakingOffsetBatch(wallets, poolStakingContracts_, offsets);
    }

    function test_setPeriodicalStakingOffset_owner_updatesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(v2));
        emit PeriodicalStakingOffsetSet(alice, address(periodicalA), 75);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), 75);
        assertEq(v2.periodicalStakingOffset(alice, address(periodicalA)), 75);
    }

    function test_setPeriodicalStakingOffset_zeroWallet_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setPeriodicalStakingOffset(address(0), address(periodicalA), 10);
    }

    function test_setPeriodicalStakingOffset_zeroContract_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setPeriodicalStakingOffset(alice, address(0), 10);
    }

    function test_periodicalStakingOffset_positive_addsToContractContribution() public {
        _seedAliceBalances(); // periodicalA = 200
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), 50);
        (,, uint256 p,) = v2.worthBreakdown(alice);
        assertEq(p, 250);
    }

    function test_periodicalStakingOffset_negative_clamps() public {
        _seedAliceBalances(); // periodicalA = 200
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), -1000);
        (,, uint256 p,) = v2.worthBreakdown(alice);
        assertEq(p, 0);
    }

    function test_setPeriodicalStakingOffsetBatch_applies() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        address[] memory periodicalStakingContracts_ = new address[](2);
        periodicalStakingContracts_[0] = address(periodicalA);
        periodicalStakingContracts_[1] = address(periodicalA);
        int256[] memory offsets = new int256[](2);
        offsets[0] = 40;
        offsets[1] = -10;
        v2.setPeriodicalStakingOffsetBatch(wallets, periodicalStakingContracts_, offsets);
        assertEq(v2.periodicalStakingOffset(alice, address(periodicalA)), 40);
        assertEq(v2.periodicalStakingOffset(bob, address(periodicalA)), -10);
    }

    function test_setPeriodicalStakingOffsetBatch_lengthMismatch_reverts() public {
        address[] memory wallets = new address[](2);
        address[] memory periodicalStakingContracts_ = new address[](2);
        int256[] memory offsets = new int256[](1);
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        v2.setPeriodicalStakingOffsetBatch(wallets, periodicalStakingContracts_, offsets);
    }

    function test_setNftCountOffset_owner_updatesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(v2));
        emit NFTCountOffsetSet(alice, address(nft), 1, 3);
        v2.setNftCountOffset(alice, address(nft), 1, 3);
        assertEq(v2.nftCountOffset(alice, address(nft), 1), 3);
    }

    function test_setNftCountOffset_zeroWallet_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setNftCountOffset(address(0), address(nft), 1, 1);
    }

    function test_setNftCountOffset_zeroToken_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        v2.setNftCountOffset(alice, address(0), 1, 1);
    }

    function test_nftCountOffset_positive_addsCountThenMultiplies() public {
        _seedAliceBalances(); // alice has 2 of id=1 (worth 100), 1 of id=2 (worth 250)
        v2.setNftCountOffset(alice, address(nft), 1, 3);
        // id=1: (2+3)*100 = 500; id=2: 1*250 = 250; nftWorth = 750
        (,,, uint256 n) = v2.worthBreakdown(alice);
        assertEq(n, 750);
    }

    function test_nftCountOffset_negative_clampsCount() public {
        _seedAliceBalances(); // alice has 2 of id=1
        v2.setNftCountOffset(alice, address(nft), 1, -10);
        // id=1 count clamps to 0; id=2 unchanged (1 * 250)
        (,,, uint256 n) = v2.worthBreakdown(alice);
        assertEq(n, 250);
        // also verify id=2's offset is untouched
        assertEq(v2.nftCountOffset(alice, address(nft), 2), 0);
    }

    function test_setNftCountOffsetBatch_applies() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = alice;
        address[] memory tokens = new address[](2);
        tokens[0] = address(nft);
        tokens[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        int256[] memory offsets = new int256[](2);
        offsets[0] = 5;
        offsets[1] = -1;
        v2.setNftCountOffsetBatch(wallets, tokens, ids, offsets);
        assertEq(v2.nftCountOffset(alice, address(nft), 1), 5);
        assertEq(v2.nftCountOffset(alice, address(nft), 2), -1);
    }

    function test_setNftCountOffsetBatch_lengthMismatch_reverts() public {
        address[] memory wallets = new address[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory ids = new uint256[](2);
        int256[] memory offsets = new int256[](1);
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        v2.setNftCountOffsetBatch(wallets, tokens, ids, offsets);
    }

    function test_setNftCountOffsetBatch_tokensLengthMismatch_reverts() public {
        address[] memory wallets = new address[](2);
        address[] memory tokens = new address[](1); // tokens diverges
        uint256[] memory ids = new uint256[](2);
        int256[] memory offsets = new int256[](2);
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        v2.setNftCountOffsetBatch(wallets, tokens, ids, offsets);
    }

    function test_setNftCountOffsetBatch_idsLengthMismatch_reverts() public {
        address[] memory wallets = new address[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory ids = new uint256[](1); // ids diverges
        int256[] memory offsets = new int256[](2);
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        v2.setNftCountOffsetBatch(wallets, tokens, ids, offsets);
    }

    function test_nftCountOffset_positive_withZeroIdWorth_stillContributesZero() public {
        _seedAliceBalances();
        // id=99 is not configured in erc1155IdWorth (stays 0). Admin boosts count.
        v2.setNftCountOffset(alice, address(nft), 99, 10);
        // Since erc1155TrackedIds only includes [1, 2], id=99 is not iterated
        // by totalERC1155Worth — the offset is effectively dormant and nftWorth
        // is unaffected.
        (,,, uint256 n) = v2.worthBreakdown(alice);
        // id=1: 2 * 100 = 200; id=2: 1 * 250 = 250; id=99 not tracked = 0
        assertEq(n, 450);
        // But the mapping storage still reflects the admin's setting:
        assertEq(v2.nftCountOffset(alice, address(nft), 99), 10);
    }

    function test_rawWorthBreakdown_ignoresOffsets() public {
        _seedAliceBalances();
        // aggressive offsets across all sources
        v2.setErc20Offset(alice, -1000);
        v2.setPoolStakingOffset(alice, address(stakingA), -1000);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), -1000);
        v2.setNftCountOffset(alice, address(nft), 1, -1000);

        (uint256 re, uint256 rs, uint256 rp, uint256 rn) = v2.rawWorthBreakdown(alice);
        assertEq(re, 500);              // raw ERC20
        assertEq(rs, 150 + 30);         // raw staking (A=150, B=30)
        assertEq(rp, 200);              // raw periodical
        assertEq(rn, 2 * 100 + 1 * 250); // raw NFT (200 + 250)
    }

    function test_getRawTotalWorth_ignoresOffsets() public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, -1000);
        // raw total = 500 + 180 + 200 + 450 = 1330 (same as V1 parity baseline)
        assertEq(v2.getRawTotalWorth(alice), 500 + 180 + 200 + 450);
    }

    function test_rawPerSource_ignoresOffsets() public {
        _seedAliceBalances();
        v2.setPoolStakingOffset(alice, address(stakingA), -1000);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), -1000);
        v2.setNftCountOffset(alice, address(nft), 1, -1000);
        assertEq(v2.rawTotalPoolStaked(alice), 180);
        assertEq(v2.rawTotalPeriodicalStaked(alice), 200);
        assertEq(v2.rawTotalERC1155Worth(alice), 450);
    }

    function test_appliedOffsetsWorth_zero_whenNoOffsets() public {
        _seedAliceBalances();
        assertEq(v2.getAppliedOffsetsWorth(alice), 0);
    }

    function test_appliedOffsetsWorth_positive_whenNetBoost() public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, 100);
        assertEq(v2.getAppliedOffsetsWorth(alice), 100);
    }

    function test_appliedOffsetsWorth_reflectsClamping() public {
        _seedAliceBalances(); // ERC20 real = 500
        v2.setErc20Offset(alice, -800);
        // adjusted ERC20 = 0 (not -300); applied delta for this source = -500
        assertEq(v2.getAppliedOffsetsWorth(alice), -500);
    }

    function test_appliedOffsetsWorth_invariant() public {
        _seedAliceBalances();
        v2.setPoolStakingOffset(alice, address(stakingA), -40);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), 100);
        v2.setNftCountOffset(alice, address(nft), 2, 2);
        int256 expected = int256(v2.getTotalWorth(alice)) - int256(v2.getRawTotalWorth(alice));
        assertEq(v2.getAppliedOffsetsWorth(alice), expected);
    }

    function testFuzz_appliedOffsetsWorth_invariant(
        int128 erc20Off,
        int128 stakingAOff,
        int128 periodicalAOff,
        int128 nftIdOneOff
    ) public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, int256(erc20Off));
        v2.setPoolStakingOffset(alice, address(stakingA), int256(stakingAOff));
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), int256(periodicalAOff));
        v2.setNftCountOffset(alice, address(nft), 1, int256(nftIdOneOff));

        int256 expected = int256(v2.getTotalWorth(alice)) - int256(v2.getRawTotalWorth(alice));
        assertEq(v2.getAppliedOffsetsWorth(alice), expected);
    }

    function test_getTokenWorth_excludesNftContribution() public {
        _seedAliceBalances();
        // Token parts: 500 ERC20 + (100+50+30) staking + 200 periodical = 880
        // NFT part: 2*100 + 1*250 = 450 (should be excluded)
        assertEq(v2.getTokenWorth(alice), 500 + 180 + 200);
    }

    function test_getTokenWorth_appliesAdjustedBranchesNotNft() public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, 100);          // ERC20: 500 -> 600
        v2.setPoolStakingOffset(alice, address(stakingA), -40); // stakingA: 150 -> 110
        v2.setNftCountOffset(alice, address(nft), 1, 5);    // NFT offset (should not affect token worth)
        // Adjusted token worth = 600 + (110 + 30) + 200 = 940
        assertEq(v2.getTokenWorth(alice), 600 + 140 + 200);
    }

    function test_getRawTokenWorth_ignoresOffsets() public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, -1000);
        v2.setPoolStakingOffset(alice, address(stakingA), -1000);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), -1000);
        v2.setNftCountOffset(alice, address(nft), 1, -1000);
        // Raw token = 500 + 180 + 200 = 880 (NFT excluded regardless)
        assertEq(v2.getRawTokenWorth(alice), 880);
    }

    function test_tokenWorth_invariant_equalsTotalMinusNft() public {
        _seedAliceBalances();
        v2.setErc20Offset(alice, 50);
        v2.setPoolStakingOffset(alice, address(stakingA), -20);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), 15);
        v2.setNftCountOffset(alice, address(nft), 2, 3);

        assertEq(v2.getTokenWorth(alice), v2.getTotalWorth(alice) - v2.totalERC1155Worth(alice));
        assertEq(v2.getRawTokenWorth(alice), v2.getRawTotalWorth(alice) - v2.rawTotalERC1155Worth(alice));
    }

    function _emptyV2() internal returns (RequirementCheckerV2) {
        TestToken placeholder = new TestToken(18);
        address[] memory empty = new address[](0);
        return new RequirementCheckerV2(address(placeholder), empty, empty, 0);
    }

    function test_cloneConfigFrom_copiesStakingArrays() public {
        RequirementCheckerV2 fresh = _emptyV2();
        fresh.cloneConfigFrom(address(v1));
        assertEq(fresh.poolStakingContractCount(), 2);
        assertEq(fresh.poolStakingContracts(0), address(stakingA));
        assertEq(fresh.poolStakingContracts(1), address(stakingB));
        assertEq(fresh.periodicalStakingContractCount(), 1);
        assertEq(fresh.periodicalStakingContracts(0), address(periodicalA));
    }

    function test_cloneConfigFrom_copiesErc1155Config() public {
        RequirementCheckerV2 fresh = _emptyV2();
        fresh.cloneConfigFrom(address(v1));
        assertEq(fresh.erc1155ContractCount(), 1);
        assertEq(fresh.erc1155Contracts(0), address(nft));
        assertEq(fresh.erc1155IdWorth(address(nft), 1), 100);
        assertEq(fresh.erc1155IdWorth(address(nft), 2), 250);
    }

    function test_cloneConfigFrom_copiesDefaultRequiredWorth() public {
        RequirementCheckerV2 fresh = _emptyV2();
        fresh.cloneConfigFrom(address(v1));
        assertEq(fresh.defaultRequiredWorth(), DEFAULT_REQ);
    }

    function test_cloneConfigFrom_copiesWorthToken() public {
        RequirementCheckerV2 fresh = _emptyV2();
        // prove fresh started with a DIFFERENT token than v1
        assertTrue(address(fresh.worthToken()) != address(token));
        fresh.cloneConfigFrom(address(v1));
        assertEq(address(fresh.worthToken()), address(token));
    }

    function test_cloneConfigFrom_emitsEvent() public {
        RequirementCheckerV2 fresh = _emptyV2();
        vm.expectEmit(true, false, false, false, address(fresh));
        emit ConfigClonedFrom(address(v1));
        fresh.cloneConfigFrom(address(v1));
    }

    function test_cloneConfigFrom_zeroAddress_reverts() public {
        RequirementCheckerV2 fresh = _emptyV2();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        fresh.cloneConfigFrom(address(0));
    }

    function test_cloneConfigFrom_nonOwner_reverts() public {
        RequirementCheckerV2 fresh = _emptyV2();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        fresh.cloneConfigFrom(address(v1));
    }

    function test_cloneConfigFrom_idempotent_reCall() public {
        RequirementCheckerV2 fresh = _emptyV2();
        fresh.cloneConfigFrom(address(v1));
        // second call should overwrite cleanly — no duplicates in arrays
        fresh.cloneConfigFrom(address(v1));
        assertEq(fresh.poolStakingContractCount(), 2);
        assertEq(fresh.periodicalStakingContractCount(), 1);
        assertEq(fresh.erc1155ContractCount(), 1);
        assertEq(fresh.defaultRequiredWorth(), DEFAULT_REQ);
    }

    function test_cloneConfigFrom_doesNotModifyPhasePeriodMap() public {
        RequirementCheckerV2 fresh = _emptyV2();
        // pre-seed a phase/period requirement on V2
        fresh.setRequiredWorthPhasePeriod(7, 11, 4242);
        fresh.cloneConfigFrom(address(v1));
        // clone does NOT touch phase/period map
        assertEq(fresh.requiredWorthPhasePeriod(7, 11), 4242);
    }

    function test_cloneConfigFrom_v1WithNoErc1155Contracts() public {
        // deploy a fresh V1 with no ERC1155 config
        address[] memory stakingOnly = new address[](1);
        stakingOnly[0] = address(stakingA);
        address[] memory periodicalOnly = new address[](0);
        RequirementChecker barebones = new RequirementChecker(address(token), stakingOnly, periodicalOnly, 500);

        RequirementCheckerV2 fresh = _emptyV2();
        fresh.cloneConfigFrom(address(barebones));

        assertEq(fresh.poolStakingContractCount(), 1);
        assertEq(fresh.periodicalStakingContractCount(), 0);
        assertEq(fresh.erc1155ContractCount(), 0);
        assertEq(fresh.defaultRequiredWorth(), 500);
    }

    function test_clonePhasePeriod_copiesValues() public {
        // seed V1 with some phase/period thresholds
        v1.setRequiredWorthPhasePeriod(1, 1, 500);
        v1.setRequiredWorthPhasePeriod(2, 5, 2500);

        RequirementCheckerV2 fresh = _emptyV2();
        uint256[] memory phases = new uint256[](2);
        phases[0] = 1;
        phases[1] = 2;
        uint256[] memory periods = new uint256[](2);
        periods[0] = 1;
        periods[1] = 5;

        // Expect per-pair RequiredPhasePeriodWorthSet (two indexed params + data)
        vm.expectEmit(true, true, false, true, address(fresh));
        emit RequiredPhasePeriodWorthSet(1, 1, 500);
        vm.expectEmit(true, true, false, true, address(fresh));
        emit RequiredPhasePeriodWorthSet(2, 5, 2500);
        // Followed by summary
        vm.expectEmit(true, false, false, true, address(fresh));
        emit PhasePeriodRequirementsClonedFrom(address(v1), phases, periods);

        fresh.clonePhasePeriodRequirements(address(v1), phases, periods);

        assertEq(fresh.requiredWorthPhasePeriod(1, 1), 500);
        assertEq(fresh.requiredWorthPhasePeriod(2, 5), 2500);
    }

    function test_clonePhasePeriod_lengthMismatch_reverts() public {
        RequirementCheckerV2 fresh = _emptyV2();
        uint256[] memory phases = new uint256[](2);
        uint256[] memory periods = new uint256[](1);
        vm.expectRevert(abi.encodeWithSignature("LengthMismatch(uint256,uint256)", 2, 1));
        fresh.clonePhasePeriodRequirements(address(v1), phases, periods);
    }

    function test_clonePhasePeriod_zeroV1_reverts() public {
        RequirementCheckerV2 fresh = _emptyV2();
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressProvided()"));
        fresh.clonePhasePeriodRequirements(address(0), empty, empty);
    }

    function test_clonePhasePeriod_nonOwner_reverts() public {
        RequirementCheckerV2 fresh = _emptyV2();
        uint256[] memory empty = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        fresh.clonePhasePeriodRequirements(address(v1), empty, empty);
    }

    function test_clonePhasePeriod_emptyArrays_emitsEventWithEmptyArrays() public {
        RequirementCheckerV2 fresh = _emptyV2();
        uint256[] memory empty = new uint256[](0);
        vm.expectEmit(true, false, false, true, address(fresh));
        emit PhasePeriodRequirementsClonedFrom(address(v1), empty, empty);
        fresh.clonePhasePeriodRequirements(address(v1), empty, empty);
    }

    function test_clonePhasePeriod_overwritesExistingV2Value() public {
        RequirementCheckerV2 fresh = _emptyV2();
        // pre-seed V2 with a value for (3, 7)
        fresh.setRequiredWorthPhasePeriod(3, 7, 999);
        assertEq(fresh.requiredWorthPhasePeriod(3, 7), 999);

        // V1 has a different value at (3, 7)
        v1.setRequiredWorthPhasePeriod(3, 7, 4242);

        uint256[] memory phases = new uint256[](1);
        phases[0] = 3;
        uint256[] memory periods = new uint256[](1);
        periods[0] = 7;
        fresh.clonePhasePeriodRequirements(address(v1), phases, periods);

        // Clone overwrites the pre-existing V2 value with V1's
        assertEq(fresh.requiredWorthPhasePeriod(3, 7), 4242);
    }

    function test_totalStaked_sumsPoolAndPeriodical() public {
        _seedAliceBalances();
        // pool (adjusted) = 180, periodical (adjusted) = 200 → total = 380
        assertEq(v2.totalStaked(alice), 180 + 200);
        // with a positive offset on pool, the sum should reflect it
        v2.setPoolStakingOffset(alice, address(stakingA), 20);
        assertEq(v2.totalStaked(alice), 200 + 200);
    }

    function test_rawTotalStaked_sumsPoolAndPeriodical_ignoresOffsets() public {
        _seedAliceBalances();
        // Heavy offsets on both sources must not affect the raw aggregate
        v2.setPoolStakingOffset(alice, address(stakingA), -10000);
        v2.setPeriodicalStakingOffset(alice, address(periodicalA), -10000);
        assertEq(v2.rawTotalStaked(alice), 180 + 200);
    }

    function test_phasePeriodKeys_tracksSetPairs() public {
        assertEq(v2.phasePeriodKeysCount(), 0);
        v2.setRequiredWorthPhasePeriod(1, 2, 500);
        v2.setRequiredWorthPhasePeriod(3, 4, 1500);
        assertEq(v2.phasePeriodKeysCount(), 2);
        (uint256 p0, uint256 pr0) = v2.phasePeriodKeys(0);
        (uint256 p1, uint256 pr1) = v2.phasePeriodKeys(1);
        assertEq(p0, 1); assertEq(pr0, 2);
        assertEq(p1, 3); assertEq(pr1, 4);
    }

    function test_phasePeriodKeys_noDuplicateOnRepeatSet() public {
        v2.setRequiredWorthPhasePeriod(7, 11, 999);
        v2.setRequiredWorthPhasePeriod(7, 11, 1234); // update, not a new key
        v2.setRequiredWorthPhasePeriod(7, 11, 5678); // update again
        assertEq(v2.phasePeriodKeysCount(), 1);
    }

    function test_phasePeriodKeys_zeroValueDoesNotAdd() public {
        v2.setRequiredWorthPhasePeriod(5, 5, 0); // never-set + zero value → not added
        assertEq(v2.phasePeriodKeysCount(), 0);
        v2.setRequiredWorthPhasePeriod(5, 5, 100); // non-zero → added
        assertEq(v2.phasePeriodKeysCount(), 1);
    }

    function test_phasePeriodKeys_zeroClearRemovesFromList() public {
        v2.setRequiredWorthPhasePeriod(5, 5, 100); // tracked
        v2.setRequiredWorthPhasePeriod(6, 6, 200); // tracked
        assertEq(v2.phasePeriodKeysCount(), 2);

        // Zero-clear on the first key drops it from the enumerable list.
        v2.setRequiredWorthPhasePeriod(5, 5, 0);
        assertEq(v2.phasePeriodKeysCount(), 1);
        // The surviving entry is (6, 6) — swap-with-last left it at index 0.
        (uint256 ph, uint256 pe) = v2.phasePeriodKeys(0);
        assertEq(ph, 6);
        assertEq(pe, 6);

        // Re-setting the cleared key re-adds it (tracking flag was flipped off).
        v2.setRequiredWorthPhasePeriod(5, 5, 300);
        assertEq(v2.phasePeriodKeysCount(), 2);
    }

    function test_clonePhasePeriodRequirements_populatesKeyList() public {
        v1.setRequiredWorthPhasePeriod(4, 8, 777);

        RequirementCheckerV2 dst = _emptyV2();
        uint256[] memory phases = new uint256[](1);
        uint256[] memory periods = new uint256[](1);
        phases[0] = 4; periods[0] = 8;
        dst.clonePhasePeriodRequirements(address(v1), phases, periods);

        assertEq(dst.requiredWorthPhasePeriod(4, 8), 777);
        // The destination is now itself V2-enumerable for future clones
        assertEq(dst.phasePeriodKeysCount(), 1);
        (uint256 ph, uint256 pe) = dst.phasePeriodKeys(0);
        assertEq(ph, 4);
        assertEq(pe, 8);
    }

    function test_setERC1155Configs_reconfigureClearsOrphanedIdWorth() public {
        MockERC1155 fresh = new MockERC1155();

        // Initial config: track ids [10, 20, 30] with worths [100, 200, 300].
        uint256[] memory ids1 = new uint256[](3);
        ids1[0] = 10; ids1[1] = 20; ids1[2] = 30;
        uint256[] memory worths1 = new uint256[](3);
        worths1[0] = 100; worths1[1] = 200; worths1[2] = 300;
        v2.setERC1155Configs(address(fresh), ids1, worths1);

        assertEq(v2.erc1155IdWorth(address(fresh), 10), 100);
        assertEq(v2.erc1155IdWorth(address(fresh), 20), 200);
        assertEq(v2.erc1155IdWorth(address(fresh), 30), 300);

        // Reconfigure: keep id 20 (new worth), drop 10 and 30, add 40.
        uint256[] memory ids2 = new uint256[](2);
        ids2[0] = 20; ids2[1] = 40;
        uint256[] memory worths2 = new uint256[](2);
        worths2[0] = 250; worths2[1] = 400;
        v2.setERC1155Configs(address(fresh), ids2, worths2);

        // Dropped ids must have their worth cleared (no orphans).
        assertEq(v2.erc1155IdWorth(address(fresh), 10), 0);
        assertEq(v2.erc1155IdWorth(address(fresh), 30), 0);
        // Surviving id reflects the new worth.
        assertEq(v2.erc1155IdWorth(address(fresh), 20), 250);
        // New id is registered.
        assertEq(v2.erc1155IdWorth(address(fresh), 40), 400);
    }
}
