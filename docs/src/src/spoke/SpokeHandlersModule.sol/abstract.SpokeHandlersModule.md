# SpokeHandlersModule
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/spoke/SpokeHandlersModule.sol)

**Inherits:**
[SpokeStorage](/src/spoke/SpokeStorage.sol/abstract.SpokeStorage.md)

**Title:**
SpokeHandlersModule

CCIP inbound entry point (_ccipReceive routing) and the four inbound message
handlers (_handleDeposit, _handleRebalance, _handleWithdrawalWithAmount,
_reportBalance), plus the aggregated-balance view they all ultimately report.

R-6 of the Spoke modularization. Sibling to SpokeAdminModule and SpokeConfirmsModule —
all three inherit SpokeStorage directly and none inherit each other.
Implements the _aggregatedSpokeBalance hook declared in SpokeStorage (bodiless
`virtual`, `override` here) — called cross-module from
SpokeConfirmsModule._buildConfirmMessage.
Calls the _sendOrQueueConfirm hook implemented in SpokeConfirmsModule (pre-declared
in SpokeStorage, no new hook needed here).


## Functions
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
function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual override;
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


### _aggregatedSpokeBalance

Sums spoke idle USDC plus totalAssets() across all currently active adapters

WI-2b: idle is first-class. A direct USDC transfer, or leftover from a partial
DEPOSIT skip / WITHDRAW_AMOUNT shortfall, is now counted — previously invisible
to the hub. Skips adapters where exists == false — removed adapters report zero.
Called before every outbound message to give hub an accurate spoke snapshot.
Value may lag slightly if adapters accrue yield between reports — accepted v1 tradeoff.


```solidity
function _aggregatedSpokeBalance() internal view virtual override returns (uint256 aggregatedSpokeBalance);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`aggregatedSpokeBalance`|`uint256`|Idle USDC plus total USDC managed across all active adapters|


