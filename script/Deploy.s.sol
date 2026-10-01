// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @title Deploy
/// @notice Standalone deployment of the launch token and the staking vault, for local or
/// testnet use. The production launch goes through the network's ProjectFactory, which deploys
/// `LaunchToken` and then `StakingVault($token, rewardsDuration)` from the manifest; this
/// script is not used there.
contract Deploy is Script {
    struct Config {
        /// Length of every reward period in seconds. The launch default is 7 days.
        uint256 rewardsDuration;
    }

    uint256 public constant DEFAULT_REWARDS_DURATION = 7 days;

    /// @dev Reads the configuration from the environment and broadcasts. Tests never call this;
    /// they call `deploy` directly with an explicit config.
    function run() external returns (LaunchToken token, StakingVault vault) {
        Config memory config = Config({rewardsDuration: vm.envOr("REWARDS_DURATION", DEFAULT_REWARDS_DURATION)});
        vm.startBroadcast();
        (token, vault) = deploy(config);
        vm.stopBroadcast();
    }

    /// @notice Deploys the token (whole supply to the caller) and a vault bound to it.
    function deploy(Config memory config) public returns (LaunchToken token, StakingVault vault) {
        token = new LaunchToken();
        vault = new StakingVault(address(token), config.rewardsDuration);
    }
}
