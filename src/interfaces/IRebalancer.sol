// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

struct AllocationProposal {
    uint256[][] proposedAllocations;
    uint256[] proposedNetApys;
    uint256[][] currentAllocations;
    uint256[] currentNetApys;
    uint64[] chainSelectors;
    bytes32[][] protocolIds;
}

interface IRebalancer {
    function proposeAllocation(AllocationProposal memory proposal) external;

    function addChainToWhitelist(uint64 _chainSelector) external;

    function removeChainFromWhitelist(uint64 _chainSelector) external;

    function addProtocolToWhitelist(bytes32 _protocolId) external;

    function removeProtocolFromWhitelist(bytes32 _protocolId) external;
}
