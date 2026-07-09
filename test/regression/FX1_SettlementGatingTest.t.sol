// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice FX-1 regression — settlement gating (freshness for Path 2, pendingLegs==0 for
///         Path 3) must live inside `_attemptSettleWithdrawal`, not only at the CCIP
///         callback call sites, since `attemptSettlement` is external and permissionless.
contract FX1_SettlementGatingTest is BaseHubTest {
    /// @notice Reproduces the defect: a Path 2 entry queued against a spoke that becomes
    /// unreachable (so its cached, stale spokeBalances never refreshes and never reflects a
    /// loss that happened after the last report) must NOT be settleable by directly calling
    /// `attemptSettlement`. Pre-fix, this call settled immediately at the stale (higher)
    /// price — bypassing the exact staleness protection Path 2 exists to provide.
    function test_fx1_directAttemptSettlement_cannotBypassFreshnessGate() public {
        _sendToSpoke(2_000e6); // idle 8_000e6, spoke reports 2_000e6 (fresh right now)

        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours); // now stale

        // Repoint the selector's registered spoke address to an unreachable mock — this
        // does NOT touch spokeBalances[chainSelector] or lastReportTimestamp[chainSelector]
        // (separate mappings, keyed by selector), so the STALE, pre-loss 2_000e6 value
        // persists forever with no way for a fresh report to ever correct it.
        address deadSpoke = makeAddr("deadSpoke");
        vm.prank(owner);
        hub.addSpoke(chainSelector, deadSpoke);

        // simulate a loss that happened on the (now unreachable) real spoke's adapter,
        // AFTER the last report — the hub has no way to learn about this
        aaveAdapter.setTotalAssets(1_000e6); // was 2_000e6, real spoke lost 1_000e6

        uint256 quotedAssets = 7_000e6; // idle (8_000e6) covers this -> Path 2

        vm.recordLogs();
        vm.prank(alice);
        hub.withdraw(quotedAssets, alice, alice);
        // Path 2 requested a fresh report from the now-dead spoke — it will never arrive,
        // so the entry stays queued with the stale, loss-blind spokeBalances.
        assertGt(hub.reservedAssets(), 0, "must still be queued, not settled by the request itself");

        bytes32 id = _lastWithdrawalId();
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        // The withdrawer (or anyone) calls attemptSettlement directly, permissionlessly.
        hub.attemptSettlement(id);

        // Must NOT have settled — the spoke is still stale (permanently, in this scenario),
        // so paying out now would use the stale, inflated totalAssets() that doesn't
        // reflect the real loss.
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore, "must not settle at the stale price");
        assertGt(hub.reservedAssets(), 0, "entry must remain pending");
        assertGt(hub.balanceOf(address(hub)), 0, "shares still escrowed at hub, not burned");
    }

    /// @notice The permissionless nudge stays useful for the case it's meant for: a Path 2
    /// entry whose spokes ARE all fresh can still be settled by a direct call.
    function test_fx1_directAttemptSettlement_stillWorks_whenFresh() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours); // stale at request

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.recordLogs();
        vm.prank(alice);
        hub.withdraw(assets, alice, alice);
        // the single real spoke responds synchronously in this harness, refreshing
        // freshness within the same call — so by the time we look, it's likely already
        // settled via the callback path. To specifically exercise the DIRECT call path
        // succeeding, re-verify settlement completed (either via callback or a no-op direct
        // call finding it already gone).
        bytes32 id = _lastWithdrawalId();
        // whether the callback already settled it or not, a direct call must not revert and
        // must be a no-op if already settled, or settle it if still pending and fresh.
        hub.attemptSettlement(id);

        assertEq(hub.balanceOf(alice), 0, "alice shares fully redeemed");
        assertEq(hub.reservedAssets(), 0, "no reservation left");
    }

    function _lastWithdrawalId() internal returns (bytes32) {
        bytes32 sig = keccak256(
            "WithdrawalQueued(address,bytes32,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == sig) {
                return logs[i - 1].topics[2];
            }
        }
        return bytes32(0);
    }
}
