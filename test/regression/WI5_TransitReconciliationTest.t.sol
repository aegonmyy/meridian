// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {ReconcileTooEarly} from "../../src/errors/hubErrors.sol";

/// @notice WI-5 regressions: removal of the unbounded adjustInTransitAssets owner setter,
///         replaced with evidence-bounded, per-message reconciliation.
contract WI5_TransitReconciliationTest is BaseHubTest {
    /// @notice Pre-fix: owner could call adjustInTransitAssets(arbitraryValue) and move
    /// share price with zero evidence, zero bound, zero delay. That function no longer
    /// exists at all post-fix: this documents the capability that was removed (compile-time
    /// proof: `hub.adjustInTransitAssets` is not a member of HUB anymore; see also the
    /// absence of the selector below).
    function test_wi5_adjustInTransitAssets_noLongerExists() public {
        // adjustInTransitAssets(uint256) selector, computed offline, asserted absent.
        bytes4 removedSelector = bytes4(keccak256("adjustInTransitAssets(uint256)"));
        (bool success, ) = address(hub).call(
            abi.encodeWithSelector(removedSelector, uint256(123))
        );
        assertFalse(success, "adjustInTransitAssets must no longer be callable");
    }

    /// @notice reconcileTransit reverts before TRANSIT_RECONCILE_DELAY has elapsed, even
    /// for a genuinely stuck in-transit leg.
    function test_wi5_reconcileTransit_revert_tooEarly() public {
        _sendToSpoke(5_000e6); // synchronous simulator settles this immediately though,
        // inTransitAssets is already back to 0 here (CONFIRM_RECEIPT landed same-block).
        // To exercise reconcileTransit we need a genuinely stuck leg, simulate one by
        // manipulating inTransitAmount/transitLegs directly via storage, representing a
        // DEPOSIT whose CONFIRM_RECEIPT will provably never arrive (dead lane).
        bytes32 fakeMessageId = keccak256("stuck-leg");
        _setInTransitAmount(fakeMessageId, 1_000e6);
        _setTransitLeg(fakeMessageId, chainSelector, block.timestamp);
        _bumpInTransitAssets(1_000e6);

        vm.prank(owner);
        vm.expectRevert(ReconcileTooEarly.selector);
        hub.reconcileTransit(fakeMessageId);
    }

    /// @notice reconcileTransit releases only the exact tracked amount for a specific,
    /// aged, tracked leg: never an arbitrary value.
    function test_wi5_reconcileTransit_releasesExactAgedLeg() public {
        bytes32 fakeMessageId = keccak256("stuck-leg-2");
        uint256 stuckAmount = 2_500e6;
        _setInTransitAmount(fakeMessageId, stuckAmount);
        _setTransitLeg(fakeMessageId, chainSelector, block.timestamp);
        _bumpInTransitAssets(stuckAmount);

        uint256 before = hub.inTransitAssets();

        vm.warp(block.timestamp + hub.TRANSIT_RECONCILE_DELAY() + 1);

        vm.prank(owner);
        hub.reconcileTransit(fakeMessageId);

        assertEq(hub.inTransitAssets(), before - stuckAmount);
        assertEq(hub.inTransitAmount(fakeMessageId), 0);
    }

    /// @notice A late CONFIRM_RECEIPT arriving after reconciliation is harmless AND
    /// self-healing: delivery does not revert, inTransitAssets is unaffected by it (the
    /// id's tracked amount was already released and the mapping deleted, so the callback's
    /// `inTransitAssets -= inTransitAmount[id]` subtracts zero), and: the real property
    /// under test, spokeBalances[selector] IS updated from the late message. A premature
    /// reconcile therefore converges to the truth once the confirm eventually lands, rather
    /// than leaving the hub's view of the spoke permanently wrong.
    /// @dev FX-4a: rewrite of the previous, tautological version of this test (it never
    /// delivered a confirm: it asserted a storage-cheat value equalled itself). Delivers a
    /// genuine CONFIRM_RECEIPT via a direct pranked-router `hub.ccipReceive` call (the
    /// shared BaseHubTest helper, same pattern as WI6_OutOfOrderDeliveryTest), since the
    /// synchronous CCIPLocalSimulator can't otherwise produce a "confirm arrives after
    /// reconcile" ordering through the normal send path.
    function test_wi5_lateConfirmAfterReconcile_isHarmlessAndSelfHealing() public {
        bytes32 fakeMessageId = keccak256("stuck-leg-3");
        uint256 stuckAmount = 1_000e6;
        _setInTransitAmount(fakeMessageId, stuckAmount);
        _setTransitLeg(fakeMessageId, chainSelector, block.timestamp);
        _bumpInTransitAssets(stuckAmount);
        // establish a netSentToSpoke baseline so the late confirm's reported balance
        // doesn't independently trip WI-7's sanity band: orthogonal to what this test
        // is about.
        _bumpNetSentToSpoke(chainSelector, stuckAmount);

        uint256 inTransitBefore = hub.inTransitAssets();

        vm.warp(block.timestamp + hub.TRANSIT_RECONCILE_DELAY() + 1);
        vm.prank(owner);
        hub.reconcileTransit(fakeMessageId);

        assertEq(hub.inTransitAmount(fakeMessageId), 0, "mapping entry deleted");
        assertEq(
            hub.inTransitAssets(),
            inTransitBefore - stuckAmount,
            "reconcile released the tracked amount"
        );

        // The late confirm finally arrives: must not revert.
        uint256 lateReportedBalance = 1_000e6;
        _deliverConfirmReceipt(fakeMessageId, lateReportedBalance);

        // Harmless: inTransitAssets is untouched by this specific id a second time
        // (inTransitAmount[id] was already 0, no double-decrement, no underflow).
        assertEq(
            hub.inTransitAssets(),
            inTransitBefore - stuckAmount,
            "late confirm must not double-decrement inTransitAssets"
        );
        // Self-healing: the hub's view of the spoke converges to the truth once the late
        // confirm lands, instead of staying permanently wrong after the reconcile.
        assertEq(
            hub.spokeBalances(chainSelector),
            lateReportedBalance,
            "spokeBalances updated from the late-arriving confirm"
        );
    }

    // ── storage helpers ──────────────────────────────────────────────────────
    // AUTHORITATIVE SOURCE: re-run `forge inspect src/Hub.sol:HUB storage-layout` whenever
    // Hub.sol's state variable declarations change, every slot constant below (and in any
    // other test file using vm.store against HUB) must be re-verified against that output.
    // Current: inTransitAssets = 15, inTransitAmount = 16, transitLegs = 17
    // (transitLegs is struct{uint64 selector; uint64 sentAt} packed into one slot,
    // selector at byte offset 0, sentAt at byte offset 8; see FX-2).
    function _setInTransitAmount(bytes32 id, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(id, uint256(16)));
        vm.store(address(hub), slot, bytes32(amount));
    }

    function _setTransitLeg(
        bytes32 id,
        uint64 selector,
        uint256 sentAt
    ) internal {
        bytes32 slot = keccak256(abi.encode(id, uint256(17)));
        bytes32 packed = bytes32(
            uint256(selector) | (uint256(uint64(sentAt)) << 64)
        );
        vm.store(address(hub), slot, packed);
    }

    function _bumpInTransitAssets(uint256 amount) internal {
        uint256 current = hub.inTransitAssets();
        vm.store(address(hub), bytes32(uint256(15)), bytes32(current + amount));
    }

    // netSentToSpoke = slot 19 (verified via `forge inspect src/Hub.sol:HUB storage-layout`)
    function _bumpNetSentToSpoke(uint64 selector, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(19)));
        uint256 current = hub.netSentToSpoke(selector);
        vm.store(address(hub), slot, bytes32(current + amount));
    }
}
