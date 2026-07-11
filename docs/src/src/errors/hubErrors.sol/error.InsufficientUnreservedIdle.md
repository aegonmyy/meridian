# InsufficientUnreservedIdle
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/errors/hubErrors.sol)

Thrown when sendToSpoke would ship more idle than is currently unreserved

requested: sum of instruction amounts. idle: current idle balance. reserved: reservedAssets.


```solidity
error InsufficientUnreservedIdle(uint256 requested, uint256 idle, uint256 reserved);
```

