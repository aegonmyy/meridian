// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

library CCIPHelpers {
    enum MessageType {
        DEPOSIT,
        WITHDRAW,
        REPORT_BALANCE,
        CONFIRM_RECEIPT
    }

    struct CCIPMessage {
        MessageType messageType;
        address adapter;
        uint256 amount;
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
