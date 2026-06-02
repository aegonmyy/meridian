// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

library CCIPHelpers {
    enum MessageType {
        DEPOSIT,
        WITHDRAW,
        REPORT_BALANCE,
        CONFIRM_RECEIPT
    }

    struct AdapterInstructions {
        bytes32 adapter;
        uint256 amount;
    }

    struct CcipMessage {
        MessageType messageType;
        AdapterInstructions[] instructions;
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
