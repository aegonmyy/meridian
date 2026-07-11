# MathLib
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/interfaces/morpho/utils/MathLib.sol)

**Title:**
MathLib

**Author:**
Morpho Labs

Library to manage fixed-point arithmetic.

**Note:**
contact: security@morpho.org


## Functions
### wMulDown

Returns (`x` * `y`) / `WAD` rounded down.


```solidity
function wMulDown(uint256 x, uint256 y) internal pure returns (uint256);
```

### wDivDown

Returns (`x` * `WAD`) / `y` rounded down.


```solidity
function wDivDown(uint256 x, uint256 y) internal pure returns (uint256);
```

### wDivUp

Returns (`x` * `WAD`) / `y` rounded up.


```solidity
function wDivUp(uint256 x, uint256 y) internal pure returns (uint256);
```

### mulDivDown

Returns (`x` * `y`) / `d` rounded down.


```solidity
function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256);
```

### mulDivUp

Returns (`x` * `y`) / `d` rounded up.


```solidity
function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256);
```

### wTaylorCompounded

Returns the sum of the first three non-zero terms of a Taylor expansion of e^(nx) - 1, to approximate a
continuous compound interest rate.


```solidity
function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256);
```

