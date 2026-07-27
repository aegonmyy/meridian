# D-0: Staleness Audit of state.md

This is a working document, not part of the published docs. It exists to answer one question: which of the design decisions recorded in `state.md` are still true at HEAD, which evolved into something different but real, and which no longer describe the shipped system at all.

Every entry below carries a one line citation naming the file and function that either confirms or contradicts the claim, checked directly against the code, not against memory of the fix campaigns that touched it. This document is the input to D-6 (`docs/design-decisions.md`) and is safe to delete after that document lands, at the owner's call.

Classification key:
- **CURRENT**: still true, mechanism unchanged.
- **EVOLVED**: the underlying decision still stands, but the mechanism that implements it changed enough that documenting the old form would mislead a reader.
- **SUPERSEDED**: no longer true. The decision was replaced, removed, or never actually shipped as described.

---

## CCIPHelpers.sol

**Implemented as `library` not `contract`**: CURRENT
Still `library CCIPHelpers`, all functions `internal pure`. (`CCIPHelpers.sol:CCIPHelpers`)

**Single struct covers all 4 message types**: EVOLVED
The uniform-struct philosophy survived, but the shape described (a single `adapter` field, zero for report/confirm types) is gone. `CcipMessage` now carries an `AdapterInstructions[] instructions` array instead of one adapter field, and the enum has grown from 4 implied types to 7 explicit `MessageType` values. The "one struct, unused fields zeroed" idea continues in the new shape. (`CCIPHelpers.sol:CcipMessage`, `CCIPHelpers.sol:MessageType`)

**`abi.encode` over `abi.encodePacked`**: CURRENT
`encode()` still calls `abi.encode(_message)` directly. (`CCIPHelpers.sol:encode`)

**No message validation in decode**: CURRENT
`decode()` is still a bare `abi.decode`, no type or field checks. (`CCIPHelpers.sol:decode`)

---

## AllocationMaths.sol

**2D array over flat array for `validateAllocation`**: CURRENT
Still `uint256[][] memory _allocations`, chain as outer index, protocol as inner. (`AllocationMaths.sol:validateAllocation`)

**Infinite loop bug (i++ instead of j++)**: CURRENT
The fix holds. Outer loop increments `i`, inner loop increments `j`, no repeat. (`AllocationMaths.sol:validateAllocation`)

**Underflow in `shouldRebalance`**: CURRENT
Early return `if (optimalWeightedApy <= currentWeightedApy) return false;` still guards the subtraction. (`AllocationMaths.sol:shouldRebalance`)

**Grand total check `!=` not `>`**: CURRENT
Still `if (grandTotal != 10000)`. (`AllocationMaths.sol:validateAllocation`)

---

## Architecture

**Dynamic adapter registration over hardcoded protocol constants**: CURRENT
`setAdapter(bytes32, address)` is still the only way to register a protocol, no hardcoded identifiers in source. (`SpokeAdminModule.sol:setAdapter`)

**Adding a new chain requires no redeployment (4 step list)**: CURRENT
`addSpoke` on the hub side and `setAdapter` on the spoke side are unchanged in shape. The off-chain script's `MARKETS` object (`src/strategy.js`) still needs manual editing per chain, matching the "update agent constraints" step. (`HubAdminModule.sol:addSpoke`, `strategy.js:MARKETS`)

---

## SpokeVault.sol

**Dual sender validation on `ccipReceive`**: CURRENT
Router check stays in the inherited `CCIPReceiver` base. The explicit hub check is still a decode-and-compare against the stored `HUB` address, now living in `SpokeHandlersModule` after the module split rather than in a single `SpokeVault.sol` file. (`SpokeHandlersModule.sol:_ccipReceive`)

**Constructor execution order, parent before child**: CURRENT
`_router` is still passed straight to `CCIPReceiver(_router)` ahead of the zero-address checks in the constructor body, now in `SpokeStorage` (the split moved the constructor, not the ordering). (`SpokeStorage.sol` constructor)

