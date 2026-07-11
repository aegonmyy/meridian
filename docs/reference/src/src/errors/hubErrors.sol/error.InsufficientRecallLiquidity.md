# InsufficientRecallLiquidity
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/errors/hubErrors.sol)

Thrown when a Path 3 withdrawal's shortfall cannot be fully covered by recalling
from active spokes even after planning legs across all of them

shortfall: assets - idleFree. coverable: sum of haircut-capped leg amounts found.
Fail-closed — the whole _withdraw call reverts, no shares move, nothing locks.


```solidity
error InsufficientRecallLiquidity(uint256 shortfall, uint256 coverable);
```

