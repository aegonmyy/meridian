# AllocationProposal
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/interfaces/IRebalancer.sol)


```solidity
struct AllocationProposal {
uint256[][] proposedAllocations;
uint256[] proposedNetApys;
uint256[][] currentAllocations;
uint256[] currentNetApys;
uint64[] chainSelectors;
bytes32[][] protocolIds;
}
```

