# IYieldSource
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/interfaces/IYieldSource.sol)


## Functions
### deposit

Deposits underlying assets into the strategy.

Caller must have approved the adapter for `amount`.


```solidity
function deposit(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of underlying asset to deposit.|


### withdraw

Withdraws underlying assets from the strategy.


```solidity
function withdraw(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of underlying asset to withdraw.|


### totalAssets

Returns total underlying assets currently managed by the strategy.

The returned value must represent assets attributable to the adapter itself.


```solidity
function totalAssets() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Total managed underlying assets.|


