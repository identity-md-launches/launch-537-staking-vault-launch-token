// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Stake Launch Token");
        assertEq(token.symbol(), "STK");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 1_234 ether;
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(deployer), 1_000_000_000 ether - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_transferRevertsWhenBalanceInsufficient() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        address attacker = makeAddr("attacker");
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)",
            "upgradeTo(address)"
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(attacker);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], attacker, type(uint128).max));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), supply, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }
}
