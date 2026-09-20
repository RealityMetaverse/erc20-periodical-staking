// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {stdError} from "forge-std/Test.sol";
import {RequirementCheckerV2Test} from "../../requirement-checker-v2/RequirementCheckerV2.t.sol";
import {RequirementCheckerV2} from "../../../src/contracts/requirement-checker/v2/RequirementCheckerV2.sol";
import {MockERC1155} from "../../shared/mocks/MockERC1155.sol";

/// @dev Configurable fake "V1" exposing exactly the getters cloneConfigFrom reads.
contract AdvFakeV1 {
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

    function pushErc1155(address token, uint256[] calldata ids, uint256[] calldata worths) external {
        erc1155Contracts.push(token);
        erc1155TrackedIds[token] = ids;
        for (uint256 i = 0; i < ids.length; i++) erc1155IdWorth[token][ids[i]] = worths[i];
    }

    function stakingContractCount() external view returns (uint256) { return stakingContracts.length; }
    function periodicalStakingContractCount() external view returns (uint256) { return periodicalStakingContracts.length; }
    function erc1155ContractCount() external view returns (uint256) { return erc1155Contracts.length; }
}

/// @notice Independent adversarial verification of the v0.5.0 RCv2 audit fixes.
///         Names prefixed `adv_` so they are easy to separate from the fix agent's own suite.
contract AdversarialRCv2 is RequirementCheckerV2Test {
    int256 constant MAXO = int256(type(int128).max);

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _two(uint256 a0, uint256 a1) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = a0;
        a[1] = a1;
    }

    // ================================================================ #27a
    /// Clearing loop with THREE contracts: a swap-with-last removal while iterating is the classic
    /// index-shifting bug. Assert every contract and every id worth is gone, none skipped.
    function test_adv_27a_clearLoopDropsAllThreeContracts() public {
        MockERC1155 b = new MockERC1155();
        MockERC1155 c = new MockERC1155();
        v2.setERC1155Configs(address(b), _two(11, 12), _two(7, 8));
        v2.setERC1155Configs(address(c), _one(13), _one(9));
        assertEq(v2.erc1155ContractCount(), 3);

        AdvFakeV1 empty = new AdvFakeV1(address(token));
        v2.cloneConfigFrom(address(empty));

        assertEq(v2.erc1155ContractCount(), 0, "all three contracts must be gone");
        assertEq(v2.erc1155IdWorth(address(nft), 1), 0);
        assertEq(v2.erc1155IdWorth(address(nft), 2), 0);
        assertEq(v2.erc1155IdWorth(address(b), 11), 0);
        assertEq(v2.erc1155IdWorth(address(b), 12), 0);
        assertEq(v2.erc1155IdWorth(address(c), 13), 0);
    }

    /// Same contract in both, but the SOURCE tracks FEWER ids. The id V2 has and V1 does not must
    /// lose its worth, and a holder of it must lose the worth it granted.
    function test_adv_27a_fewerIdsInSourceDropsExtraId() public {
        AdvFakeV1 src = new AdvFakeV1(address(token));
        src.pushErc1155(address(nft), _one(1), _one(100)); // only id 1, no id 2

        nft.mint(bob, 2, 10); // 10 * 250 = 2500 under V2's current config
        assertTrue(v2.meetsRequirement(bob, 1, 1));

        v2.cloneConfigFrom(address(src));

        assertEq(v2.erc1155IdWorth(address(nft), 2), 0, "dropped id must have zero worth");
        assertEq(v2.totalERC1155Worth(bob), 0);
        // NOTE: meetsRequirement is now TRUE for everyone, not because bob still has worth, but because
        // cloneConfigFrom also copied the source's defaultRequiredWorth of 0, and meetsRequirement
        // short-circuits to true when the resolved requirement is 0. Cloning from a V1 whose default is 0
        // silently opens the gate for every wallet. That is orthogonal to #27a but worth pinning.
        assertEq(v2.defaultRequiredWorth(), 0, "clone copied the source default of 0");
        assertTrue(v2.meetsRequirement(bob, 1, 1));
        v2.setDefaultRequiredWorth(DEFAULT_REQ);
        assertFalse(v2.meetsRequirement(bob, 1, 1), "with the gate restored bob no longer passes");
        // tracked list is exactly [1]
        assertEq(v2.erc1155TrackedIds(address(nft), 0), 1);
        vm.expectRevert();
        v2.erc1155TrackedIds(address(nft), 1);
    }

    /// Cloning twice in a row must be idempotent, and a clone from a rich source AFTER a clone from
    /// an empty one must rebuild correctly (registration is keyed on previousIds.length == 0).
    function test_adv_27a_cloneTwiceIsIdempotentAndRebuilds() public {
        v2.cloneConfigFrom(address(v1));
        uint256 n1 = v2.erc1155ContractCount();
        v2.cloneConfigFrom(address(v1));
        assertEq(v2.erc1155ContractCount(), n1, "second clone must not duplicate the contract");
        assertEq(v2.erc1155Contracts(0), address(nft));
        assertEq(v2.erc1155IdWorth(address(nft), 2), 250);

        AdvFakeV1 empty = new AdvFakeV1(address(token));
        v2.cloneConfigFrom(address(empty));
        assertEq(v2.erc1155ContractCount(), 0);

        v2.cloneConfigFrom(address(v1)); // rebuild from scratch
        assertEq(v2.erc1155ContractCount(), 1);
        assertEq(v2.erc1155IdWorth(address(nft), 1), 100);
        assertEq(v2.erc1155IdWorth(address(nft), 2), 250);
        nft.mint(bob, 2, 4);
        assertEq(v2.totalERC1155Worth(bob), 1000);
    }

    /// Admin offsets and phase/period requirements must survive a clone (documented as NOT touched) —
    /// a clone that silently wiped an incident offset would be a fund-visibility bug.
    function test_adv_27a_cloneDoesNotTouchOffsetsOrRequirements() public {
        v2.setNftCountOffset(alice, address(nft), 2, -5);
        v2.setErc20Offset(alice, 7);
        v2.setRequiredWorthPhasePeriod(3, 4, 12345);

        AdvFakeV1 empty = new AdvFakeV1(address(token));
        v2.cloneConfigFrom(address(empty));

        assertEq(v2.nftCountOffset(alice, address(nft), 2), -5, "offset survives");
        assertEq(v2.erc20Offset(alice), 7);
        assertEq(v2.getRequiredWorth(3, 4), 12345, "phase/period requirement survives");
    }

    /// Gas of the clearing loop is unbounded in erc1155Contracts x tracked ids. Record the real
    /// number for 25 contracts x 5 ids so the "owner-controlled, keep it small" note has a figure.
    function test_adv_27a_clearLoopGasIsUnbounded() public {
        for (uint256 i = 0; i < 25; i++) {
            MockERC1155 m = new MockERC1155();
            uint256[] memory ids = new uint256[](5);
            uint256[] memory ws = new uint256[](5);
            for (uint256 j = 0; j < 5; j++) { ids[j] = j; ws[j] = 1; }
            v2.setERC1155Configs(address(m), ids, ws);
        }
        assertEq(v2.erc1155ContractCount(), 26);
        AdvFakeV1 empty = new AdvFakeV1(address(token));
        uint256 g = gasleft();
        v2.cloneConfigFrom(address(empty));
        emit log_named_uint("cloneConfigFrom gas, 26 contracts x ~5 ids", g - gasleft());
        assertEq(v2.erc1155ContractCount(), 0);
    }

    // ================================================================ #28
    /// Try to create a DUPLICATE entry in erc1155Contracts: registration is keyed on
    /// `erc1155TrackedIds[token].length == 0`, so a token whose tracked list could be emptied while
    /// it stayed registered would be pushed twice and double counted. Exercise every path that
    /// touches the tracked list and assert the contract never appears twice.
    function test_adv_28_erc1155ContractCannotBeRegisteredTwice() public {
        v2.setERC1155Configs(address(nft), _one(1), _one(100)); // shrink
        v2.setERC1155Configs(address(nft), _two(1, 2), _two(100, 250)); // grow
        v2.removeERC1155Contract(address(nft));
        v2.setERC1155Configs(address(nft), _one(1), _one(100)); // re-add
        v2.cloneConfigFrom(address(v1)); // clear + rebuild
        v2.setERC1155Configs(address(nft), _one(1), _one(100));
        assertEq(v2.erc1155ContractCount(), 1, "nft registered exactly once");
        assertEq(v2.erc1155Contracts(0), address(nft));

        nft.mint(bob, 1, 3);
        assertEq(v2.totalERC1155Worth(bob), 300, "no double count");
    }

    /// Duplicate detection must catch a duplicate at the FIRST and the LAST position of the array
    /// (off-by-one on the O(n^2) bounds), and must accept a clean list of the same length.
    function test_adv_28_duplicateBoundsFirstAndLast() public {
        // ids: duplicate spanning index 0 and index n-1
        uint256[] memory ids = new uint256[](4);
        ids[0] = 5; ids[1] = 6; ids[2] = 7; ids[3] = 5;
        uint256[] memory ws = new uint256[](4);
        ws[0] = 1; ws[1] = 1; ws[2] = 1; ws[3] = 1;
        vm.expectRevert(abi.encodeWithSignature("DuplicateId(uint256)", 5));
        v2.setERC1155Configs(address(nft), ids, ws);

        // duplicate in adjacent middle positions
        ids[3] = 8; ids[2] = 6;
        vm.expectRevert(abi.encodeWithSignature("DuplicateId(uint256)", 6));
        v2.setERC1155Configs(address(nft), ids, ws);

        // clean 4-id list is accepted
        ids[2] = 7;
        v2.setERC1155Configs(address(nft), ids, ws);
        assertEq(v2.erc1155TrackedIds(address(nft), 3), 8);

        // single-element list (loop starts at i = 1) still works
        v2.setERC1155Configs(address(nft), _one(9), _one(2));
        assertEq(v2.erc1155TrackedIds(address(nft), 0), 9);

        // address lists: duplicate at first/last
        address[] memory l = new address[](3);
        l[0] = address(stakingA); l[1] = address(stakingB); l[2] = address(stakingA);
        vm.expectRevert(abi.encodeWithSignature("DuplicateAddress(address)", address(stakingA)));
        v2.setPoolStakingContracts(l);
        l[2] = address(0xDEAD);
        v2.setPoolStakingContracts(l); // clean list of the same length accepted
        assertEq(v2.poolStakingContractCount(), 3);
    }

    /// clonePhasePeriodRequirements with the same (phase, period) supplied twice must not push the
    /// enumerable key twice.
    function test_adv_28_clonePhasePeriodDuplicatePairsDoNotDoubleTrack() public {
        v1.setRequiredWorthPhasePeriod(2, 2, 777);
        uint256[] memory ph = _two(2, 2);
        uint256[] memory pe = _two(2, 2);
        v2.clonePhasePeriodRequirements(address(v1), ph, pe);
        assertEq(v2.phasePeriodKeysCount(), 1, "key tracked once");
        assertEq(v2.getRequiredWorth(2, 2), 777);
    }

    // ================================================================ #29
    /// type(int128).min is exactly one past the accepted lower bound and must be rejected; the two
    /// boundary values themselves must be accepted, on every setter incl. the batch variants.
    function test_adv_29_int128MinRejected_boundsAcceptedEverywhere() public {
        int256 int128min = int256(type(int128).min);
        vm.expectRevert(abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", int128min, MAXO));
        v2.setErc20Offset(alice, int128min);
        vm.expectRevert(abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", int128min, MAXO));
        v2.setNftCountOffset(alice, address(nft), 1, int128min);

        address[] memory w = new address[](1);
        w[0] = alice;
        address[] memory cs = new address[](1);
        cs[0] = address(stakingA);
        address[] memory pcs = new address[](1);
        pcs[0] = address(periodicalA);
        address[] memory tk = new address[](1);
        tk[0] = address(nft);
        uint256[] memory id = _one(1);
        int256[] memory bad = new int256[](1);
        bad[0] = int128min;

        vm.expectRevert(abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", int128min, MAXO));
        v2.setPoolStakingOffsetBatch(w, cs, bad);
        vm.expectRevert(abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", int128min, MAXO));
        v2.setPeriodicalStakingOffsetBatch(w, pcs, bad);
        vm.expectRevert(abi.encodeWithSignature("OffsetOutOfBounds(int256,int256)", int128min, MAXO));
        v2.setNftCountOffsetBatch(w, tk, id, bad);

        int256[] memory ok = new int256[](1);
        ok[0] = -MAXO;
        v2.setPoolStakingOffsetBatch(w, cs, ok);
        v2.setPeriodicalStakingOffsetBatch(w, pcs, ok);
        v2.setNftCountOffsetBatch(w, tk, id, ok);
        assertEq(v2.poolStakingOffset(alice, address(stakingA)), -MAXO);
        assertEq(v2.periodicalStakingOffset(alice, address(periodicalA)), -MAXO);
        assertEq(v2.nftCountOffset(alice, address(nft), 1), -MAXO);
    }

    /// idWorth is NOT bounded, so a bounded, accepted offset multiplied by a large owner-set idWorth still
    /// Panics 0x11 on the SINGLE-wallet reads — that is documented now, not claimed away. The batch is the
    /// one read that survives it: the poisoned entry comes back `false`, the others are still answered.
    function test_adv_29_boundedOffsetStillPanicsWithLargeIdWorth() public {
        uint256 hugeWorth = uint256(1) << 200;
        v2.setERC1155Configs(address(nft), _one(1), _one(hugeWorth)); // accepted, no cap
        v2.setNftCountOffset(alice, address(nft), 1, MAXO); // accepted, within bounds

        vm.expectRevert(stdError.arithmeticError);
        v2.totalERC1155Worth(alice);
        vm.expectRevert(stdError.arithmeticError);
        v2.getTotalWorth(alice);
        vm.expectRevert(stdError.arithmeticError);
        v2.getAppliedOffsetsWorth(alice);
        // the single-wallet check still propagates the revert, by design
        vm.expectRevert(stdError.arithmeticError);
        v2.meetsRequirement(alice, 0, 0);

        // FIXED: the batch no longer dies with it — alice reports false, bob is still evaluated.
        address[] memory users = new address[](2);
        users[0] = bob;
        users[1] = alice;
        uint256[] memory z = new uint256[](2);
        bool[] memory res = v2.meetsRequirementBatch(users, z, z);
        assertEq(res.length, 2);
        assertEq(res[0], v2.meetsRequirement(bob, 0, 0), "bob must still be evaluated normally");
        assertFalse(res[1], "a wallet whose worth read reverts must report as NOT meeting the requirement");
    }

    /// FIXED (#29 follow-up): a tracked ERC1155 with open minting lets ANY unprivileged wallet give itself a
    /// balance that trips SafeCast. That used to brick every meetsRequirementBatch the wallet appeared in.
    /// Now only that wallet's own entry is false; every other entry is answered.
    function test_adv_29_unprivilegedWalletPoisonsBatchViaOpenMintErc1155() public {
        uint256 absurd = uint256(1) << 255;
        vm.prank(bob); // not the owner
        nft.mint(bob, 1, absurd);

        // Single-wallet reads still surface the real cause to an operator debugging bob.
        bytes memory err = abi.encodeWithSignature("SafeCastOverflowedUintToInt(uint256)", absurd);
        vm.expectRevert(err);
        v2.getTotalWorth(bob);
        vm.expectRevert(err);
        v2.meetsRequirement(bob, 1, 1);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = owner;
        uint256[] memory z = new uint256[](3);
        bool[] memory res = v2.meetsRequirementBatch(users, z, z);
        assertEq(res.length, 3);
        assertEq(res[0], v2.meetsRequirement(alice, 0, 0), "alice unaffected");
        assertFalse(res[1], "bob's poisoned entry must read false, not revert the batch");
        assertEq(res[2], v2.meetsRequirement(owner, 0, 0), "owner unaffected");

        // alice on her own is still fine
        assertFalse(v2.meetsRequirement(alice, 1, 1));
    }

    /// An ERC1155 balance well below 2^255 (so SafeCast passes) still Panics on the worth multiply —
    /// SafeCast does not close the arithmetic hole, it only moves the threshold.
    function test_adv_29_safeCastDoesNotCoverTheMultiplyOverflow() public {
        uint256 big = uint256(1) << 250; // passes SafeCast.toInt256
        nft.mint(alice, 1, big); // idWorth 100 -> 2^250 * 100 overflows
        vm.expectRevert(stdError.arithmeticError);
        v2.totalERC1155Worth(alice);
    }

    // ================================================================ #40
    /// The old owner must keep FULL power between nomination and acceptance, and the nominee none.
    function test_adv_40_oldOwnerKeepsPowerUntilAccept() public {
        v2.transferOwnership(alice);
        assertEq(v2.owner(), owner);
        assertEq(v2.pendingOwner(), alice);

        // old owner still writes
        v2.setDefaultRequiredWorth(4242);
        assertEq(v2.defaultRequiredWorth(), 4242);

        // pending owner has nothing
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        v2.setDefaultRequiredWorth(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        v2.cloneConfigFrom(address(v1));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        v2.acceptOwnership();

        vm.prank(alice);
        v2.acceptOwnership();
        assertEq(v2.owner(), alice);
        assertEq(v2.pendingOwner(), address(0));

        // old owner is now powerless
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        v2.setDefaultRequiredWorth(1);
    }

    /// renounceOwnership is unreachable through every route: owner, non-owner, pending owner, and a
    /// raw low-level call with the bare selector. transferOwnership(0) must only cancel, never renounce.
    function test_adv_40_renounceUnreachableAndZeroTransferOnlyCancels() public {
        vm.expectRevert(abi.encodeWithSignature("RenounceOwnershipDisabled()"));
        v2.renounceOwnership();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("RenounceOwnershipDisabled()"));
        v2.renounceOwnership();

        (bool ok, bytes memory ret) = address(v2).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok);
        assertTrue(bytes4(ret) == bytes4(keccak256("RenounceOwnershipDisabled()")));

        v2.transferOwnership(address(0));
        assertEq(v2.pendingOwner(), address(0));
        assertEq(v2.owner(), owner, "owner unchanged by transferOwnership(0)");

        // BUT: the renounce block is NOT airtight. pendingOwner defaults to address(0), and
        // Ownable2Step.acceptOwnership only checks `pendingOwner() == _msgSender()`. A call whose
        // msg.sender is address(0) therefore passes and renounces ownership, reaching exactly the state
        // RenounceOwnershipDisabled exists to prevent. No EOA can sign as address(0), so this is not
        // reachable on a live chain — but the invariant "the checker can never become ownerless" is
        // enforced by the EVM, not by this contract.
        assertEq(v2.pendingOwner(), address(0));
        vm.prank(address(0));
        v2.acceptOwnership();
        assertEq(v2.owner(), address(0), "ownership renounced through acceptOwnership from address(0)");
    }

    // ================================================================ #26
    /// The NatSpec says a requirement of 1 "effectively exempts" the cell. It does not: a wallet with
    /// zero worth still fails. Only a requirement that resolves to 0 truly exempts, and 0 cannot be
    /// stored while defaultRequiredWorth is non-zero.
    function test_adv_26_oneDoesNotExemptAZeroWorthWallet() public {
        v2.setRequiredWorthPhasePeriod(9, 9, 1);
        assertEq(v2.getRequiredWorth(9, 9), 1);
        assertEq(v2.getTotalWorth(bob), 0);
        assertFalse(v2.meetsRequirement(bob, 9, 9), "a zero-worth wallet is NOT exempt at required=1");

        // the only true exemption is default 0 + no override
        v2.setDefaultRequiredWorth(0);
        v2.setRequiredWorthPhasePeriod(9, 9, 0);
        assertEq(v2.getRequiredWorth(9, 9), 0);
        assertTrue(v2.meetsRequirement(bob, 9, 9));
    }
}
