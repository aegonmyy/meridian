# MarketParamsLib
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/interfaces/morpho/utils/MarketParamsLib.sol)

**Title:**
MarketParamsLib

**Author:**
Morpho Labs

Library to convert a market to its id.

**Note:**
contact: security@morpho.org


## Constants
### MARKET_PARAMS_BYTES_LENGTH
The length of the data used to compute the id of a market.

The length is 5 * 32 because `MarketParams` has 5 variables of 32 bytes each.


```solidity
uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32
```


## Functions
### id

Returns the id of the market `marketParams`.


```solidity
function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId);
```

