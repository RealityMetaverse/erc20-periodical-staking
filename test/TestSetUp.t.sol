// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {MockToken} from "./MockToken.sol";

import {ERC20PeriodicalStaking} from "../src/ERC20PeriodicalStaking.sol";
import "../src/ProgramManager.sol";

contract TestSetUp is Test {
    MockToken myToken;

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
        myToken = new MockToken(myTokenDecimal);
        stakingContract = new ERC20PeriodicalStaking(address(myToken));
        stakingContract.addContractAdmin(contractAdmin);

        for (uint256 userNo = 0; userNo < addressList.length; userNo++) {
            myToken.transfer(addressList[userNo], tokenToDistribute);
        }

        myToken.transfer(userThree, _refStakingTarget);
        myToken.transfer(contractAdmin, amountToProvide);
    }
}
