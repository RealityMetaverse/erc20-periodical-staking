// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../AuxiliaryFunctions.sol";
import "../../../src/contracts/LimitController.sol";
import "../../../src/common/Errors.sol";

contract LimitControllerFunctions is AuxiliaryFunctions {
    LimitController limitController;

    function _deployLimitController(address stakingContractAddress) internal {
        limitController = new LimitController(stakingContractAddress);
    }

    // No _setStakingContract helper: LimitController.stakingContract is immutable (finding #16).

    function _setWalletLimit(address wallet, uint256 phase, uint256 period, uint256 limit, bool ifRevertExpected)
        internal
    {
        if (ifRevertExpected) {
            vm.expectRevert();
        }
        limitController.setWalletLimit(wallet, phase, period, limit);
    }

    function _setWalletLimits(
        address[] memory wallets,
        uint256 phase,
        uint256 period,
        uint256[] memory limits,
        bool ifRevertExpected
    ) internal {
        if (ifRevertExpected) {
            vm.expectRevert();
        }
        limitController.setWalletLimits(wallets, phase, period, limits);
    }

    function _getAllowed(address wallet, uint256 phase, uint256 period) internal view returns (uint256) {
        return limitController.getAllowed(wallet, phase, period);
    }

    function _getRemaining(address wallet, uint256 phase, uint256 period) internal view returns (uint256) {
        return limitController.getRemaining(wallet, phase, period);
    }

    function _setLimitControllerOnStakingContract(address controllerAddress) internal {
        stakingContract.setLimitController(controllerAddress);
    }
}
