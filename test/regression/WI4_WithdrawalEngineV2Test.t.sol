// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {HUB} from "../../src/Hub.sol";
import {HubStorage} from "../../src/hub/HubStorage.sol";
import {NoPendingWithdrawal, NotWithdrawalOwner, WithdrawalNotYetCancellable} from "../../src/errors/hubErrors.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice WI-4 regressions — withdrawal engine v2: multi-spoke recall, claim-time pricing,
///         cancel. Companion to WithdrawPath1Test's InsufficientRecallLiquidity tests (Path 3
///         fail-closed) which live alongside the ordering tests they depend on.
contract WI4_WithdrawalEngineV2Test is BaseHubTest {
    bytes32 constant REPORT_BALANCE_SIG =
        keccak256("SpokeBalanceUpdated(uint64,uint256)");

    /// @notice Old bug: Path 2 settled on the FIRST spoke's report even with other spokes
    /// still stale. Fixed: settlement only attempted once _allSpokesFresh() is true.
    /// Demonstrated here with a second, non-responding (mock) spoke that never reports —
    /// the withdrawal must stay pending forever rather than settling off the one real
    /// spoke's report.
    function test_wi4_pathTwo_doesNotSettleUntilAllSpokesFresh() public {
        uint64 selector2 = 9999;
        address mockSpoke2 = makeAddr("nonRespondingSpoke");
        vm.prank(owner);
        hub.addSpoke(selector2, mockSpoke2);

        vm.warp(1 days);
        // real spoke fresh, mock spoke2 stale (never reports, never will)
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _setLastReportTimestamp(selector2, block.timestamp - 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice); // idle covers, but not all spokes fresh -> Path 2

        // mock spoke2 never replies to the REPORT_BALANCE request -> _allSpokesFresh()
        // never becomes true -> the withdrawal must remain queued indefinitely, not
        // settled off the real spoke's report alone.
        assertGt(hub.reservedAssets(), 0, "withdrawal must still be pending");
        assertEq(usdc.balanceOf(alice), 0, "alice must not have been paid yet");
    }

    /// @notice Old bug: Path 2 payout used the quote taken at request time, ignoring any
    /// loss reported during the refresh. Fixed: claim-time pricing — previewRedeem is
    /// recomputed at settlement, so a loss discovered during the REPORT_BALANCE refresh
    /// reduces the actual payout below the original quote.
    function test_wi4_claimTimePricing_lossReducesPayout() public {
        _sendToSpoke(2_000e6); // hub idle 8_000e6, spoke 2_000e6 (reported)

        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours); // stale -> Path 2

        uint256 quotedAssets = 7_000e6; // idle (8_000e6) covers this -> Path 2, not Path 3

        // simulate a loss discovered on the adapter — real balance is now lower than the
        // hub's cached spokeBalances (2_000e6). The request-time quote is computed off the
        // still-stale cached value; the loss is only revealed once the REPORT_BALANCE
        // refresh (triggered by this very Path 2 request) reads the adapter live.
        aaveAdapter.setTotalAssets(1_000e6); // was 2_000e6 -> lost 1_000e6

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(quotedAssets, alice, alice);

        // claim-time pricing: alice receives less than her quote because the loss is now
        // reflected in totalAssets by the time settlement runs (same synchronous call, but
        // AFTER the refreshed report — the ordering that matters for the fix).
        uint256 received = usdc.balanceOf(alice) - aliceBalanceBefore;
        assertLt(received, quotedAssets, "loss must reduce actual payout below quote");
        // shares burned = 7_000e6 (1:1 price pre-loss); post-loss totalAssets = 9_000e6
        // over 10_000e6 total supply -> payout = 7_000e6 * 9_000e6 / 10_000e6 = 6_300e6
        assertEq(received, 6_300e6, "payout must reflect the 1_000e6 loss exactly");
    }

    /// @notice cancelWithdrawal reverts before WITHDRAWAL_TIMEOUT, reverts for non-owners,
    /// and succeeds after timeout — returning shares and releasing the reservation.
    function test_wi4_cancelWithdrawal_returnsSharesAfterTimeout() public {
        uint64 selector2 = 9999;
        address mockSpoke2 = makeAddr("nonRespondingSpoke2");
        vm.prank(owner);
        hub.addSpoke(selector2, mockSpoke2);

        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _setLastReportTimestamp(selector2, block.timestamp - 2 hours); // permanently stale

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.recordLogs();
        vm.prank(alice);
        hub.withdraw(assets, alice, alice);
        bytes32 id = _lastWithdrawalId();

        // too early
        vm.prank(alice);
        vm.expectRevert(WithdrawalNotYetCancellable.selector);
        hub.cancelWithdrawal(id);

        // not the owner
        vm.warp(block.timestamp + 25 hours);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(NotWithdrawalOwner.selector);
        hub.cancelWithdrawal(id);

        uint256 reservedBefore = hub.reservedAssets();
        vm.prank(alice);
        hub.cancelWithdrawal(id);

        assertEq(hub.balanceOf(alice), shares, "shares returned to alice");
        assertEq(
            hub.reservedAssets(),
            reservedBefore - assets,
            "reservation released"
        );

        // cancelling again reverts — entry is gone
        vm.prank(alice);
        vm.expectRevert(NoPendingWithdrawal.selector);
        hub.cancelWithdrawal(id);
    }

    /// @notice A settlement attempt that finds insufficient claimable idle right now defers
    /// rather than reverting — the entry stays pending and can be retried later.
    function test_wi4_settlementDeferred_whenInsolventRightNow() public {
        // no spokes registered on a fresh hub — every withdrawal is Path 2 and permanently
        // pending (nothing ever reports back to trigger _allSpokesFresh()==true)
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

        address bob = makeAddr("bob");
        usdc.mint(alice, 8_000e6);
        usdc.mint(bob, 8_000e6);
        vm.startPrank(alice);
        usdc.approve(address(freshHub), 8_000e6);
        freshHub.deposit(8_000e6, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(freshHub), 8_000e6);
        freshHub.deposit(8_000e6, bob);
        vm.stopPrank();

        // both request 7_000e6 — reservedAssets sums to 14_000e6, well within the current
        // 16_000e6 idle, so both are accepted at request time
        vm.recordLogs();
        vm.prank(alice);
        freshHub.withdraw(7_000e6, alice, alice);
        bytes32 aliceId = _lastWithdrawalIdFor(freshHub);

        vm.prank(bob);
        freshHub.withdraw(7_000e6, bob, bob);
        bytes32 bobId = _lastWithdrawalIdFor(freshHub);

        // simulate idle dropping well below what's reserved (e.g. an unrelated adapter
        // loss elsewhere is not possible here with no spokes — this directly forces the
        // "insufficient claimable idle right now" condition the deferred path guards)
        deal(address(usdc), address(freshHub), 10_000e6);

        vm.expectEmit(true, false, false, false);
        emit HubStorage.SettlementDeferred(aliceId, 0, 0);
        freshHub.attemptSettlement(aliceId);

        // entry must still be pending — non-reverting, no funds moved
        assertEq(freshHub.balanceOf(address(freshHub)) > 0, true);
        assertGt(freshHub.reservedAssets(), 0, "reservation must remain");
        assertEq(usdc.balanceOf(alice), 0, "alice not paid while deferred");

        bobId; // silence unused warning if bob's id isn't asserted further
    }

    function _lastWithdrawalId() internal returns (bytes32) {
        return _lastWithdrawalIdFor(hub);
    }

    /// @dev WithdrawalQueued's second indexed topic is the withdrawal id — the only
    /// off-chain source of it (the hub exposes no enumeration of pending withdrawals).
    function _lastWithdrawalIdFor(HUB _hub) internal returns (bytes32) {
        bytes32 sig = keccak256(
            "WithdrawalQueued(address,bytes32,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].emitter != address(_hub)) continue;
            if (logs[i - 1].topics[0] != sig) continue;
            return logs[i - 1].topics[2];
        }
        return bytes32(0);
    }
}
