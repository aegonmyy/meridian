# AllocationProposal
[Git Source](https://github.com/aegonmyy/meridian/blob/8f085e328b747676203173bc0d1ecf2a95d5e520/src/interfaces/IRebalancer.sol)


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

