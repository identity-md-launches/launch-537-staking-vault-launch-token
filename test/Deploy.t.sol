// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

contract DeployTest is Test {
    function test_deployWiresVaultToToken() public {
        Deploy script = new Deploy();
        (LaunchToken token, StakingVault vault) = script.deploy(Deploy.Config({rewardsDuration: 3 days}));

        assertEq(address(vault.token()), address(token));
        assertEq(vault.rewardsDuration(), 3 days);
        assertEq(vault.LOCK_PERIOD(), 7 days);
        // The script contract is the token's deployer, so it holds the whole supply.
        assertEq(token.balanceOf(address(script)), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_deployRejectsZeroDuration() public {
        Deploy script = new Deploy();
        vm.expectRevert(StakingVault.ZeroDuration.selector);
        script.deploy(Deploy.Config({rewardsDuration: 0}));
    }
}
