# IRebalancer
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/interfaces/IRebalancer.sol)


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

