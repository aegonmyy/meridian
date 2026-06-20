// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "./BaseHubTest.t.sol";
import {ZeroWithdrawal} from "../../../src/errors/hubErrors.sol";

/// @notice Tests for _withdraw Path 2 — idle covers + spokes stale → queue + report balance
/// Condition: idle >= assets AND _allSpokesFresh() == false
/// Setup: vm.warp to safe timestamp, set stale lastReportTimestamp via vm.store
/// CCIP synchronous — report arrives and withdrawal settles in same transaction
contract WithdrawPath2Test is BaseHubTest {

    function test_withdrawPath2_aliceReceivesCorrectUSDC() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);
        uint256 balanceBefore = usdc.balanceOf(betty);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(usdc.balanceOf(betty), balanceBefore + assets);
    }

    function test_withdrawPath2_sharesFullyBurned() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.balanceOf(betty), 0);
        assertEq(hub.balanceOf(address(hub)), 0);
    }

    function test_withdrawPath2_reservedAssetsZeroAfterSettlement() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.reservedAssets(), 0);
    }

    function test_withdrawPath2_totalAssetsDecreased() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 totalBefore = hub.totalAssets();
        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.totalAssets(), totalBefore - assets);
    }

    function test_withdrawPath2_lastReportTimestampRefreshed() public {
        vm.warp(1 days);
        uint256 staleTimestamp = block.timestamp - 2 hours;
        _setLastReportTimestamp(chainSelector, staleTimestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertGt(hub.lastReportTimestamp(chainSelector), staleTimestamp);
    }

    function test_withdrawPath2_spokeBalancesUpdated() public {
        // send some funds to spoke first so spoke has a real balance to report
        _sendToSpoke(3_000e6);

        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.spokeBalances(chainSelector), 3_000e6);
        assertGt(
            hub.lastReportTimestamp(chainSelector),
            block.timestamp - 2 hours
        );
    }

    function test_withdrawPath2_multipleUsers_bothSettle() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        address charlie = makeAddr("charlie");

        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        usdc.mint(charlie, 2_000e6);
        vm.startPrank(charlie);
        usdc.approve(address(hub), 2_000e6);
        hub.deposit(2_000e6, charlie);
        vm.stopPrank();

        uint256 bettyShares = hub.balanceOf(betty);
        uint256 bettyAssets = hub.previewRedeem(bettyShares);
        uint256 charlieShares = hub.balanceOf(charlie);
        uint256 charlieAssets = hub.previewRedeem(charlieShares);

        vm.prank(betty);
        hub.withdraw(bettyAssets, betty, betty);

        // warp again to make stale for charlie
        vm.warp(block.timestamp + 2 hours);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        vm.prank(charlie);
        hub.withdraw(charlieAssets, charlie, charlie);

        assertEq(usdc.balanceOf(betty), bettyAssets);
        assertEq(usdc.balanceOf(charlie), charlieAssets);
        assertEq(hub.balanceOf(betty), 0);
        assertEq(hub.balanceOf(charlie), 0);
    }

    function test_withdrawPath2_partialWithdrawal() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 2_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 2_000e6);
        hub.deposit(2_000e6, betty);
        vm.stopPrank();

        uint256 totalShares = hub.balanceOf(betty);
        uint256 halfShares = totalShares / 2;
        uint256 halfAssets = hub.previewRedeem(halfShares);

        vm.prank(betty);
        hub.redeem(halfShares, betty, betty);

        assertEq(hub.balanceOf(betty), totalShares - halfShares);
        assertEq(usdc.balanceOf(betty), halfAssets);
    }

    function test_withdrawPath2_revert_zeroAmount() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawal.selector);
        hub.withdraw(0, alice, alice);
    }

    function test_withdrawPath2_revert_exceedsBalance() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        vm.expectRevert();
        hub.withdraw(assets + 1e6, alice, alice);
    }
}
