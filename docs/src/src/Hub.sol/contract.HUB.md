# HUB
[Git Source](https://github.com/aegonmyy/meridian/blob/04fdcb3887d6bfe7076e798735b94bee541e7ecf/src/Hub.sol)

**Inherits:**
ERC4626, CCIPReceiver, Ownable

**Title:**
HubVault

ERC4626 vault on Ethereum — entry point for all user deposits and withdrawals.
Users deposit USDC here and receive vault shares representing their proportional
ownership of all protocol-managed capital across all chains.

Inherits ERC4626, CCIPReceiver, and Ownable. Delegates capital deployment to
spoke vaults on L2s via Chainlink CCIP. Share price reflects total managed assets
across all spokes including yield accrued on deployed capital.
Only the Rebalancer contract can move capital between hub and spokes.
Withdrawals are asynchronous when capital is deployed — three paths exist:
Path 1 (sync): idle covers withdrawal and all spoke reports are fresh.
Path 2 (async): idle covers withdrawal but spoke reports are stale — refreshes first.
Path 3 (async): idle insufficient — recalls shortfall from best spoke via CCIP.


## Constants
### LINK
LINK token used to pay CCIP fees for all outbound messages

Immutable — set once at deployment. Hub must hold sufficient LINK balance.


```solidity
IERC20 public immutable LINK
```


### MAX_STALENESS
Maximum age of a spoke balance report before it is considered stale

Stale reports trigger Path 2 withdrawal — a REPORT_BALANCE refresh cycle.


```solidity
uint256 public constant MAX_STALENESS = 1 hours
```


## State Variables
### REBALANCER
Address of the Rebalancer contract — sole authorized caller for capital movement

Mutable to resolve circular deployment dependency between Hub and Rebalancer.
Use setRebalancer() after deployment. Protected by onlyOwner.


```solidity
address public REBALANCER
```


### spokeChainSelectors
Ordered list of all chain selectors ever registered as spokes

Soft-delete pattern — entries are never removed. Inactive spokes are
skipped during iteration via the `exists` flag on SpokeInfo.
Used to iterate spokeBalances in totalManagedAssets().


```solidity
uint64[] public spokeChainSelectors
```


### reservedAssets
Total USDC currently reserved for pending withdrawals

Prevents concurrent withdrawers from being promised the same idle balance.
Incremented when a withdrawal is queued, decremented on settlement.


```solidity
uint256 public reservedAssets
```


### spokes
Maps CCIP chain selector to spoke vault info for that chain


```solidity
mapping(uint64 => SpokeInfo) public spokes
```


### addressToSelector
Reverse mapping from spoke address to its registered chain selector

Enables O(1) lookup to prevent the same address being registered on two selectors.
Deleted when a spoke is removed or updated to a new address.


```solidity
mapping(address => uint64) public addressToSelector
```


### spokeBalances
Last reported total balance per spoke chain in USDC

Updated on every CONFIRM_RECEIPT, CONFIRM_REBALANCE, and REPORT_BALANCE message.
May be slightly stale between reports — staleness bounded by MAX_STALENESS.


```solidity
mapping(uint64 => uint256) public spokeBalances
```


### lastReportTimestamp
Unix timestamp of last balance report received per spoke

Compared against block.timestamp to determine staleness before processing withdrawals.
A spoke with timestamp 0 is treated as stale — triggers Path 2 withdrawal.


```solidity
mapping(uint64 => uint256) public lastReportTimestamp
```


### pendingWithdrawals
Pending withdrawals keyed by messageId awaiting async settlement

messageId is keccak256(receiver, timestamp) — unique per withdrawal per block.
Same-block collision is a known v1 limitation; nonce will be added in v2.


```solidity
mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals
```


### inTransitAssets
Total USDC currently in CCIP transit — sent to spoke but not yet confirmed

Incremented on DEPOSIT ccipSend, decremented on CONFIRM_RECEIPT callback.
Included in totalAssets() so share price is not deflated during transit.


```solidity
uint256 public inTransitAssets
```


### inTransitAmount
Maps CCIP messageId to the amount sent in that transit leg

Used to decrement inTransitAssets precisely on CONFIRM_RECEIPT.
Deleted after the callback is processed.


```solidity
mapping(bytes32 => uint256) public inTransitAmount
```


## Functions
### onlyRebalancer

Restricts access to the Rebalancer contract or hub itself

Hub uses `address(this)` when calling recallFromSpoke and _requestAllBalanceReports
internally via `this.functionName()` to change msg.sender context.
This is a temporary pattern — visibility will be tightened before mainnet.


```solidity
modifier onlyRebalancer() ;
```

### _onlyRebalancer

Extracted to reduce bytecode size from modifier inlining


```solidity
function _onlyRebalancer() internal view;
```

### constructor

Deploys HubVault with core configuration

Parent constructors run before the body — CCIPReceiver validates _router internally.
_rebalancer can be address(0) at deploy time and set later via setRebalancer()
to resolve the circular dependency between Hub and Rebalancer deployment.


```solidity
constructor(
    string memory _name,
    string memory _symbol,
    address _router,
    address _owner,
    address _link,
    address _asset,
    address _rebalancer
) ERC4626(IERC20(_asset)) Ownable(_owner) ERC20(_name, _symbol) CCIPReceiver(_router);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_name`|`string`|ERC20 share token name (e.g. "Meridian USDC")|
|`_symbol`|`string`|ERC20 share token symbol (e.g. "mUSDC")|
|`_router`|`address`|Chainlink CCIP router address on Ethereum|
|`_owner`|`address`|Contract owner — should be a multisig before mainnet deployment|
|`_link`|`address`|LINK token address used to pay CCIP fees|
|`_asset`|`address`|Underlying asset address (USDC)|
|`_rebalancer`|`address`|Rebalancer contract address — pass address(0) to set later|


### setRebalancer

Sets or updates the Rebalancer contract address

Only callable by owner. Allows post-deployment configuration to resolve
circular dependency — Hub needs Rebalancer address and vice versa.
No guard against re-setting — owner is trusted to manage this correctly.


```solidity
function setRebalancer(address _rebalancer) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_rebalancer`|`address`|New Rebalancer contract address|


### addSpoke

Registers a new spoke or updates an existing spoke's contract address

Uses `everRegistered` flag to prevent duplicate entries in spokeChainSelectors
when a selector is removed and re-added. The same address cannot be registered
on two different selectors simultaneously — enforced via addressToSelector reverse mapping.
On update: old address is invalidated, new address is mapped.


```solidity
function addSpoke(uint64 _chainSelector, address _spokeAddress) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector identifying the spoke chain|
|`_spokeAddress`|`address`|Address of the SpokeVault deployed on that chain|


### removeSpoke

Disables a spoke by setting its exists flag to false

Emergency mechanism — does not remove from spokeChainSelectors array.
Inactive spokes are skipped during iteration via the exists flag.
Also clears addressToSelector reverse mapping for the spoke address.


```solidity
function removeSpoke(uint64 _chainSelector) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the spoke to disable|


### isValidSpoke

Returns whether an address is currently a valid active spoke

Checks both the reverse mapping and the exists flag to guard against
stale entries where address was removed or updated.


```solidity
function isValidSpoke(address _spoke) public view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_spoke`|`address`|Address to check|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if _spoke is the currently registered active spoke for its selector|


### sendToSpoke

Sends USDC and deposit instructions to a spoke via CCIP

Only callable by Rebalancer. Encodes a DEPOSIT message — the only message type
that attaches USDC tokens to the CCIP transfer. Spoke deposits into adapters
and sends CONFIRM_RECEIPT back. inTransitAssets is incremented here and
decremented when CONFIRM_RECEIPT arrives.


```solidity
function sendToSpoke(uint64 _chainSelector, CCIPHelpers.AdapterInstructions[] memory _instructions)
    external
    onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the destination spoke|
|`_instructions`|`CCIPHelpers.AdapterInstructions[]`|Array of adapter instructions — protocol id and USDC amount per market|


### recallFromSpoke

Sends a recall instruction to a spoke to return funds to hub via CCIP

Only callable by Rebalancer or hub itself (via this.recallFromSpoke in _withdraw).
Sends a WITHDRAW_AMOUNT message — instruction only, no tokens attached outbound.
Spoke pulls proportionally from its adapters and sends tokens back via CCIP.
Used in Path 3 withdrawals to retrieve the shortfall not covered by idle.


```solidity
function recallFromSpoke(
    uint64 _chainSelector,
    CCIPHelpers.AdapterInstructions[] memory _instructions,
    bytes32 _messageId
) external onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the target spoke|
|`_instructions`|`CCIPHelpers.AdapterInstructions[]`|Single instruction with adapter=bytes32(0) and amount=shortfall|
|`_messageId`|`bytes32`|Matches the pendingWithdrawal entry so callback can settle correctly|


### rebalance

Sends intra-spoke rebalance instructions to move capital between adapters

Only callable by Rebalancer. Sends a REBALANCE message — instruction only,
no tokens attached. Spoke withdraws from source adapter and deposits into target
adapter on the same chain. No capital leaves the spoke chain.
Spoke responds with CONFIRM_REBALANCE carrying updated spoke balance.


```solidity
function rebalance(
    uint64 _chainSelector,
    CCIPHelpers.AdapterInstructions[] memory _instructions,
    bytes32 _messageId
) external onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the target spoke|
|`_instructions`|`CCIPHelpers.AdapterInstructions[]`|Array specifying source adapter, target adapter, and amount to move|
|`_messageId`|`bytes32`|Unique identifier for this rebalance operation|


### _deposit

Overrides ERC4626._deposit — no additional logic needed beyond standard behaviour

totalPrincipal tracking was removed as it was dead state — totalAssets() via
totalManagedAssets() is the source of truth for share pricing.


```solidity
function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|Address initiating the deposit|
|`receiver`|`address`|Address receiving the minted shares|
|`assets`|`uint256`|Amount of USDC being deposited|
|`shares`|`uint256`|Amount of vault shares being minted|


### _withdraw

Overrides ERC4626._withdraw to implement three-path async withdrawal

Shares are transferred to hub at start and only burned on final settlement.
No super() call — full flow is owned here.
messageId = keccak256(receiver, timestamp) — same-block collision is a known
v1 limitation; a nonce will be added in v2.
Path 1 (sync): idle >= assets AND all spokes fresh → immediate settlement.
Path 2 (async): idle >= assets AND any spoke stale → queue + REPORT_BALANCE.
Path 3 (async): idle < assets → reserve idle, recall shortfall from best spoke.


```solidity
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    internal
    override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|Address initiating the withdrawal (may differ from owner if approved)|
|`receiver`|`address`|Address to receive the USDC|
|`owner`|`address`|Address whose shares are being redeemed|
|`assets`|`uint256`|Ignored — recalculated internally via previewRedeem(shares)|
|`shares`|`uint256`|Number of shares to burn|


### _processWithdrawal

Settles a withdrawal by burning shares and transferring USDC to receiver

Called directly for Path 1 (sync) and from CCIP callbacks for Path 2 and 3.
Decrements reservedAssets by exactly the amount that was reserved at queue time
— handles all three paths correctly regardless of partial idle reservation.


```solidity
function _processWithdrawal(
    address owner,
    address receiver,
    uint256 shares,
    uint256 assets,
    uint256 _reservedAssets,
    bytes32 _messageId
) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner`|`address`|Address whose shares are burned|
|`receiver`|`address`|Address receiving the USDC|
|`shares`|`uint256`|Number of shares to burn from hub's escrow balance|
|`assets`|`uint256`|Amount of USDC to transfer to receiver|
|`_reservedAssets`|`uint256`|Amount to decrement from reservedAssets (set at queue time)|
|`_messageId`|`bytes32`|MessageId emitted in WithdrawalProcessed for off-chain tracking|


### _requestAllBalanceReports

Broadcasts REPORT_BALANCE requests to all active spokes

Called in Path 2 when spoke balances are stale. Each spoke responds
asynchronously with a REPORT_BALANCE message carrying its current balance.
Marked public with onlyRebalancer so hub can call via this.functionName()
to update msg.sender context. Will be refactored to internal before mainnet.


```solidity
function _requestAllBalanceReports(bytes32 _messageId) public onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_messageId`|`bytes32`|Forwarded to spokes so responses can be matched to the pending withdrawal|


### _findBestSpoke

Returns the chain selector of the spoke with the highest reported balance

Used in Path 3 to select which spoke to recall from. spokeBalances may be
slightly stale but safe — balances only decrease via user-triggered recalls,
so the selected spoke will always have at least as much as reported.


```solidity
function _findBestSpoke() internal view returns (uint64 bestSelector);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bestSelector`|`uint64`|Chain selector of the spoke with the highest reported USDC balance|


### _sendToSpoke

Encodes and dispatches a CCIP message to a spoke vault

Handles all outbound message types. Only DEPOSIT messages attach USDC tokens —
all other types (WITHDRAW_AMOUNT, REBALANCE, REPORT_BALANCE) carry instructions only.
REBALANCE messages use a higher gasLimit (1_000_000) to accommodate multiple
adapter operations in a single message. All others use 500_000.
Hub must hold sufficient LINK to pay the CCIP fee.


```solidity
function _sendToSpoke(uint64 _chainSelector, CCIPHelpers.CcipMessage memory _message) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|Destination chain selector|
|`_message`|`CCIPHelpers.CcipMessage`|Fully populated CcipMessage to encode and send|


### _messageIdForWithdrawal


```solidity
function _messageIdForWithdrawal(address receiver) internal view returns (bytes32);
```

### totalAssets

Returns total protocol assets per ERC4626 standard

Overrides ERC4626.totalAssets(). Delegates to totalManagedAssets() which
aggregates idle + in-transit + all spoke balances. Share price reflects
real yield-inclusive value as spokes report updated balances.


```solidity
function totalAssets() public view override returns (uint256);
```

### totalManagedAssets

Aggregates total USDC managed across hub and all active spokes

Returns idle only when no spokes registered — inTransitAssets is always
zero in that state so one SLOAD is saved.
Spoke balances may lag by up to MAX_STALENESS between reports — this is
by design and accepted as a v1 tradeoff.


```solidity
function totalManagedAssets() internal view returns (uint256 total);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`total`|`uint256`|Sum of idle USDC on hub + in-transit USDC + all active spoke balances|


### _ccipReceive

Entry point for all incoming CCIP messages from registered spokes

Validates sender is a registered active spoke before processing.
Routes to the appropriate internal handler based on message type:
CONFIRM_WITHDRAWAL → _handleWithdrawalCallback (funds arrived from spoke)
REPORT_BALANCE     → _handleReportBalanceCallback (spoke reports balance)
CONFIRM_RECEIPT    → _handleDepositCallback (spoke confirms deposit)
CONFIRM_REBALANCE  → _handleRebalanceCallback (spoke confirms intra-rebalance)


```solidity
function _ccipReceive(Client.Any2EVMMessage memory message) internal override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`message`|`Client.Any2EVMMessage`|Raw CCIP message delivered by the Chainlink router|


### _idleBalance

Returns the USDC balance sitting idle on hub — not deployed or in transit


```solidity
function _idleBalance() internal view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Idle USDC balance of this contract|


### _allSpokesFresh

Checks whether all active spoke balance reports are within MAX_STALENESS

Returns false if no spokes are registered — safe default that prevents
Path 1 from triggering when there is nothing to be fresh about.
A spoke with lastReportTimestamp == 0 is always considered stale.


```solidity
function _allSpokesFresh() internal view returns (bool);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True only if every active spoke has reported within the last MAX_STALENESS seconds|


### _handleRebalanceCallback

Handles CONFIRM_REBALANCE from spoke — updates balance after intra-spoke rebalance

No pending withdrawal involved — just updates accounting.
Spoke sends this after successfully moving capital between adapters.


```solidity
function _handleRebalanceCallback(CCIPHelpers.CcipMessage memory _message, uint64 _chainSelector) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message carrying updated spokeBalance and reportTimestamp|
|`_chainSelector`|`uint64`|Source chain selector identifying which spoke sent the message|


### _handleDepositCallback

Handles CONFIRM_RECEIPT from spoke — confirms deposit and clears inTransit

Spoke sends this after depositing received USDC into adapters.
Decrements inTransitAssets by the tracked amount for this messageId.


```solidity
function _handleDepositCallback(CCIPHelpers.CcipMessage memory _message, uint64 _chainSelector) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message carrying updated spokeBalance and reportTimestamp|
|`_chainSelector`|`uint64`|Source chain selector identifying which spoke sent the message|


### _handleReportBalanceCallback

Handles REPORT_BALANCE from spoke — updates balance and settles pending Path 2 withdrawal

Spoke sends this in response to a REPORT_BALANCE request from hub.
If a pending withdrawal exists for this messageId it is settled immediately
since idle was already reserved and balances are now confirmed fresh.


```solidity
function _handleReportBalanceCallback(CCIPHelpers.CcipMessage memory _message, uint64 _chainSelector) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message carrying updated spokeBalance and reportTimestamp|
|`_chainSelector`|`uint64`|Source chain selector identifying which spoke sent the message|


### _handleWithdrawalCallback

Handles CONFIRM_WITHDRAWAL from spoke — funds arrived, settles pending Path 3 withdrawal

Spoke sends this after pulling funds from adapters and transferring USDC back to hub.
By the time this fires, the shortfall USDC has arrived at hub. Combined with
the idle that was reserved at queue time, hub has enough to settle the withdrawal.


```solidity
function _handleWithdrawalCallback(CCIPHelpers.CcipMessage memory _message, uint64 _chainSelector) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message carrying updated spokeBalance and reportTimestamp|
|`_chainSelector`|`uint64`|Source chain selector identifying which spoke sent the message|


### spokeChainSelectorsLength

Returns the length of the spokeChainSelectors array

Includes inactive (removed) spokes — length only grows, never shrinks.
Use spokes[selector].exists to check active status.


```solidity
function spokeChainSelectorsLength() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Length of the spokeChainSelectors array|


## Events
### WithdrawalQueued
Emitted when a withdrawal cannot be settled immediately and is queued


```solidity
event WithdrawalQueued(address indexed owner, uint256 shares, uint256 assets, uint256 _reservedAssets);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner`|`address`|Address whose shares are held in escrow by hub|
|`shares`|`uint256`|Number of shares transferred to hub and locked|
|`assets`|`uint256`|Full USDC value owed to the withdrawer on settlement|
|`_reservedAssets`|`uint256`|Amount of idle USDC reserved at queue time (0 if none available)|

### WithdrawalProcessed
Emitted when a queued or synchronous withdrawal is fully settled


```solidity
event WithdrawalProcessed(address indexed owner, address indexed receiver, uint256 assets, bytes32 messageId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner`|`address`|Address whose shares were burned|
|`receiver`|`address`|Address that received the USDC|
|`assets`|`uint256`|Amount of USDC transferred to receiver|
|`messageId`|`bytes32`|The messageId that keyed this withdrawal in pendingWithdrawals|

### SpokeAdded
Emitted when a new spoke is registered or an existing spoke address is updated


```solidity
event SpokeAdded(uint64 indexed spokeSelector, address indexed spokeAddress);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`spokeSelector`|`uint64`|CCIP chain selector of the spoke chain|
|`spokeAddress`|`address`|Address of the SpokeVault contract on that chain|

### SpokeRemoved
Emitted when a spoke is disabled via removeSpoke


```solidity
event SpokeRemoved(uint64 indexed spokeSelector);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`spokeSelector`|`uint64`|CCIP chain selector of the disabled spoke|

### SpokeBalanceUpdated
Emitted whenever a spoke reports its current total balance to hub

Fired on CONFIRM_RECEIPT, CONFIRM_REBALANCE, and REPORT_BALANCE callbacks


```solidity
event SpokeBalanceUpdated(uint64 indexed chainSelector, uint256 balance);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|Chain selector of the reporting spoke|
|`balance`|`uint256`|Updated total balance reported by the spoke in USDC|

## Structs
### PendingWithdrawal
Tracks a queued withdrawal awaiting spoke balance confirmation or fund recall

Created in Path 2 (stale balances) and Path 3 (insufficient idle).
`_reservedAssets` tracks how much idle was locked at queue time so
`reservedAssets` can be decremented precisely on settlement regardless of path.
Path 1: no pending withdrawal created — settled synchronously.
Path 2: `_reservedAssets == assets` — full idle reservation.
Path 3: `_reservedAssets == idle` — partial reservation, remainder recalled from spoke.


```solidity
struct PendingWithdrawal {
    /// @dev Shares transferred to hub contract at queue time — burned on settlement
    uint256 shares;
    /// @dev Full asset value owed to the withdrawer
    uint256 assets;
    /// @dev Block timestamp when withdrawal was queued
    uint256 requestedAt;
    /// @dev Address that will receive the USDC on settlement
    address receiver;
    /// @dev Address whose shares were transferred to hub
    address owner;
    /// @dev Amount of idle USDC reserved at queue time — 0 if no idle was available
    uint256 _reservedAssets;
}
```

### SpokeInfo
Stores spoke vault address and registration status for a chain

`exists` is the source of truth for active status — false means disabled.
`everRegistered` is write-once — prevents duplicate entries in spokeChainSelectors
when a spoke is removed then re-added on the same selector.


```solidity
struct SpokeInfo {
    /// @dev Address of the SpokeVault contract on the target chain
    address spoke;
    /// @dev True if spoke is currently active — false if disabled via removeSpoke
    bool exists;
    /// @dev True once a selector has been registered — never reset. Guards array deduplication.
    bool everRegistered;
}
```

