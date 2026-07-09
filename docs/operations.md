# Operations

## LINK balances

Both `HUB` and every `SpokeVault` pay CCIP fees in LINK for every outbound message. Neither
side self-funds — LINK must be topped up manually (or via a Chainlink Automation/Keeper job
in production) before it runs out.

**What happens if it runs out.** `_sendToSpoke` (hub) and `_sendOrQueueConfirm` (spoke) both
call `router.getFee(...)` then `LINK.forceApprove(...)` + `router.ccipSend(...)`. If the
contract's LINK balance is insufficient to cover the fee:

- **Hub-side sends** (`sendToSpoke`, `recallFromSpoke`, `rebalance`, `_requestAllBalanceReports`)
  are not wrapped in a queue-and-retry mechanism — the call reverts outright. This is a
  synchronous, caller-visible failure: the Rebalancer's transaction reverts, nothing is lost,
  and the operator simply retries after topping up LINK. There is nothing to "recover" here
  because nothing was ever committed.
- **Spoke-side confirm sends** (`CONFIRM_RECEIPT`, `CONFIRM_REBALANCE`, `CONFIRM_WITHDRAWAL`,
  the `REPORT_BALANCE` response) are the higher-stakes case, because by the time the outbound
  send is attempted, real fund-touching work has already happened (adapter deposits,
  withdrawals, or an intra-spoke rebalance). WI-2d's `_sendOrQueueConfirm` wraps these sends
  in `try/catch`: on failure, the confirm is persisted to the spoke's `pendingConfirms` queue
  (`ConfirmSendFailed` event) instead of reverting the whole handler and rolling back work
  that already landed. **`retryConfirm(uint256 index)` is the recovery path** — permissionless,
  callable by anyone once the spoke's LINK balance is topped up. It rebuilds the confirm
  message fresh (recomputing `spokeBalance` at retry time, not the stale value from the
  original failure) and resends it.

**Minimum balances.** There is no on-chain minimum enforced — this is an off-chain monitoring
responsibility. As a starting operational baseline:

- Alert when a contract's LINK balance would cover fewer than ~10 outbound messages at the
  current CCIP lane fee (fees vary by lane and gas price; check
  [CCIP Directory](https://docs.chain.link/ccip/directory) for current lane fee estimates).
  Ten is a rough five-nines-uptime buffer for a lane an operator checks daily — tune down for
  higher-frequency spokes.
- Alert immediately (page, not just log) if a `ConfirmSendFailed` event fires — every minute
  the corresponding `PendingConfirm` stays unresolved is a minute the affected withdrawal or
  deposit's confirm is invisible to the hub, and (per WI-6) it also blocks `setHub` from
  rotating that spoke's Hub pointer.

## Monitoring both sides

Minimum event set to watch, per chain:

**Hub:**
- `SentToSpoke` — every outbound dispatch; cross-reference `ccipMessageId` against
  [CCIP Explorer](https://ccip.chain.link) to confirm delivery within the expected window.
- `TransitReconciled` — should be rare. Any occurrence means an operator manually wrote down
  a stuck `inTransitAssets` leg after confirming (via CCIP Explorer) that the message is
  permanently dead and manual execution cannot recover it. Investigate the root cause (dead
  lane? decommissioned spoke?) before it recurs.
- `SuspiciousSpokeReport` (WI-7) — pauses deposits/withdrawals. Page immediately.
- `WithdrawalQueued` / `SettlementDeferred` — a growing count of deferred, unsettled
  withdrawals signals a persistent solvency gap (idle not keeping pace with claims) worth
  investigating before users start hitting `WITHDRAWAL_TIMEOUT` and cancelling.

**Spoke:**
- `ConfirmSendFailed` — see above; page-worthy.
- `DepositInstructionFailed` / `RebalanceInstructionFailed` — an adapter rejected funds or a
  rebalance leg; funds land as spoke idle instead (not lost), but investigate why the adapter
  rejected the operation (paused protocol? removed adapter still referenced by a stale
  proposal?).
- `RecallShortfall` — the spoke could not fully satisfy a requested recall from idle +
  adapters combined. Expected occasionally under the RECALL_HAIRCUT_BPS margin; frequent
  occurrences suggest spokeBalances is drifting stale faster than reports refresh it.

## Recovery path summary

| Symptom | Cause | Recovery |
|---|---|---|
| Spoke confirm never lands, `ConfirmSendFailed` fired | LINK exhausted (or transient router issue) on spoke | Top up spoke LINK, call `retryConfirm(index)` (permissionless) |
| `inTransitAssets` stuck non-zero for a specific leg, CCIP Explorer shows FAILURE, manual execution exhausted | Dead lane / spoke decommissioned | Wait out `TRANSIT_RECONCILE_DELAY` (7 days), then owner calls `reconcileTransit(messageId)` — releases exactly that leg's tracked amount, nothing more |
| Hub-side send reverts | LINK exhausted on hub, or `InsufficientUnreservedIdle` / `InsufficientRecallLiquidity` guard tripped | Top up LINK; or wait for idle/spoke capacity to recover before resubmitting |
| `setHub` reverts with `PendingConfirmsOutstanding` | Spoke has an unresolved queued confirm | Resolve it via `retryConfirm` first (or wait it out) before rotating `HUB` |
| `removeSpoke` reverts with `SpokeNotDrained` / `SpokeHasInFlightLegs` | Spoke still holds reported balance or has an in-flight DEPOSIT leg | Recall the balance to zero (`Rebalancer.recallFromSpoke`) and let in-flight legs land, then retry; or use `forceRemoveSpoke` if the situation is a genuine emergency (accepts an instant mispricing window — see its NatSpec) |
