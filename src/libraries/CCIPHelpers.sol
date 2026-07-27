// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title CCIPHelpers
/// @notice Shared types and codec functions for all CCIP messages between HubVault and SpokeVaults
/// @dev All cross-chain communication in Meridian uses a single encoded CcipMessage payload.
///      Hub and spokes encode/decode this payload using the functions in this library.
///      Message flow overview:
///      Hub → Spoke: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT
///      Spoke → Hub: CONFIRM_RECEIPT, CONFIRM_WITHDRAWAL, CONFIRM_REBALANCE, REPORT_BALANCE
library CCIPHelpers {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice Identifies the intent of a CCIP message so the receiver can route correctly
    /// @dev Encoded as a uint8 inside CcipMessage. Each value maps to a handler function
    ///      in both HubVault._ccipReceive and SpokeVault._ccipReceive.
    ///
    ///      Hub → Spoke messages (outbound from hub):
    ///      DEPOSIT: hub sends USDC to spoke for deployment into yield adapters
    ///      REBALANCE: hub instructs spoke to move capital between adapters on same chain
    ///      REPORT_BALANCE: hub requests spoke to report its current aggregated balance
    ///      WITHDRAW_AMOUNT: hub instructs spoke to pull funds from adapters and return to hub
    ///
    ///      Spoke → Hub messages (inbound to hub):
    ///      CONFIRM_RECEIPT: spoke confirms deposit completed, carries new spoke balance
    ///      CONFIRM_WITHDRAWAL: spoke confirms funds were pulled and sent back to hub
    ///      CONFIRM_REBALANCE: spoke confirms intra-spoke rebalance completed, carries new balance
    ///      REPORT_BALANCE: spoke responds to hub's balance request, carries current balance
    enum MessageType {
        DEPOSIT,
        REBALANCE,
        REPORT_BALANCE,
        WITHDRAW_AMOUNT,
        CONFIRM_RECEIPT,
        CONFIRM_WITHDRAWAL,
        CONFIRM_REBALANCE
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Describes a single capital movement instruction for a yield adapter
    /// @dev Used in both deposit and rebalance contexts, field semantics vary by message type:
    ///      DEPOSIT: adapter = target protocol, amount = USDC to deposit, targetAdapter/targetAmount unused
    ///      REBALANCE: adapter = source protocol, amount = USDC to move, targetAdapter = destination protocol
    ///      WITHDRAW_AMOUNT: adapter = bytes32(0), amount = USDC shortfall to recall, targetAdapter unused
    ///      CONFIRM_* messages: may carry zero-value placeholders for encoding consistency
    struct AdapterInstructions {
        /// @dev bytes32 protocol identifier, e.g. keccak256("AAVE"). bytes32(0) means "any/all adapters"
        bytes32 adapter;
        /// @dev USDC amount in absolute 6-decimal units for DEPOSIT/WITHDRAW, 0 for confirmation messages
        uint256 amount;
        /// @dev Target protocol identifier for REBALANCE instructions, bytes32(0) if not applicable
        bytes32 targetAdapter;
        /// @dev Reserved for future use: always 0 in v1
        uint256 targetAmount;
    }

    /// @notice The canonical message payload encoded in the CCIP `data` field for all Meridian messages
    /// @dev Encoded via abi.encode and decoded via abi.decode. The same struct is used for all
    ///      message types: unused fields are zero-valued for a given message type.
    struct CcipMessage {
        /// @dev Determines which handler function processes this message on the receiving side
        MessageType messageType;
        /// @dev One entry per adapter operation, empty array for REPORT_BALANCE requests
        AdapterInstructions[] instructions;
        /// @dev Aggregated USDC balance of the spoke at message creation time.
        ///      Populated in spoke → hub messages (CONFIRM_*, REPORT_BALANCE).
        ///      Zero in hub → spoke messages (DEPOSIT, REBALANCE, REPORT_BALANCE request, WITHDRAW_AMOUNT).
        uint256 spokeBalance;
        /// @dev block.timestamp on the chain where the message was created.
        ///      Used by hub to update lastReportTimestamp[] and evaluate staleness.
        uint256 reportTimestamp;
        /// @dev Unique identifier linking a response message back to its originating request.
        ///      Set by hub on outbound messages, echoed back by spoke in responses.
        ///      Used to match CONFIRM_WITHDRAWAL to a pendingWithdrawals entry.
        bytes32 messageId;
    }

    // =========================================================================
    // Codec Functions
    // =========================================================================

    /// @notice ABI-encodes a CcipMessage into bytes for inclusion in a CCIP message payload
    /// @dev Used by both hub and spoke before calling router.ccipSend().
    ///      Receiver decodes using decode().
    /// @param _message The CcipMessage struct to encode
    /// @return ABI-encoded bytes ready for use as the CCIP message data field
    function encode(
        CcipMessage memory _message
    ) internal pure returns (bytes memory) {
        return abi.encode(_message);
    }

    /// @notice ABI-decodes bytes from a CCIP message payload back into a CcipMessage struct
    /// @dev Used by both hub and spoke inside _ccipReceive() after receiving a message.
    ///      Reverts with a generic ABI decode error if the bytes are malformed,
    ///      only messages from registered hubs/spokes should ever reach this point.
    /// @param _encodedMessage Raw bytes from the CCIP message data field
    /// @return Decoded CcipMessage struct ready for routing and processing
    function decode(
        bytes memory _encodedMessage
    ) internal pure returns (CcipMessage memory) {
        return abi.decode(_encodedMessage, (CcipMessage));
    }
}
