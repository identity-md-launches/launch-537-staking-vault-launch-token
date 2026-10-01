// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Receiver-side hook, in the spirit of ERC-777 `tokensReceived` / ERC-1363 `onTransferReceived`.
interface ITokenHookReceiver {
    function onTokenMoved(address from, address to, uint256 value) external;
}

/// @dev Test-only ERC-20 that calls a hook on the sender and on the recipient of every transfer
/// when they are contracts. The launch token has no hooks; this mock exists only to prove that
/// the vault's reentrancy guard holds if the token ever did.
contract ReentrantToken is ERC20 {
    constructor(uint256 supply) ERC20("Hook Token", "HOOK") {
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _notify(from, from, to, value);
        if (to != from) _notify(to, from, to, value);
    }

    /// @dev Contracts that do not implement the hook (the vault itself) are left alone.
    function _notify(address target, address from, address to, uint256 value) private {
        if (target == address(0) || target.code.length == 0) return;
        try ITokenHookReceiver(target).onTokenMoved(from, to, value) {} catch {}
    }
}
