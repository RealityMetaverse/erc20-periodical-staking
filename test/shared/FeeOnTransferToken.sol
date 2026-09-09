// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferToken
/// @notice ERC20 that burns a percentage of every transfer (fee-on-transfer). Used to prove the staking
///         contract rejects tokens whose received amount differs from the requested amount (v0.3.0 strict token accounting).
contract FeeOnTransferToken is ERC20 {
    /// @dev Fee in basis points (100 = 1%).
    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps) ERC20("FeeToken", "FEE") {
        FEE_BPS = feeBps;
        _mint(msg.sender, 10_000_000 ether);
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        // Mint and burn paths are fee-free.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        if (fee != 0) super._update(from, address(0), fee); // burn the fee
        super._update(from, to, value - fee);
    }
}
