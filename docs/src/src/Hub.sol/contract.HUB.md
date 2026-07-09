# HUB
[Git Source](https://github.com/aegonmyy/meridian/blob/8f085e328b747676203173bc0d1ecf2a95d5e520/src/Hub.sol)

**Inherits:**
ERC4626, CCIPReceiver, Ownable, Pausable

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


### WITHDRAWAL_TIMEOUT
Grace period after which an unsettled withdrawal becomes cancellable

Backstop for a withdrawal stuck in SettlementDeferred (persistent insolvency) or
a Path 3 recall leg that never arrives. Cancelling returns escrowed shares —
the user keeps their claim on any later-arriving leg funds via ordinary idle.


```solidity
uint256 public constant WITHDRAWAL_TIMEOUT = 24 hours
```


### RECALL_HAIRCUT_BPS
Basis-point haircut applied to a spoke's reported balance when sizing a Path 3 recall leg

Safety margin against stale spokeBalances — never ask a spoke for more than
(10000 - RECALL_HAIRCUT_BPS)/10000 of what hub believes it holds.


```solidity
uint256 public constant RECALL_HAIRCUT_BPS = 50
```


### TRANSIT_RECONCILE_DELAY
Minimum age of a stuck in-transit leg before the owner may reconcile it

WI-5 — replaces the removed adjustInTransitAssets. Operational order: attempt
CCIP manual execution first; reconcile only when the message is provably dead
(CCIP Explorer confirms permanent FAILURE and manual execution cannot recover
it). The delay exists so a merely-slow (not dead) message isn't reconciled out
from under a legitimate in-flight confirm.


```solidity
uint256 public constant TRANSIT_RECONCILE_DELAY = 7 days
```


### MAX_YIELD_BPS
Upside band width, in bps, a spoke's reported balance may exceed netSentToSpoke by

WI-7 (Issue 7b, Option A). Under-reporting (losses) always passes — it deflates
rather than inflates share price, which is the direction that's safe to trust.


```solidity
uint256 public constant MAX_YIELD_BPS = 2_000
```


### REPORT_DUST
Flat USDC dust allowance added on top of the MAX_YIELD_BPS band

Absorbs rounding noise for small spokes where a percentage-only band would be
too tight to be useful.


```solidity
uint256 public constant REPORT_DUST = 100e6
```


### LOSS_ALERT_BPS
Bps drop between consecutive reports that triggers an informational event

Not one of the plan's named tunable constants (WITHDRAWAL_TIMEOUT,
RECALL_HAIRCUT_BPS, TRANSIT_RECONCILE_DELAY, MAX_YIELD_BPS, REPORT_DUST) — the
plan asks for "an informational event when it drops >X% between reports" without
specifying X. Judgment call, flagged for review: 500 bps (5%) as a reasonable
default. Purely informational — never blocks or quarantines anything.


```solidity
uint256 public constant LOSS_ALERT_BPS = 500
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

messageId is derived from a monotonic nonce via _newMessageId — unique
across the hub's lifetime, so same-block withdrawals never collide.


```solidity
mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals
```


### legToWithdrawal
Maps a Path 3 recall leg's messageId back to the withdrawal id it belongs to

Set when a leg is dispatched, read (not deleted) on arrival — deliberately never
deleted so a late-arriving leg for an already-settled or cancelled withdrawal can
still be recognized and routed to the orphaned-arrival no-op path instead of being
silently mistaken for a fresh, unrelated Rebalancer-driven recall (WI-3).


```solidity
mapping(bytes32 => bytes32) public legToWithdrawal
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


### transitLegs
Maps CCIP messageId to the origin selector and send time of that DEPOSIT leg

WI-5/FX-2 — set in _sendToSpoke alongside inTransitAmount. Deleted alongside
inTransitAmount on both the normal path (_handleDepositCallback) and
reconciliation (reconcileTransit) — the latter also uses the stored selector to
decrement inTransitToSpoke, which the old inTransitSince-only design could not do.


```solidity
mapping(bytes32 => TransitLeg) public transitLegs
```


### inTransitToSpoke
Count of outstanding in-flight DEPOSIT legs per spoke selector

