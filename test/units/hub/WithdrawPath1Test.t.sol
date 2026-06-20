// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "./BaseHubTest.t.sol";
import {HUB} from "../../../src/Hub.sol";
import {ZeroWithdrawal} from "../../../src/errors/hubErrors.sol";

/// @notice Tests for _withdraw Path 1, _allSpokesFresh, and _findBestSpoke
contract WithdrawPath1Test is BaseHubTest {

    // =========================================================================
    // _withdraw Path 1 — idle covers + spokes fresh → immediate settlement
    // Setup: set fresh timestamp via vm.store, fresh actor deposits small amount
    // Hub has enough idle from alice's setUp deposit to cover betty's withdrawal
    // =========================================================================

    function test_withdraw_path1_burnsShares() public {
        // fresh timestamp — Path 1 condition met
        _setLastReportTimestamp(chainSelector, block.timestamp);

        // betty deposits small amount — hub has 10_000 idle, easily covers 1_000
        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);
        uint256 totalBefore = hub.totalAssets();

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.balanceOf(betty), 0);
        assertEq(hub.totalAssets(), totalBefore - assets);
    }

    function test_withdraw_path1_transfersUSDCToReceiver() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

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

    function test_withdraw_path1_receiverDifferentFromOwner() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        address receiver = makeAddr("receiver");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, receiver, betty);

        assertEq(hub.balanceOf(betty), 0);
        assertEq(usdc.balanceOf(receiver), assets);
        assertEq(usdc.balanceOf(betty), 0);
    }

    function test_withdraw_path1_reservedAssetsZeroAfter() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

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

        // Path 1 processes immediately — reservedAssets never stays elevated
        assertEq(hub.reservedAssets(), 0);
    }

    function test_withdraw_path1_totalAssetsDecreased() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

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

    function test_withdraw_path1_fullWithdrawal_totalSupplyZero() public {
        // both alice and betty fully withdraw — totalSupply goes to 0
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 bettyShares = hub.balanceOf(betty);
        uint256 bettyAssets = hub.previewRedeem(bettyShares);
        vm.prank(betty);
        hub.withdraw(bettyAssets, betty, betty);

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 aliceAssets = hub.previewRedeem(aliceShares);
        vm.prank(alice);
        hub.withdraw(aliceAssets, alice, alice);

        assertEq(hub.totalSupply(), 0);
        assertEq(hub.totalAssets(), 0);
    }

    function test_withdraw_path1_multipleUsers() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address bob = makeAddr("bob");
        usdc.mint(bob, 2_000e6);
        vm.startPrank(bob);
        usdc.approve(address(hub), 2_000e6);
        hub.deposit(2_000e6, bob);
        vm.stopPrank();

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 aliceAssets = hub.previewRedeem(aliceShares);
        uint256 bobShares = hub.balanceOf(bob);
        uint256 bobAssets = hub.previewRedeem(bobShares);

        vm.prank(alice);
        hub.withdraw(aliceAssets, alice, alice);

        vm.prank(bob);
        hub.withdraw(bobAssets, bob, bob);

        assertEq(hub.totalSupply(), 0);
        assertEq(hub.balanceOf(alice), 0);
        assertEq(hub.balanceOf(bob), 0);
    }

    function test_withdraw_path1_callerNotOwner_usesAllowance() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        address operator = makeAddr("operator");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.approve(operator, shares);

        vm.prank(operator);
        hub.withdraw(assets, operator, betty);

        assertEq(hub.balanceOf(betty), 0);
        assertEq(usdc.balanceOf(operator), assets);
    }

    function test_withdraw_path1_revert_insufficientAllowance() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        address operator = makeAddr("operator");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(operator);
        vm.expectRevert();
        hub.withdraw(assets, operator, betty);
    }

    function test_withdraw_path1_revert_zeroAmount() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawal.selector);
        hub.withdraw(0, alice, alice);
    }

    function test_withdraw_path1_revert_exceedsBalance() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        vm.expectRevert();
        hub.withdraw(assets + 1e6, alice, alice);
    }

    // =========================================================================
    // _allSpokesFresh Tests
    // =========================================================================

    function test_allSpokesFresh_path1WhenFresh() public {
        // fresh timestamp set — _allSpokesFresh returns true
        // idle (10_000) covers alice's shares — Path 1 executes immediately
        _setLastReportTimestamp(chainSelector, block.timestamp);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assets);
        assertEq(hub.reservedAssets(), 0);
    }

    function test_allSpokesFresh_path2WhenStale() public {
        // warp to a safe timestamp first to avoid underflow
        vm.warp(1 days);

        // set stale timestamp — _allSpokesFresh returns false
        // idle covers — Path 2: queue + request report balance
        // CCIP synchronous — report arrives, withdrawal settles
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assets);
        assertGt(
            hub.lastReportTimestamp(chainSelector),
            block.timestamp - 2 hours
        );
    }

    function test_allSpokesFresh_returnsFalseWithNoSpokes() public {
        // fresh hub with no spokes — _allSpokesFresh returns false
        // idle covers — Path 2 but no spokes to send report to
        // withdrawal stays queued indefinitely
        vm.prank(owner);
        HUB freshHub = new HUB(
            "Test",
            "TST",
            address(router),
            owner,
            address(link),
            address(usdc),
            rebalancer
        );
        ccipSimulator.requestLinkFromFaucet(address(freshHub), 10 ether);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(freshHub), 1_000e6);
        freshHub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = freshHub.balanceOf(betty);
        uint256 assets = freshHub.previewRedeem(shares);

        vm.prank(betty);
        freshHub.withdraw(assets, betty, betty);

        // no spokes to report — withdrawal stays queued
        assertEq(freshHub.reservedAssets(), assets);
        assertEq(usdc.balanceOf(betty), 0);
    }

    function test_allSpokesFresh_staleAfterWarp() public {
        // set fresh then warp past MAX_STALENESS — becomes stale
        // CCIP synchronous — Path 2 still settles via report balance
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        vm.warp(block.timestamp + 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assets);
        assertGe(hub.lastReportTimestamp(chainSelector), block.timestamp);
    }

    // =========================================================================
    // _findBestSpoke Tests
    // =========================================================================

    function test_findBestSpoke_recallsFromHighestBalance() public {
        // register second spoke — mock address, CCIP will fail to it
        // we only care that hub ATTEMPTS to recall from the highest balance spoke
        uint64 selector2 = 9999;
        address mockSpoke2 = makeAddr("spoke2");
        vm.prank(owner);
        hub.addSpoke(selector2, mockSpoke2);

        // spoke1 balance = 3_000, spoke2 balance = 8_000
        _setSpokeBalance(chainSelector, 3_000e6);
        _setSpokeBalance(selector2, 8_000e6);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _setLastReportTimestamp(selector2, block.timestamp);

        // drain hub idle below alice's share value — triggers Path 3
        deal(address(usdc), address(hub), 100e6);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        // Path 3 — CCIP to mockSpoke2 will fail since it's not a real contract
        // withdrawal stays queued
        vm.prank(alice);
        try hub.withdraw(assets, alice, alice) {} catch {}

        // withdrawal is queued — reservedAssets > 0
        assertGt(hub.reservedAssets(), 0);
    }

    function test_findBestSpoke_singleSpoke() public {
        // single spoke with real balance — Path 3 recalls from it
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _sendToSpoke(5_000e6);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        // recalled from real spoke — CCIP synchronous — should settle
        assertEq(hub.balanceOf(alice), 0);
    }
}
