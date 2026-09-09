// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that invokes an arbitrary hook (low-level call) after every transfer / transferFrom.
///         Used to drive reentrancy into the staking contract from inside `_receiveToken` / `_sendToken`.
contract ReentrantERC20 is ERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookOnTransfer;
    bool public hookOnTransferFrom;
    bool public swallowHookRevert;
    uint256 public maxHookCalls;
    uint256 public hookCalls;

    bool public lastHookSuccess;
    bytes public lastHookReturn;

    constructor() ERC20("Reentrant", "RNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(
        address target,
        bytes calldata data,
        bool onTransfer,
        bool onTransferFrom,
        bool swallow,
        uint256 maxCalls
    ) external {
        hookTarget = target;
        hookData = data;
        hookOnTransfer = onTransfer;
        hookOnTransferFrom = onTransferFrom;
        swallowHookRevert = swallow;
        maxHookCalls = maxCalls;
        hookCalls = 0;
    }

    function clearHook() external {
        hookTarget = address(0);
        hookOnTransfer = false;
        hookOnTransferFrom = false;
    }

    function _fire() internal {
        if (hookTarget == address(0) || hookCalls >= maxHookCalls) return;
        hookCalls++;
        (bool ok, bytes memory ret) = hookTarget.call(hookData);
        lastHookSuccess = ok;
        lastHookReturn = ret;
        if (!ok && !swallowHookRevert) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool r = super.transfer(to, amount);
        if (hookOnTransfer) _fire();
        return r;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool r = super.transferFrom(from, to, amount);
        if (hookOnTransferFrom) _fire();
        return r;
    }
}

/// @notice Charges a fee (in basis points) on every transfer; recipient receives less than `amount`.
contract FeeOnTransferToken is ERC20 {
    uint256 public feeBps;

    constructor(uint256 _feeBps) ERC20("Fee", "FEE") {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Returns `false` from transfer / transferFrom instead of reverting (no tokens move).
contract FalseReturningToken is ERC20 {
    bool public failTransfer;
    bool public failTransferFrom;

    constructor() ERC20("False", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFail(bool _transfer, bool _transferFrom) external {
        failTransfer = _transfer;
        failTransferFrom = _transferFrom;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, amount);
    }
}

/// @notice transferFrom moves only half of the requested amount but still returns true.
contract ShortTransferToken is ERC20 {
    constructor() ERC20("Short", "SHT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount / 2);
        return true;
    }
}

/// @notice USDT-style token: transfer / transferFrom have no return value.
contract NoReturnToken {
    string public name = "NoReturn";
    string public symbol = "NRT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Plain mintable ERC20 (18 decimals) for "foreign token" rescue tests.
contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
