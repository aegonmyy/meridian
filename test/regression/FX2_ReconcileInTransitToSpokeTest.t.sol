// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {SpokeHasInFlightLegs} from "../../src/errors/hubErrors.sol";

/// @notice FX-2 regression — reconcileTransit must decrement inTransitToSpoke for the
///         reconciled leg's origin selector, or the safe removeSpoke path is permanently
///         blocked for that selector even after full drain.
contract FX2_ReconcileInTransitToSpokeTest is BaseHubTest {
    /// @notice Reproduces the defect: reconcile a stuck deposit leg, drain the spoke to
    /// zero balance, then removeSpoke — pre-fix this reverts SpokeHasInFlightLegs forever
    /// because inTransitToSpoke[selector] was never decremented by reconcileTransit.
    function test_fx2_removeSpokeSucceeds_afterReconcileAndDrain() public {
        // Send a deposit, then simulate it getting stuck (never confirmed) by directly
        // incrementing inTransitToSpoke the same way _sendToSpoke does, alongside a fake
        // tracked leg — this mirrors "the confirm never arrives" without relying on a
        // mock spoke plumbing quirk, matching the WI5 test file's established pattern.
        _sendToSpoke(3_000e6); // real, resolves synchronously; spoke now has 3_000e6

        bytes32 stuckLegId = keccak256("stuck-deposit-leg");
        uint256 stuckAmount = 500e6;
        _setInTransitAmount(stuckLegId, stuckAmount);
        _setTransitLeg(stuckLegId, chainSelector, block.timestamp);
        _bumpInTransitAssets(stuckAmount);
        _bumpInTransitToSpoke(chainSelector, 1);

        // drain the spoke's real balance to zero so only the in-flight-legs guard remains
        bytes32 recallId = _generateMessageId(address(hub));
        _recallFromSpoke(3_000e6, recallId);
        assertEq(hub.spokeBalances(chainSelector), 0, "spoke fully drained");

        // still blocked — one in-flight leg remains
        vm.prank(owner);
        vm.expectRevert(SpokeHasInFlightLegs.selector);
        hub.removeSpoke(chainSelector);

        // reconcile the stuck leg (dead lane, provably never arriving)
        vm.warp(block.timestamp + hub.TRANSIT_RECONCILE_DELAY() + 1);
        vm.prank(owner);
        hub.reconcileTransit(stuckLegId);

        assertEq(hub.inTransitToSpoke(chainSelector), 0, "in-flight leg counter released");

        // now the safe removal path must succeed
        vm.prank(owner);
        hub.removeSpoke(chainSelector);

        (, bool exists, ) = hub.spokes(chainSelector);
        assertFalse(exists, "spoke removed via the safe path");
    }

    // Slot constants verified via `forge inspect src/Hub.sol:HUB storage-layout` — re-run
    // and update whenever Hub.sol's state variable declarations change.
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

    function _bumpInTransitToSpoke(uint64 selector, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(18)));
        uint256 current = hub.inTransitToSpoke(selector);
        vm.store(address(hub), slot, bytes32(current + amount));
    }
}
