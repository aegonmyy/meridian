# AllocationProposal
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/interfaces/IRebalancer.sol)


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

