// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../shared/TestToken.sol";
import {MockStakingContract} from "../shared/mocks/MockStakingContract.sol";
import {MockPeriodicalStakingContract} from "../shared/mocks/MockPeriodicalStakingContract.sol";
import {MockERC1155} from "../shared/mocks/MockERC1155.sol";
import {RequirementChecker} from "../../src/contracts/requirement-checker/RequirementChecker.sol";
import {RequirementCheckerV2} from "../../src/contracts/requirement-checker/v2/RequirementCheckerV2.sol";
import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";

contract RequirementCheckerV2IntegrationTest is Test {
    TestToken token;
    MockStakingContract stakingA;
    MockPeriodicalStakingContract periodicalA;
    MockERC1155 nft;

    RequirementChecker v1;
    RequirementCheckerV2 v2;
    ERC20PeriodicalStaking consumer;

    address alice = address(0xA11CE);

    uint256 constant DEFAULT_REQ = 1000;

    function setUp() public {
        token = new TestToken(18);
        stakingA = new MockStakingContract(1);
        periodicalA = new MockPeriodicalStakingContract();
        nft = new MockERC1155();

        address[] memory staking = new address[](1);
        staking[0] = address(stakingA);
        address[] memory periodical = new address[](1);
        periodical[0] = address(periodicalA);

        v1 = new RequirementChecker(address(token), staking, periodical, DEFAULT_REQ);
        v2 = new RequirementCheckerV2(address(token), staking, periodical, DEFAULT_REQ);

        // identical ERC1155 config
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory worths = new uint256[](1);
        worths[0] = 100;
        v1.setERC1155Configs(address(nft), ids, worths);
        v2.setERC1155Configs(address(nft), ids, worths);

        consumer = new ERC20PeriodicalStaking(address(token));
    }

    // ----- Basic drop-in replacement -----

    function test_consumer_readsV2_withoutOffsets_matchesV1() public {
        // alice total worth = 1500 (all in ERC20) > 1000 default → passes
        token.transfer(alice, 1500);

        consumer.setRequirementChecker(address(v1));
        // Note: (phase=0, period=0) is used throughout as the "default" requirement tuple.
        // The consumer has no per-phase/period thresholds configured in these tests, so
        // every call falls through to the defaultRequiredWorth path in getRequiredWorth.
        bool passV1 = consumer.checkIfUserMeetsRequirements(alice, 0, 0);

        consumer.setRequirementChecker(address(v2));
        bool passV2 = consumer.checkIfUserMeetsRequirements(alice, 0, 0);

        assertEq(passV1, passV2, "V1 and V2 should agree on the same input");
        assertTrue(passV2, "alice's 1500 ERC20 worth should pass the default 1000 requirement");
    }

    // ----- Negative offset through consumer -----

    function test_consumer_readsV2_negativeOffset_forcesFail() public {
        token.transfer(alice, 1500);
        consumer.setRequirementChecker(address(v2));

        // Without offset, alice passes
        assertTrue(consumer.checkIfUserMeetsRequirements(alice, 0, 0));

        // Apply a large negative ERC20 offset on V2
        v2.setErc20Offset(alice, -2000);

        // Consumer now reports failure through V2's adjusted meetsRequirement
        assertFalse(consumer.checkIfUserMeetsRequirements(alice, 0, 0));
    }

    // ----- Positive offset through consumer -----

    function test_consumer_readsV2_positiveOffset_forcesPass() public {
        // alice has 500 ERC20 — below the 1000 default, would normally fail
        token.transfer(alice, 500);
        consumer.setRequirementChecker(address(v2));
        assertFalse(consumer.checkIfUserMeetsRequirements(alice, 0, 0));

        // Admin-boost alice's perceived ERC20 worth
        v2.setErc20Offset(alice, 600);

        // Adjusted ERC20 = 1100 >= 1000 → passes
        assertTrue(consumer.checkIfUserMeetsRequirements(alice, 0, 0));
    }

    // ----- Reversion path -----

    function test_consumer_switchBackToV1_restoresBehavior() public {
        token.transfer(alice, 1500);

        // V2 with a large negative offset → alice fails on V2
        consumer.setRequirementChecker(address(v2));
        v2.setErc20Offset(alice, -2000);
        assertFalse(consumer.checkIfUserMeetsRequirements(alice, 0, 0));

        // Switch back to V1 — V1 has no offsets and alice has 1500 worth → passes
        consumer.setRequirementChecker(address(v1));
        assertTrue(consumer.checkIfUserMeetsRequirements(alice, 0, 0));
    }

    // ----- Clearing checker disables the check -----

    function test_consumer_withNullChecker_alwaysPasses() public {
        consumer.setRequirementChecker(address(0));
        // alice has zero worth but the consumer skips the check when no checker is wired
        assertTrue(consumer.checkIfUserMeetsRequirements(alice, 0, 0));
    }

    // ----- NFT count offset through consumer -----

    function test_consumer_readsV2_nftCountOffset_flowsThroughConsumer() public {
        // alice has 500 ERC20 + 3 NFTs of id=1 @ 100 = 800 raw worth. Below 1000.
        token.transfer(alice, 500);
        nft.mint(alice, 1, 3);
        consumer.setRequirementChecker(address(v2));
        assertFalse(consumer.checkIfUserMeetsRequirements(alice, 0, 0));

        // Admin boosts alice's perceived NFT count by +3 -> +300 worth -> 1100 total -> passes
        v2.setNftCountOffset(alice, address(nft), 1, 3);
        assertTrue(consumer.checkIfUserMeetsRequirements(alice, 0, 0));
    }
}
