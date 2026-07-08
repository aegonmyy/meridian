// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice WI-1 regression — content-derived message ids collide.
/// @dev The CCIPLocalSimulator routes messages synchronously (nested), so the
///      async fund-stranding manifestation (two same-id messages in flight,
///      corrupting inTransitAmount / overwriting a pending withdrawal) cannot be
///      reproduced end-to-end in this harness — each round trip fully settles
///      before the next call. We therefore assert the ROOT CAUSE directly: two
///      logically distinct operations in the same block must produce distinct
///      internal message ids. Pre-fix these ids are equal (keccak of
///      amount+timestamp / receiver+timestamp); post-WI-1 they are nonce'd and
///      always distinct.
contract WI1_MessageIdCollisionTest is BaseHubTest {
    // event signatures for log parsing
    bytes32 constant SENT_TO_SPOKE_SIG =
        keccak256("SentToSpoke(uint64,bytes32,bytes32,uint256)");
    bytes32 constant WITHDRAWAL_PROCESSED_SIG =
        keccak256("WithdrawalProcessed(address,address,uint256,bytes32)");

    /// @notice Two deposits of identical amount in one block must not share a message id.
    function test_wi1_sendToSpoke_sameAmountSameBlock_distinctIds() public {
        vm.recordLogs();

        _sendToSpoke(3_000e6);
        _sendToSpoke(3_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 firstId;
        bytes32 secondId;
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SENT_TO_SPOKE_SIG) {
                (bytes32 internalId, ) = abi.decode(
                    logs[i].data,
                    (bytes32, uint256)
                );
                if (seen == 0) {
                    firstId = internalId;
                } else if (seen == 1) {
                    secondId = internalId;
                }
                seen++;
            }
        }
        assertGe(seen, 2, "expected two SentToSpoke events");
        assertTrue(
            firstId != secondId,
            "message id collision: identical ids for two distinct deposits"
        );
    }

    /// @notice Two same-receiver withdrawals in one block must not share a message id.
    function test_wi1_withdrawal_sameReceiverSameBlock_distinctIds() public {
        // deploy some capital so a report cycle exists, then make it stale so
        // idle-covered withdrawals take Path 2 (queued, then settled on report).
        _sendToSpoke(4_000e6);
        vm.warp(block.timestamp + 2 hours); // exceed MAX_STALENESS

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 quarterShares = aliceShares / 4;

        vm.recordLogs();

        vm.prank(alice);
        hub.redeem(quarterShares, alice, alice);
        vm.prank(alice);
        hub.redeem(quarterShares, alice, alice);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 firstId;
        bytes32 secondId;
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == WITHDRAWAL_PROCESSED_SIG) {
                (, bytes32 messageId) = abi.decode(
                    logs[i].data,
                    (uint256, bytes32)
                );
                if (seen == 0) {
                    firstId = messageId;
                } else if (seen == 1) {
                    secondId = messageId;
                }
                seen++;
            }
        }
        assertGe(seen, 2, "expected two WithdrawalProcessed events");
        assertTrue(
            firstId != secondId,
            "withdrawal id collision: identical ids overwrite the pending entry"
        );
    }
}
