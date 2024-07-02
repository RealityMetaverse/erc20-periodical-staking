// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./ReadFunctions.sol";

contract AuxiliaryFunctions is ReadFunctions {
    function _pushStakingPhase(address userAddress) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);
        uint256[] memory _stakingPeriods = stakingContract.getStakingPeriods();

        uint256 _stakingPeriodCount = _stakingPeriods.length;
        uint256[] memory _apyForEachStakingPeriod = new uint256[](_stakingPeriodCount);
        uint256[] memory _targetForEachStakingPeriod = new uint256[](_stakingPeriodCount);

        for (uint256 index = 0; index < _stakingPeriodCount; index++) {
            _apyForEachStakingPeriod[index] = _refAPY;
            _targetForEachStakingPeriod[index] = _refStakingTarget;

            _refAPY += _refAPYModifier;
            _refStakingTarget += _refStakingTargetModifier;
        }

        stakingContract.pushStakingPhase(_apyForEachStakingPeriod, _targetForEachStakingPeriod);

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _pushStakingPhaseWithTest(address userAddress) internal {
        uint256 _targetStakingPhase = stakingContract.stakingPhaseCount();

        uint256[] memory _stakingPeriods = stakingContract.getStakingPeriods();
        uint256 _stakingPeriodCount = _stakingPeriods.length;

        for (uint256 index = 0; index < _stakingPeriodCount; index++) {
            assertEq(_getPhasePeriodAPY(_targetStakingPhase, _stakingPeriods[index]), 0);
            assertEq(_getPhasePeriodStakingTarget(_targetStakingPhase, _stakingPeriods[index]), 0);
        }

        _pushStakingPhase(userAddress);

        assertEq(stakingContract.stakingPhaseCount(), _targetStakingPhase + 1);

        for (uint256 index = 0; index < _stakingPeriodCount; index++) {
            assertEq(
                _getPhasePeriodAPY(_targetStakingPhase, _stakingPeriods[index]),
                _refAPY - ((_stakingPeriodCount - index) * _refAPYModifier)
            );
            assertEq(
                _getPhasePeriodStakingTarget(_targetStakingPhase, _stakingPeriods[index]),
                _refStakingTarget - ((_stakingPeriodCount - index) * _refStakingTargetModifier)
            );
        }
    }

    function _popStakingPhase(address userAddress) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        stakingContract.popStakingPhase();

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _popStakingPhaseWithTest(address userAddress) internal {
        uint256 _targetStakingPhase = stakingContract.stakingPhaseCount();

        _popStakingPhase(userAddress);

        uint256[] memory _stakingPeriods = stakingContract.getStakingPeriods();
        uint256 _stakingPeriodCount = _stakingPeriods.length;

        assertEq(stakingContract.stakingPhaseCount(), _targetStakingPhase - 1);

        for (uint256 index = 0; index < _stakingPeriodCount; index++) {
            assertEq(_getPhasePeriodAPY(_targetStakingPhase, _stakingPeriods[index]), 0);
            assertEq(_getPhasePeriodStakingTarget(_targetStakingPhase, _stakingPeriods[index]), 0);
        }
    }

    function _addStakingPeriod(address userAddress) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        uint256 _stakingPhaseCount = stakingContract.stakingPhaseCount();
        uint256[] memory _apyForEachStakingPhase = new uint256[](_stakingPhaseCount);
        uint256[] memory _targetForEachStakingPhase = new uint256[](_stakingPhaseCount);

        for (uint256 index = 0; index < _stakingPhaseCount; index++) {
            _apyForEachStakingPhase[index] = _refAPY;
            _targetForEachStakingPhase[index] = _refStakingTarget;

            _refAPY += _refAPYModifier;
            _refStakingTarget += _refStakingTargetModifier;
        }

        stakingContract.addStakingPeriod(_refPeriod, _apyForEachStakingPhase, _targetForEachStakingPhase);
        _refPeriod += _refPeriodModifier;

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _addStakingPeriodWithTest(address userAddress) internal {
        uint256 _stakingPhaseCount = stakingContract.stakingPhaseCount();
        uint256 _stakingPeriodCount = stakingContract.getStakingPeriods().length;
        uint256 _targetStakingPeriod = _refPeriod;

        for (uint256 index = 0; index < _stakingPhaseCount; index++) {
            assertEq(_getPhasePeriodAPY(index, _targetStakingPeriod), 0);
            assertEq(_getPhasePeriodStakingTarget(index, _targetStakingPeriod), 0);
        }

        _addStakingPeriod(userAddress);

        assertEq(stakingContract.getStakingPeriods().length, _stakingPeriodCount + 1);

        for (uint256 index = 0; index < _stakingPhaseCount; index++) {
            assertEq(
                _getPhasePeriodAPY(index, _targetStakingPeriod),
                _refAPY - ((_stakingPhaseCount - index) * _refAPYModifier)
            );
            assertEq(
                _getPhasePeriodStakingTarget(index, _targetStakingPeriod),
                _refStakingTarget - ((_stakingPhaseCount - index) * _refStakingTargetModifier)
            );
        }
    }

    function _removeStakingPeriod(address userAddress) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        _refPeriod -= _refPeriodModifier;
        stakingContract.removeStakingPeriod(_refPeriod);

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _removeStakingPeriodWithTest(address userAddress) internal {
        uint256 _stakingPhaseCount = stakingContract.stakingPhaseCount();
        uint256 _stakingPeriodCount = stakingContract.getStakingPeriods().length;
        uint256 _targetStakingPeriod = _refPeriod;

        _removeStakingPeriod(userAddress);

        assertEq(stakingContract.getStakingPeriods().length, _stakingPeriodCount - 1);

        for (uint256 index = 0; index < _stakingPhaseCount; index++) {
            assertEq(_getPhasePeriodAPY(index, _targetStakingPeriod), 0);
            assertEq(_getPhasePeriodStakingTarget(index, _targetStakingPeriod), 0);
        }
    }

    function _addPhasesAndPeriods() internal {
        uint8 x = 5;
        uint8 y = 5;

        for (uint8 No = 0; No < x; No++) {
            _pushStakingPhaseWithTest(address(this));
        }
        for (uint8 No = 0; No < y; No++) {
            _addStakingPeriodWithTest(address(this));
        }
    }

    function _increaseAllowance(address userAddress, uint256 tokenAmount) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        myToken.increaseAllowance(address(stakingContract), tokenAmount);

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _stakeTokenWithTest(
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 tokenAmount,
        bool ifRevertExpected
    ) internal {
        if (userAddress != address(this)) vm.startPrank(userAddress);

        uint256 phasePeriodAPY = _getPhasePeriodAPY(stakingPhase, stakingPeriod);

        if (ifRevertExpected) {
            vm.expectRevert();
            stakingContract.safeStake(stakingPhase, stakingPeriod, tokenAmount, phasePeriodAPY);
        } else {
            uint256[] memory currentData = _getCurrentData(userAddress, stakingPhase, stakingPeriod);
            uint256 userDepositCountBefore = _getUserDepositCount(userAddress);

            uint256 rewardExpected =
                (stakingPeriod == 0) ? 0 : stakingContract.calculateReward(tokenAmount, phasePeriodAPY, stakingPeriod);

            uint256[] memory expectedData = new uint256[](10);
            expectedData[0] = currentData[0] + tokenAmount;
            expectedData[1] = currentData[1] - tokenAmount;
            expectedData[2] = currentData[2] + tokenAmount;
            expectedData[3] = currentData[3] + tokenAmount;
            expectedData[4] = currentData[4] + tokenAmount;
            expectedData[8] = currentData[8] + rewardExpected;
            expectedData[9] = currentData[9] + rewardExpected;

            stakingContract.safeStake(stakingPhase, stakingPeriod, tokenAmount, phasePeriodAPY);

            currentData = _getCurrentData(userAddress, stakingPhase, stakingPeriod);

            assertEq(currentData[0], expectedData[0]);
            assertEq(currentData[1], expectedData[1]);
            assertEq(currentData[2], expectedData[2]);
            assertEq(currentData[3], expectedData[3]);
            assertEq(currentData[4], expectedData[4]);
            assertEq(currentData[8], expectedData[8]);
            assertEq(currentData[9], expectedData[9]);

            uint256 userDepositCountAfter = _getUserDepositCount(userAddress);
            assertEq(userDepositCountAfter, userDepositCountBefore + 1);

            ProgramManager.TokenDeposit memory targetDeposit =
                stakingContract.getDeposit(userAddress, userDepositCountAfter - 1);
            assertEq(targetDeposit.stakingPhase, stakingPhase);
            assertEq(targetDeposit.stakingPeriod, stakingPeriod);
            assertEq(targetDeposit.amount, tokenAmount);
            assertEq(targetDeposit.APY, phasePeriodAPY);
            assertEq(targetDeposit.rewardGenerated, rewardExpected);
        }

        if (userAddress != address(this)) vm.stopPrank();
    }

    function _stakeTokenWithAllowance(
        address userAddress,
        uint256 stakingPhase,
        uint256 stakingPeriod,
        uint256 tokenAmount
    ) internal {
        _increaseAllowance(userAddress, tokenAmount);
        _stakeTokenWithTest(userAddress, stakingPhase, stakingPeriod, tokenAmount, false);
    }

    function _tryMultiUserMultiStake() internal returns (uint256) {
        uint256 _stakingPhaseCount = stakingContract.stakingPhaseCount();
        uint256[] memory _stakingPeriods = stakingContract.getStakingPeriods();

        for (uint256 phase = 0; phase < _stakingPhaseCount; phase++) {
            stakingContract.changeStakingPhase(phase);
            for (uint256 periodIndex = 0; periodIndex < _stakingPeriods.length; periodIndex++) {
                for (uint256 userNo = 0; userNo < addressList.length; userNo++) {
                    _increaseAllowance(addressList[userNo], amountToStake);
                    _stakeTokenWithTest(addressList[userNo], phase, _stakingPeriods[periodIndex], amountToStake, false);
                }
            }
        }

        return _stakingPhaseCount * _stakingPeriods.length;
    }
}
