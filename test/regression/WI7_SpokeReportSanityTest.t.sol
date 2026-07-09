// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {HUB} from "../../src/Hub.sol";
import {NoQuarantinedReport} from "../../src/errors/hubErrors.sol";

/// @notice WI-7 regressions — spoke-report sanity band + circuit breaker.
contract WI7_SpokeReportSanityTest is BaseHubTest {
    /// @notice Pre-fix: spokeBalances is written verbatim from any spoke message — a
    /// 100x-inflated report directly inflates totalAssets and share price with no check.
    /// Post-fix: the report is quarantined (spokeBalances untouched), the vault pauses, and
    /// the exploit path (redeem at the inflated price) is unavailable while paused.
    function test_wi7_massivelyInflatedReport_isQuarantinedNotApplied() public {
        _sendToSpoke(1_000e6); // netSentToSpoke[chainSelector] = 1_000e6

        vm.warp(1 days);
        // simulate a compromised/buggy spoke reporting 100x its real balance via a
        // REPORT_BALANCE round trip — trigger the request, then let the mock adapter lie.
        aaveAdapter.setTotalAssets(100_000e6); // 100x the real 1_000e6
        _triggerReportBalance();

        // the report must NOT have been applied — spokeBalances still reflects the last
        // legitimate value, not the inflated one
        assertEq(hub.spokeBalances(chainSelector), 1_000e6, "inflated report not applied");
        assertEq(hub.quarantinedReports(chainSelector), 100_000e6, "report quarantined verbatim");
        assertTrue(hub.paused(), "vault paused on suspicious report");

        // the exploit — redeeming at the inflated price — is unavailable while paused
        vm.prank(alice);
        vm.expectRevert();
        hub.redeem(1, alice, alice);
    }

    /// @notice An honest, large-yield report within the band flows through normally.
    function test_wi7_honestLargeYieldReport_appliesNormally() public {
        _sendToSpoke(1_000e6);

        vm.warp(1 days);
        // 15% yield — within MAX_YIELD_BPS (2000 = 20%) + REPORT_DUST
        aaveAdapter.setTotalAssets(1_150e6);
        _triggerReportBalance();

        assertEq(hub.spokeBalances(chainSelector), 1_150e6, "honest yield report applied");
        assertEq(hub.quarantinedReports(chainSelector), 0, "nothing quarantined");
        assertFalse(hub.paused(), "vault not paused for an honest report");
    }

    /// @notice A report right at the band edge (netSent * 1.2 + dust) still passes.
    function test_wi7_reportAtBandEdge_passes() public {
        _sendToSpoke(1_000e6);
        vm.warp(1 days);

        uint256 ceiling = (1_000e6 * (10_000 + hub.MAX_YIELD_BPS())) /
            10_000 +
            hub.REPORT_DUST();
        aaveAdapter.setTotalAssets(ceiling);
        _triggerReportBalance();

        assertEq(hub.spokeBalances(chainSelector), ceiling);
        assertFalse(hub.paused());
    }

    /// @notice A report one wei above the band ceiling is quarantined.
    function test_wi7_reportOneWeiOverBand_isQuarantined() public {
        _sendToSpoke(1_000e6);
        vm.warp(1 days);

        uint256 ceiling = (1_000e6 * (10_000 + hub.MAX_YIELD_BPS())) /
            10_000 +
            hub.REPORT_DUST();
        aaveAdapter.setTotalAssets(ceiling + 1);
        _triggerReportBalance();

        assertEq(
            hub.spokeBalances(chainSelector),
            1_000e6,
            "not applied, stays at the prior confirmed value"
        );
        assertEq(hub.quarantinedReports(chainSelector), ceiling + 1);
        assertTrue(hub.paused());
    }

    /// @notice Owner can accept a quarantined report — applies it and unpauses.
    function test_wi7_acceptQuarantinedReport_appliesAndUnpauses() public {
        _sendToSpoke(1_000e6);
        vm.warp(1 days);
        aaveAdapter.setTotalAssets(100_000e6);
        _triggerReportBalance();
        assertTrue(hub.paused());

        vm.prank(owner);
        hub.acceptQuarantinedReport(chainSelector);

        assertEq(hub.spokeBalances(chainSelector), 100_000e6);
        assertEq(hub.quarantinedReports(chainSelector), 0);
        assertFalse(hub.paused());
    }

    /// @notice Owner can reject a quarantined report — discards it and unpauses, prior
    /// spokeBalances value is preserved.
    function test_wi7_rejectQuarantinedReport_discardsAndUnpauses() public {
        _sendToSpoke(1_000e6);
        vm.warp(1 days);
        aaveAdapter.setTotalAssets(100_000e6);
        _triggerReportBalance();

        vm.prank(owner);
        hub.rejectQuarantinedReport(chainSelector);

        assertEq(hub.spokeBalances(chainSelector), 1_000e6, "prior value preserved");
        assertEq(hub.quarantinedReports(chainSelector), 0);
        assertFalse(hub.paused());
    }

    function test_wi7_acceptQuarantinedReport_revert_noneQuarantined() public {
        vm.prank(owner);
        vm.expectRevert(NoQuarantinedReport.selector);
        hub.acceptQuarantinedReport(chainSelector);
    }

    /// @notice The quarantine branch must not revert a token-carrying CONFIRM_WITHDRAWAL's
    /// CCIP execution — the recalled tokens are always delivered (truthfully credited to
    /// hub idle) regardless of whether the accompanying reported balance passes the band.
    /// @dev Settlement of the withdrawal itself is a SEPARATE, solvency-gated decision
    /// (WI-4): here the quarantined (rejected, stale) spokeBalances value still overstates
    /// totalAssets by the amount just recalled (the old, pre-recall report is never applied
    /// down since the new one was rejected), which makes previewRedeem(shares) exceed the
    /// currently-available idle — so settlement correctly DEFERS rather than overpaying
    /// alice from other depositors' idle. This is the WI-4/WI-7 interaction the plan calls
    /// out to "think through and test": quarantine never blocks token delivery, but it can
    /// legitimately leave a settlement deferred until the owner resolves the report and a
    /// later attempt sees an accurate totalAssets().
    function test_wi7_quarantine_doesNotBlockTokenDelivery_butMaySeferSettlement() public {
        _addPath3Headroom();
        _sendToSpoke(9_000e6); // idle 1_500e6, spoke 9_000e6, netSentToSpoke = 9_000e6

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 idleBefore = usdc.balanceOf(address(hub));

        // simulate the spoke reporting a wildly inflated balance in the SAME confirm that
        // carries the real recalled tokens back.
        aaveAdapter.setTotalAssets(9_000e6 * 100);

        vm.recordLogs();
        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice); // Path 3 — must not revert

        // the recalled tokens were truthfully delivered to hub idle regardless of the
        // quarantined report
        assertGt(usdc.balanceOf(address(hub)), idleBefore, "recalled tokens landed in hub idle");
        assertTrue(hub.paused(), "vault paused due to the inflated report");
        assertGt(hub.quarantinedReports(chainSelector), 0, "report quarantined, not applied");

        // settlement correctly deferred (not reverted, not incorrectly paid) because the
        // stale, unapplied spokeBalances still overstates totalAssets beyond current idle
        assertEq(hub.balanceOf(address(hub)), aliceShares, "shares still escrowed, not yet settled");
        assertEq(usdc.balanceOf(alice), 0, "alice not paid while settlement is deferred");
    }
}
