# IMorpho
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/interfaces/morpho/IMorpho.sol)


## Functions
### supply


```solidity
function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes memory data
) external returns (uint256 assetsSupplied, uint256 sharesSupplied);
```

### withdraw


```solidity
function withdraw(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);
```

### position


```solidity
function position(Id id, address user) external view returns (Position memory p);
```

### market


```solidity
function market(Id id) external view returns (Market memory m);
```