**Asset hardcoded to USDC**: CURRENT
`ASSET` is still a single immutable `IERC20`, no multi-asset path. (`SpokeStorage.sol:ASSET`)

---

## SpokeVault.sol (continued)

**Adapter registry, exists flag as source of truth**: CURRENT
`removeAdapter` still just flips `exists = false`, array never shrinks, iteration everywhere gates on `exists`. Worth noting the struct picked up an `everRegistered` field since this entry was written, for array dedup on re-registration, but it doesn't change what `exists` means. (`SpokeAdminModule.sol:removeAdapter`, `SpokeStorage.sol:AdapterInfo`)

**Adapter struct packs into one slot**: EVOLVED
Still one storage slot, one SLOAD, but the struct now has three fields instead of two (`adapter`, `exists`, `everRegistered`), not the `address + bool` pair originally described. Still fits comfortably (20 + 1 + 1 of 32 bytes). (`SpokeStorage.sol:AdapterInfo`)

**Separation of concerns, deposit validation**: CURRENT
`_handleDeposit` still only checks `adapter.exists` and `amount != 0`, no bps math at the spoke. (`SpokeHandlersModule.sol:_handleDeposit`)

**`removeAdapter` as emergency circuit breaker, no timelock**: CURRENT
Still an instant `onlyOwner` call with no delay. (`SpokeAdminModule.sol:removeAdapter`)

**`setAdapter`/`removeAdapter`, no timelock in v1**: CURRENT
Both still instant owner calls. The tradeoff acknowledged in state.md is unchanged and belongs in the known limitations table for v1. (`SpokeAdminModule.sol:setAdapter`, `SpokeAdminModule.sol:removeAdapter`)

**`CCIPMessage.adapter` typed `bytes32` not `address`**: CURRENT
`AdapterInstructions.adapter` is still `bytes32`, spoke resolves the address locally from its own registry. (`CCIPHelpers.sol:AdapterInstructions`)

**Programmable Token Transfer, tokens and instructions are atomic**: CURRENT
`_handleDeposit` still never pulls tokens itself, it approves and deposits what CCIP has already delivered by the time `_ccipReceive` runs. (`SpokeHandlersModule.sol:_handleDeposit`)

**CCIP message latency, 24hr rebalance cooldown**: SUPERSEDED
The latency reasoning (15-20 min per CCIP leg, spoke reports always somewhat stale) is still sound background, but the specific mitigation described, a 24 hour cooldown between rebalances, does not exist anywhere in the code. `Rebalancer.sol` has no cooldown constant, no last-rebalance timestamp, no rate limiting of any kind on `proposeAllocation` or `rebalance`. Whatever mitigated this in practice, it isn't an on-chain cooldown. (`Rebalancer.sol`, no `constant` timing guard present)

**CCIPMessage redesigned for batch adapter instructions**: CURRENT
Still `AdapterInstructions[] instructions` inside `CcipMessage`, one CCIP send can carry multiple adapter operations. (`CCIPHelpers.sol:CcipMessage`)

**Critical: deposit confirmation required, hub must not assume success**: EVOLVED
The core fix (spoke must always tell hub what happened) is still in place, but the mechanism moved from "confirm only after every deposit in the batch succeeds" to "confirm always, truthfully, per instruction." Each instruction is now independently attempted with try/catch. A failed or skipped instruction emits `DepositInstructionFailed` and leaves its amount as spoke idle rather than blocking the whole batch. `CONFIRM_RECEIPT` fires unconditionally at the end regardless of how many instructions succeeded. (`SpokeHandlersModule.sol:_handleDeposit`)

**CCIP failed message recovery (first mention, in SpokeVault section)**: SUPERSEDED
See the fuller entry under HubVault.sol below, same verdict applies here. `retryFailedMessage`/`getFailedMessages` was never built, `reconcileTransit` is what shipped instead. (`HubAdminModule.sol:reconcileTransit`)

