# SpokeStorage
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/spoke/SpokeStorage.sol)

**Inherits:**
CCIPReceiver, Ownable

**Title:**
SpokeStorage

Shared storage, structs, constants, events, constructor, and cross-module hook
declarations for the Spoke. All state lives here, in the exact declaration order
of the pre-split Spoke.sol, so storage slot assignment is unaffected by the
module split.

Every Spoke module (SpokeAdminModule, SpokeHandlersModule, SpokeConfirmsModule)
inherits this contract directly (sibling inheritance) — none of them inherit each
other. Any function called across module boundaries must be declared here as a
bodiless `virtual` function and implemented with `override` in its owning module —
the only way one sibling module's code can see a function implemented in another.
See the executor's final report for the real call-graph derivation of the hook set
below.


## Constants
### ASSET
The ERC20 asset managed by this vault (USDC in v1)

Immutable — single asset per spoke in v1. Multi-asset support deferred to v2.


```solidity
IERC20 public immutable ASSET
```


### HUB_CHAIN_SELECTOR
CCIP chain selector for Ethereum mainnet — destination for all outbound messages

Immutable — all spoke-to-hub messages use this selector regardless of operation type.


```solidity
uint64 public immutable HUB_CHAIN_SELECTOR
```


### LINK
LINK token used to pay CCIP fees for all outbound messages

Immutable — spoke must hold sufficient LINK balance for all response messages.


```solidity
IERC20 public immutable LINK
```


## State Variables
### HUB
Address of the HubVault on Ethereum — sole authorized CCIP message sender

Validated in _ccipReceive for every message. Mutable via setHub() so Hub can
be redeployed (e.g. to add features) without redeploying all spokes.


```solidity
address public HUB
```


### adapters
Maps protocol identifiers to their adapter registration info

Key is an arbitrary bytes32 agreed upon at deployment, e.g. keccak256("AAVE").
Use setAdapter() to register or update, removeAdapter() to disable.


```solidity
mapping(bytes32 => AdapterInfo) public adapters
```


### activeAdapters
Ordered list of all protocol identifiers ever registered, including removed ones

Soft-delete pattern — entries are never removed. Inactive adapters are
skipped during iteration via the `exists` flag on AdapterInfo.
Kept small by design — 3 to 5 protocols max per spoke in v1.


```solidity
bytes32[] public activeAdapters
```


### pendingConfirms
Queue of confirm messages whose outbound ccipSend failed and await retry

WI-2d — see PendingConfirm. Never shrinks; resolved entries stay for history and
are skipped on retry. Grows only when LINK is exhausted or the router hiccups.


```solidity
PendingConfirm[] public pendingConfirms
```


### unresolvedConfirmCount
Count of pendingConfirms entries not yet resolved

FX-6a — maintained incrementally (incremented in _queueConfirm, decremented in
retryConfirm on success) so setHub's guard is O(1) instead of linear-scanning
the append-only pendingConfirms array on every call. The array itself stays
untouched (history is useful) — only this counter changes.


```solidity
uint256 public unresolvedConfirmCount
```


## Functions
### constructor

Deploys the SpokeVault with initial chain and protocol configuration

CCIPReceiver validates _router internally — no explicit check needed here.
Parent constructors run before the zero address checks in the body.
_hubSelector == 0 is rejected as it would make all outbound CCIP messages fail.
HUB is mutable post-deployment via setHub() — update when Hub is redeployed.


```solidity
constructor(address _hub, address _asset, address _router, address _owner, address _link, uint64 _hubSelector)
    CCIPReceiver(_router)
    Ownable(_owner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_hub`|`address`|Address of the HubVault on Ethereum mainnet|
|`_asset`|`address`|Address of the ERC20 asset this vault manages (USDC)|
|`_router`|`address`|Address of the Chainlink CCIP router on this L2 chain|
|`_owner`|`address`|Address of the contract owner — should be a multisig before mainnet|
|`_link`|`address`|Address of the LINK token on this L2 chain|
|`_hubSelector`|`uint64`|CCIP chain selector for Ethereum mainnet|


### _aggregatedSpokeBalance

Hook for _aggregatedSpokeBalance — implemented in SpokeHandlersModule, called
cross-module from SpokeConfirmsModule._buildConfirmMessage.


```solidity
function _aggregatedSpokeBalance() internal view virtual returns (uint256 aggregatedSpokeBalance);
```

### _sendOrQueueConfirm

Hook for _sendOrQueueConfirm — implemented in SpokeConfirmsModule, called
cross-module from SpokeHandlersModule's four inbound message handlers
(_handleDeposit, _handleRebalance, _handleWithdrawalWithAmount, _reportBalance).


```solidity
function _sendOrQueueConfirm(CCIPHelpers.MessageType _type, bytes32 _messageId, uint256 _tokenAmount)
    internal
    virtual;
```

## Events
### AdapterSet
Emitted when a new adapter is registered or an existing one is updated


