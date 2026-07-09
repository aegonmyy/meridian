// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {SpokeNotDrained, SpokeHasInFlightLegs, SpokeNotFound} from "../../src/errors/hubErrors.sol";
import {HUB} from "../../src/Hub.sol";
import {PendingConfirmsOutstanding, ZeroAddress} from "../../src/errors/spokeErrors.sol";

/// @notice WI-6 regressions — removeSpoke/forceRemoveSpoke guards and setHub guard.
contract WI6_OperationalHardeningTest is BaseHubTest {
    /// @notice Pre-fix: removeSpoke on a funded spoke instantly craters totalManagedAssets()
    /// by that spoke's reported balance. Post-fix: reverts with SpokeNotDrained.
    function test_wi6_removeSpoke_revert_funded() public {
        _sendToSpoke(3_000e6);

        vm.prank(owner);
        vm.expectRevert(SpokeNotDrained.selector);
        hub.removeSpoke(chainSelector);

        // totalAssets must be unaffected — the guard blocked the removal before any state changed
        assertEq(hub.totalAssets(), 10_000e6);
    }

    /// @notice removeSpoke succeeds once the spoke is fully drained (balance == 0).
    function test_wi6_removeSpoke_succeeds_whenDrained() public {
        _sendToSpoke(3_000e6);
        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(3_000e6, messageId);

        assertEq(hub.spokeBalances(chainSelector), 0);

        vm.prank(owner);
        hub.removeSpoke(chainSelector);

        (, bool exists, ) = hub.spokes(chainSelector);
        assertFalse(exists);
    }

    /// @notice forceRemoveSpoke bypasses the guard entirely — the emergency escape hatch.
    function test_wi6_forceRemoveSpoke_bypassesGuard() public {
        _sendToSpoke(3_000e6);

        uint256 totalBefore = hub.totalAssets();

        vm.prank(owner);
        hub.forceRemoveSpoke(chainSelector);

        (, bool exists, ) = hub.spokes(chainSelector);
        assertFalse(exists);
        // the funded balance is now excluded from totalManagedAssets() — the documented
        // instant mispricing this function accepts as the cost of the emergency path
        assertLt(hub.totalAssets(), totalBefore);
    }

    function test_wi6_forceRemoveSpoke_revert_notFound() public {
        vm.prank(owner);
        vm.expectRevert(SpokeNotFound.selector);
        hub.forceRemoveSpoke(9999);
    }

    /// @notice setHub reverts while the spoke has an unresolved queued confirm (WI-2d).
    /// @dev The local CCIPLocalSimulator's MockCCIPRouter ignores LINK fees entirely
    ///      (getFee always returns the mock's configurable, default-zero fee — see
    ///      lib/chainlink-local's MockRouter.sol), so LINK exhaustion cannot be forced
    ///      through this harness to genuinely exercise _queueConfirm's failure path end to
    ///      end. Instead, a PendingConfirm entry is injected directly via storage — a
    ///      narrow, deterministic way to test setHub's guard LOGIC (which only reads
    ///      pendingConfirms[i].resolved) independent of how that entry came to exist.
    function test_wi6_setHub_revert_pendingConfirmsOutstanding() public {
        _injectPendingConfirm(keccak256("stuck-confirm"));
        assertEq(spoke.pendingConfirmsLength(), 1);

        address newHub = makeAddr("newHub");
        vm.prank(owner);
        vm.expectRevert(PendingConfirmsOutstanding.selector);
        spoke.setHub(newHub);
    }

    /// @notice setHub still enforces the basic zero-address check.
    function test_wi6_setHub_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        spoke.setHub(address(0));
    }

    /// @notice setHub succeeds once the pendingConfirms queue is empty (the common case).
    function test_wi6_setHub_succeeds_whenQueueEmpty() public {
        address newHub = makeAddr("newHub");
        vm.prank(owner);
        spoke.setHub(newHub);
        assertEq(spoke.HUB(), newHub);
    }

    /// @notice setHub succeeds once a previously-queued confirm is marked resolved (as
    /// retryConfirm does on success) — proves the guard checks live state, not just "was
    /// ever queued".
    function test_wi6_setHub_succeeds_onceResolved() public {
        bytes32 id = keccak256("stuck-confirm-2");
        _injectPendingConfirm(id);
        assertEq(spoke.pendingConfirmsLength(), 1);

        _markPendingConfirmResolved(0);

        address newHub = makeAddr("newHub");
        vm.prank(owner);
        spoke.setHub(newHub);
        assertEq(spoke.HUB(), newHub);
    }

    // ── storage helpers ──────────────────────────────────────────────────────
    // pendingConfirms is a dynamic array at slot 4 (verified via
    // `forge inspect src/Spoke.sol:SpokeVault storage-layout`). Each PendingConfirm element
    // occupies 4 slots: messageType, messageId, actualAmount, resolved.
    function _injectPendingConfirm(bytes32 messageId) internal {
        vm.store(address(spoke), bytes32(uint256(4)), bytes32(uint256(1))); // length = 1
        uint256 base = uint256(keccak256(abi.encode(uint256(4))));
        vm.store(address(spoke), bytes32(base), bytes32(uint256(4))); // CONFIRM_RECEIPT
        vm.store(address(spoke), bytes32(base + 1), messageId);
        vm.store(address(spoke), bytes32(base + 2), bytes32(uint256(0))); // actualAmount
        vm.store(address(spoke), bytes32(base + 3), bytes32(uint256(0))); // resolved = false
    }

    function _markPendingConfirmResolved(uint256 index) internal {
        uint256 base = uint256(keccak256(abi.encode(uint256(4)))) + (index * 4);
        vm.store(address(spoke), bytes32(base + 3), bytes32(uint256(1))); // resolved = true
    }
}
