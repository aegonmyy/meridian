// SPDX-License-Identifier: MIT

pragma solidity 0.8.33;

struct AdapterInstructions {
    bytes32 adapter;
    uint256 amount;
}

contract IHub {
    function addSpoke(uint64 _chainSelector, address _spokeAddress) external {}

    function removeSpoke(uint64 _chainSelector) external {}

    function sendToSpoke(
        uint64 _chainSelector,
        AdapterInstructions[] memory _instructions
    ) external {}

    function recallFromSpoke(
        uint64 _chainSelector,
        AdapterInstructions[] memory _instructions,
        bytes32 _messageId
    ) external {}

    function totalAssets() public view returns (uint256) {}
}
