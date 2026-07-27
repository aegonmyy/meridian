// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";

/// @notice FX-5 regression, forceRemoveSpoke must zero the dangling spokeBalances (and
///         inTransitToSpoke) it leaves behind, or a later re-add via addSpoke instantly
///         resurrects the stale balance into totalAssets().
contract FX5_ForceRemoveReAddTest is BaseHubTest {
    /// @notice Reproduces the defect: fund a spoke, forceRemove it (funded balance excluded
    /// from totalAssets, as documented/intended), then re-add the SAME selector via
    /// addSpoke, pre-fix, totalAssets() instantly jumps back up by the stale balance the
    /// moment the selector becomes active again, even though the underlying capital may
    /// have been compromised or drained in the interim.
    function test_fx5_reAddAfterForceRemove_doesNotResurrectStaleBalance() public {
        _sendToSpoke(3_000e6);
        assertEq(hub.spokeBalances(chainSelector), 3_000e6);

        uint256 totalBefore = hub.totalAssets();

        vm.prank(owner);
        hub.forceRemoveSpoke(chainSelector);

        // documented, intended instant mispricing window while removed
        assertEq(hub.totalAssets(), totalBefore - 3_000e6, "balance excluded while removed");

        // re-register the same selector (e.g. after confirming the spoke is safe again, or
        // pointing it at a freshly redeployed contract)
        address newSpokeAddress = makeAddr("redeployedSpoke");
        vm.prank(owner);
        hub.addSpoke(chainSelector, newSpokeAddress);

        // the stale 3_000e6 must not resurrect: the new spoke has reported nothing yet
        assertEq(
            hub.spokeBalances(chainSelector),
            0,
            "stale balance must not resurrect on re-add"
        );
        assertEq(
            hub.totalAssets(),
            totalBefore - 3_000e6,
            "totalAssets must not jump back up on re-add alone"
        );
    }

    /// @notice inTransitToSpoke is also zeroed: those legs' confirms can never land once
    /// the spoke is force-removed (NotSpoke), so the counter would otherwise dangle forever
    /// and permanently block the safe removeSpoke path on any future re-add + re-remove.
    function test_fx5_forceRemoveSpoke_zerosInTransitToSpoke() public {
        // simulate an in-flight leg the same way FX-2's test does
        _sendToSpoke(1_000e6);
        bytes32 stuckLegId = keccak256("stuck-leg-fx5");
        _bumpInTransitToSpoke(chainSelector, 1);
        assertGt(hub.inTransitToSpoke(chainSelector), 0);
        stuckLegId; // unused beyond documenting intent

        vm.prank(owner);
        hub.forceRemoveSpoke(chainSelector);

        assertEq(hub.inTransitToSpoke(chainSelector), 0, "in-flight leg counter zeroed");
    }

    /// @notice After force-remove + re-add, the safe removeSpoke path works once the
    /// re-added spoke is itself drained (proves the counters stay clean, rather than being
    /// zeroed once and then silently broken for future guard checks).
    function test_fx5_removeSpoke_worksOnReAddedSpoke_onceDrained() public {
        _sendToSpoke(2_000e6);

        vm.prank(owner);
        hub.forceRemoveSpoke(chainSelector);

        vm.prank(owner);
        hub.addSpoke(chainSelector, address(spoke)); // re-point back to the same real spoke

        // spoke's real adapter still holds 2_000e6, but hub's spokeBalances was zeroed,
        // report balance to resync hub's view with reality before it can be safely removed
        vm.warp(block.timestamp + 1 hours);
        _triggerReportBalance();
        assertEq(hub.spokeBalances(chainSelector), 2_000e6, "resynced via report");

        // drain for real, then the safe path must work
        bytes32 recallId = _generateMessageId(address(hub));
        _recallFromSpoke(2_000e6, recallId);
        assertEq(hub.spokeBalances(chainSelector), 0);

        vm.prank(owner);
        hub.removeSpoke(chainSelector);

        (, bool exists, ) = hub.spokes(chainSelector);
        assertFalse(exists);
    }

    // inTransitToSpoke = slot 18 (verified via `forge inspect src/Hub.sol:HUB storage-layout`)
    function _bumpInTransitToSpoke(uint64 selector, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(18)));
        uint256 current = hub.inTransitToSpoke(selector);
        vm.store(address(hub), slot, bytes32(current + amount));
    }
}
