// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../../src/Spoke.sol";
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
        bytes32 balanceSlot = keccak256(abi.encode(user, uint256(0)));
        vm.store(address(usdc), balanceSlot, bytes32(uint256(1_000e6)));

        vm.prank(user);
        usdc.approve(address(adapter), 1_000e6);
        vm.prank(user);
        adapter.deposit(1_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 1_000e6);
        assertEq(adapter.totalAssets(), 1_000e6);
    }

    function test_withdraw_returnsUserBalance() public {
        address user = makeAddr("user");
        bytes32 adapterBalanceSlot = keccak256(abi.encode(address(adapter), uint256(0)));
        vm.store(address(usdc), adapterBalanceSlot, bytes32(uint256(5_000e6)));

        vm.prank(user);
        adapter.withdraw(2_000e6);

        assertEq(usdc.balanceOf(user), 2_000e6);
        assertEq(adapter.totalAssets(), 3_000e6);
    }
}
