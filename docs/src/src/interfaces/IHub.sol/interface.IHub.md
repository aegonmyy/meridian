# IHub
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/interfaces/IHub.sol)


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

### totalAssets


```solidity
function totalAssets() external view returns (uint256);
```

### rebalance


```solidity
function rebalance(
    uint64 _chainSelector,
    CCIPHelpers.AdapterInstructions[] memory _instructions,
    bytes32 _messageId
) external;
```

