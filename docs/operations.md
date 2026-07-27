# Operations

## LINK balances

Both `HUB` and every `SpokeVault` pay CCIP fees in LINK for every outbound message. Neither
side self-funds: LINK must be topped up manually (or via a Chainlink Automation/Keeper job
in production) before it runs out.

**What happens if it runs out.** `_sendToSpoke` (hub) and `_sendOrQueueConfirm` (spoke) both
call `router.getFee(...)` then `LINK.forceApprove(...)` + `router.ccipSend(...)`. If the
contract's LINK balance is insufficient to cover the fee:

- **Hub-side sends** (`sendToSpoke`, `recallFromSpoke`, `rebalance`, `_requestAllBalanceReports`)
  are not wrapped in a queue-and-retry mechanism, the call reverts outright. This is a
  synchronous, caller-visible failure: the Rebalancer's transaction reverts, nothing is lost,
  and the operator retries after topping up LINK. There is nothing to "recover" here
  because nothing was ever committed.
- **Spoke-side confirm sends** (`CONFIRM_RECEIPT`, `CONFIRM_REBALANCE`, `CONFIRM_WITHDRAWAL`,
  the `REPORT_BALANCE` response) are the higher-stakes case, because by the time the outbound
  send is attempted, real fund-touching work has already happened (adapter deposits,
  withdrawals, or an intra-spoke rebalance). WI-2d's `_sendOrQueueConfirm` wraps these sends
  in `try/catch`: on failure, the confirm is persisted to the spoke's `pendingConfirms` queue
  (`ConfirmSendFailed` event) instead of reverting the whole handler and rolling back work
  that already landed. `retryConfirm(uint256 index)` is the recovery path, permissionless,
  callable by anyone once the spoke's LINK balance is topped up. It rebuilds the confirm
  message fresh (recomputing `spokeBalance` at retry time, not the stale value from the
  original failure) and resends it.

**Minimum balances.** There is no on-chain minimum enforced, this is an off-chain monitoring
responsibility. As a starting operational baseline:

