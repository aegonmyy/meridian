# IMorpho
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/interfaces/morpho/IMorpho.sol)


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

