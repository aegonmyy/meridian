# HubAdminModule
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/hub/HubAdminModule.sol)

**Inherits:**
[HubStorage](/src/hub/HubStorage.sol/abstract.HubStorage.md)

**Title:**
HubAdminModule

Owner-only administrative surface: spoke registry management, misc owner setters,
in-transit leg reconciliation, and quarantined-report resolution.

R-2 of the Hub modularization. Sibling to HubMessagingModule and HubWithdrawalModule —
all three inherit HubStorage directly and none inherit each other. isValidSpoke is
declared as a hook in HubStorage (bodiless `virtual`) because HubMessagingModule's
_ccipReceive calls it cross-module; this file provides the `override` implementation.
No other function here is called across module boundaries.


## Functions
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


### setOutboundGasLimit

Updates the gas limit passed to CCIP router for all outbound messages

Increase if CCIP messages land with execution failure at the spoke.
Default 1_500_000 covers most operations including adapter deposits + CCIP reply.


```solidity
function setOutboundGasLimit(uint32 _gasLimit) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_gasLimit`|`uint32`|New gas limit — must be > 0 and reasonable for spoke execution|


### reconcileTransit

Releases a specific, aged, tracked in-transit leg whose CONFIRM_RECEIPT will
provably never arrive (dead lane, spoke decommissioned, permanent CCIP failure)

WI-5 — replaces the removed adjustInTransitAssets, which let the owner write
inTransitAssets to ANY value with no evidence, bound, or delay — an unbounded
write to a share-price input. This can only write down a SPECIFIC id by its
EXACT tracked amount, and only after TRANSIT_RECONCILE_DELAY has passed since it
was sent. It can never invent value or inflate the vault.
Operational order: attempt CCIP manual execution first; call this only once the
message is provably dead. A late CONFIRM_RECEIPT arriving after reconciliation
is harmless — inTransitAmount[id] is already deleted, so
`inTransitAssets -= inTransitAmount[id]` in _handleDepositCallback subtracts
zero and only updates the spoke balance (see WI5 regression tests).
FX-2: also decrements inTransitToSpoke[selector] for the leg's origin selector
(read from the stored TransitLeg, never an owner-supplied parameter — the stored
value is the only trustworthy source). Without this, a reconciled leg — by
definition one whose confirm will never arrive — left inTransitToSpoke
permanently nonzero, making the safe removeSpoke path revert
SpokeHasInFlightLegs forever for that selector even after the spoke was fully
drained, forcing forceRemoveSpoke as the routine tool for exactly the dead-lane
scenario this function exists to clean up.


```solidity
function reconcileTransit(bytes32 messageId) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`messageId`|`bytes32`|The stuck DEPOSIT leg's internal message id|


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

Disables a spoke by setting its exists flag to false — safe path, default choice

WI-6 guard: requires spokeBalances[selector] == 0 and no in-flight legs
(inTransitToSpoke[selector] == 0). Rationale: removing a FUNDED spoke instantly
craters totalManagedAssets() by that spoke's reported balance — a mispricing
window that shortchanges every share until re-registered — and turns any
still-in-flight CONFIRM_RECEIPT for that selector into NotSpoke poison the moment
it lands (isValidSpoke() goes false mid-flight). Drain the spoke (recallFromSpoke
until spokeBalances[selector] == 0) and let in-flight legs land first; only then
is this safe. For true emergencies where waiting isn't acceptable, see
forceRemoveSpoke — the unsafe path is intentionally a separate, loudly-named
function so the safe path stays the default.
Does not remove from spokeChainSelectors array — inactive spokes are skipped
during iteration via the exists flag. Also clears addressToSelector.


```solidity
function removeSpoke(uint64 _chainSelector) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the spoke to disable|


### forceRemoveSpoke

Emergency: disables a spoke WITHOUT the safety checks removeSpoke enforces

WI-6. Use only when the safe path (removeSpoke) is genuinely not viable — e.g.
the spoke contract itself is compromised and continuing to interact with it
(even to drain it) is the greater risk. Skipping the checks means:
(a) totalManagedAssets() instantly drops by spokeBalances[selector] — a real,
immediate mispricing event against every current shareholder, not merely a
cosmetic one; (b) any CONFIRM_RECEIPT still in flight for this selector will
revert with NotSpoke on arrival (poisoning that CCIP message permanently — the
DEPOSIT's inTransitAmount becomes a WI-5 reconcileTransit candidate once its
TRANSIT_RECONCILE_DELAY has passed, since the confirm can now never land).
Owner-only, separate from removeSpoke by design so the destructive path is never
the accidental default.


```solidity
function forceRemoveSpoke(uint64 _chainSelector) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|CCIP chain selector of the spoke to forcibly disable|


### isValidSpoke

Returns whether an address is currently a valid active spoke

Checks both the reverse mapping and the exists flag to guard against
stale entries where address was removed or updated.


```solidity
function isValidSpoke(address _spoke) public view override returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_spoke`|`address`|Address to check|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if _spoke is the currently registered active spoke for its selector|


### acceptQuarantinedReport

Owner accepts a quarantined report — applies it to spokeBalances and unpauses
once no spoke has an outstanding quarantine

WI-7. Use once the owner has independently confirmed the reported balance is
legitimate (e.g. genuine outsized yield, or a one-off catch-up report after a
period of stale reporting).


```solidity
function acceptQuarantinedReport(uint64 _chainSelector) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|The spoke whose quarantined report to accept|


### rejectQuarantinedReport

Owner rejects a quarantined report — discards it, spokeBalances stays as it
was before the suspicious report, unpauses once no spoke has an outstanding
quarantine

WI-7. Use when the report is confirmed bogus (compromised spoke, decoding bug,
etc.) — spokeBalances simply keeps its last-known-good value.


```solidity
function rejectQuarantinedReport(uint64 _chainSelector) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainSelector`|`uint64`|The spoke whose quarantined report to reject|


