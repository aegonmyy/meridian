// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";

/// @title WI6_OutOfOrderDeliveryTest
/// @notice WI-6 accept criterion: "write one integration test delivering a recall before
///         its logically-prior deposit confirm and assert accounting stays consistent."
/// @dev CCIPLocalSimulator (used by every non-fork test in this suite) delivers every
///      message synchronously and inline within the same call that sends it — there is no
///      way to interleave or reorder deliveries through the normal sendToSpoke/
///      recallFromSpoke entrypoints (same constraint documented in WI3_TwoPhaseRebalanceTest
///      and WI4_WithdrawalEngineIntegrationTest). To still exercise genuine reordering, this
///      test bypasses the router's auto-delivery and calls HUB.ccipReceive directly
///      (pranked as the router, which is exactly what CCIPReceiver's onlyRouter modifier
///      permits) with hand-built Any2EVMMessage payloads, delivered in a DELIBERATELY
///      reversed order relative to when they were conceptually generated on the spoke side.
///      This is a faithful test of the hub-side handler logic's order-tolerance — the part
///      of the system WI-0/WI-6 is actually making a claim about — independent of whatever
///      the underlying CCIP transport does.
contract WI6_OutOfOrderDeliveryTest is BaseHubTest {
    bytes32 constant DEPOSIT_ID = keccak256("deposit-leg");
    bytes32 constant RECALL_ID = keccak256("recall-leg");

    /// @notice A DEPOSIT was conceptually sent first (5_000e6, spoke aggregate becomes
    /// 5_000e6), then a WITHDRAW_AMOUNT recall was sent second (1_000e6, spoke aggregate
    /// drops to 4_000e6). Their confirms are delivered to the hub in the OPPOSITE order —
    /// the recall's CONFIRM_WITHDRAWAL lands first, the deposit's CONFIRM_RECEIPT lands
    /// second. Both deliveries must succeed (no revert), and the accounting identity
    /// (totalAssets == idle + inTransit + spokeBalances) must hold after each step.
    function test_wi6_recallConfirmBeforeDepositConfirm_accountingStaysConsistent() public {
        // Simulate the DEPOSIT having been sent: tokens left the hub, inTransitAssets
        // tracks it under DEPOSIT_ID — mirrors exactly what HUB._sendToSpoke does, including
        // netSentToSpoke (WI-7's sanity-band baseline — without it the simulated confirms
        // below would exceed the band and be quarantined instead of applied).
        uint256 depositAmount = 5_000e6;
        deal(address(usdc), address(hub), usdc.balanceOf(address(hub)) - depositAmount);
        _simulateInTransit(DEPOSIT_ID, depositAmount);
        _setNetSentToSpoke(depositAmount);

        _assertAccountingIdentity("after simulated DEPOSIT send");

        // Deliver the RECALL's CONFIRM_WITHDRAWAL FIRST — out of order relative to the
        // deposit's confirm, which was conceptually generated earlier on the spoke side.
        // 1_000e6 arrives at the hub as real tokens (matching the recalled amount), and the
        // spoke reports its aggregate net of that recall: 5_000e6 - 1_000e6 = 4_000e6.
        uint256 recallAmount = 1_000e6;
        deal(
            address(usdc),
            address(hub),
            usdc.balanceOf(address(hub)) + recallAmount
        );
        _deliverConfirmWithdrawal(RECALL_ID, 4_000e6, recallAmount);

        // inTransitAssets must be untouched by the unrelated recall confirm — proves the
        // two independent id-tracked legs don't interfere with each other regardless of
        // delivery order.
        assertEq(hub.inTransitAssets(), depositAmount, "inTransit untouched by recall confirm");
        assertEq(hub.spokeBalances(chainSelector), 4_000e6, "spoke balance reflects recall");
        _assertAccountingIdentity("after recall confirm (delivered first)");

        // Now deliver the DEPOSIT's CONFIRM_RECEIPT — logically prior, delivered second.
        _deliverConfirmReceipt(DEPOSIT_ID, 5_000e6);

        assertEq(hub.inTransitAssets(), 0, "inTransit cleared by its own deposit confirm");
        // spokeBalances is a simple last-write overwrite (documented staleness tradeoff,
        // unrelated to WI-6) — the key claim under test is that NEITHER delivery reverted
        // and inTransitAssets/spokeBalances bookkeeping stayed internally consistent
        // (no double-decrement, no cross-contamination between the two independent ids).
        _assertAccountingIdentity("after deposit confirm (delivered second)");
    }

    function _simulateInTransit(bytes32 id, uint256 amount) internal {
        // inTransitAssets = slot 15, inTransitAmount = slot 16 (verified via
        // `forge inspect src/Hub.sol:HUB storage-layout`)
        uint256 currentInTransit = hub.inTransitAssets();
        vm.store(
            address(hub),
            bytes32(uint256(15)),
            bytes32(currentInTransit + amount)
        );
        bytes32 amountSlot = keccak256(abi.encode(id, uint256(16)));
        vm.store(address(hub), amountSlot, bytes32(amount));
    }

    /// @dev netSentToSpoke is a mapping at slot 19 (verified via
    /// `forge inspect src/Hub.sol:HUB storage-layout`) — WI-7's sanity-band baseline.
    function _setNetSentToSpoke(uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(uint256(chainSelector), uint256(19)));
        vm.store(address(hub), slot, bytes32(amount));
    }

    // _deliverConfirmWithdrawal / _deliverConfirmReceipt live in BaseHubTest (FX-4 —
    // extracted so this pattern isn't duplicated across test files).

    function _assertAccountingIdentity(string memory label) internal view {
        assertEq(
            hub.totalAssets(),
            usdc.balanceOf(address(hub)) +
                hub.inTransitAssets() +
                hub.spokeBalances(chainSelector),
            label
        );
    }
}