---

## HubVault.sol

**`totalAssets()` anchored to `totalPrincipal`**: SUPERSEDED
`totalPrincipal` does not exist anywhere in the codebase. It was removed as dead state, per the comment left in its place. This entry describes the very first design, already reversed once inside state.md itself and now fully gone. (`HubWithdrawalModule.sol:_deposit` doc comment: "totalPrincipal tracking was removed as it was dead state")

**Yield distribution deferred to v2**: SUPERSEDED
Once `totalAssets()` reflects real managed value directly (see next entry), there is no separate yield bucket waiting on a v2 distribution mechanism. Yield already flows into share price today. Distribution isn't deferred, it already happened by the time this entry would apply. (`HubWithdrawalModule.sol:totalAssets`)

**CCIP failed message recovery, funds never permanently lost**: SUPERSEDED
The reasoning about CCIP's recoverable-failed-state behavior is accurate background, but the concrete plan ("SpokeVault needs `retryFailedMessage` and `getFailedMessages`") was not what shipped. What actually shipped is `reconcileTransit`, an owner-gated, per-message, amount-exact release that only works after `TRANSIT_RECONCILE_DELAY` (7 days) has passed, replacing the earlier `adjustInTransitAssets` free-form setter along the way. Much narrower and more precise than the generic retry pattern described here. (`HubAdminModule.sol:reconcileTransit`)

**`totalAssets()` reverted to standard ERC4626 behaviour**: CURRENT
This is exactly what ships today. `totalAssets()` returns `totalManagedAssets()`, idle plus spoke balances plus in-transit. (`HubWithdrawalModule.sol:totalAssets`, `HubWithdrawalModule.sol:totalManagedAssets`)

**Withdrawal flow, two path design with implicit balance updates**: EVOLVED
The path shapes described here (Path 1 idle and fresh, Path 2 idle but stale, Path 3 idle insufficient) map remarkably closely to the three paths that ship today, so the underlying intuition held up well. What changed is everything about settlement mechanics: queue-time quoting became claim-time pricing (payout recomputed at settlement, not promised at request time), single-spoke recall became multi-leg haircut-capped recall planning across all active spokes, and settlement gating moved inside `_attemptSettleWithdrawal` so it can't be bypassed by calling the permissionless entry point early. Document the current form, not this one. (`HubWithdrawalModule.sol:_withdraw`, `HubWithdrawalModule.sol:_attemptSettleWithdrawal`)

**Yield socialization, proportional slice of the whole protocol**: CURRENT
Still true, still the correct mental model. No per-user or per-spoke claim tracking exists anywhere in Hub state. (`HubStorage.sol`, no per-user spoke-attribution state)

**ERC4626 override strategy, internal functions over public facing**: CURRENT
Still `_deposit` and `_withdraw` overridden, `redeem`/`withdraw` (the public entry points) left untouched. (`HubWithdrawalModule.sol:_deposit`, `HubWithdrawalModule.sol:_withdraw`)

**Why no `super._withdraw`**: CURRENT
Still no `super._withdraw` call anywhere in the override. Shares still only burned once funds are confirmed available. (`HubWithdrawalModule.sol:_withdraw`)

**Two path withdrawal flow summary (Path 1/2/3 breakdown)**: EVOLVED
Same verdict as the entry above it. The three-way shape survived, the settlement internals were rewritten wholesale for v2 (claim-time pricing, multi-leg recall, gates inside settlement). (`HubWithdrawalModule.sol:_withdraw`)

**Accidentally sent tokens are unrecoverable, donated to shareholders**: CURRENT
`_idleBalance()` still reads raw `balanceOf(address(this))`, no filtering of unsolicited transfers. (`HubWithdrawalModule.sol:_idleBalance`)

