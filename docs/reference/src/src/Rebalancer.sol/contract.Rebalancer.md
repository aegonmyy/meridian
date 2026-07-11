# Rebalancer
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/Rebalancer.sol)

**Title:**
Rebalancer

Safety layer between the off-chain agent and the HubVault — validates all allocation
proposals and intra-spoke rebalance instructions before forwarding to hub.

All capital movement flows through this contract. The agent (AgentConsumer) submits
proposals; Rebalancer enforces on-chain guards before calling hub functions.
Guards enforced in order:
1. Access control — only owner or AgentConsumer
2. Allocation validity — sum, per-market cap, chain cap, dust floor
3. APY threshold — optimal must beat current by >= 50 bps (proposeAllocation only)
4. Chain whitelist — all selectors in proposal must be approved
5. Protocol whitelist — all protocol ids must be approved
6. Max single move — no allocation may exceed 30% of totalAssets


## Constants
### HUB
HubVault contract on Ethereum — target for all capital movement calls

Immutable — set once at deployment. Hub must have this contract as its REBALANCER.


```solidity
IHub public immutable HUB
```


### AGENT_CONSUMER
Address of the AgentConsumer contract — authorized alongside owner to call guards

Immutable — off-chain agent submits proposals through AgentConsumer which calls here.


```solidity
address public immutable AGENT_CONSUMER
```


## State Variables
### owner
Contract owner — authorized to call all functions and manage whitelists

Mutable — can be transferred. Should be a multisig before mainnet.


```solidity
address public owner
```


### whitelistedChains
Maps CCIP chain selectors to their whitelist status

Only whitelisted chains can receive capital. Managed by owner or agentConsumer.


```solidity
mapping(uint64 => bool) public whitelistedChains
```


### whitelistedProtocols
Maps protocol identifiers to their whitelist status

Only whitelisted protocols can receive capital. Key is e.g. keccak256("AAVE").


```solidity
mapping(bytes32 => bool) public whitelistedProtocols
```


## Functions
### onlyAuthorized

Restricts access to owner or AgentConsumer


```solidity
modifier onlyAuthorized() ;
```

### _onlyAuthorized

Extracted to reduce bytecode size from modifier inlining


```solidity
function _onlyAuthorized() internal view;
```

### constructor

Deploys the Rebalancer with immutable hub and agent references

All three addresses are required — zero address for any reverts.
Deploy Rebalancer after Hub is deployed (needs hub address).
Call hub.setRebalancer(address(this)) after deployment.


```solidity
constructor(address _hub, address _agentConsumer, address _owner) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_hub`|`address`|Address of the HubVault on Ethereum|
|`_agentConsumer`|`address`|Address of the AgentConsumer contract|
|`_owner`|`address`|Address of the contract owner — should be a multisig before mainnet|


### rebalance

Executes an intra-spoke rebalance — moves capital between adapters on one chain

Guards enforced in order: access control, source != target,
amount != 0, chain whitelisted, both protocols whitelisted.
Does NOT validate APY gain — intra-spoke rebalances are manual operator decisions.
Does NOT enforce max single move — amount is absolute not proportional to totalAssets.
Calls hub.rebalance() which sends a REBALANCE CCIP message to the target spoke.


```solidity
function rebalance(bytes32 _source, bytes32 _target, uint256 _amount, uint64 _chainSelector)
    external
    onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_source`|`bytes32`|bytes32 protocol identifier of the source adapter to withdraw from|
|`_target`|`bytes32`|bytes32 protocol identifier of the target adapter to deposit into|
|`_amount`|`uint256`|Amount of USDC to move from source to target in the same spoke|
|`_chainSelector`|`uint64`|CCIP chain selector of the spoke where both adapters live|


### recallFromSpoke

Recalls capital off an overweight spoke back to hub idle — the "move weight
off a chain" lever that proposeAllocation alone cannot provide

WI-3 (Issue 5, Option A). Guards: access control, chain whitelisted, amount != 0.
No pendingWithdrawal is created — the hub just credits the arrived tokens as
ordinary idle and emits RecallCompleted once the CONFIRM_WITHDRAWAL lands.
Intended v1 operator flow (on-chain diff engine is explicitly out of scope, v2):
1. Off-chain agent computes the desired allocation diff.
2. For each overweight chain, call recallFromSpoke(selector, amount) to pull
capital back to hub idle.
3. Await the hub's RecallCompleted event confirming the funds landed.
4. Call proposeAllocation() sized against the now-larger idle balance —
HUB.sendToSpoke's solvency guard (and this contract's own pre-check) will
reject a proposal sized before the recall actually lands.


```solidity
function recallFromSpoke(uint64 _chainSelector, uint256 _amount) external onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the spoke to recall from — must be whitelisted|
|`_amount`|`uint256`|USDC amount to recall — must be nonzero|


### proposeAllocation

Validates and executes a full cross-chain allocation proposal from the agent

Five guards enforced in order — any failure reverts without side effects:
1. onlyAuthorized — owner or AgentConsumer only
2. InvalidAllocation — validateAllocation(proposedAllocations) must pass
3. BelowThreshold — optimal weighted APY must exceed current by >= 50 bps
4. ChainNotWhitelisted — all chainSelectors in proposal must be approved
5. ProtocolNotWhitelisted — all protocolIds in proposal must be approved
On success: calls hub.sendToSpoke() per chain.
Known limitation: proposedAllocations amounts are in bps but sendToSpoke expects
absolute USDC amounts — the TODO comment in code flags this conversion gap.


```solidity
function proposeAllocation(AllocationProposal memory proposal) external onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`proposal`|`AllocationProposal`|The AllocationProposal struct containing current and proposed allocations, APYs, chain selectors, and protocol ids for all target chains|


