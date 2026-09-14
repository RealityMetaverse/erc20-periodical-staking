// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../functions/ClaimFunctions.sol";
import "../functions/WithdrawalFunctions.sol";
import "../../../src/common/Errors.sol";
import "../../../src/common/Events.sol";
import "../../../src/contracts/erc20-periodical-staking/AccessControl.sol";

/// @dev Shared bootstrap for the v0.3.0 unit tests: 1 phase, periods 7 and 90, optionally funded pool.
///      Inherits Events so tests can `emit` them inside vm.expectEmit blocks. `_now()` (live timestamp,
///      via_ir-safe) is inherited from TestSetUp; never read `block.timestamp` after a warp in these tests.
abstract contract V030Base is ClaimFunctions, WithdrawalFunctions, Events {
    uint256 constant PERIOD_SHORT = 7;
    uint256 constant PERIOD_LONG = 90;
    uint256 constant APY = 3000; // bps
    uint256 constant TARGET = 10_000_000 ether;
    uint256 constant STAKE_AMOUNT = 200 ether;

    /// @dev Periods 0 (indefinite), 7 and 90 on a single phase; users topped up so multi-deposit tests
    ///      never run out of balance.
    function _setupProgram(bool fundPool) internal {
        uint256[] memory emptyAPY = new uint256[](0);
        uint256[] memory emptyTarget = new uint256[](0);
        stakingContract.addStakingPeriod(0, emptyAPY, emptyTarget);
        stakingContract.addStakingPeriod(PERIOD_SHORT, emptyAPY, emptyTarget);
        stakingContract.addStakingPeriod(PERIOD_LONG, emptyAPY, emptyTarget);

        uint256[] memory apys = new uint256[](3);
        uint256[] memory targets = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            apys[i] = APY;
            targets[i] = TARGET;
        }
        stakingContract.pushStakingPhase(apys, targets);

        for (uint256 i = 0; i < addressList.length; i++) {
            myToken.transfer(addressList[i], 100_000 ether);
        }

        if (fundPool) _fundRewardPool(amountToProvide);
    }

    function _fundRewardPool(uint256 amount) internal {
        _increaseAllowance(contractAdmin, amount);
        vm.prank(contractAdmin);
        stakingContract.provideReward(amount);
    }

    function _stakeFor(address user, uint256 period, uint256 amount) internal {
        _increaseAllowance(user, amount);
        _stakeV(stakingContract, user, 0, period, amount);
    }

    function _periodicalReward(uint256 amount, uint256 period) internal view returns (uint256) {
        return stakingContract.calculateReward(amount, APY, period);
    }
}
