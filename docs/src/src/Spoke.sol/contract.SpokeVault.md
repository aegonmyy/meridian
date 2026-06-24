# SpokeVault
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/Spoke.sol)

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
### HUB
Address of the HubVault on Ethereum — sole authorized CCIP message sender

Immutable — set once at deployment. Validated in _ccipReceive for every message.


```solidity
address public immutable HUB
```


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


## Functions
### constructor

Deploys the SpokeVault with immutable chain and protocol configuration

CCIPReceiver validates _router internally — no explicit check needed here.
Parent constructors run before the zero address checks in the body.
_hubSelector == 0 is rejected as it would make all outbound CCIP messages fail.


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


### _aggregatedSpokeBalance

Sums totalAssets() across all currently active adapters

Skips adapters where exists == false — removed adapters report zero balance.
Called before every outbound message to give hub an accurate spoke snapshot.
Value may lag slightly if adapters accrue yield between reports — accepted v1 tradeoff.


```solidity
function _aggregatedSpokeBalance() internal view returns (uint256 aggregatedSpokeBalance);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`aggregatedSpokeBalance`|`uint256`|Total USDC managed across all active adapters including yield|


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

