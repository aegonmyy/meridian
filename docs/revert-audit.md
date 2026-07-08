# Revert Audit — `Spoke._ccipReceive` and `HUB._ccipReceive`

WI-2a deliverable. Enumerates every revert reachable inside the two CCIP entry points
(including reverts raised by external calls: adapters, `getFee`, `ccipSend`, `safeTransfer`),
classifies each as **KEEP** / **EVENT** / **RECONCILE**, and states the reasoning.

**Decision rule applied:** before tokens/irreversible effects → KEEP is acceptable; after →
never hard-revert the whole handler; if the failure blocks a confirm the hub is waiting on →
RECONCILE.

**Core CCIP fact this audit relies on:** a revert anywhere inside `_ccipReceive` unwinds the
*entire* destination execution, including the token release/mint that happened earlier in the
same call frame. So any revert after tokens have logically "arrived" doesn't strand funds in the
receiving contract — it strands them in CCIP limbo (the message sits FAILURE, retryable only via
manual execution, and permanently stuck if the condition is deterministic).

---

## `Spoke._ccipReceive`

| # | Revert | Location | Class | Reasoning |
|---|--------|----------|-------|-----------|
| 1 | `NotHub()` | sender check, top of `_ccipReceive` | **KEEP** | Pre-commitment. No tokens have been attributed to any adapter yet. Retry-after-config-fix works (fix `HUB` pointer, or it was never a real hub message). |
| 2 | ABI decode revert on malformed `message.data` | `CCIPHelpers.decode` | **KEEP** | Pre-commitment, and only reachable if the sender is a corrupted/malicious hub — should never happen from the real hub. Fail-closed is correct; there is no sensible instruction to execute. |
| 3 | `InvalidMessageType()` | end of type dispatch | **KEEP** | Pre-commitment — no handler-specific tokens/effects have started. |
| 4 | `InvalidMessageType()` on `instructions.length == 0` | `_handleDeposit` | **KEEP** | If length is 0, `totalAmount` computed hub-side is 0 too (no `EVMTokenAmount` was attached), so nothing is at stake. Pre-commitment in effect. |
| 5 | `AmountCannotBeZero()` per instruction | `_handleDeposit` loop | **EVENT** (changed from KEEP) | The DEPOSIT message's tokens arrive as *one* lump-sum transfer covering all instructions' amounts, before the loop runs. A revert here rolls back the whole transfer, stranding the good instructions along with the bad one. Fixed: skip the zero/unknown instruction, leave its amount as spoke idle, emit `DepositInstructionFailed`, continue. |
| 6 | `AdapterNotFound()` per instruction | `_handleDeposit` loop | **EVENT** | Same reasoning as #5 — unknown/removed adapter for one instruction must not strand the rest of the deposit. |
| 7 | `adapter.deposit(amount)` external call reverts | `_handleDeposit` loop | **EVENT** | Adapter-specific failure (protocol paused, cap hit, etc.) after tokens are already resident on the spoke. Wrapped in `try/catch`; failure leaves that instruction's amount as idle + `DepositInstructionFailed`. |
| 8 | Outbound `ccipSend` for `CONFIRM_RECEIPT` (incl. `getFee`, LINK `forceApprove`/balance) | end of `_handleDeposit` | **RECONCILE** | Confirmed by design: LINK exhaustion or router hiccup here is independent of whether the deposits themselves succeeded. If this reverts, it would roll back the deposits with it even though funds are validly deployed — the hub is also left waiting on a confirm it will never get. Wrapped: attempt send, on failure persist to `pendingConfirms` + `ConfirmSendFailed`, and do NOT revert — the deposits stay committed. `retryConfirm` is the recovery path (WI-2d). |
| 9 | `InvalidMessageType()` on `instructions.length == 0` | `_handleRebalance` | **KEEP** | REBALANCE carries no CCIP tokens at all — nothing external is at stake. |
| 10 | `AmountCannotBeZero()` per instruction | `_handleRebalance` loop | **EVENT** | No CCIP tokens involved, but the loop performs real `adapter.withdraw` + `adapter.deposit` calls per instruction; a later instruction's revert would unwind an earlier instruction's already-executed intra-spoke move within the same call frame, and block the confirm the hub is watching for spoke balance refresh. Fixed: skip the zero-amount instruction, emit `RebalanceInstructionFailed`, continue with the rest. |
| 11 | `AdapterNotFound()` (source or target) per instruction | `_handleRebalance` loop | **EVENT** | Same reasoning as #10. |
| 12 | `sourceAdapter.withdraw(amount)` external call reverts | `_handleRebalance` loop | **EVENT** | Clamp the pull to `min(requested, sourceAdapter.totalAssets())` first (removes the common revert cause); any remaining failure is caught via `try/catch`, skip + event, funds stay in source adapter. |
| 13 | `targetAdapter.deposit(pulled)` external call reverts | `_handleRebalance` loop | **EVENT** | Wrapped in `try/catch`; failure leaves the pulled amount as spoke idle (not lost — just undeployed) + `RebalanceInstructionFailed`. |
| 14 | Outbound `ccipSend` for `CONFIRM_REBALANCE` | end of `_handleRebalance` | **RECONCILE** | Same reasoning as #8 — LINK exhaustion must not roll back already-executed adapter moves. |
| 15 | `InvalidMessageType()` on `instructions.length == 0` | `_handleWithdrawalWithAmount` | **KEEP** | WITHDRAW_AMOUNT carries no inbound CCIP tokens. Nothing is at stake pre-pull. |
| 16 | `AdapterNotFound()` on `activeAdapters.length == 0` | `_handleWithdrawalWithAmount` | **EVENT** (changed from KEEP) | Previously a hard revert that would permanently block the hub's Path 3 recall if no adapters are ever registered again. Fixed: fall through — idle-only pull, `actualPulled` may be 0, still send a (possibly token-less) `CONFIRM_WITHDRAWAL` so the hub learns the true state instead of waiting forever. This is what unblocks the confirm the hub is waiting on, rather than leaving it permanently stuck (which the old KEEP behavior would have caused — hence the reclassification). |
| 17 | Division by zero when `_totalSpokeBalance == 0` | `_handleWithdrawalWithAmount` proportional math | **EVENT** | Not a deliberate `revert`, but an unguarded division that panics. Guarded: if `_totalSpokeBalance == 0`, skip the proportional pull entirely and rely on idle only. |
| 18 | `adapter.withdraw(pullAmount)` external call reverts (exact-full recall overflow / Morpho `mulDivDown` vs round-up-withdraw mismatch) | `_handleWithdrawalWithAmount` loop | **EVENT in effect, via prevention** | Per the plan's explicit design, adapters stay revert-on-insufficient and the *spoke* adapts: each pull is `min(proportionalShare, adapter.totalAssets())`, and the last adapter's remainder is also min-capped. This removes the two known deterministic revert triggers by construction. **Residual, out of scope per plan:** an adapter that reverts for an unrelated reason (e.g. protocol-level pause) inside this loop is not wrapped in `try/catch` — the plan's WI-2c design does not call for one here (unlike deposit/rebalance), and adapters are explicitly documented as staying revert-on-insufficient. This is flagged as a judgment call in the executor's final report; it is a narrower attack surface than #5/#10 because amounts are now provably within `totalAssets()`. |
| 19 | Outbound `ccipSend` for `CONFIRM_WITHDRAWAL` (token-carrying) | end of `_handleWithdrawalWithAmount` | **RECONCILE** | Highest-stakes case — a revert here would roll back funds *already pulled from adapters into spoke idle*, silently re-depositing nowhere (funds just sit as idle, not lost, but the hub never learns and the withdrawal is stuck). Wrapped exactly as #8/#14: persist to `pendingConfirms`, emit `ConfirmSendFailed`, `retryConfirm` re-sends (re-checking the USDC is still actually held, since `deployIdle` could have redeployed it in the interim — see WI-2d race note). |
| 20 | Outbound `ccipSend` for `REPORT_BALANCE` response | end of `_reportBalance` | **RECONCILE** (extended for consistency) | No tokens are involved, but a stuck REPORT_BALANCE response permanently blocks a Path 2 hub withdrawal from ever settling. Treated the same as the confirm messages for symmetry and because it blocks a confirm the hub is waiting on — this is a judgment call beyond the plan's literal text (which discusses "confirm" sends), extending the same protection to the report-balance response since the underlying hazard (LINK exhaustion) and consequence (permanently stuck hub-side wait) are identical. |

