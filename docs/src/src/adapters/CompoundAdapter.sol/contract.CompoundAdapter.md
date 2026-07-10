# CompoundAdapter
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/adapters/CompoundAdapter.sol)

**Inherits:**
[IYieldSource](/src/interfaces/IYieldSource.sol/interface.IYieldSource.md)

**Title:**
CompoundAdapter

Yield adapter that routes assets into Compound V3 Comet.


## Constants
### ASSET

```solidity
IERC20 public immutable ASSET
```


### COMPOUND

```solidity
IComet public immutable COMPOUND
```


## Functions
### constructor


```solidity
constructor(address _asset, address _compound) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_asset`|`address`|Underlying ERC20 asset.|
|`_compound`|`address`|Compound V3 Comet address.|


### deposit

Deposits underlying assets into the strategy.

Caller must have approved the adapter for `amount`.


```solidity
function deposit(uint256 _amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_amount`|`uint256`||


### withdraw

Withdraws underlying assets from the strategy.


```solidity
function withdraw(uint256 _amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_amount`|`uint256`||


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


## Errors
### ZeroAddress
Raised when a required constructor address is zero.


```solidity
error ZeroAddress();
```

