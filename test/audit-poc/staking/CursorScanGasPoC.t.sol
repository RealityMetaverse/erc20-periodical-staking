// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {console2} from "forge-std/console2.sol";
import {V050Base} from "../../v050/V050Base.sol";
import {ProgramManager} from "../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";

/// @notice Finding #18: _updateActiveDepositStartIndex used to scan every closed deposit after the cursor in ONE
///         call. FIXED: at most 256 deposits per call, progress stored, so the cursor is a lower-bound hint.
/// @dev Deposit 0 stays open (cursor pinned at 0) while deposits 1..N are opened and closed. Closing deposit 0
///      then walks the closed deposits behind it. State is built in setUp so the measured call starts with COLD
///      storage, as on chain. Measured with the fix (withdrawDeposit(0), cold): N = 0: 146,087 gas; N = 200:
///      665,687 (~2,600 per scanned deposit); N = 400 and N = 1000: 817,963 each -- both scan exactly 256, so
///      the cost no longer grows with N. Unbounded, N = 1000 would be roughly 146k + 1000 x 2.6k = 2.7M.
abstract contract CursorScanGasBase is V050Base {
    uint256 internal constant MAX_CURSOR_SCAN = 256; // WriteFunctions.MAX_CURSOR_SCAN
    /// @dev Ceiling for ONE close whatever N is: the N = 0 cost plus a full 256-step scan, with headroom.
    uint256 internal constant GAS_CEILING = 900_000;

    function _n() internal pure virtual returns (uint256);

    function setUp() public override {
        super.setUp();
        stakeFor(alice, P30, 1_000 * ONE); // deposit 0, stays open
        for (uint256 i = 1; i <= _n(); i++) {
            uint256 d = stakeFor(alice, P30, 100); // minimumDeposit = 100 wei
            vm.prank(alice);
            staking.withdrawDeposit(d);
        }
        assertEq(staking.stakerActiveDepositStartIndex(alice), 0, "cursor pinned behind the open deposit");
    }

    function test_fixed18_gasToCloseOldestDepositIsBounded() public {
        vm.prank(alice);
        uint256 g = gasleft();
        staking.withdrawDeposit(0);
        g -= gasleft();
        console2.log("closed deposits behind the cursor:", _n());
        console2.log("gas withdrawDeposit(0):", g);
        assertLt(g, GAS_CEILING, "one close is bounded no matter how many closed deposits follow");

        // One call advances at most MAX_CURSOR_SCAN; everything before the cursor is closed.
        uint256 count = _n() + 1;
        uint256 expected = count < MAX_CURSOR_SCAN ? count : MAX_CURSOR_SCAN;
        assertEq(staking.stakerActiveDepositStartIndex(alice), expected);
    }

    /// @dev A lagging cursor is only a hint: the readers stay correct, and later closes carry the scan on.
    function test_fixed18_laggingCursorIsSafeAndCatchesUp() public {
        vm.prank(alice);
        staking.withdrawDeposit(0);
        uint256 count = _n() + 1;

        (uint256 claimable, uint256 periodical, uint256 indefinite) = staking.checkClaimableDataFor(alice);
        assertEq(claimable + periodical + indefinite, 0, "every deposit is closed");

        // New deposits land after the closed tail. claimAll starts at the lagging cursor and still pays them.
        uint256 a = stakeFor(alice, P30, 1_000 * ONE);
        uint256 b = stakeFor(alice, P30, 2_000 * ONE);
        _warpDays(30);
        (claimable,,) = staking.checkClaimableDataFor(alice);
        assertEq(claimable, 3_000 * ONE, "view sees both through the lagging cursor");

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimAll();
        uint256 reward = staking.calculateReward(1_000 * ONE, APY_P30, 30) + staking.calculateReward(2_000 * ONE, APY_P30, 30);
        assertEq(token.balanceOf(alice) - before, 3_000 * ONE + reward, "claimAll paid both");
        assertEq(uint256(_status(alice, a)), uint256(ProgramManager.DepositStatus.CLAIMED));
        assertEq(uint256(_status(alice, b)), uint256(ProgramManager.DepositStatus.CLAIMED));

        // The cursor never passes an open deposit and never exceeds the count; each close moves it <= 256.
        uint256 cursor = staking.stakerActiveDepositStartIndex(alice);
        assertLe(cursor, count + 2);
        uint256 guard;
        while (cursor < count + 2 + guard) {
            uint256 d = stakeFor(alice, P30, 100);
            vm.prank(alice);
            staking.withdrawDeposit(d);
            uint256 next = staking.stakerActiveDepositStartIndex(alice);
            assertGt(next, cursor, "every close makes progress");
            assertLe(next - cursor, MAX_CURSOR_SCAN);
            cursor = next;
            guard++;
            assertLt(guard, 10, "catches up in a few closes");
        }
        assertEq(cursor, staking.checkDepositCountOfAddress(alice), "fully caught up");
    }
}

contract CursorScanGas0 is CursorScanGasBase {
    function _n() internal pure override returns (uint256) {
        return 0;
    }
}

contract CursorScanGas200 is CursorScanGasBase {
    function _n() internal pure override returns (uint256) {
        return 200;
    }
}

contract CursorScanGas400 is CursorScanGasBase {
    function _n() internal pure override returns (uint256) {
        return 400;
    }
}

contract CursorScanGas1000 is CursorScanGasBase {
    function _n() internal pure override returns (uint256) {
        return 1_000;
    }
}