```solidity
event AdapterSet(bytes32 indexed protocolId, address indexed adapter);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`protocolId`|`bytes32`|The bytes32 identifier for the yield protocol|
|`adapter`|`address`|Address of the new IYieldSource adapter contract|

### AdapterRemoved
Emitted when an adapter is disabled via removeAdapter


```solidity
event AdapterRemoved(bytes32 indexed protocolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`protocolId`|`bytes32`|The bytes32 identifier of the disabled protocol|

### HubUpdated
Emitted when the Hub address is updated via setHub


```solidity
event HubUpdated(address indexed oldHub, address indexed newHub);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`oldHub`|`address`|Previous Hub address|
|`newHub`|`address`|New Hub address|

### DepositInstructionFailed
Emitted when a single DEPOSIT instruction is skipped instead of reverting

Skip reasons: zero amount, unknown/removed adapter, or adapter.deposit() reverted.
The instruction's amount is left as spoke idle — never lost, just undeployed.


```solidity
event DepositInstructionFailed(bytes32 indexed protocolId, uint256 amount, bytes reason);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`protocolId`|`bytes32`|The adapter identifier the instruction targeted|
|`amount`|`uint256`|The amount that was left idle|
|`reason`|`bytes`|Raw revert reason bytes, or a short ASCII literal for validation skips|

### RebalanceInstructionFailed
Emitted when a single REBALANCE instruction is skipped instead of reverting


```solidity
event RebalanceInstructionFailed(bytes32 indexed source, bytes32 indexed target, uint256 amount, bytes reason);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`source`|`bytes32`|The source adapter identifier|
|`target`|`bytes32`|The target adapter identifier|
|`amount`|`uint256`|The amount that could not be moved|
|`reason`|`bytes`|Raw revert reason bytes, or a short ASCII literal for validation skips|

### RecallShortfall
Emitted whenever a WITHDRAW_AMOUNT recall returns less than the hub requested


```solidity
event RecallShortfall(uint256 requested, uint256 actualPulled);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`requested`|`uint256`|The amount the hub asked for|
|`actualPulled`|`uint256`|The amount actually pulled from idle + adapters|

### RecallPullFailed
Emitted when a single adapter's pull fails during a WITHDRAW_AMOUNT recall

FX-6b. Min-capping (pullAmount <= adapter.totalAssets()) already prevents the
insufficient-balance revert; this covers the residual case — a protocol-level
condition (paused Aave pool, frozen Comet market) that still reverts withdraw()
regardless of the requested amount. That adapter's leg is skipped; the loop
continues with the remaining adapters, and the truthful actualPulled (via
RecallShortfall if short) still reaches the hub instead of stalling the whole
recall — the original Issue-1 shape this closes.


```solidity
event RecallPullFailed(bytes32 indexed adapter, uint256 attempted, bytes reason);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`adapter`|`bytes32`|The protocol identifier whose pull failed|
|`attempted`|`uint256`|The amount that was being pulled from it|
|`reason`|`bytes`|Raw revert reason bytes|

### ConfirmSendFailed
Emitted when an outbound confirm's ccipSend fails and is queued for retry


```solidity
event ConfirmSendFailed(uint256 indexed index, CCIPHelpers.MessageType messageType, bytes32 messageId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|Index into pendingConfirms where this record was stored|
|`messageType`|`CCIPHelpers.MessageType`|The message type that failed to send|
|`messageId`|`bytes32`|The messageId of the failed confirm|

### ConfirmRetried
Emitted when a queued confirm is successfully retried via retryConfirm


```solidity
event ConfirmRetried(uint256 indexed index);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|Index into pendingConfirms that was resolved|

### IdleDeployed
Emitted when owner deploys parked spoke idle into a registered adapter


```solidity
event IdleDeployed(bytes32 indexed protocolId, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`protocolId`|`bytes32`|The adapter identifier idle was deployed into|
|`amount`|`uint256`|The amount deployed|

## Structs
### AdapterInfo
Stores adapter contract and registration status for a yield protocol

`exists` differentiates unregistered (never seen) vs removed (was active, now disabled).
`everRegistered` is write-once — prevents duplicate entries in activeAdapters
when a protocol is removed then re-registered on the same protocolId.


```solidity
struct AdapterInfo {
    /// @dev The IYieldSource adapter contract for this protocol — address(0) if removed
    IYieldSource adapter;
    /// @dev True if adapter is currently active — false if disabled via removeAdapter
    bool exists;
    /// @dev True once a protocolId has been registered — never reset. Guards array deduplication.
    bool everRegistered;
}
```

### AdapterBalances
Snapshot of a single adapter's balance — returned by getAllocations()


```solidity
struct AdapterBalances {
    /// @dev The bytes32 protocol identifier (e.g. keccak256("AAVE"))
    bytes32 protocolId;
    /// @dev Current total USDC managed by this adapter including accrued yield
    uint256 balance;
}
```

### PendingConfirm
A confirm message whose outbound ccipSend failed and is queued for retry

WI-2d reconciliation record. Deliberately minimal — spokeBalance is NOT stored
here, it is recomputed fresh at retry time so a stale snapshot is never resent.


```solidity
struct PendingConfirm {
    /// @dev Which outbound message type this confirm is (CONFIRM_RECEIPT, CONFIRM_REBALANCE,
    ///      CONFIRM_WITHDRAWAL, or REPORT_BALANCE response)
    CCIPHelpers.MessageType messageType;
    /// @dev The messageId being confirmed — echoed from the originating hub message
    bytes32 messageId;
    /// @dev USDC amount to attach on retry — 0 for token-less confirms
    uint256 actualAmount;
    /// @dev True once successfully retried — resolved entries are inert
    bool resolved;
}
```

