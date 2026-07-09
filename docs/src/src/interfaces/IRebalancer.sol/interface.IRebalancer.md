# IRebalancer
[Git Source](https://github.com/aegonmyy/meridian/blob/8f085e328b747676203173bc0d1ecf2a95d5e520/src/interfaces/IRebalancer.sol)


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

