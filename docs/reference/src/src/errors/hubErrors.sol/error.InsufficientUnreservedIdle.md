# InsufficientUnreservedIdle
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/errors/hubErrors.sol)

Thrown when sendToSpoke would ship more idle than is currently unreserved

requested: sum of instruction amounts. idle: current idle balance. reserved: reservedAssets.


```solidity
error InsufficientUnreservedIdle(uint256 requested, uint256 idle, uint256 reserved);
```

