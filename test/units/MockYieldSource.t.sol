// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";

contract MockYieldSourceTest is Test {
    Asset public usdc;
    MockYieldSource public adapter;

    address public owner;

    bytes32 public constant AAVE = keccak256("AAVE");

    function setUp() public {
        owner = makeAddr("owner");
        usdc = new Asset();
        adapter = new MockYieldSource(address(usdc));
    }

    function test_transferFrom_depositsCorrectly() public {
        address user = makeAddr("user");
        vm.store(address(usdc), user, bytes32(1_000e6));
        usdc.approve(address(adapter), 1_000e6);

        vm.prank(user);
        adapter.deposit(1_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 1_000e6);
        assertEq(adapter.totalAssets(), 1_000e6);
    }

    function test_withdraw_returnsUserBalance() public {
        address user = makeAddr("user");
        vm.store(address(usdc), address(adapter), bytes32(5_000e6));

        adapter.withdraw(2_000e6);

        assertEq(usdc.balanceOf(user), 2_000e6);
        assertEq(adapter.totalAssets(), 3_000e6);
    }
}
