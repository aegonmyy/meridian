# AaveAdapter
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/adapters/AaveAdapter.sol)

**Inherits:**
[IYieldSource](/src/interfaces/IYieldSource.sol/interface.IYieldSource.md)

**Title:**
AaveAdapter

Yield adapter that routes assets into Aave.


## Constants
### AAVE

```solidity
IPool public immutable AAVE
```


### A_TOKEN

```solidity
IAtoken public immutable A_TOKEN
```


### ASSET

```solidity
IERC20 public immutable ASSET
```


## Functions
### constructor


```solidity
constructor(address _aave, address _aToken, address _asset) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_aave`|`address`|Aave pool contract.|
|`_aToken`|`address`|Interest-bearing token for `_asset`.|
|`_asset`|`address`|Underlying ERC20 asset.|


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