WI-6 — incremented in _sendToSpoke alongside inTransitAmount (one per DEPOSIT
message sent to that selector), decremented in _handleDepositCallback when that
selector's CONFIRM_RECEIPT lands. Guards removeSpoke: disabling a spoke while it
has in-flight legs turns their eventual CONFIRM_RECEIPT into NotSpoke poison
(the spoke would still be mid-flight but no longer isValidSpoke).


```solidity
mapping(uint64 => uint256) public inTransitToSpoke
```


### netSentToSpoke
Net USDC ever sent to a spoke via DEPOSIT, minus actual USDC ever recalled back

WI-7 — the baseline a spoke's self-reported balance is checked against.
Incremented in _sendToSpoke for DEPOSIT messages; decremented by the ACTUAL
arrived amount (destTokenAmounts, never the payload's claimed amount) on every
CONFIRM_WITHDRAWAL arrival, consistent with WI-4. Clamped at 0 — a spoke cannot
recall more than the hub believes it ever sent without that surplus itself being
yield, which the upside band below is what actually polices.
FX-3: also REBASED (overwritten, not incremented) to the accepted value by
acceptQuarantinedReport — the band is flat and time-blind, so without a durable
rebase on accept, genuine cumulative yield eventually exceeds it permanently and
every honest report after an accept would immediately re-quarantine.


```solidity
mapping(uint64 => uint256) public netSentToSpoke
```


### quarantinedReports
A quarantined self-reported balance awaiting owner review

WI-7. Set when a report exceeds the upside-only sanity band; spokeBalances is
left untouched (never clamped — clamping corrupts pricing in the other
direction). Owner resolves via acceptQuarantinedReport or rejectQuarantinedReport.


```solidity
mapping(uint64 => uint256) public quarantinedReports
```


### activeQuarantineCount
Count of spokes currently holding a quarantined report

Used to know when it is safe to unpause — resolving one quarantined spoke must
not unpause the vault while another remains quarantined.


```solidity
uint256 public activeQuarantineCount
```


### outboundGasLimit
Gas limit supplied to the CCIP router for all outbound messages

Configurable by owner. Default 1_500_000 — covers the most expensive spoke
operations (deposit → adapter → CONFIRM_RECEIPT CCIP send).
Increase via setOutboundGasLimit() if messages fail at destination.


```solidity
uint32 public outboundGasLimit = 1_500_000
```


### _messageNonce
Monotonic counter used to derive collision-free internal message ids

Incremented for every id produced by _newMessageId. Because it is part of
the preimage, two operations in the same block (same amount / receiver /
target) can never share an id — this is the fix for the content-derived
id collisions that previously corrupted inTransitAmount bookkeeping and
overwrote pending withdrawals.


```solidity
uint256 private _messageNonce
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
) external onlyRebalancer;
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
function attemptSettlement(bytes32 id) external;
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
function _newMessageId(bytes32 context) internal returns (bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`context`|`bytes32`|Caller-supplied disambiguator (e.g. selector or receiver)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`|A unique bytes32 message id|


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

`id` is required off-chain to call cancelWithdrawal() or attemptSettlement() —
the hub never exposes a way to enumerate pending withdrawals, so this event is
the only source of an owner's withdrawal id.


```solidity
event WithdrawalQueued(
    address indexed owner, bytes32 indexed id, uint256 shares, uint256 assets, uint256 _reservedAssets
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner`|`address`|Address whose shares are held in escrow by hub|
|`id`|`bytes32`|The withdrawal id keying this entry in pendingWithdrawals|
|`shares`|`uint256`|Number of shares transferred to hub and locked|
|`assets`|`uint256`|Full USDC value owed to the withdrawer on settlement (quote, not a promise — WI-4 claim-time pricing)|
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

### SpokeForceRemoved
Emitted when a spoke is disabled via the unsafe forceRemoveSpoke path

Loud by design — the presence of nonzero danglingBalance or danglingInFlightLegs
signals exactly what was skipped and what operational cleanup remains.


```solidity
event SpokeForceRemoved(uint64 indexed spokeSelector, uint256 danglingBalance, uint256 danglingInFlightLegs);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`spokeSelector`|`uint64`|CCIP chain selector of the forcibly-disabled spoke|
|`danglingBalance`|`uint256`|spokeBalances[selector] at the moment of removal — now instantly excluded from totalManagedAssets()|
|`danglingInFlightLegs`|`uint256`|inTransitToSpoke[selector] at the moment of removal — legs whose eventual CONFIRM_RECEIPT will now revert with NotSpoke|

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

### SentToSpoke
Emitted when hub dispatches a CCIP message to a spoke

ccipMessageId is the bytes32 returned by router.ccipSend() — track it on
https://ccip.chain.link to monitor delivery status.
amount is 0 for non-deposit message types.


```solidity
event SentToSpoke(
    uint64 indexed chainSelector, bytes32 indexed ccipMessageId, bytes32 internalMessageId, uint256 amount
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|Destination chain CCIP selector|
|`ccipMessageId`|`bytes32`|CCIP protocol message ID from router.ccipSend()|
|`internalMessageId`|`bytes32`|Hub's internal keccak256 message ID|
|`amount`|`uint256`|USDC amount sent (0 for REBALANCE / REPORT_BALANCE)|

### RecallCompleted
Emitted when a CONFIRM_WITHDRAWAL arrives that matches no pendingWithdrawal

This is the WI-3 rebalancer-driven recall completion signal — the off-chain
agent watches for this to sequence "recall from overweight chain, then propose
allocation to the now-idle funds." The arrived tokens become ordinary hub idle;
no further hub-side action is needed.


```solidity
event RecallCompleted(uint64 indexed chainSelector, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|Chain selector the recall was sourced from|
|`amount`|`uint256`|Actual USDC amount that arrived (from the CCIP token envelope)|

### TransitReconciled
Emitted when a stuck in-transit DEPOSIT leg is reconciled by the owner

WI-5. amount is exactly the tracked inTransitAmount for this id — the owner
cannot invent or inflate a value.


```solidity
event TransitReconciled(bytes32 indexed messageId, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`messageId`|`bytes32`|The reconciled leg's internal message id|
|`amount`|`uint256`|The exact amount released from inTransitAssets|

### SuspiciousSpokeReport
Emitted when a spoke's self-reported balance exceeds the upside-only sanity
band and is quarantined instead of applied

WI-7. spokeBalances[selector] is left untouched; deposits and withdrawals pause.


```solidity
event SuspiciousSpokeReport(uint64 indexed chainSelector, uint256 reported, uint256 ceiling);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|The reporting spoke's chain selector|
|`reported`|`uint256`|The rejected, quarantined value|
|`ceiling`|`uint256`|The band ceiling it exceeded (netSentToSpoke-derived)|

### SpokeBalanceDropped
Emitted when a spoke's reported balance drops sharply between reports

Informational only — under-reporting always passes the band (it deflates share
price, the safe direction) but a sharp drop is worth an operator's attention.


```solidity
event SpokeBalanceDropped(uint64 indexed chainSelector, uint256 previous, uint256 reported);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|The reporting spoke's chain selector|
|`previous`|`uint256`|The previously recorded balance|
|`reported`|`uint256`|The new, lower balance|

### QuarantinedReportAccepted
Emitted when the owner accepts a quarantined report


```solidity
event QuarantinedReportAccepted(uint64 indexed chainSelector, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|The spoke whose quarantined report was accepted|
|`amount`|`uint256`|The value now applied to spokeBalances|

### QuarantinedReportRejected
Emitted when the owner rejects a quarantined report


```solidity
event QuarantinedReportRejected(uint64 indexed chainSelector, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|The spoke whose quarantined report was discarded|
|`amount`|`uint256`|The discarded value|

### OrphanedRecallArrival
Emitted when a Path 3 recall leg or stray token arrival matches no live
pendingWithdrawal — e.g. a leg for a withdrawal that was cancelled, or (as of
FX-1) a late leg for an id whose entry has already been deleted for any other
reason. Since FX-1, settlement never happens before all of an entry's legs
have landed (`pendingLegs == 0`), so a live entry can no longer be settled out
from under a still-outstanding leg.

Funds become ordinary hub idle — no action needed, this is informational.


```solidity
event OrphanedRecallArrival(uint64 indexed chainSelector, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`chainSelector`|`uint64`|Chain selector the arrival came from|
|`amount`|`uint256`|Actual USDC amount that arrived|

### SettlementDeferred
Emitted when a settlement attempt finds insufficient claimable idle right now

Non-fatal — the entry stays pending and a later confirm (another leg arrival, or
another REPORT_BALANCE round for Path 2) retries. Never reverts a CCIP execution.


```solidity
event SettlementDeferred(bytes32 indexed id, uint256 payout, uint256 availableForThisEntry);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`bytes32`|The withdrawal id|
|`payout`|`uint256`|Claim-time payout that would be owed if settled now|
|`availableForThisEntry`|`uint256`|Idle currently claimable by this entry alone|

### WithdrawalRepriced
Emitted alongside WithdrawalProcessed when claim-time payout differs from the
quote taken at request time (yield or loss accrued while the withdrawal was pending)


```solidity
event WithdrawalRepriced(bytes32 indexed id, uint256 quotedAssets, uint256 payout);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`bytes32`|The withdrawal id|
|`quotedAssets`|`uint256`|previewRedeem(shares) at request time|
|`payout`|`uint256`|Actual previewRedeem(shares) at settlement time|

### WithdrawalCancelled
Emitted when a timed-out pending withdrawal is cancelled by its owner


```solidity
event WithdrawalCancelled(bytes32 indexed id, uint256 shares);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`bytes32`|The withdrawal id|
|`shares`|`uint256`|Shares returned to the owner|

## Structs
### PendingWithdrawal
Tracks a queued withdrawal awaiting spoke balance confirmation or fund recall

WI-4 withdrawal engine v2. Created in Path 2 (stale balances) and Path 3
(insufficient idle). Path 1: no pending withdrawal created — settled synchronously.
`quotedAssets` is the previewRedeem() value AT REQUEST TIME — reference and recall
sizing only. It is NOT a promise: settlement recomputes payout via previewRedeem()
again at claim time (claim-time pricing is the decided v2 semantic — a loss or
gain reported while a Path 3 recall is in flight changes what the withdrawer
actually receives). `reservedIdle` is the idle locked at request time
(`<= quotedAssets`) — `reservedAssets` is decremented by exactly this amount on
settlement or cancellation, regardless of what payout ends up being.
`arrivedAssets` accumulates the ACTUAL token amounts (destTokenAmounts — never the
payload's claimed amount) from each Path 3 recall leg as they land.
`pendingLegs` counts outstanding Path 3 recall legs — 0 for Path 2 (no legs, just
a REPORT_BALANCE refresh) and 0 once all Path 3 legs have arrived.


```solidity
struct PendingWithdrawal {
    /// @dev Shares transferred to hub contract at queue time — burned on settlement
    uint256 shares;
    /// @dev previewRedeem(shares) at request time — reference & recall sizing only, not a promise
    uint256 quotedAssets;
    /// @dev Idle USDC reserved (locked) at request time — <= quotedAssets
    uint256 reservedIdle;
    /// @dev Sum of ACTUAL recalled token arrivals for this withdrawal's Path 3 legs
    uint256 arrivedAssets;
    /// @dev Outstanding Path 3 recall legs — 0 for Path 2, decrements as legs arrive
    uint32 pendingLegs;
    /// @dev Block timestamp when withdrawal was queued — gates cancelWithdrawal via WITHDRAWAL_TIMEOUT
    uint64 requestedAt;
    /// @dev Address that will receive the USDC on settlement
    address receiver;
    /// @dev Address whose shares were transferred to hub — also the only address that can cancel
    address owner;
}
```

### TransitLeg
Tracks a single outstanding DEPOSIT leg's origin selector and send time

FX-2. Replaces the old parallel `inTransitSince` mapping — reconcileTransit needs
to know which selector's inTransitToSpoke counter to decrement, and an owner-
supplied selector parameter would be unverifiable (the stored value is the only
trustworthy source). Both fields fit one slot.


```solidity
struct TransitLeg {
    /// @dev Chain selector the DEPOSIT was sent to
    uint64 selector;
    /// @dev block.timestamp the DEPOSIT was sent — gates TRANSIT_RECONCILE_DELAY
    uint64 sentAt;
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

