// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "./BaseHubTest.t.sol";
import {HUB} from "../../../src/Hub.sol";
import {ZeroWithdrawal, InsufficientRecallLiquidity} from "../../../src/errors/hubErrors.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Tests for _withdraw Path 1, _allSpokesFresh, and _findBestSpoke
contract WithdrawPath1Test is BaseHubTest {

    // =========================================================================
    // _withdraw Path 1: idle covers + spokes fresh → immediate settlement
    // Setup: set fresh timestamp via vm.store, fresh actor deposits small amount
    // Hub has enough idle from alice's setUp deposit to cover betty's withdrawal
    // =========================================================================

    function test_withdraw_path1_burnsShares() public {
        // fresh timestamp. Path 1 condition met
        _setLastReportTimestamp(chainSelector, block.timestamp);

        // betty deposits small amount: hub has 10_000 idle, easily covers 1_000
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

        // Path 1 processes immediately, reservedAssets never stays elevated
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
        // both alice and betty fully withdraw, totalSupply goes to 0
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
        // fresh timestamp set, _allSpokesFresh returns true
        // idle (10_000) covers alice's shares. Path 1 executes immediately
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

        // set stale timestamp, _allSpokesFresh returns false
        // idle covers. Path 2: queue + request report balance
        // CCIP synchronous, report arrives, withdrawal settles
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
        // fresh hub with no spokes, _allSpokesFresh returns false
        // idle covers. Path 2 but no spokes to send report to
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

        // no spokes to report: withdrawal stays queued
        assertEq(freshHub.reservedAssets(), assets);
        assertEq(usdc.balanceOf(betty), 0);
    }

    function test_allSpokesFresh_staleAfterWarp() public {
        // set fresh then warp past MAX_STALENESS, becomes stale
        // CCIP synchronous. Path 2 still settles via report balance
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
    // Path 3 leg planning Tests (WI-4: replaces the old single-best-spoke _findBestSpoke)
    // =========================================================================

    /// @dev WI-4 replaces single-spoke selection with multi-leg planning across active
    /// spokes ordered by descending reported balance. This verifies that ordering directly
    /// via dispatched SentToSpoke events, using a scenario sized so the shortfall requires
    /// both legs. spoke2 is a mock (non-contract) address. Its leg dispatch never actually
    /// delivers or confirms (CCIP to a non-contract address silently no-ops rather than
    /// reverting), so this test only asserts dispatch ORDER, not full settlement.
    function test_pathThree_multiLeg_ordersByDescendingBalance() public {
        uint64 selector2 = 9999;
        address mockSpoke2 = makeAddr("spoke2");
        vm.prank(owner);
        hub.addSpoke(selector2, mockSpoke2);

        // real spoke funded with 3_000e6, genuinely backed
        _sendToSpoke(3_000e6);
        // mock spoke2 "reports" a higher balance via storage, narrow unit-test
        // construction for ordering purposes only, consistent with existing
        // _setSpokeBalance conventions elsewhere in this suite.
        _setSpokeBalance(selector2, 5_000e6);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _setLastReportTimestamp(selector2, block.timestamp);

        // drain hub idle so a moderate withdrawal needs a multi-leg recall:
        // shortfall (5_500e6) > either spoke's single haircut-capped capacity alone
        // (4_975e6 / 2_985e6) but <= their sum (7_960e6), fully coverable across both.
        deal(address(usdc), address(hub), 500e6);

        vm.recordLogs();
        vm.prank(alice);
        hub.withdraw(6_000e6, alice, alice);

        uint64[] memory dispatchOrder = _sentToSpokeSelectors();
        assertEq(dispatchOrder.length, 2, "expected two dispatched legs");
        assertEq(dispatchOrder[0], selector2, "higher-balance spoke recalled first");
        assertEq(dispatchOrder[1], chainSelector, "lower-balance spoke recalled second");
    }

    /// @dev WI-4 fail-closed behavior: when even planning across every active spoke cannot
    /// cover the shortfall (haircut-capped), the whole _withdraw call reverts,
    /// InsufficientRecallLiquidity: instead of the old silent oversized single-spoke recall
    /// that could permanently lock the user's shares. Shares stay with the user, nothing locks.
    function test_pathThree_revert_insufficientRecallLiquidity() public {
        uint64 selector2 = 9999;
        address mockSpoke2 = makeAddr("spoke2");
        vm.prank(owner);
        hub.addSpoke(selector2, mockSpoke2);

        _sendToSpoke(3_000e6);
        _setSpokeBalance(selector2, 5_000e6);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _setLastReportTimestamp(selector2, block.timestamp);

        // full redemption needs 100% of both spokes' reported balances combined,
        // structurally uncoverable under the RECALL_HAIRCUT_BPS margin.
        deal(address(usdc), address(hub), 100e6);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientRecallLiquidity.selector,
                assets - 100e6,
                7_960e6 // 4_975e6 (selector2) + 2_985e6 (chainSelector)
            )
        );
        hub.withdraw(assets, alice, alice);

        // fail-closed, nothing committed
        assertEq(hub.balanceOf(alice), shares, "shares untouched");
        assertEq(hub.reservedAssets(), 0, "nothing reserved");
    }

    function test_findBestSpoke_singleSpoke() public {
        // single spoke with real balance and headroom. Path 3 recalls from it and settles
        _addPath3Headroom();
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _sendToSpoke(5_000e6);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        // recalled from real spoke, CCIP synchronous: should settle
        assertEq(hub.balanceOf(alice), 0);
    }

    /// @dev Parses recorded logs for SentToSpoke(uint64 indexed chainSelector, ...) and
    /// returns the chain selectors in emission order.
    function _sentToSpokeSelectors() internal returns (uint64[] memory) {
        bytes32 sig = keccak256("SentToSpoke(uint64,bytes32,bytes32,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint64[] memory result = new uint64[](logs.length);
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            result[count++] = uint64(uint256(logs[i].topics[1]));
        }
        uint64[] memory trimmed = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            trimmed[i] = result[i];
        }
        return trimmed;
    }
}