### addChainToWhitelist

Adds a CCIP chain selector to the whitelist

Capital can only be deployed to whitelisted chains. No-op if already whitelisted.


```solidity
function addChainToWhitelist(uint64 _chainSelector) external onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector to whitelist|


### removeChainFromWhitelist

Removes a CCIP chain selector from the whitelist

Capital already deployed to this chain is NOT recalled — only new deployments blocked.
Use in combination with a recall instruction to fully exit a chain.


```solidity
function removeChainFromWhitelist(uint64 _chainSelector) external onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector to remove from whitelist|


### addProtocolToWhitelist

Adds a protocol identifier to the whitelist

Capital can only be deployed to whitelisted protocols. No-op if already whitelisted.


```solidity
function addProtocolToWhitelist(bytes32 _protocolId) external onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_protocolId`|`bytes32`|bytes32 protocol identifier (e.g. keccak256("AAVE"))|


### removeProtocolFromWhitelist

Removes a protocol identifier from the whitelist

Capital already deployed to this protocol is NOT recalled — only new deployments blocked.
Use spoke.removeAdapter() on the target chain to fully disable a protocol.


```solidity
function removeProtocolFromWhitelist(bytes32 _protocolId) external onlyAuthorized;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_protocolId`|`bytes32`|bytes32 protocol identifier to remove from whitelist|


### _flatten

Flattens a 2D uint256 array into a 1D array for AllocationMaths functions

AllocationMaths.weightedApy expects flat arrays — this converts the nested
per-chain per-protocol structure of AllocationProposal into a single sequence.
Order preserved: outer array iterated first, inner array second.


```solidity
function _flatten(uint256[][] memory arr) internal pure returns (uint256[] memory flat);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`arr`|`uint256[][]`|2D array where arr[chain][protocol] holds an allocation or APY value|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`flat`|`uint256[]`|1D array concatenating all inner arrays in order|


## Events
### RebalanceExecuted
Emitted after a successful rebalance() or proposeAllocation() execution

RebalanceExecuted is not currently emitted — reserved for future use


```solidity
event RebalanceExecuted(uint256 timestamp, uint256 weightedApy);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`timestamp`|`uint256`|Block timestamp of execution|
|`weightedApy`|`uint256`|Optimal weighted APY from the accepted proposal (0 for rebalance())|

### ChainWhitelisted
Emitted when a chain selector is added to the whitelist


```solidity
event ChainWhitelisted(uint64 chainSelector);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|The CCIP chain selector that was whitelisted|

### ChainRemovedFromWhitelist
Emitted when a chain selector is removed from the whitelist


```solidity
event ChainRemovedFromWhitelist(uint64 chainSelector);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|The CCIP chain selector that was removed|

### ProtocolWhitelisted
Emitted when a protocol identifier is added to the whitelist


```solidity
event ProtocolWhitelisted(bytes32 protocolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`protocolId`|`bytes32`|The bytes32 protocol identifier that was whitelisted|

### ProtocolRemovedFromWhitelist
Emitted when a protocol identifier is removed from the whitelist


```solidity
event ProtocolRemovedFromWhitelist(bytes32 protocolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`protocolId`|`bytes32`|The bytes32 protocol identifier that was removed|

## Errors
### InvalidConstructorArguments
Thrown when constructor receives a zero address argument


```solidity
error InvalidConstructorArguments();
```

### NotAuthorized
Thrown when caller is neither owner nor AgentConsumer


```solidity
error NotAuthorized();
```

### SourceEqualsTarget
Thrown when source and target adapter are the same in rebalance()


```solidity
error SourceEqualsTarget();
```

### ZeroAmount
Thrown when rebalance amount is zero


```solidity
error ZeroAmount();
```

### BelowThreshold
Thrown when optimal weighted APY does not exceed current by >= 50 bps


```solidity
error BelowThreshold();
```

### MaxSingleMoveExceeded

```solidity
error MaxSingleMoveExceeded();
```

### ChainNotWhitelisted
Thrown when a chain selector in the proposal is not whitelisted


```solidity
error ChainNotWhitelisted();
```

### ProtocolNotWhitelisted
Thrown when a protocol id in the proposal is not whitelisted


```solidity
error ProtocolNotWhitelisted();
```

### InvalidAllocation
Thrown when proposed allocations fail validateAllocation checks

Covers: sum != 10000, market > 6000 bps, chain > 8000 bps, dust < 500 bps


```solidity
error InvalidAllocation();
```

### InsufficientIdleForProposal
Thrown when a proposal's total requested amount exceeds hub's unreserved idle

WI-3 friendly pre-check — fails legibly before dispatching any per-chain sends,
instead of a partial dispatch dying deep inside a later chain's CCIP token
transfer. Mirrors (and is intentionally more conservative than racing with)
the authoritative guard enforced in HUB.sendToSpoke itself.


```solidity
error InsufficientIdleForProposal(uint256 requested, uint256 available);
```

