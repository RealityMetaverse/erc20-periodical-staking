// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V030Base.sol";

/// @title rescueTokens cannot touch staked principal or the reward pool
contract RescueTokensTest is V030Base {
    TestToken otherToken;

    function _setupOther() internal {
        otherToken = new TestToken(18);
    }

    function test_RescueForeignToken_Full() public {
        _setupOther();
        otherToken.transfer(address(stakingContract), 500 ether);

        uint256 before = otherToken.balanceOf(address(this));
        vm.expectEmit(true, true, false, true, address(stakingContract));
        emit RescueTokens(address(otherToken), address(this), 500 ether);
        stakingContract.rescueTokens(address(otherToken), 500 ether);

        assertEq(otherToken.balanceOf(address(this)), before + 500 ether);
        assertEq(otherToken.balanceOf(address(stakingContract)), 0);
    }

    function test_RescueForeignToken_MoreThanBalanceReverts() public {
        _setupOther();
        otherToken.transfer(address(stakingContract), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 11 ether, 10 ether));
        stakingContract.rescueTokens(address(otherToken), 11 ether);
    }

    function test_CannotRescueStakedPrincipalOrRewardPool() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);
        _stakeFor(userTwo, 0, STAKE_AMOUNT);

        uint256 reserved = stakingContract.totalDataList(Types.DataType.STAKING) + stakingContract.rewardPool();
        assertEq(myToken.balanceOf(address(stakingContract)), reserved);

        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 1, 0));
        stakingContract.rescueTokens(address(myToken), 1);

        // Users are unaffected and can still exit in full.
        skip(PERIOD_SHORT * 1 days + 1);
        vm.prank(userOne);
        stakingContract.claimDeposit(0);
        vm.prank(userTwo);
        stakingContract.withdrawDeposit(0);
    }

    function test_RescueStakingToken_OnlyExcess() public {
        _setupProgram(true);
        _stakeFor(userOne, PERIOD_SHORT, STAKE_AMOUNT);

        // Tokens sent directly (not via provideReward / safeStake) are excess.
        uint256 stray = 42 ether;
        myToken.transfer(address(stakingContract), stray);

        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, stray + 1, stray));
        stakingContract.rescueTokens(address(myToken), stray + 1);

        uint256 before = myToken.balanceOf(address(this));
        stakingContract.rescueTokens(address(myToken), stray);
        assertEq(myToken.balanceOf(address(this)), before + stray);

        // Accounting untouched, balance again equals principal + pool.
        assertEq(
            myToken.balanceOf(address(stakingContract)),
            stakingContract.totalDataList(Types.DataType.STAKING) + stakingContract.rewardPool()
        );
        assertEq(stakingContract.rewardPool(), amountToProvide);
        assertEq(stakingContract.totalDataList(Types.DataType.STAKING), STAKE_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 1, 0));
        stakingContract.rescueTokens(address(myToken), 1);
    }

    function test_RescueStakingToken_PartialExcess() public {
        _setupProgram(true);
        myToken.transfer(address(stakingContract), 10 ether);
        stakingContract.rescueTokens(address(myToken), 4 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueAmountExceedsExcess.selector, 7 ether, 6 ether));
        stakingContract.rescueTokens(address(myToken), 7 ether);
        stakingContract.rescueTokens(address(myToken), 6 ether);
    }

    function test_OnlyOwner() public {
        _setupOther();
        otherToken.transfer(address(stakingContract), 1 ether);

        vm.prank(contractAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER)
        );
        stakingContract.rescueTokens(address(otherToken), 1 ether);

        vm.prank(userOne);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControl.UnauthorizedAccess.selector, AccessControl.AccessTier.OWNER)
        );
        stakingContract.rescueTokens(address(otherToken), 1 ether);
    }

    function test_InputValidation() public {
        _setupOther();
        vm.expectRevert(Errors.ZeroAddressProvided.selector);
        stakingContract.rescueTokens(address(0), 1);

        vm.expectRevert(Errors.ZeroAmountProvided.selector);
        stakingContract.rescueTokens(address(otherToken), 0);
    }
}
