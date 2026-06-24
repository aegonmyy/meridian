# AllocationProposal
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/interfaces/IRebalancer.sol)


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

