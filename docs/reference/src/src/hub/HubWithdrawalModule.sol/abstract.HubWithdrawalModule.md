# HubWithdrawalModule
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/hub/HubWithdrawalModule.sol)

**Inherits:**
[HubStorage](/src/hub/HubStorage.sol/abstract.HubStorage.md)

**Title:**
HubWithdrawalModule

The ERC4626 deposit/withdraw overrides implementing the WI-4 three-path async
withdrawal engine, claim-time settlement, cancellation, share-price accounting
(totalAssets/totalManagedAssets), and the spoke-selection/freshness/idle-balance
helpers those paths depend on.

R-4 of the Hub modularization — final step for Hub. Sibling to HubAdminModule and
HubMessagingModule — all three inherit HubStorage directly and none inherit each
other.
Implements 2 hooks declared in HubStorage (bodiless `virtual`, `override` here):
_idleBalance (called cross-module from HubMessagingModule's sendToSpoke and
idleBalance) and _allSpokesFresh (called cross-module from
HubMessagingModule._handleReportBalanceCallback).
Calls 3 hooks implemented in HubMessagingModule: _newMessageId (bare call),
_requestAllBalanceReports and the 3-arg recallFromSpoke overload (both via
`this.fn()` self-calls to change msg.sender context for the onlyRebalancer check —
see HubStorage's onlyRebalancer NatSpec). Also implements the external
attemptSettlement hook (called cross-module via `this.attemptSettlement(...)` from
HubMessagingModule's two report/withdrawal callbacks).


## Functions
### _deposit

Overrides ERC4626._deposit — no additional logic needed beyond standard behaviour

totalPrincipal tracking was removed as it was dead state — totalAssets() via
totalManagedAssets() is the source of truth for share pricing.
WI-7: whenNotPaused — user deposits pause while any spoke report is quarantined.
(Whether capital-movement functions like sendToSpoke/recallFromSpoke should also
be gated is Open Questions #4 — not decided here; only user entry/exit is paused.)


```solidity
function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
    internal
    virtual
    override
    whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|Address initiating the deposit|
|`receiver`|`address`|Address receiving the minted shares|
|`assets`|`uint256`|Amount of USDC being deposited|
|`shares`|`uint256`|Amount of vault shares being minted|


### _withdraw

Overrides ERC4626._withdraw to implement the WI-4 three-path async withdrawal engine

Shares are transferred to hub at start and only burned on final settlement.
No super() call — full flow is owned here.
messageId is derived from a monotonic nonce via _newMessageId — collision-free.
Path 1 (sync): idle >= assets AND all spokes fresh → immediate settlement at the
quote taken this instant (no daylight between quote and settlement).
Path 2 (async): idle >= assets AND any spoke stale → queue + REPORT_BALANCE;
settles once ALL spokes report fresh (not on the first report — that was a bug).
Path 3 (async): idle < assets → reserve available idle, plan recall legs across
active spokes by descending spokeBalances, haircut-capped
(RECALL_HAIRCUT_BPS) per leg. If the shortfall cannot be fully planned even
across every active spoke, the ENTIRE call reverts with
InsufficientRecallLiquidity — fail-closed, nothing locks, user keeps shares.
Only if fully coverable does the hub commit (reserve idle, create the pending
entry) and dispatch legs. Settlement itself only happens once ALL of this
entry's legs have landed (pendingLegs == 0) — see _attemptSettleWithdrawal's
FX-1 NatSpec for why early settlement out of free idle was removed.
CLAIM-TIME PRICING (user-facing behavioral change from v1): for Path 2/3, the
amount actually paid out is previewRedeem(shares) recomputed AT SETTLEMENT, not
the quote taken here. Yield accrued while pending is credited to the withdrawer;
a loss reported while pending reduces their payout. See _attemptSettleWithdrawal.
WI-7: whenNotPaused — new withdrawal REQUESTS pause while any spoke report is
quarantined. Settlement of ALREADY-pending withdrawals (attemptSettlement,
cancelWithdrawal) is intentionally NOT gated — those must keep working during a
pause so users with in-flight withdrawals aren't additionally stuck.


```solidity
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    internal
    virtual
    override
    whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|Address initiating the withdrawal (may differ from owner if approved)|
|`receiver`|`address`|Address to receive the USDC|
|`owner`|`address`|Address whose shares are being redeemed|
|`assets`|`uint256`|Ignored — recalculated internally via previewRedeem(shares)|
|`shares`|`uint256`|Number of shares to burn|


### cancelWithdrawal

Cancels a pending withdrawal after WITHDRAWAL_TIMEOUT has elapsed

Backstop for a withdrawal stuck in SettlementDeferred, or a Path 3 leg that never
arrives. Returns escrowed shares to the owner and releases the reservation.
Already-arrived leg funds (if any) remain vault idle — correct, since the caller
got their shares back and thus their proportional claim on those assets too.
Late-arriving legs after cancellation hit the unknown-leg no-op path in
_handleWithdrawalCallback (legToWithdrawal still resolves, but
pendingWithdrawals[id].shares == 0 after this delete) — no special handling needed.


```solidity
function cancelWithdrawal(bytes32 id) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`bytes32`|The withdrawal id to cancel|


### attemptSettlement

Attempts to settle a pending withdrawal at its claim-time price

Permissionless — anyone can nudge a pending withdrawal to retry settlement (also
called internally, wrapped in try/catch, from the CCIP arrival callbacks so an
external-call failure here — e.g. safeTransfer to an incompatible receiver — can
never revert a token-carrying CCIP execution). Never reverts on insolvency; see
_attemptSettleWithdrawal.


```solidity
function attemptSettlement(bytes32 id) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`bytes32`|The withdrawal id to attempt settlement for|


### _attemptSettleWithdrawal

Core non-reverting settlement attempt — claim-time pricing, freshness/leg
gated, solvency-gated

FX-1: gating moved INSIDE this function so it holds for every caller, including
the permissionless external `attemptSettlement`. Previously the freshness/arrival
gates existed only at the CCIP callback call sites — anyone could call
`attemptSettlement(id)` directly the instant a Path 2 withdrawal was queued and
settle at the still-stale price, reopening the exact bug this engine fixed.
Classification is derived purely from stored state (no separate "which path"
flag needed): an entry with `pendingLegs > 0 || arrivedAssets > 0` was routed
through Path 3 (it has, or is expecting, recall legs); otherwise it's a pure
Path 2 entry.
- Pure Path 2: defer unless `_allSpokesFresh()` — settlement must use a fully
refreshed balance picture, not whatever was stale at request time.
- Path 3: defer unless `pendingLegs == 0` — DECIDED POLICY (see FX-1 escalation):
no early settlement out of free idle while legs are still outstanding. A
user's own recalled liquidity is no longer a commons another withdrawer can
claim first via idle, and settlement timing becomes predictable — once all of
THIS entry's legs have landed, not whenever idle happens to be sufficient.
CLAIM-TIME PRICING: payout is previewRedeem(shares) recomputed NOW, not the quote
taken at request time. quotedAssets is reference/sizing only, never a promise —
this is the decided v2 semantic (yield during flight settles from free idle by
design; a loss during flight reduces payout).
SOLVENCY: settles only if idle currently claimable by THIS entry alone (total idle
minus everyone else's reservation) covers payout — never touches other entries'
reservations. If not yet solvent, emits SettlementDeferred and returns; the entry
stays pending for a later retry (another leg arrival, cancellation is the backstop).
Never reverts on insufficiency — that would poison a token-carrying CCIP message.


```solidity
function _attemptSettleWithdrawal(bytes32 id) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`bytes32`|The withdrawal id to attempt settlement for|


### _spokesByDescendingBalance

Returns active spoke selectors ordered by descending reported balance

WI-4 replaces the old single-best-spoke selection — Path 3 now plans legs
across as many spokes as needed (greedy, largest first) rather than recalling
everything from one spoke. spokeBalances may be slightly stale; RECALL_HAIRCUT_BPS
in the caller is the safety margin for that, not this ordering.
Selection sort — active spoke counts are small by design (a handful per protocol).


```solidity
function _spokesByDescendingBalance() internal view returns (uint64[] memory sorted);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sorted`|`uint64[]`|Active chain selectors, descending by spokeBalances|


### totalAssets

Returns total protocol assets per ERC4626 standard

Overrides ERC4626.totalAssets(). Delegates to totalManagedAssets() which
aggregates idle + in-transit + all spoke balances. Share price reflects
real yield-inclusive value as spokes report updated balances.


```solidity
function totalAssets() public view virtual override returns (uint256);
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


### _idleBalance

Returns the USDC balance sitting idle on hub — not deployed or in transit


```solidity
function _idleBalance() internal view override returns (uint256);
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
function _allSpokesFresh() internal view override returns (bool);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True only if every active spoke has reported within the last MAX_STALENESS seconds|


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


