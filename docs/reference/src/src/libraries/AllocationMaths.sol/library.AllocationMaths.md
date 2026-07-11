# AllocationMaths
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/libraries/AllocationMaths.sol)

**Title:**
AllocationMaths

Pure math library for computing and validating yield allocation proposals

All functions are internal pure — no state reads or writes, no CCIP dependency.
Used exclusively by the Rebalancer contract to evaluate agent proposals before
forwarding capital movement instructions to the HubVault.
Units convention:
- APY values are in basis points (bps): 100 = 1%, 500 = 5%, 10000 = 100%
- Allocation values are in basis points: 3000 = 30% of total capital
- totalAssets is in absolute USDC (6 decimal units)
- All bps values divide by 10_000 to get percentages


## Functions
### netApy

Computes net APY by subtracting protocol costs from gross APY

Both inputs and output are in basis points.
Reverts with arithmetic underflow if costs exceed gross — intentional,
a negative net APY is not a valid input to the allocation system.


```solidity
function netApy(uint256 _grossApy, uint256 _costs) internal pure returns (uint256 _netApy);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_grossApy`|`uint256`|Gross APY of the protocol in basis points (e.g. 500 = 5%)|
|`_costs`|`uint256`|Total costs of the protocol in basis points (e.g. 50 = 0.5%)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`_netApy`|`uint256`|Net APY after costs in basis points|


### weightedApy

Computes the weighted average APY across a set of allocations and their net APYs

Weighted average formula: sum(allocation[i] * netApy[i]) / 10_000
Both arrays must be the same length and represent parallel data — allocation[i]
corresponds to netApy[i]. Reverts with arrayOutOfBound if lengths differ.
Used to compare current vs proposed allocations in shouldRebalance().


```solidity
function weightedApy(uint256[] memory _allocations, uint256[] memory _netApYs)
    internal
    pure
    returns (uint256 _weightedApy);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_allocations`|`uint256[]`|Array of allocation weights in basis points (must sum to 10_000)|
|`_netApYs`|`uint256[]`|Array of net APY values in basis points, one per allocation|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`_weightedApy`|`uint256`|Weighted average APY in basis points|


### validateAllocation

Validates a 2D allocation array against protocol safety constraints

_allocations[i][j] represents the allocation for protocol j on chain i in basis points.
Four constraints enforced — returns false (not revert) on any violation:
1. Dust floor: each non-zero allocation must be >= 500 bps (5%)
Prevents economically meaningless positions with high relative gas cost.
2. Per-market cap: no single allocation may exceed 6000 bps (60%)
Limits concentration risk in a single protocol.
3. Per-chain cap: sum of all allocations on one chain must not exceed 8000 bps (80%)
Limits concentration risk on a single L2.
4. Grand total: sum of all allocations across all chains must equal exactly 10000 bps
Ensures 100% of capital is accounted for.
Zero allocations are valid — they represent a protocol not currently used.


```solidity
function validateAllocation(uint256[][] memory _allocations) internal pure returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_allocations`|`uint256[][]`|2D array where _allocations[chain][protocol] is a bps value|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if all constraints pass, false if any constraint is violated|


### shouldRebalance

Determines whether the gain from rebalancing justifies the operation

Returns true only if optimalWeightedApy strictly exceeds currentWeightedApy
by at least 50 bps (0.5%). This threshold prevents unnecessary rebalances
that would incur CCIP fees for marginal APY improvement.
Returns false if optimal <= current — never rebalance to a worse or equal position.


```solidity
function shouldRebalance(uint256 currentWeightedApy, uint256 optimalWeightedApy) internal pure returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currentWeightedApy`|`uint256`|Weighted average APY of current allocation in basis points|
|`optimalWeightedApy`|`uint256`|Weighted average APY of proposed allocation in basis points|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if the gain is >= 50 bps and rebalancing is worthwhile|


### validateSingleMove

Validates that no single allocation in a proposal exceeds 30% of totalAssets

Converts each bps allocation to an absolute USDC amount and compares against
maxMove = 30% of totalAssets. Returns false (not revert) if any allocation exceeds the cap.
Guards against the agent moving too much capital in a single operation —
limits potential loss if the agent submits a bad proposal.
Zero totalAssets: all amounts are 0, maxMove is 0 — all pass trivially.
Exactly 30% passes (strict greater than, not greater than or equal).


```solidity
function validateSingleMove(uint256[][] memory allocations, uint256 totalAssets) internal pure returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`allocations`|`uint256[][]`|2D array of bps allocations — same structure as validateAllocation input|
|`totalAssets`|`uint256`|Total USDC managed by the hub in 6-decimal absolute units|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if every individual allocation converts to <= 30% of totalAssets|