- Alert when a contract's LINK balance would cover fewer than ~10 outbound messages at the
  current CCIP lane fee (fees vary by lane and gas price; check
  [CCIP Directory](https://docs.chain.link/ccip/directory) for current lane fee estimates).
  Ten is a rough five-nines-uptime buffer for a lane an operator checks daily, tune down for
  higher-frequency spokes.
- Page immediately, rather than only logging, if a `ConfirmSendFailed` event fires. Every minute
  the corresponding `PendingConfirm` stays unresolved is a minute the affected withdrawal or
  deposit's confirm is invisible to the hub, and (per WI-6) it also blocks `setHub` from
  rotating that spoke's Hub pointer.

## Monitoring both sides

Minimum event set to watch, per chain:

**Hub:**
- `SentToSpoke`, every outbound dispatch; cross-reference `ccipMessageId` against
  [CCIP Explorer](https://ccip.chain.link) to confirm delivery within the expected window.
- `TransitReconciled`, should be rare. Any occurrence means an operator manually wrote down
  a stuck `inTransitAssets` leg after confirming (via CCIP Explorer) that the message is
  permanently dead and manual execution cannot recover it. Investigate the root cause (dead
  lane? decommissioned spoke?) before it recurs.
- `SuspiciousSpokeReport` (WI-7), pauses deposits/withdrawals. Page immediately.
- `WithdrawalQueued` / `SettlementDeferred`, a growing count of deferred, unsettled
  withdrawals signals a persistent solvency gap (idle not keeping pace with claims) worth
  investigating before users start hitting `WITHDRAWAL_TIMEOUT` and cancelling.

**Spoke:**
- `ConfirmSendFailed`, see above; page-worthy.
- `DepositInstructionFailed` / `RebalanceInstructionFailed`, an adapter rejected funds or a
  rebalance leg; funds land as spoke idle instead (not lost), but investigate why the adapter
  rejected the operation (paused protocol? removed adapter still referenced by a stale
  proposal?).
- `RecallShortfall`, the spoke could not fully satisfy a requested recall from idle +
  adapters combined. Expected occasionally under the RECALL_HAIRCUT_BPS margin; frequent
  occurrences suggest spokeBalances is drifting stale faster than reports refresh it.

## Recovery path summary

| Symptom | Cause | Recovery |
|---|---|---|
| Spoke confirm never lands, `ConfirmSendFailed` fired | LINK exhausted (or transient router issue) on spoke | Top up spoke LINK, call `retryConfirm(index)` (permissionless) |
| `inTransitAssets` stuck non-zero for a specific leg, CCIP Explorer shows FAILURE, manual execution exhausted | Dead lane / spoke decommissioned | Wait out `TRANSIT_RECONCILE_DELAY` (7 days), then owner calls `reconcileTransit(messageId)`, releases exactly that leg's tracked amount, nothing more |
| Hub-side send reverts | LINK exhausted on hub, or `InsufficientUnreservedIdle` / `InsufficientRecallLiquidity` guard tripped | Top up LINK; or wait for idle/spoke capacity to recover before resubmitting |
| `setHub` reverts with `PendingConfirmsOutstanding` | Spoke has an unresolved queued confirm | Resolve it via `retryConfirm` first (or wait it out) before rotating `HUB` |
| `removeSpoke` reverts with `SpokeNotDrained` / `SpokeHasInFlightLegs` | Spoke still holds reported balance or has an in-flight DEPOSIT leg | Recall the balance to zero (`Rebalancer.recallFromSpoke`) and let in-flight legs land, then retry; or use `forceRemoveSpoke` if the situation is an emergency (accepts an instant mispricing window, see its NatSpec) |

## Path 2 liveness composition

`_allSpokesFresh()` requires **every** active spoke to have reported within `MAX_STALENESS`,
whether or not that spoke is involved in the withdrawal being settled. So one permanently-stale
spoke blocks all Path 2 settlement globally, for every user, including withdrawals that would
never have touched that spoke. A spoke can go permanently stale for reasons that have nothing
to do with its solvency: a redeployed spoke contract nobody re-registered, a decommissioned L2,
or simply an operator who stopped triggering `REPORT_BALANCE` refreshes.

If a spoke is stuck stale and is blocking Path 2 for the whole vault, the decision sequence
is:

1. **Diagnose first.** Is the spoke still solvent and reachable (just not reporting), or is it
   dead? Check `lastReportTimestamp(selector)` and attempt a manual
   `_requestAllBalanceReports` round-trip (via any Path 2 withdrawal, or a dedicated
   maintenance call) before assuming it is unrecoverable.
2. **If reachable but not reporting:** fix whatever is preventing its `REPORT_BALANCE`
   response (LINK balance on the spoke, `retryConfirm` if a confirm is queued). This is the
   cheapest fix and requires no hub-side state changes.
3. **If dead and still funded:** it must be drained before it can be safely removed.
   `Rebalancer.recallFromSpoke` the reported balance back to hub idle (the WI-3 v1 operator
   flow), confirm via `RecallCompleted`, then `removeSpoke`. The WI-6 guard requires
   `spokeBalances[selector] == 0` and no in-flight legs, which this sequence satisfies.
4. **If it cannot be drained** (the spoke contract itself is unresponsive or compromised, a
   deeper failure than a reporting gap), the only path is `forceRemoveSpoke`. Accept the instant
   `totalAssets()` mispricing window this causes (see its NatSpec), and be aware any
   in-flight `DEPOSIT` legs to that spoke become `NotSpoke`-poisoned and will eventually need
   `reconcileTransit` once `TRANSIT_RECONCILE_DELAY` elapses.

Removing (or force-removing) the dead spoke is what restores Path 2 liveness for every other
user, `_allSpokesFresh()` only iterates spokes with `exists == true`.

## Post-reject refresh

After `rejectQuarantinedReport(selector)`, `spokeBalances[selector]` is left exactly as it
was before the suspicious report, the rejected value is discarded, nothing is
recomputed. If the rejected report accompanied a token-carrying `CONFIRM_WITHDRAWAL` (WI-7's
documented interaction: the quarantine only blocks the reported-*balance* write, never the
token delivery), the tokens from that recall already landed in hub idle, but
`spokeBalances[selector]` still reflects the old, pre-recall value, which double-counts
those just-recalled funds in `totalAssets()` (once as hub idle, once as the stale spoke
balance) until the next legitimate report corrects it.

**Operator action: after any `rejectQuarantinedReport`, force a fresh report promptly**, rather
than waiting for organic traffic to trigger one. Do not leave `totalAssets()` overstated for
however long it takes the next natural `REPORT_BALANCE`/`CONFIRM_*` message to arrive. A small
`Rebalancer.recallFromSpoke` round-trip (even a nominal amount) is the fastest way to force a
fresh, accurate report back from the spoke.

## Stuck return legs vs. stuck deposit legs

`reconcileTransit` only covers deposit legs (hub to spoke, tracked via `inTransitAmount` /
`transitLegs`). It has no counterpart for a stuck return leg (spoke to hub, a
`CONFIRM_WITHDRAWAL` or other confirm that never makes it back), that direction is recovered
differently:

- **Stuck deposit leg** (hub sent, spoke's confirm never arrives): the hub-side tool is
  `reconcileTransit(messageId)`, gated by `TRANSIT_RECONCILE_DELAY`. This writes down the
  hub's `inTransitAssets` accounting, it does not and cannot resend anything, since the hub
  is not the side that failed to send.
- **Stuck return leg** (spoke pulled funds and tried to confirm, but the outbound send
  itself failed, LINK exhaustion, router hiccup): the spoke-side tool is
  `retryConfirm(index)`, permissionless, no delay. This one is a real resend: the funds never
  left the spoke in this failure mode (WI-2d's `_sendOrQueueConfirm` queues instead of
  reverting the fund-touching work), so retrying is safe and immediate rather than a
  last-resort write-down.

Point operators at the right tool for the direction: hub-side accounting write-down
(`reconcileTransit`) for stuck deposits, spoke-side resend (`retryConfirm`) for stuck
returns. Confusing the two wastes the `TRANSIT_RECONCILE_DELAY` wait on a problem
`retryConfirm` would have fixed immediately.

## UI guidance: prefer `redeem(shares)` over `withdraw(assets)`

WI-4's claim-time pricing means the actual payout for a Path 2/3 withdrawal is
`previewRedeem(shares)` recomputed at settlement, not the amount quoted at request time.
For `redeem(shares, receiver, owner)`, the caller-specified `shares` is exactly what gets
burned regardless of price movement, the semantics are unambiguous. For
`withdraw(assets, receiver, owner)`, the caller names a USDC *amount*, which ERC4626 converts
to shares via `previewWithdraw(assets)` at request time, that conversion is a quote, not
a promise, and the shares it locks in may end up worth more or less than `assets` by
settlement.

**Integrations should default to `redeem(shares)`**, not `withdraw(assets)`, and present users
with a share-denominated confirmation (or a clearly-labeled "estimated" USDC amount) rather
than implying `withdraw`'s named amount is guaranteed. This is a UI/integration guidance note,
not a contract change, both functions remain available and correctly implemented; the
ERC-7540-style sync/async preview divergence they inherit is a known, explicitly out-of-scope
v1 tradeoff (see the original plan's Open Questions #5).
