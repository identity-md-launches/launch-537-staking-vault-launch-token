// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token that burns a fee on every transfer. The launch token is plain; this
/// mock only checks that the vault credits what it actually receives.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_, uint256 supply) ERC20("Fee Token", "FEE") {
        feeBps = feeBps_;
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                super._update(from, address(0), fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
