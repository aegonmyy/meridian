// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";

/// @notice FX-3 regression, acceptQuarantinedReport must rebase netSentToSpoke, or the
///         sanity band's flat, time-blind ceiling causes a permanent pause/accept flap once
///         a spoke's genuine cumulative yield exceeds it.
contract FX3_QuarantineRebaselineTest is BaseHubTest {
    /// @notice Reproduces the defect: report just over the ceiling -> quarantine -> owner
    /// accepts -> spoke reports a slightly higher (still honest) value -> pre-fix this
    /// quarantines and pauses again immediately, because accepting never moved the
    /// baseline the band is measured against.
    function test_fx3_acceptedReport_becomesNewBaseline_nextHonestReportApplies() public {
        _sendToSpoke(1_000e6); // netSentToSpoke[chainSelector] = 1_000e6
        vm.warp(1 days);

        uint256 ceiling = (1_000e6 * (10_000 + hub.MAX_YIELD_BPS())) /
            10_000 +
            hub.REPORT_DUST();

        // first report: just over the ceiling relative to the original 1_000e6 baseline,
        // legitimate two-years-of-yield scenario, not an attack.
        aaveAdapter.setTotalAssets(ceiling + 1);
        _triggerReportBalance();
        assertTrue(hub.paused(), "quarantined and paused");

        vm.prank(owner);
        hub.acceptQuarantinedReport(chainSelector);
        assertFalse(hub.paused(), "unpaused after accept");
        assertEq(hub.spokeBalances(chainSelector), ceiling + 1);

        // netSentToSpoke must now be rebased to the accepted value. The owner just
        // attested this balance is legitimate, so it becomes the new verified baseline.
        assertEq(
            hub.netSentToSpoke(chainSelector),
            ceiling + 1,
            "accept must rebase netSentToSpoke to the accepted amount"
        );

        // a SLIGHTLY higher, still-honest follow-up report must apply cleanly against the
        // new baseline instead of quarantining again.
        uint256 nextReport = ceiling + 1 + 10e6; // a modest, honest increment
        aaveAdapter.setTotalAssets(nextReport);
        vm.warp(block.timestamp + 1 hours);
        _triggerReportBalance();

        assertEq(hub.spokeBalances(chainSelector), nextReport, "honest follow-up report applied");
        assertFalse(hub.paused(), "must not re-quarantine/pause on an honest follow-up");
        assertEq(hub.quarantinedReports(chainSelector), 0);
    }

    /// @notice rejectQuarantinedReport must not rebase netSentToSpoke: the report was
    /// discarded as bogus, so the baseline correctly stays where it was.
    function test_fx3_rejectedReport_doesNotRebaseNetSentToSpoke() public {
        _sendToSpoke(1_000e6);
        vm.warp(1 days);

        aaveAdapter.setTotalAssets(1_000_000e6); // wildly bogus
        _triggerReportBalance();
        assertTrue(hub.paused());

        vm.prank(owner);
        hub.rejectQuarantinedReport(chainSelector);

        assertEq(
            hub.netSentToSpoke(chainSelector),
            1_000e6,
            "reject must leave the baseline untouched"
        );
        assertFalse(hub.paused());
    }
}
