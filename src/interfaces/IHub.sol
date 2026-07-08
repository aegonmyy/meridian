// SPDX-License-Identifier: MIT

pragma solidity 0.8.33;

import {CCIPHelpers} from "../libraries/CCIPHelpers.sol";

interface IHub {
    function addSpoke(uint64 _chainSelector, address _spokeAddress) external;

    function removeSpoke(uint64 _chainSelector) external;

    function sendToSpoke(uint64 _chainSelector, CCIPHelpers.AdapterInstructions[] memory _instructions) external;

    function recallFromSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions,
        bytes32 _messageId
    ) external;

    /// @notice Rebalancer-driven recall — hub derives its own id, no pendingWithdrawal is created
    function recallFromSpoke(uint64 _chainSelector, uint256 _amount) external;

    function totalAssets() external view returns (uint256);

    function idleBalance() external view returns (uint256);

    function reservedAssets() external view returns (uint256);

    function rebalance(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions
    ) external;
}
