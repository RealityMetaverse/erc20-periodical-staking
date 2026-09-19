// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../../src/interfaces/ILimitController.sol";
import "../../../src/interfaces/IRequirementChecker.sol";

/// @notice A limit controller that can be switched into several hostile modes.
contract MaliciousLimitController is ILimitController {
    enum Mode {
        ALLOW_ALL, // returns type(uint256).max
        ALLOW_NONE, // returns 0
        REVERT, // reverts with a custom error
        REENTER, // tries to call back into the staking contract (state-changing)
        GAS_BURN, // loops until out of gas
        WRONG_LENGTH, // batch functions return arrays of the wrong length
        EMPTY_REVERT // reverts with no data
    }

    error ControllerRevert();

    Mode public mode;
    address public staking;
    bytes public reenterData;
    bool public lastReenterSuccess;
    bytes public lastReenterReturn;

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenter(address _staking, bytes calldata data) external {
        staking = _staking;
        reenterData = data;
    }

    function _burn() internal pure {
        uint256 x;
        while (true) {
            x++;
        }
    }

    function _act() internal view returns (uint256) {
        if (mode == Mode.ALLOW_ALL) return type(uint256).max;
        if (mode == Mode.ALLOW_NONE) return 0;
        if (mode == Mode.REVERT) revert ControllerRevert();
        if (mode == Mode.EMPTY_REVERT) revert();
        if (mode == Mode.GAS_BURN) _burn();
        return type(uint256).max;
    }

    function getRemaining(address, uint256, uint256) external view returns (uint256) {
        if (mode == Mode.REENTER) {
            // This function is invoked via STATICCALL from the staking contract. Any state change must fail.
            (bool ok, bytes memory ret) = staking.staticcall(reenterData);
            // We can't record in a view; the staking contract will see whatever we return.
            // If the re-entrant call somehow succeeded, return 0 so the outer stake fails loudly.
            if (ok) return 0;
            ret;
            return type(uint256).max;
        }
        return _act();
    }

    function getAllowedAndUsed(address, uint256, uint256) external view returns (uint256, uint256) {
        if (mode == Mode.REENTER) {
            // Invoked via STATICCALL: a state-changing re-entry must fail. If it somehow succeeded, allow nothing.
            (bool ok,) = staking.staticcall(reenterData);
            if (ok) return (0, 0);
            return (type(uint256).max, 0);
        }
        if (mode == Mode.WRONG_LENGTH) return (type(uint256).max, 0);
        return (_act(), 0);
    }

    function getRemainingBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        view
        returns (uint256[] memory remainings)
    {
        if (mode == Mode.WRONG_LENGTH) return new uint256[](wallets.length == 0 ? 1 : wallets.length - 1);
        uint256 v = _act();
        remainings = new uint256[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            remainings[i] = v;
        }
    }

    function getAllowedBatch(address[] calldata wallets, uint256[] calldata, uint256[] calldata)
        external
        view
        returns (uint256[] memory allowed)
    {
        if (mode == Mode.WRONG_LENGTH) return new uint256[](wallets.length == 0 ? 1 : wallets.length - 1);
        uint256 v = _act();
        allowed = new uint256[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            allowed[i] = v;
        }
    }
}

/// @notice A requirement checker that can be switched into several hostile modes.
contract MaliciousRequirementChecker is IRequirementChecker {
    enum Mode {
        PASS,
        FAIL,
        REVERT,
        GAS_BURN,
        WRONG_LENGTH,
        REENTER
    }

    error CheckerRevert();

    Mode public mode;
    address public staking;
    bytes public reenterData;

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenter(address _staking, bytes calldata data) external {
        staking = _staking;
        reenterData = data;
    }

    function _burn() internal pure {
        uint256 x;
        while (true) {
            x++;
        }
    }

    function meetsRequirement(address, uint256, uint256) external view returns (bool) {
        if (mode == Mode.PASS) return true;
        if (mode == Mode.FAIL) return false;
        if (mode == Mode.REVERT) revert CheckerRevert();
        if (mode == Mode.GAS_BURN) _burn();
        if (mode == Mode.REENTER) {
            (bool ok,) = staking.staticcall(reenterData);
            return !ok;
        }
        return true;
    }

    function meetsRequirementBatch(address[] calldata users, uint256[] calldata, uint256[] calldata)
        external
        view
        returns (bool[] memory results)
    {
        if (mode == Mode.WRONG_LENGTH) return new bool[](users.length == 0 ? 1 : users.length - 1);
        if (mode == Mode.REVERT) revert CheckerRevert();
        if (mode == Mode.GAS_BURN) _burn();
        results = new bool[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            results[i] = mode != Mode.FAIL;
        }
    }

    function getTotalWorth(address) external view returns (uint256) {
        if (mode == Mode.REVERT) revert CheckerRevert();
        return 0;
    }

    function worthBreakdown(address) external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    function getRequiredWorth(uint256, uint256) external view returns (uint256) {
        if (mode == Mode.REVERT) revert CheckerRevert();
        return 1;
    }

    function getRequiredWorthBatch(uint256[] calldata phases, uint256[] calldata)
        external
        view
        returns (uint256[] memory requiredWorths)
    {
        if (mode == Mode.WRONG_LENGTH) return new uint256[](phases.length == 0 ? 1 : phases.length - 1);
        if (mode == Mode.REVERT) revert CheckerRevert();
        requiredWorths = new uint256[](phases.length);
    }

    function getRawTotalWorth(address) external pure returns (uint256) {
        return 0;
    }

    function rawWorthBreakdown(address) external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    function getAppliedOffsetsWorth(address) external pure returns (int256) {
        return 0;
    }

    function getTokenWorth(address) external pure returns (uint256) {
        return 0;
    }

    function getRawTokenWorth(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Contract wallet that owns deposits and performs a configurable re-entrant call when poked.
contract ReentrancyAttacker {
    address public staking;
    address public token;
    bytes public reenterData;
    bool public lastSuccess;
    bytes public lastReturn;
    uint256 public pokes;

    constructor(address _staking, address _token) {
        staking = _staking;
        token = _token;
    }

    function setReenter(bytes calldata data) external {
        reenterData = data;
    }

    /// @dev Called by the malicious token from inside transfer / transferFrom.
    function poke() external {
        pokes++;
        (bool ok, bytes memory ret) = staking.call(reenterData);
        lastSuccess = ok;
        lastReturn = ret;
    }

    /// @dev Like poke() but bubbles the inner revert so the outer staking call fails too.
    function pokeStrict() external {
        pokes++;
        (bool ok, bytes memory ret) = staking.call(reenterData);
        lastSuccess = ok;
        lastReturn = ret;
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function approveAll() external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", staking, type(uint256).max));
        require(ok, "approve");
    }

    function exec(bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = staking.call(data);
    }
}
