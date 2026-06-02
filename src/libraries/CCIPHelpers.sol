// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

library CCIPHelpers {
    enum MessageType {
        DEPOSIT,
        WITHDRAW,
        REPORT_BALANCE,
        CONFIRM_RECEIPT
    }

    struct adapterInstructions {
        bytes32 adapter;
        uint256 amount;
    }

    struct CCIPMessage {
        MessageType messageType;
        adapterInstructions[] instructions;
    }

    function encode(
        CCIPMessage memory _message
    ) internal pure returns (bytes memory) {
        return abi.encode(_message);
    }

    function decode(
        bytes memory _encodedMessage
    ) internal pure returns (CCIPMessage memory) {
        return abi.decode(_encodedMessage, (CCIPMessage));
    }
}
