# SpokeAdminModule
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/spoke/SpokeAdminModule.sol)

**Inherits:**
[SpokeStorage](/src/spoke/SpokeStorage.sol/abstract.SpokeStorage.md)

**Title:**
SpokeAdminModule

Owner-only adapter registry management (setAdapter/removeAdapter), Hub address
rotation, idle redeployment, and the adapter-registry view accessors.

R-6 of the Spoke modularization. Sibling to SpokeHandlersModule and
SpokeConfirmsModule — all three inherit SpokeStorage directly and none inherit each
other. No function here is called across module boundaries, so no hooks are
implemented in this file.
getAllocations/activeAdaptersLength placement is a judgment call — the plan doesn't
explicitly assign them; kept here alongside the adapter registry they read, mirroring
isValidSpoke's placement in HubAdminModule.


## Functions
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