---

## `HUB._ccipReceive`

| # | Revert | Location | Class | Reasoning |
|---|--------|----------|-------|-----------|
| 1 | `NotSpoke()` | sender check, top of `_ccipReceive` | **KEEP** | Pre-commitment sender validation. If a legitimately-registered spoke's message hits this, it means the spoke was deregistered mid-flight — WI-6's `removeSpoke` guard (in-flight leg tracking) is designed to prevent creating this scenario, rather than this handler needing to change. |
| 2 | ABI decode revert on malformed `message.data` | `CCIPHelpers.decode` | **KEEP** | Only reachable from a corrupted/malicious spoke message; fail-closed is correct. |
| 3 | `InvalidMessageType()` | end of type dispatch | **KEEP** | Pre-commitment. |
| 4 | `_handleDepositCallback` / `_handleRebalanceCallback` / `_handleReportBalanceCallback` | storage writes + event only | **N/A — no revert path** | Pure accounting updates; cannot revert under normal Solidity semantics (no external calls, no user-controlled arithmetic that underflows given `inTransitAmount[id]` is always `<=` what was recorded). |
| 5 | `_handleWithdrawalCallback` → `_processWithdrawal` → `IERC20(asset()).safeTransfer(receiver, assets)` | settlement on a token-carrying `CONFIRM_WITHDRAWAL` / `REPORT_BALANCE` arrival | **RECONCILE-adjacent, addressed structurally in WI-4** | A hard revert here (e.g. a blacklisted/incompatible `receiver`, or — pre-WI-4 — insufficient idle causing an underflow) would roll back the token crediting from a CONFIRM_WITHDRAWAL, directly violating "never revert inside a confirm-execution over insufficiency." WI-4 restructures settlement into a non-reverting attempt (`SettlementDeferred` on insolvency) and this audit additionally recommends wrapping the settlement attempt itself (`try/catch` via a self-call, mirroring the existing `this.recallFromSpoke` pattern) so that an external-call failure in `safeTransfer` degrades to "stay pending" rather than reverting the whole CCIP execution. Implemented in WI-4. |

---

## Summary of behavioral changes required by this audit

1. `_handleDeposit`: per-instruction try/catch, skip + event, never hard-revert after the lump-sum transfer has landed (WI-2c).
2. `_handleRebalance`: per-instruction try/catch, skip + event, clamp source pull (WI-2c).
3. `_handleWithdrawalWithAmount`: remove the `AdapterNotFound` hard revert on empty adapter set, guard the zero-total-balance division, min-cap every pull, always send a (possibly token-less) confirm (WI-2b/2c).
4. All four spoke outbound `ccipSend` call sites (`CONFIRM_RECEIPT`, `CONFIRM_REBALANCE`, `CONFIRM_WITHDRAWAL`, `REPORT_BALANCE` response): wrap in try/catch, degrade to `pendingConfirms` + `ConfirmSendFailed` on failure instead of reverting (WI-2d).
5. `HUB._handleWithdrawalCallback` settlement path: made non-reverting under insolvency (claim-time pricing + `SettlementDeferred`) and defensively isolated from external-call failure in `safeTransfer` (WI-4).

Every EVENT/RECONCILE reclassification above satisfies invariant 4 from the plan: no handler
reachable from `_ccipReceive` on either side reverts after tokens are committed, except the KEEP
class enumerated here.