**`totalManagedAssets` formula, three mutually exclusive buckets**: CURRENT
Still idle plus spoke balances plus in-transit, no overlap. `totalPrincipal` is no longer part of the sum because it no longer exists at all (see above), rather than being excluded from a sum it could still contribute to. (`HubWithdrawalModule.sol:totalManagedAssets`)

**Critical: concurrent withdrawal race, `reservedAssets`**: CURRENT
The exact pattern quoted in state.md (`reservedAssets += assets` on queue, `reservedAssets -= assets` on release) is still literally present in the withdrawal path, now spread across the three-path engine with per-entry `reservedIdle` tracking rather than one flat variable touched inline everywhere. (`HubWithdrawalModule.sol:_withdraw`, `HubWithdrawalModule.sol:_attemptSettleWithdrawal`)

**Architecture: hub sends amount, spoke decides withdrawal source**: CURRENT
The quoted signature `recallFromSpoke(uint64 chainSelector, uint256 amount) external onlyRebalancer` is still present verbatim as the Rebalancer-driven overload. A second, 3-arg overload was added later for Path 3 leg dispatch (carries a `messageId` so the arrival can be matched to a pending withdrawal), which state.md doesn't mention but doesn't contradict either. (`HubMessagingModule.sol:recallFromSpoke`, 2-arg overload)

**`WITHDRAW` vs `WITHDRAW_AMOUNT`, two message types for two use cases**: EVOLVED
The separation of concerns (Rebalancer gets adapter-level precision, user withdrawal recall gets simple total-amount) is still exactly right and still shipped. What changed is the name and the disambiguation mechanism: there is no `WITHDRAW` type anymore, intra-spoke moves now get their own dedicated `REBALANCE` message type instead of being a `targetAdapter`-flagged variant of a shared `WITHDRAW` type. (`CCIPHelpers.sol:MessageType`)

**`WITHDRAW_AMOUNT`, proportional withdrawal, not greedy**: EVOLVED
The proportional formula and the "last active adapter absorbs the rounding remainder" fix are both still in the code exactly as described. What's new since this entry was written: spoke idle is now drained first before touching any adapter, and each adapter's `withdraw()` call is individually wrapped in try/catch so one paused or reverting protocol can't stall the whole recall. Skipped legs are reported via `RecallPullFailed`, and the CCIP amount sent back always reflects the truthful total pulled, never the amount requested. (`SpokeHandlersModule.sol:_handleWithdrawalWithAmount`)

**Spoke balance staleness, report timestamp vs arrival timestamp**: CURRENT
Hub still stores `_message.reportTimestamp` (spoke-generated) into `lastReportTimestamp`, not local arrival time, across all four callback handlers. `MAX_STALENESS` is still 1 hour. (`HubMessagingModule.sol:_handleReportBalanceCallback`, `HubStorage.sol:MAX_STALENESS`)

**Cross-chain timestamp drift acceptable for staleness window**: CURRENT
The reasoning depends on `MAX_STALENESS` being generous relative to cross-chain drift. `MAX_STALENESS` is still 1 hour, so the same conclusion holds. No code enforces or measures drift directly, this was always an operational judgment call and remains one. (`HubStorage.sol:MAX_STALENESS`)

**`WITHDRAW` message type, intra-spoke rebalancing only**: EVOLVED
Same underlying idea (move capital between adapters on one chain, no cross-chain hop, no token transfer back), but the confirm sent back is `CONFIRM_REBALANCE`, a dedicated type, not the `CONFIRM_RECEIPT` reuse described in state.md's worked example. The `targetAdapter` field's role also changed. Rather than a zero or nonzero flag disambiguating one message type, `REBALANCE` and `WITHDRAW_AMOUNT` are now separate types entirely, so `targetAdapter` is simply always meaningful inside a `REBALANCE` instruction. (`SpokeHandlersModule.sol:_handleRebalance`)

