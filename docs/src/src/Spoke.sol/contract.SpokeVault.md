# SpokeVault
[Git Source](https://github.com/aegonmyy/meridian/blob/8f085e328b747676203173bc0d1ecf2a95d5e520/src/Spoke.sol)

**Inherits:**
CCIPReceiver, Ownable

**Title:**
SpokeVault

Receives CCIP instructions from the HubVault and manages capital deployment
into yield protocols (Aave, Compound, Morpho) on a single L2 chain.

Deployed once per supported L2 chain (Arbitrum, Base, Optimism).
Only the HubVault on Ethereum can send instructions to this contract via CCIP —
all other senders are rejected. Users never interact with this contract directly.
Capital flow: Hub sends DEPOSIT → spoke deploys into adapters → spoke reports balance back.
Four inbound message types: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT.
Four outbound message types: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL.


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


### setAdapter

Registers a new yield adapter or updates the contract address of an existing one

Uses `everRegistered` to prevent duplicate protocolId entries in activeAdapters
when a protocol is removed then re-added. On first registration protocolId is
pushed to activeAdapters. On update only the adapter address changes.
Uses forceApprove pattern — adapter contracts may require non-zero allowance resets.


```solidity
function setAdapter(bytes32 _protocolId, address _adapter) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_protocolId`|`bytes32`|Arbitrary bytes32 identifier for the protocol (e.g. keccak256("AAVE"))|
|`_adapter`|`address`|Address of the IYieldSource adapter implementing deposit/withdraw/totalAssets|


### removeAdapter

Disables a yield adapter by setting its exists flag to false

Emergency mechanism — instantly stops capital from being deployed to this protocol.
Does not remove the protocolId from activeAdapters — inactive entries are skipped
during iteration via the exists flag. No timelock in v1 — owner is trusted.
Capital already deployed to this adapter is NOT automatically withdrawn.
A separate WITHDRAW_AMOUNT instruction from hub is needed to reclaim funds.


```solidity
function removeAdapter(bytes32 _protocolId) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_protocolId`|`bytes32`|The bytes32 identifier of the protocol to disable|


### setHub

Updates the Hub address — use when Hub is redeployed with new features

All subsequent CCIP messages will only be accepted from the new Hub address.
Pending in-flight messages from the old Hub will be rejected on arrival.
Ensure no critical messages are in-flight before calling.

WI-6 guard: reverts while any pendingConfirms entry is unresolved. A confirm
queued under the old Hub relationship (messageId semantics, expected sender)
could resolve incorrectly — or not at all — after HUB is repointed. Resolve or
wait out every queued confirm via retryConfirm() before rotating Hub.


```solidity
function setHub(address _hub) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_hub`|`address`|New HubVault address on Ethereum|


### deployIdle

Deploys parked spoke idle USDC into a registered adapter

v1: onlyOwner. Spoke idle can accumulate from partial DEPOSIT skips (WI-2c),
shortfalls left over after a WITHDRAW_AMOUNT recall, or direct transfers.
This lets an operator redeploy that idle instead of it sitting unproductively.
Races with retryConfirm() on token-carrying confirms — see ConfirmFundsUnavailable.


```solidity
function deployIdle(bytes32 _protocolId, uint256 _amount) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_protocolId`|`bytes32`|Target adapter identifier — must be currently registered and active|
|`_amount`|`uint256`|Amount of spoke idle USDC to deposit|


### retryConfirm

Retries a previously-failed confirm send

Permissionless — anyone can pay gas to unstick the queue. Rebuilds the confirm
message fresh (spokeBalance recomputed at call time, not from the failure moment)
and resends. Token-carrying confirms re-verify the USDC is still held by this
contract — if deployIdle() redeployed it in the interim, this reverts with
ConfirmFundsUnavailable rather than attempting to send tokens the spoke no longer
holds (WI-2d's documented conservative choice for the retryConfirm/deployIdle race).


```solidity
function retryConfirm(uint256 index) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|Index into pendingConfirms to retry|


### _ccipReceive

Entry point for all incoming CCIP messages from the HubVault

Overrides CCIPReceiver._ccipReceive. Router authenticity is checked by the
base CCIPReceiver contract before this function is called.
Hub origin is validated by decoding message.sender and comparing to HUB.
Routes to the correct internal handler based on CCIPHelpers.MessageType:
DEPOSIT          → _handleDeposit (deploy USDC into adapters)
REBALANCE        → _handleRebalance (move capital between adapters)
REPORT_BALANCE   → _reportBalance (respond with current aggregated balance)
WITHDRAW_AMOUNT  → _handleWithdrawalWithAmount (pull funds and send back to hub)


```solidity
function _ccipReceive(Client.Any2EVMMessage memory message) internal override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`message`|`Client.Any2EVMMessage`|The raw CCIP message struct delivered by the Chainlink router|


### _handleDeposit

Handles DEPOSIT — deploys received USDC into specified yield adapters

Iterates instructions array depositing into each specified adapter.
Allocation validation (bps constraints, chain cap, dust floor) is enforced
upstream in the Rebalancer contract before the message is sent — not repeated here.
After depositing, sends CONFIRM_RECEIPT back to hub carrying the new aggregated
spoke balance so hub can update spokeBalances[] and decrement inTransitAssets.
Uses forceApprove to handle USDT-like tokens that revert on non-zero allowance.

WI-2c: instructions are no longer all-or-nothing. Because the DEPOSIT's tokens
arrive as a single lump-sum CCIP transfer covering every instruction's amount
combined, a hard revert on one bad instruction would roll back the whole transfer
and strand every valid instruction's amount in CCIP limbo too (see docs/revert-audit.md
#5-#7). Each instruction is now independently attempted: zero amount, an unknown/
removed adapter, or a reverting adapter.deposit() call are all skipped with a
DepositInstructionFailed event, leaving that instruction's amount as spoke idle
(which _aggregatedSpokeBalance now counts, so hub accounting stays exact — WI-2b).
The outbound CONFIRM_RECEIPT itself never hard-reverts the handler either — see
_sendOrQueueConfirm (WI-2d).


```solidity
function _handleDeposit(CCIPHelpers.CcipMessage memory _message) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message containing adapter instructions with protocol ids and amounts|


### _handleRebalance

Handles REBALANCE — moves capital between adapters on this spoke chain

Intra-spoke operation — no USDC leaves this chain. Withdraws from source adapter
and deposits into target adapter for each instruction in the message.
Both source and target adapters must be registered and active.
After rebalancing, sends CONFIRM_REBALANCE back to hub carrying updated spoke balance
so hub can refresh spokeBalances[] and lastReportTimestamp[].
Note: the @dev comment in the original incorrectly described this as a withdrawal —
this handler does NOT send tokens back to hub.

WI-2c: no CCIP tokens are attached to REBALANCE, but the loop performs real
adapter.withdraw/deposit calls — a hard revert on one bad instruction would
unwind an earlier instruction's already-executed move within the same call frame
and permanently block the CONFIRM_REBALANCE the hub is waiting on for a balance
refresh (docs/revert-audit.md #10-#13). Each instruction is now independently
attempted: zero amount, unknown/removed adapter, or a reverting withdraw/deposit
call are skipped with a RebalanceInstructionFailed event. The source pull is
clamped to the source adapter's real balance to remove the most common revert
cause outright.


```solidity
function _handleRebalance(CCIPHelpers.CcipMessage memory _message) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message with instructions specifying source adapter, target adapter, and amount to move for each operation|


### _handleWithdrawalWithAmount

Handles WITHDRAW_AMOUNT — pulls requested USDC from adapters and sends back to hub

Called during Path 3 hub withdrawals when hub idle is insufficient to cover a user
withdrawal. Hub sends the shortfall amount — spoke pulls proportionally from all
active adapters weighted by their current balance, then sends the USDC back to hub
via a programmable token transfer (CONFIRM_WITHDRAWAL + tokens attached).
Proportional withdrawal preserves allocation ratios across adapters.
Last adapter receives remainder to avoid dust from integer division.
Hub uses messageId in CONFIRM_WITHDRAWAL to match the pending withdrawal and settle it.

WI-2b/2c rewrite. Spoke idle is drained first (up to the full request), then any
remaining shortfall is pulled proportionally from active adapters. Each adapter
pull is capped at that adapter's real totalAssets() — including the last adapter's
remainder — which removes both the exact-full-recall wei-overflow revert and the
Morpho mulDivDown-report-vs-round-up-withdraw mismatch by construction (never asks
an adapter for more than it reports holding). The division-by-zero on an empty
spoke is guarded. The CCIP token amount and RecallShortfall event always reflect
the truthful actualPulled, never the hub's requested amount — the hub must trust
only the delivered token envelope (destTokenAmounts), consistent with WI-4.
If actualPulled == 0 a token-less CONFIRM_WITHDRAWAL is still sent so the hub
learns the true state instead of waiting forever on a message that never comes.
FX-6b: each adapter's withdraw() is now wrapped in try/catch. Min-capping already
prevents the insufficient-balance revert, but not a protocol-level condition
(paused Aave pool, frozen Comet market) that still reverts regardless of amount
— without the wrap, that hard-reverted the whole handler, no confirm was ever
sent, and the hub's withdrawal stalled exactly like the original Issue-1 shape.
On failure: skip that adapter's leg (emit RecallPullFailed), continue the loop,
and let the already-truthful actualPulled confirm report whatever was pulled.


```solidity
function _handleWithdrawalWithAmount(CCIPHelpers.CcipMessage memory _message) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message with single instruction — amount is the shortfall to recall|


### _reportBalance

Handles REPORT_BALANCE — responds to hub's balance refresh request

Called during Path 2 hub withdrawals when spoke reports are stale.
Hub sends REPORT_BALANCE carrying a messageId matching the queued pending withdrawal.
Spoke responds with current aggregated balance so hub can update spokeBalances[],
refresh lastReportTimestamp[], and settle the pending withdrawal.
No tokens are moved — this is an accounting-only message.


```solidity
function _reportBalance(CCIPHelpers.CcipMessage memory _message) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message — messageId is forwarded back to hub for withdrawal matching|


### _buildConfirmMessage

Builds the outbound CCIP message for any confirm/report type

spokeBalance is always computed fresh at call time — critical for retryConfirm,
which must never resend a stale snapshot from the moment of original failure.
Instructions are always empty for confirm messages: none of the hub-side handlers
read the instructions field on a confirm — settlement trusts only the token
envelope (destTokenAmounts) and spokeBalance, consistent with WI-4's "trust the
token envelope, never the payload's claimed amount."


```solidity
function _buildConfirmMessage(CCIPHelpers.MessageType _type, bytes32 _messageId, uint256 _tokenAmount)
    internal
    view
    returns (Client.EVM2AnyMessage memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_type`|`CCIPHelpers.MessageType`|The outbound message type|
|`_messageId`|`bytes32`|The messageId being confirmed/reported|
|`_tokenAmount`|`uint256`|USDC to attach — 0 for token-less messages|


### _sendOrQueueConfirm

Attempts to send a confirm/report message; queues it for retry on failure

WI-2d. This is the mechanism that prevents a LINK-exhaustion or router failure
on the outbound leg from rolling back the fund-touching work already done in the
calling handler (docs/revert-audit.md #8, #14, #19, #20). getFee and ccipSend are
both external calls, wrapped in try/catch — any failure degrades to a queued
PendingConfirm + ConfirmSendFailed event rather than reverting.
NatSpec-documented observability contract: the hub cannot observe a spoke-side
failure it was never told about. This queue plus its events, together with
permissionless retryConfirm(), IS the observability contract — the WI-5 hub-side
per-message transit reconciliation is the last resort if a confirm truly never
lands (e.g. spoke abandoned).


```solidity
function _sendOrQueueConfirm(CCIPHelpers.MessageType _type, bytes32 _messageId, uint256 _tokenAmount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_type`|`CCIPHelpers.MessageType`|The outbound message type|
|`_messageId`|`bytes32`|The messageId being confirmed/reported|
|`_tokenAmount`|`uint256`|USDC to attach — 0 for token-less messages|


### _queueConfirm

Persists a failed confirm send for later retry


```solidity
function _queueConfirm(CCIPHelpers.MessageType _type, bytes32 _messageId, uint256 _tokenAmount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_type`|`CCIPHelpers.MessageType`|The outbound message type|
|`_messageId`|`bytes32`|The messageId being confirmed/reported|
|`_tokenAmount`|`uint256`|USDC to attach on retry — 0 for token-less messages|


### _aggregatedSpokeBalance

Sums spoke idle USDC plus totalAssets() across all currently active adapters

WI-2b: idle is first-class. A direct USDC transfer, or leftover from a partial
DEPOSIT skip / WITHDRAW_AMOUNT shortfall, is now counted — previously invisible
to the hub. Skips adapters where exists == false — removed adapters report zero.
Called before every outbound message to give hub an accurate spoke snapshot.
Value may lag slightly if adapters accrue yield between reports — accepted v1 tradeoff.


```solidity
function _aggregatedSpokeBalance() internal view returns (uint256 aggregatedSpokeBalance);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`aggregatedSpokeBalance`|`uint256`|Idle USDC plus total USDC managed across all active adapters|


### pendingConfirmsLength

Returns the length of the pendingConfirms array


```solidity
function pendingConfirmsLength() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Length of the pendingConfirms array|


### getAllocations

Returns a snapshot of each registered adapter's current balance

Array length always equals activeAdapters.length — includes removed adapters
as zero-initialized entries (protocolId == bytes32(0), balance == 0).
Callers should filter by protocolId != bytes32(0) to skip removed entries.
Off-chain agents use this to observe current allocation before proposing rebalances.


```solidity
function getAllocations() external view returns (AdapterBalances[] memory balances);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`balances`|`AdapterBalances[]`|Array of AdapterBalances structs ordered by registration sequence|


### activeAdaptersLength

Returns the length of the activeAdapters array

Includes removed adapters — length only grows, never shrinks.
Use adapters[id].exists to check whether a specific adapter is still active.


```solidity
function activeAdaptersLength() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Length of the activeAdapters array|


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

