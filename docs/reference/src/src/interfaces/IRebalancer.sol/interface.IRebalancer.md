# IRebalancer
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/interfaces/IRebalancer.sol)


## Functions
### proposeAllocation


```solidity
function proposeAllocation(AllocationProposal memory proposal) external;
```

### addChainToWhitelist


```solidity
function addChainToWhitelist(uint64 _chainSelector) external;
```

### removeChainFromWhitelist


```solidity
function removeChainFromWhitelist(uint64 _chainSelector) external;
```

### addProtocolToWhitelist


```solidity
function addProtocolToWhitelist(bytes32 _protocolId) external;
```

### removeProtocolFromWhitelist


```solidity
function removeProtocolFromWhitelist(bytes32 _protocolId) external;
```

