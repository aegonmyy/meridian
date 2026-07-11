# HubMessagingModule
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/hub/HubMessagingModule.sol)

**Inherits:**
[HubStorage](/src/hub/HubStorage.sol/abstract.HubStorage.md)

**Title:**
HubMessagingModule

CCIP outbound dispatch (Rebalancer-facing sendToSpoke/recallFromSpoke/rebalance) and
inbound CCIP callback handling (_ccipReceive routing + the four confirm/report
handlers), plus the single choke point (_applyReportedBalance) every balance-
carrying callback routes through.

R-3 of the Hub modularization. Sibling to HubAdminModule and HubWithdrawalModule — all
three inherit HubStorage directly and none inherit each other.
Implements 3 hooks declared in HubStorage (bodiless `virtual`, `override` here):
_newMessageId (called cross-module from HubWithdrawalModule._withdraw),
_requestAllBalanceReports (called cross-module via `this._requestAllBalanceReports(...)`
from HubWithdrawalModule._withdraw's Path 2), and the 3-arg recallFromSpoke overload
(called cross-module via `this.recallFromSpoke(...)` from
HubWithdrawalModule._withdraw's Path 3 leg dispatch).
Calls 2 hooks implemented in HubWithdrawalModule: _idleBalance (sendToSpoke,
idleBalance) and _allSpokesFresh (_handleReportBalanceCallback). Also calls
isValidSpoke, implemented in HubAdminModule (hook declared in HubStorage since R-2).


## Functions
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

Only callable by hub itself, via this.recallFromSpoke in _withdraw's Path 3.
Sends a WITHDRAW_AMOUNT message — instruction only, no tokens attached outbound.
Spoke pulls proportionally from its adapters and sends tokens back via CCIP.
The messageId here matches an existing pendingWithdrawals entry so the arrival
callback can settle it — this is what distinguishes this overload from the
Rebalancer-driven one below, which creates no pendingWithdrawal and therefore
must not accept a caller-supplied id (WI-1 ids are always hub-derived when there
is nothing external to match against).


```solidity
function recallFromSpoke(
    uint64 _chainSelector,
    CCIPHelpers.AdapterInstructions[] memory _instructions,
    bytes32 _messageId
) external override onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the target spoke|
|`_instructions`|`CCIPHelpers.AdapterInstructions[]`|Single instruction with adapter=bytes32(0) and amount=shortfall|
|`_messageId`|`bytes32`|Matches the pendingWithdrawal entry so callback can settle correctly|


### recallFromSpoke

Rebalancer-driven recall — moves capital off an overweight spoke with no
pendingWithdrawal attached; the arrived tokens simply become hub idle

WI-3 (Issue 5, Option A). This is the missing "move weight off a chain" lever —
without it the only way capital left a spoke was via a user-triggered Path 3
withdrawal. The hub derives its own fresh id via _newMessageId (WI-1); callers
never supply one, since there is no pendingWithdrawal to match against.
Intended v1 operator flow (see Rebalancer.recallFromSpoke NatSpec for the full
sequence): off-chain diff → recallFromSpoke per overweight chain → await
RecallCompleted → proposeAllocation sized to the now-idle funds. The on-chain
diff engine that would automate this sequencing is explicitly out of scope (v2).


```solidity
function recallFromSpoke(uint64 _chainSelector, uint256 _amount) external onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the spoke to recall from|
|`_amount`|`uint256`|USDC amount to recall — must be nonzero|


### idleBalance

Returns the USDC balance sitting idle on hub — not deployed or in transit

External view mirror of _idleBalance(), exposed so Rebalancer can pre-check
solvency before dispatching a proposal (WI-3 friendly pre-check).


```solidity
function idleBalance() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Idle USDC balance of this contract|


### rebalance

Sends intra-spoke rebalance instructions to move capital between adapters

Only callable by Rebalancer. Sends a REBALANCE message — instruction only,
no tokens attached. Spoke withdraws from source adapter and deposits into target
adapter on the same chain. No capital leaves the spoke chain.
Spoke responds with CONFIRM_REBALANCE carrying updated spoke balance.
The message id is derived internally via the nonce'd _newMessageId helper —
callers no longer supply one (removed in WI-1 to eliminate id collisions).


```solidity
function rebalance(uint64 _chainSelector, CCIPHelpers.AdapterInstructions[] memory _instructions)
    external
    onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the target spoke|
|`_instructions`|`CCIPHelpers.AdapterInstructions[]`|Array specifying source adapter, target adapter, and amount to move|


### _requestAllBalanceReports

Broadcasts REPORT_BALANCE requests to all active spokes

Called in Path 2 when spoke balances are stale. Each spoke responds
asynchronously with a REPORT_BALANCE message carrying its current balance.
Marked public with onlyRebalancer so hub can call via this.functionName()
to update msg.sender context. Will be refactored to internal before mainnet.


```solidity
function _requestAllBalanceReports(bytes32 _messageId) public override onlyRebalancer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_messageId`|`bytes32`|Forwarded to spokes so responses can be matched to the pending withdrawal|


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


### _newMessageId

Derives a collision-free internal message id from a monotonic nonce

Every id is unique across the hub's lifetime — the incrementing nonce
guarantees no two operations (deposits, withdrawals, rebalances, recalls)
ever share an id, even within a single block. The additional context,
chainid, and address inputs harden the id against cross-contract reuse.


```solidity
function _newMessageId(bytes32 context) internal override returns (bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`context`|`bytes32`|Caller-supplied disambiguator (e.g. selector or receiver)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`|A unique bytes32 message id|


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


### _applyReportedBalance

Applies (or quarantines) a spoke's self-reported balance — the single choke
point every balance-carrying callback routes through

WI-7 (Issue 7b, Option A). Upside-only sanity band: accept if
`reported <= netSentToSpoke[selector] * (10000 + MAX_YIELD_BPS) / 10000 + REPORT_DUST`.
Under-reporting always passes — it deflates share price, the safe direction —
but a drop exceeding LOSS_ALERT_BPS since the last report emits an informational
event. On breach: NEVER clamp (clamping corrupts pricing the other direction) —
quarantine instead. spokeBalances is left untouched, the report is stored in
quarantinedReports, SuspiciousSpokeReport fires, and deposits/withdrawals pause.
This function itself never reverts — callers include token-carrying CCIP arrival
paths (CONFIRM_WITHDRAWAL) that must still deliver their tokens and settle
regardless of whether the reported BALANCE passes the band.


```solidity
function _applyReportedBalance(uint64 _chainSelector, uint256 reported) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|The reporting spoke's chain selector|
|`reported`|`uint256`|The spoke's self-reported aggregate balance|


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

Handles REPORT_BALANCE from spoke — updates balance and attempts to settle a
pending Path 2 withdrawal once ALL active spokes are fresh

Spoke sends this in response to a REPORT_BALANCE request from hub. WI-4 fix:
previously settled on the FIRST spoke's report even with other spokes still
stale — now gated on _allSpokesFresh() so settlement uses a fully-refreshed
balance picture. Settlement itself is via attemptSettlement (claim-time pricing,
non-reverting), wrapped in try/catch so an external-call failure inside
settlement (e.g. safeTransfer to an incompatible receiver) can never revert this
CCIP execution.


```solidity
function _handleReportBalanceCallback(CCIPHelpers.CcipMessage memory _message, uint64 _chainSelector) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message carrying updated spokeBalance and reportTimestamp|
|`_chainSelector`|`uint64`|Source chain selector identifying which spoke sent the message|


### _handleWithdrawalCallback

Handles CONFIRM_WITHDRAWAL from spoke — funds arrived. Three cases:
(1) a live Path 3 recall leg — credit the arrival and attempt settlement;
(2) an orphaned leg (withdrawal was cancelled, or its entry is otherwise gone)
— funds become ordinary idle, informational event only;
(3) never a leg at all — a WI-3 Rebalancer-driven recall, funds become idle

Spoke sends this after pulling funds from adapters and transferring USDC back to
hub. actualAmount is read from destTokenAmounts (the CCIP token envelope) — the
ground truth of what arrived — never from the payload, which carries no amount
for confirm messages post-WI-2 (see docs/revert-audit.md). legToWithdrawal
disambiguates case (2) from (3): a leg id is always registered at dispatch time,
so `legToWithdrawal[id] != 0` proves this WAS a leg (case 1/2); a fresh WI-3 id
was never registered as a leg (case 3).


```solidity
function _handleWithdrawalCallback(
    CCIPHelpers.CcipMessage memory _message,
    uint64 _chainSelector,
    Client.EVMTokenAmount[] memory destTokenAmounts
) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_message`|`CCIPHelpers.CcipMessage`|Decoded CCIP message carrying updated spokeBalance and reportTimestamp|
|`_chainSelector`|`uint64`|Source chain selector identifying which spoke sent the message|
|`destTokenAmounts`|`Client.EVMTokenAmount[]`|Token envelope delivered alongside this message — ground truth|


