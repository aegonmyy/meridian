# SpokeConfirmsModule
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/spoke/SpokeConfirmsModule.sol)

**Inherits:**
[SpokeStorage](/src/spoke/SpokeStorage.sol/abstract.SpokeStorage.md)

**Title:**
SpokeConfirmsModule

Outbound confirm/report dispatch (WI-2d): builds and sends CONFIRM_RECEIPT /
CONFIRM_REBALANCE / CONFIRM_WITHDRAWAL / REPORT_BALANCE messages, queues them for
retry on failure, and exposes the permissionless retry entry point.

R-7 of the Spoke modularization — final step for Spoke. Sibling to SpokeAdminModule
and SpokeHandlersModule — all three inherit SpokeStorage directly and none inherit
each other.
Implements the _sendOrQueueConfirm hook declared in SpokeStorage (bodiless `virtual`,
`override` here) — called cross-module from SpokeHandlersModule's four inbound
message handlers.
Calls the _aggregatedSpokeBalance hook implemented in SpokeHandlersModule
(pre-declared in SpokeStorage, no new hook needed here).
_buildConfirmMessage needs no hook — both its callers (retryConfirm,
_sendOrQueueConfirm) live in this same module.


## Functions
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
function _sendOrQueueConfirm(CCIPHelpers.MessageType _type, bytes32 _messageId, uint256 _tokenAmount)
    internal
    virtual
    override;
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


### pendingConfirmsLength

Returns the length of the pendingConfirms array


```solidity
function pendingConfirmsLength() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Length of the pendingConfirms array|


