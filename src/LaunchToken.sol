// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice The fixed-supply launch token staked in, and paid out by, the StakingVault.
/// @dev Plain ERC-20: 18 decimals, exactly 1,000,000,000 tokens minted once to the deployer
/// (the ProjectFactory at launch), no constructor arguments, and no mint, owner, pause,
/// blocklist, fee or upgrade functions. The factory splits the supply; nothing here holds or
/// forwards any of it.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 10^9 tokens with 18 decimals.
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Stake Launch Token", "STK") {
        _mint(msg.sender, SUPPLY);
    }
}
