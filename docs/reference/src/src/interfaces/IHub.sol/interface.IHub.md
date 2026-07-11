# IHub
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/interfaces/IHub.sol)


## Functions
### addSpoke


```solidity
function addSpoke(uint64 _chainSelector, address _spokeAddress) external;
```

### removeSpoke


```solidity
function removeSpoke(uint64 _chainSelector) external;
```

### sendToSpoke


```solidity
function sendToSpoke(uint64 _chainSelector, CCIPHelpers.AdapterInstructions[] memory _instructions) external;
```

### recallFromSpoke


```solidity
function recallFromSpoke(
    uint64 _chainSelector,
    CCIPHelpers.AdapterInstructions[] memory _instructions,
    bytes32 _messageId
) external;
```

### recallFromSpoke

Rebalancer-driven recall — hub derives its own id, no pendingWithdrawal is created


```solidity
function recallFromSpoke(uint64 _chainSelector, uint256 _amount) external;
```

### totalAssets


```solidity
function totalAssets() external view returns (uint256);
```

### idleBalance


```solidity
function idleBalance() external view returns (uint256);
```

### reservedAssets


```solidity
function reservedAssets() external view returns (uint256);
```

### rebalance


```solidity
function rebalance(uint64 _chainSelector, CCIPHelpers.AdapterInstructions[] memory _instructions) external;
```