**`inTransitAssets` accounting via `transitAmounts` mapping**: EVOLVED
The core idea (track the exact amount sent per message so the decrement on confirmation is precise, never derived from the spoke's self-reported balance) is fully intact, now under the name `inTransitAmount` (singular) rather than `transitAmounts`. What's new: a companion `transitLegs` mapping now also stores the origin selector and send timestamp per message, added to support `reconcileTransit`'s per-selector, age-gated recovery path, something state.md predates entirely. (`HubStorage.sol:inTransitAmount`, `HubStorage.sol:transitLegs`)

**Full deposit accounting flow with numbers**: EVOLVED
The arithmetic identity in the walkthrough (idle plus inTransitAssets plus spokeBalances, no double counting across the transit boundary) still matches `totalManagedAssets()` exactly, and the numbers in the example are still internally consistent under that formula. What the walkthrough doesn't show, because it predates it, is that an arriving spoke balance no longer gets applied to `spokeBalances` directly. It first passes through `_applyReportedBalance`'s upside-only sanity band, and is quarantined instead of applied if it looks too good to be true relative to `netSentToSpoke`. (`HubWithdrawalModule.sol:totalManagedAssets`, `HubMessagingModule.sol:_applyReportedBalance`)

---

## Agent Strategy

**Deterministic Optimiser with AI Risk Gate (original)**: SUPERSEDED
This was the first of two agent-architecture decisions recorded back to back in state.md, and it was already superseded by the "Revised" entry immediately below it in the same document. Recording it here only for completeness, see the next entry for what actually shipped.

**Revised: AI Allocation with Deterministic Fallback and Validation**: EVOLVED
The overall shape shipped. An LLM proposes an allocation from live APY data plus hard constraints, and the constraints are enforced independently of what the model returns. Three concrete details differ from what's written, though. First, the model is Gemini (`gemini-3-flash-preview` via the Google Generative Language API), not DeepSeek. Second, the "fallback to greedy math optimizer if AI output is invalid or unavailable" path does not exist in `strategy.js`. There is no try/catch around the model call and no greedy path to fall back to. Third, the off-chain `validateAllocation` function that mirrors the hard constraints is defined in `strategy.js` but is never actually called anywhere in the file. Only the on-chain `Rebalancer.proposeAllocation` check (`AllocationMaths.validateAllocation`, which reverts rather than falling back) is the real safety net today. (`strategy.js:getGeminiAllocation`, `strategy.js:validateAllocation`, defined but unused, `Rebalancer.sol:proposeAllocation`)

---

## Note for D-5: proposeAllocation sizing, one of the two "still open" items

The documentation plan flags `proposeAllocation` bps sizing (of `totalAssets` vs of idle) as an open decision to verify at time of writing, not to assume. It has landed. `Rebalancer.proposeAllocation` sizes every allocation as bps of `HUB.totalAssets()`, then runs a separate WI-3 pre-check comparing the resulting total request against currently unreserved idle (`idle - reserved`), failing the whole proposal atomically with `InsufficientIdleForProposal` if it doesn't fit, before any CCIP message is sent. So the semantics are bps-of-totalAssets with an idle-sufficiency guard layered on top, not bps-of-idle directly. This should be written up as settled, not as an open question, in `docs/security.md` and `docs/architecture.md`. (`Rebalancer.sol:proposeAllocation`)

The second open item, owner-initiated manual pause with a separate pause reason (deferred to v1.1 per state.md), is still open. No manual pause entry point exists anywhere in the Hub modules. `_pause()`/`_unpause()` are only ever called automatically from inside `_applyReportedBalance`'s quarantine logic. (`HubMessagingModule.sol:_applyReportedBalance`, only caller of `_pause()`/`_unpause()`)

---

## Counts

- CURRENT: 29
- EVOLVED: 11
- SUPERSEDED: 6

46 entries total, counting the two Agent Strategy decisions and the two CCIP recovery mentions (one in the SpokeVault section, one in the HubVault section) as distinct entries since state.md records them separately in separate sections.
