// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

library CCIPHelpers {
    enum MessageType {
        DEPOSIT,
        REBALANCE,
        REPORT_BALANCE,
        WITHDRAW_AMOUNT,
        CONFIRM_RECEIPT,
        CONFIRM_WITHDRAWAL,
        CONFIRM_REBALANCE
    }

    struct AdapterInstructions {
        bytes32 adapter;
        uint256 amount;
        bytes32 targetAdapter;
        uint256 targetAmount;
    }

    struct CcipMessage {
        MessageType messageType;
        AdapterInstructions[] instructions;
        uint256 spokeBalance;
        uint256 reportTimestamp;
        bytes32 messageId;
    }

    function encode(
        CcipMessage memory _message
    ) internal pure returns (bytes memory) {
        return abi.encode(_message);
    }

    function decode(
        bytes memory _encodedMessage
    ) internal pure returns (CcipMessage memory) {
        return abi.decode(_encodedMessage, (CcipMessage));
    }
}
