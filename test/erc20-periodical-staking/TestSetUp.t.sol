// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {TestToken} from "../shared/TestToken.sol";
import {Clock} from "../shared/Clock.sol";

import {ERC20PeriodicalStaking} from "../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import "../../src/contracts/erc20-periodical-staking/ProgramManager.sol";

contract TestSetUp is Test {
    /// @dev Live-timestamp source. With `via_ir` a raw `block.timestamp` read after `skip` / `vm.warp` inside
    ///      the same test function can be CSE-d to the pre-warp value (see test/shared/ClockHazard.t.sol), so
    ///      every test that compares against the current time must go through `_now()`.
    Clock internal clock = new Clock();

    function _now() internal view returns (uint256) {
        return clock.now();
    }

    TestToken myToken;

    uint256 myTokenDecimal = 18;
    uint256 myTokenDecimals = 10 ** myTokenDecimal;

    uint256 _defaultMinimumDeposit = 100 * myTokenDecimals;

    uint256 _refPeriod = 0;
    uint256 _refAPY = 5;
    uint256 _refStakingTarget = 1000 * myTokenDecimals;

    uint256 _refPeriodModifier = 90;
    uint256 _refAPYModifier = 5;
    uint256 _refStakingTargetModifier = 1 * myTokenDecimals;

    ERC20PeriodicalStaking stakingContract;
    uint256 _confirmationCode = 0;

    address contractAdmin = address(1);
    address userOne = address(2);
    address userTwo = address(3);
    address userThree = address(4);

    address[] addressList = [userOne, userTwo, userThree];
    uint256 amountToProvide = 10000 * myTokenDecimals;
    uint256 amountToStake = 10 * myTokenDecimals;

    uint256 tokenToDistribute = 1000 * myTokenDecimals;

    function setUp() external {
        myToken = new TestToken(myTokenDecimal);
        stakingContract = new ERC20PeriodicalStaking(address(myToken));
        stakingContract.addContractAdmin(contractAdmin);

        for (uint256 userNo = 0; userNo < addressList.length; userNo++) {
            myToken.transfer(addressList[userNo], tokenToDistribute);
        }

        myToken.transfer(userThree, _refStakingTarget);
        myToken.transfer(contractAdmin, amountToProvide);
    }
}
