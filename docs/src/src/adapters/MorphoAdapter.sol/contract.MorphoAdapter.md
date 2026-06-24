# MorphoAdapter
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/adapters/MorphoAdapter.sol)

**Inherits:**
[IYieldSource](/src/interfaces/IYieldSource.sol/interface.IYieldSource.md)

**Title:**
MorphoAdapter

Yield adapter that routes assets into a configured Morpho market.


## Constants
### ASSET

```solidity
IERC20 public immutable ASSET
```


### MORPHO

```solidity
IMorpho public immutable MORPHO
```


## State Variables
### marketparams

```solidity
MarketParams public marketparams
```


## Functions
### constructor


```solidity
constructor(
    address _asset,
    address _morpho,
    address _loanToken,
    address _collateralToken,
    address _oracle,
    address _irm,
    uint256 _lltv
) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_asset`|`address`|Underlying ERC20 asset.|
|`_morpho`|`address`|Morpho core contract.|
|`_loanToken`|`address`|Market loan token.|
|`_collateralToken`|`address`|Market collateral token.|
|`_oracle`|`address`|Market oracle.|
|`_irm`|`address`|Market interest rate model.|
|`_lltv`|`uint256`|Market liquidation loan-to-value.|


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

Returns underlying assets claimable by this adapter in Morpho.

Uses share-to-asset conversion against current market totals.


```solidity
function totalAssets() external view returns (uint256);
```

## Errors
### ZeroAddress
Raised when a required constructor address is zero.


```solidity
error ZeroAddress();
```

