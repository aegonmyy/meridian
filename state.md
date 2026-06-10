# Meridian Protocol — Findings & Design Decisions

---

## CCIPHelpers.sol

### Design Decisions

**Implemented as `library` not `contract`**
No state, no deployment, gets linked into other contracts. Functions are `internal pure` — no external attack surface, no side effects.

**Single struct covers all 4 message types**
`adapter` is zero address for `REPORT_BALANCE` and `CONFIRM_RECEIPT` messages. Intentional to keep encoding uniform across all message types.

**`abi.encode` over `abi.encodePacked`**
Packed encoding can cause hash collisions when concatenating dynamic types. `abi.encode` is safer and unambiguous for struct encoding.

### Known Limitations

**No message validation in decode**
Caller is responsible for checking `messageType` before acting on the payload. `SpokeVault` and `HubVault` must handle unknown message types gracefully.

---

## AllocationMath.sol

### Design Decisions

**2D array over flat array for `validateAllocation`**
Initially considered a flat array of 9 elements with hardcoded chain groupings (indices 0–2 Arbitrum, 3–5 Base, 6–8 Optimism). Rejected in favour of a 2D array `uint256[][] allocations` where `allocations[i]` represents a chain and `allocations[i][j]` represents a protocol on that chain.

Why it matters: hardcoded indices require redeployment of the library every time a new chain or protocol is added. The 2D structure makes the chain concentration check a natural outer loop and scales to any number of chains and protocols without touching the library code.

### Bugs Caught During Development

**Infinite loop — `i++` instead of `j++` in inner loop**
In `validateAllocation`, the inner loop was incrementing `i` instead of `j`. This would cause the inner loop to never terminate. Critical bug caught in review before testing.

**Underflow in `shouldRebalance`**
`uint256 result = optimalWeightedApy - currentWeightedApy` reverts if current is greater than optimal. Fixed by returning false early if `optimalWeightedApy <= currentWeightedApy`.

**Grand total check used `>` instead of `!=`**
`grandTotal > 10_000` catches over-allocation but silently passes under-allocation. Fixed to `grandTotal != 10_000` — allocations must sum to exactly 10_000 bps.

---

## Architecture

### Design Decisions

**Dynamic adapter registration over hardcoded protocol constants**
Initially considered hardcoding protocol identifiers as `bytes32` constants (`AAVE`, `COMPOUND`, `MORPHO`). Rejected in favour of a dynamic `setAdapter(bytes32 protocolId, IYieldSource adapter)` admin function.

Why it matters: hardcoded constants require redeployment to add new protocols. Dynamic registration means adding a new protocol = one `setAdapter` call, no redeployment.

**Adding a new chain after deployment requires no redeployment of existing contracts:**
1. Deploy new `SpokeVault` on new chain
2. Call `setAdapter` for each protocol on that spoke
3. Whitelist new chain + spoke address on hub
4. Update agent constraints

The combination of the 2D allocation array in `AllocationMath.sol` and dynamic adapter registration means the entire protocol scales to new chains and protocols with configuration changes only, not code changes.

---

## SpokeVault.sol

### Design Decisions

**Dual sender validation on `ccipReceive`**
`CCIPReceiver` base contract handles the router check internally via its own modifier — only the legitimate CCIP router can call `ccipReceive`. On top of that an explicit hub check decodes `message.sender` and compares against the stored hub address.

Two separate trust boundaries:
- Router check — is this coming through legitimate CCIP infrastructure (handled by base contract)
- Hub check — did this specifically originate from our hub contract, not any other contract on the source chain

A compromised message coming through the router from a non-hub address would pass the first check but fail the second. Both are needed.

**Solidity constructor execution order — parent before child**
Parent constructor executes before the child constructor body. This means if an invalid value is passed to a parent constructor, it is processed by the parent before any checks in the child constructor body run.

In `SpokeVault` the `_router` address is passed directly to `CCIPReceiver` before our zero address checks execute. We rely on `CCIPReceiver` to validate its own inputs.

Why this matters for other protocols: a parent contract that doesn't validate its inputs combined with a child that assumes the parent handles validation is a silent bug waiting to happen. Always check what the parent does with constructor arguments before assuming it's safe.

### Known Limitations

**Asset is hardcoded to USDC**
Adapters support multiple tokens but `SpokeVault` v1 assumes a single asset. Multi-asset support would require removing the hardcoded asset and making each adapter responsible for its own token handling. Deferred to v2.

---

*Document is live — updated as protocol is built.*

---

## SpokeVault.sol (continued)

### Design Decisions

**Adapter registry — exists flag as source of truth**
Chose to flip `exists = false` on removal instead of swap-and-pop from the array. Tradeoff: `removeAdapter` is O(1) instead of O(n), but the array grows permanently. Acceptable because the array is small by design (3-5 protocols max) and the exists flag gates all iteration and lookup logic.

**Adapter struct packs address + bool into one storage slot**
`AdapterInfo { IYieldSource adapter; bool exists; }` — address is 20 bytes, bool is 1 byte, both fit in one 32 byte storage slot. One SLOAD reads both fields. Gas efficient.

**Separation of concerns — deposit validation**
`_handleDeposit` only validates what arrives at the spoke — adapter exists, amount > 0. Allocation math (bps constraints, market limits) is upstream in the Rebalancer. By the time a deposit message arrives the allocation has already been validated on-chain. No double validation needed.

**`removeAdapter` as emergency circuit breaker**
Designed to disable a compromised protocol instantly with one owner call. Speed matters in an exploit scenario — no timelock on removal intentionally.

**`setAdapter` and `removeAdapter` — no timelock in v1**
Both are instant owner calls. Tradeoff acknowledged — a compromised owner key could swap an adapter to a malicious contract immediately. Accepted for v1. Production deployment should use a multisig owner and consider a timelock on `setAdapter` specifically while keeping `removeAdapter` instant for emergency response.

**CCIPMessage.adapter typed as `bytes32` not `address`**
Initially typed as `address` — caused a type mismatch with the `mapping(bytes32 => AdapterInfo)` registry. Fixed to `bytes32` so hub and spoke speak the same language using protocol identifiers (e.g. `keccak256("AAVE")`). The spoke resolves the address locally from its own registry. Hub never needs to know the adapter's address on the spoke — only the protocol ID.

**Programmable Token Transfer (PTT) — tokens and instructions are atomic**
When the hub sends a DEPOSIT message to a spoke, both the USDC and the instruction travel together in a single `ccipSend` call as a Programmable Token Transfer. The CCIP router delivers the tokens to the spoke contract before `_ccipReceive` is called — by the time `_handleDeposit` runs, the USDC is already sitting in the SpokeVault. This means `_handleDeposit` never needs to pull tokens from anywhere — it just approves the adapter and deposits what's already there. The atomicity guarantee means you can never receive an instruction without the corresponding funds, and never receive funds without the instruction.

**CCIP message latency — spoke balance reports are stale by design**
CCIP takes 15-20 minutes per message due to waiting for source chain finality before RMN blessing. A full REPORT_BALANCE round trip (hub → spoke → hub) takes 30-40 minutes. This means the hub's view of spoke balances is always stale by at least that window.

Implication for the Rebalancer: rebalance decisions should not be triggered immediately after a balance report request. The agent and Rebalancer must account for the fact that reported balances reflect state from 30-40 minutes ago, not the current moment. The 24hr cooldown between rebalances partially mitigates this — stale data within a 40 minute window is negligible relative to a 24hr rebalance cycle.

LayerZero would be 2-5 minutes per message but trades the security of full finality confirmation for speed. CCIP's slower speed is a deliberate security tradeoff.

**CCIPMessage redesigned for batch adapter instructions**
Initial design had a single `adapter` and `amount` field in `CCIPMessage` — one message per adapter deposit/withdrawal. Rejected in favour of a batch design where `CCIPMessage` carries an array of `AdapterInstruction` structs:

```
struct AdapterInstruction {
    bytes32 adapter;
    uint256 amount;
}

struct CCIPMessage {
    MessageType messageType;
    AdapterInstruction[] instructions;
}
```

Why it matters: a rebalance may allocate capital to multiple adapters on the same spoke (e.g. Aave + Compound on Arbitrum). Single message design would require two separate CCIP sends — double the fees, double the latency, two separate atomic operations instead of one. Batch design handles all adapter instructions for a spoke in one CCIP message — one fee, one atomic execution, one token transfer covering the total amount.

For REPORT_BALANCE and CONFIRM_RECEIPT, instructions carries a single entry with adapter: bytes32(0) and amount: totalBalance.

**Critical: Deposit confirmation required — hub must not assume successful deployment**
Initial design had `_handleDeposit` executing silently with no confirmation back to hub. This is a vulnerability — if `_handleDeposit` reverts on the spoke (adapter not found, amount zero, adapter paused, protocol exploit), the USDC is stuck on the spoke and the hub never knows. Hub would continue accounting for that capital as deployed via `inTransitAssets` while the spoke holds idle USDC or has failed entirely.

Fix: `_handleDeposit` must send a `CONFIRM_RECEIPT` message back to hub after all deposits succeed — same pattern as `_handleWithdrawal`. Hub only decrements `inTransitAssets` on confirmed receipt, never optimistically.

**CCIP failed message recovery:**
If `_ccipReceive` reverts, CCIP puts the message in a recoverable failed state — it does not auto-refund. The hub needs a `retryFailedMessage` or manual recovery mechanism for stuck messages. Without this, a failed deposit leaves USDC permanently stuck on the spoke with no way to recover it. This must be addressed before mainnet.

---

## HubVault.sol

### Design Decisions

**`totalAssets()` anchored to `totalPrincipal` not `totalManagedAssets`**
ERC4626 does not mandate how `totalAssets()` is implemented — it just requires a `uint256` return. HubVault overrides it to return `totalPrincipal` — the sum of all deposits minus withdrawals — rather than the real managed balance.

Why it matters:
- Share price never drops during CCIP transit (20 min window where funds are neither on hub nor spoke)
- Share price never fluctuates due to stale spoke balance reports (30-40 min latency)
- Principal protection guarantee is enforced at the math level — shares always redeem 1:1 minimum
- Yield accrues in `totalManagedAssets` above the principal floor and is distributed separately

`totalManagedAssets` = idle balance + sum of spoke balances + inTransitAssets. This is the real picture but is not used for share math.

**Yield distribution deferred to v2**
V1 accumulates yield in `totalManagedAssets` above `totalPrincipal`. How yield is distributed — claim function, periodic snapshots, share price appreciation at settlement — is a v2 design decision. ERC4626 does not require yield to flow through the underlying token or share price.

**CCIP failed message recovery — funds are never permanently lost**
Confirmed via Chainlink docs: if `_ccipReceive` reverts on the spoke, the token transfer also reverts and the message enters a recoverable failed state. Funds are locked in CCIP's pool — not lost. Recovery is via `retryFailedMessage` which releases locked funds to a specified receiver.

Implication for Meridian:
- `inTransitAssets` stays incremented until either `CONFIRM_RECEIPT` arrives or manual recovery is triggered
- Funds are always accounted for — either in transit, confirmed on spoke, or recoverable from failed state
- SpokeVault needs to implement the defensive pattern — `retryFailedMessage` and `getFailedMessages` functions from Chainlink's reference implementation
- This confirms the `inTransitAssets` accounting model is safe — no scenario where funds disappear without a corresponding decrement path

**`totalAssets()` — reverted to standard ERC4626 behaviour**
Initial design anchored `totalAssets()` to `totalPrincipal` for principal protection and share price stability. Reverted — following standard ERC4626 convention is more important for composability.

`totalAssets()` now returns `totalManagedAssets` = idle balance + spokeBalances + inTransitAssets.

Why the reversal:
- Standard ERC4626 integrations — dashboards, aggregators, other protocols — expect `totalAssets` to reflect real value including yield
- `previewRedeem` and `previewWithdraw` work correctly for users
- Breaking the convention means Meridian doesn't compose cleanly with the rest of DeFi

Tradeoffs accepted:
- Share price now depends on `inTransitAssets` being tracked correctly — increment on send, decrement on CONFIRM_RECEIPT. If this accounting breaks, share price breaks.
- Share price depends on spoke balance reports being reasonably fresh — stale by up to 30-40 mins between reports. Acceptable given 24hr rebalance cycle.
- Principal protection is no longer guaranteed at the math level — a spoke exploit drops `totalAssets` and share price. This is the honest tradeoff for standard compliance.

`totalPrincipal` is still tracked separately for reference and potential v2 yield distribution mechanics.

**Withdrawal flow — two path design with implicit balance updates**

This took significant reasoning to get right. The core insight is that CONFIRM_RECEIPT messages from spokes always carry the updated spoke balance — every hub↔spoke interaction is an implicit balance report. This eliminates the need for separate REPORT_BALANCE calls in most cases.

**The problem we were solving:**
`totalAssets()` depends on `spokeBalances` being accurate to calculate correct share redemption value. Stale spoke balances mean users redeem at wrong price. But triggering a REPORT_BALANCE before every withdrawal adds 30-40 mins latency and a separate CCIP call. We needed a smarter flow.

**Key insight — piggyback balance updates:**
Every `CONFIRM_RECEIPT` message from a spoke carries the spoke's current total balance. So any deposit or withdrawal to/from a spoke automatically refreshes `spokeBalances` and `lastReportTimestamp` as a side effect. Balances only go stale during idle periods with no protocol activity.

**The two path withdrawal flow:**

**Path 1 — Idle balance covers withdrawal:**
```
requestWithdrawal(shares)
→ Lock shares
→ Idle covers amount
→ Check lastReportTimestamp
→ If fresh → pay immediately, burn shares
→ If stale → trigger REPORT_BALANCE to stale spokes, queue withdrawal
   → Reports arrive → spokeBalances updated
   → Process queued withdrawal → pay, burn shares
```

**Path 2 — Idle balance does NOT cover withdrawal:**
```
requestWithdrawal(shares)
→ Lock shares
→ Idle doesn't cover amount
→ Send WITHDRAW to spoke for shortfall
→ Spoke withdraws from adapter
→ Spoke sends funds + current balance back via CONFIRM_RECEIPT
→ Hub receives funds AND updated spokeBalances in one CCIP message
→ Pay user, burn shares
```

**Why Path 2 never needs a separate REPORT_BALANCE:**
The WITHDRAW instruction forces a spoke interaction. The CONFIRM_RECEIPT that comes back carries the updated balance. One stone, two birds — funds retrieved and balances refreshed atomically.

**Why Path 1 needs REPORT_BALANCE only when stale:**
If idle covers the withdrawal we don't need to touch the spoke for funds. But we still need fresh balances to calculate accurate redemption value. If balances are already fresh from recent activity we skip the report entirely and pay immediately.

**State needed in HubVault:**
```solidity
mapping(uint64 => uint256) public lastReportTimestamp;
mapping(address => PendingWithdrawal) public pendingWithdrawals;
uint256 public constant MAX_STALENESS; // configurable
```

**Yield socialization — users own a proportional slice of the entire protocol**
Users never interact below the HubVault level. They deposit USDC, receive ERC4626 shares representing a proportional claim on `totalAssets()` — the combined value across all spokes, all adapters, all chains.

Yield earned anywhere in the protocol — whether from Aave on Arbitrum, Morpho on Base, or Compound on Optimism — flows into `totalAssets()` and appreciates all shareholders proportionally. No user is allocated to a specific spoke or adapter. There is no concept of "my capital is in Morpho" at the user level.

This means:
- Rebalances between markets are invisible to users — share value is unaffected by which adapter holds the capital
- Yield is socialized — a high performing market benefits all shareholders not just those who "happened to be" in it
- Losses are also socialized — a spoke exploit affects all shareholders proportionally, not just some
- The spoke/adapter architecture is purely internal execution infrastructure

This is standard behavior for a pooled yield vault and is the correct mental model for Meridian.

**ERC4626 override strategy — internal functions over public facing**
OZ explicitly warns against overriding public facing functions like `redeem` and `withdraw` as it can lead to inconsistent behaviour between paired functions. Instead:

- `_deposit` overridden to increment `totalPrincipal` before calling `super._deposit`
- `_withdraw` overridden to implement the two path withdrawal flow — no `super._withdraw` call, no `_transferOut` call. Full flow owned by HubVault.

**Why no `super._withdraw`:**
The standard `_withdraw` burns shares then calls `_transferOut`. For async paths (stale balances or insufficient idle) shares must NOT be burned until funds are confirmed available. Calling super would burn shares before funds arrive — unrecoverable state. So `_withdraw` is fully overridden and handles burn + transfer + event emission manually only on the synchronous path. Async paths defer everything to `_processWithdrawal` which executes when CCIP confirmation arrives.

**Two path withdrawal flow summary:**
- Path 1: idle covers + balances fresh → burn shares, transfer immediately, standard behaviour
- Path 2: idle covers + balances stale → lock shares, trigger REPORT_BALANCE, queue withdrawal
- Path 3: idle doesn't cover → lock shares, send WITHDRAW to spoke, queue withdrawal

Shares only ever burned when funds are confirmed available. No scenario where shares are burned without corresponding asset transfer.

**Accidentally sent tokens are unrecoverable — donated to shareholders**
`totalManagedAssets` sums idle balance via `IERC20(asset()).balanceOf(address(this))`. Any tokens sent directly to HubVault outside of the `deposit` flow are picked up by `_idleBalance` and included in `totalAssets`. This inflates share price slightly — effectively donating the accidentally sent tokens to all existing shareholders proportionally. No recovery path exists for the sender. This is standard behaviour for ERC4626 vaults and is acceptable. A token rescue function could be added for non-asset tokens in v2.

**`totalManagedAssets` formula:**
```
totalManagedAssets = idleBalance + spokeBalances + inTransitAssets
```
These three are mutually exclusive — capital is either sitting idle on the hub, deployed on a spoke, or in CCIP transit. No overlap, no double counting. `totalPrincipal` is NOT included in this sum — it would cause double counting since principal is already represented across the three buckets above.

**Critical: Concurrent withdrawal race condition — idle balance over-promising**
Without reservation, two users requesting withdrawals simultaneously could both be told "idle covers this" when only one can actually be paid.

Example:
- Hub idle = 10 USDC
- User A requests 8 → idle check passes → queued
- User B requests 9 → idle check passes → queued
- Total promised = 17, available = 10 → one will fail

Fix: introduce `reservedAssets` state variable. When a withdrawal is queued and idle covers it, immediately reserve that amount:
```solidity
reservedAssets += assets;
```

Available idle check becomes:
```solidity
uint256 availableIdle = _idleBalance() - reservedAssets;
```

On withdrawal completion, release the reservation:
```solidity
reservedAssets -= assets;
```

This prevents over-promising idle balance to concurrent withdrawers. Without this, the protocol could queue more idle-backed withdrawals than it can actually fulfill.

**Architecture: Hub sends amount, spoke decides withdrawal source**
Initial design had hub specifying exact adapter instructions for withdrawals. Problem: hub doesn't know per-adapter balances on spokes — only total spoke balance. Hub can't safely build adapter-specific withdrawal instructions without risking pulling from an adapter that doesn't have enough.

Fix: new `WITHDRAW_AMOUNT` message type. Hub sends total amount needed, spoke executes greedy withdrawal across adapters:
```
need 500 USDC
Aave balance = 300 → withdraw 300, still need 200
Compound balance = 400 → withdraw 200, done
```

Spoke loops active adapters, withdraws greedily until amount is covered. Hub never needs to know adapter internals — clean separation of concerns.

This simplifies `recallFromSpoke` on hub:
```solidity
function recallFromSpoke(uint64 chainSelector, uint256 amount) external onlyRebalancer
```

No adapter instructions — just chain selector and amount. Spoke handles the rest.

`recallFromSpoke` still uses `AdapterInstruction[]` for explicit rebalance withdrawals where the Rebalancer knows exactly which adapter to pull from. `WITHDRAW_AMOUNT` is specifically for user withdrawal recalls where the hub just needs funds back.

**`WITHDRAW` vs `WITHDRAW_AMOUNT` — two distinct message types for two distinct use cases**

`WITHDRAW` — Rebalancer initiated. Carries explicit `AdapterInstruction[]` specifying exact adapter and amount. Used when rebalancing capital between markets — e.g. "pull 300 USDC from Aave Arbitrum specifically to redeploy into Morpho Base." Rebalancer knows where capital is because it put it there. Precise, intentional.

`WITHDRAW_AMOUNT` — User withdrawal initiated. Carries only a total amount. No adapter specified. Used when hub needs funds back to pay a withdrawing user and doesn't care which adapter they come from. Spoke executes greedy withdrawal across active adapters until amount is covered.

Why both are necessary:
- Rebalancer needs adapter-level precision to execute allocation changes correctly
- User withdrawal path has no adapter-level information at the hub — only total spoke balances are tracked
- Collapsing both into one message type would either force the hub to guess adapter sources (unsafe) or force the Rebalancer to lose precision (suboptimal)

The distinction cleanly maps to the separation of concerns — Rebalancer owns allocation decisions, hub owns user-facing accounting.

**`WITHDRAW_AMOUNT` — proportional withdrawal across adapters, not greedy**
Initial approach was greedy — deplete one adapter before touching the next. Rejected in favour of proportional withdrawal to preserve allocation balance.

Greedy problem: after a user withdrawal, one adapter could be fully depleted while others are untouched. This creates an unbalanced state that forces an unnecessary rebalance cycle.

Proportional approach: each adapter contributes its fair share based on its weight in the total spoke balance:
```
pullAmount[i] = requestedAmount * adapterBalance[i] / totalSpokeBalance
```

This preserves relative allocation ratios across adapters after every withdrawal — the Rebalancer doesn't need to immediately correct the spoke's internal balance.

**Rounding handling:**
Solidity truncates division. Summing individual proportional pulls produces dust shortfall. Fix: last active adapter receives the remainder (`requestedAmount - totalPulled`) instead of the formula result. This guarantees exactly `requestedAmount` is returned with no dust left in adapters.

**Implementation pattern:**
Two passes — first pass identifies the last active adapter index, second pass executes proportional withdrawals switching to remainder logic at the last adapter.

**Spoke balance staleness — report timestamp vs arrival timestamp**
Initial design used arrival time (`block.timestamp` on hub when message received) as `lastReportTimestamp`. This is inaccurate — a report generated 20 mins ago on the spoke arrives at the hub already 20 mins old. Using arrival time understates true staleness.

Fix: spoke includes `reportTimestamp = block.timestamp` in every `CONFIRM_RECEIPT` and `REPORT_BALANCE` message. Hub stores `lastReportTimestamp[chainSelector] = decoded.reportTimestamp` — true age from when the spoke generated the report.

Staleness check `block.timestamp - lastReportTimestamp > MAX_STALENESS` now measures real report age not arrival age.

`MAX_STALENESS = 1 hour` is kept — a report generated on the spoke is considered fresh for 1 hour from generation. Given CCIP takes ~20 mins one way, a report arrives with ~40 mins of freshness remaining. Sufficient window for withdrawal processing.

`CCIPMessage` struct updated to include `uint256 reportTimestamp` field. Spoke populates it, hub reads it.

**Cross-chain timestamp drift — acceptable for staleness window**
`block.timestamp` is not synchronized across EVM chains — each chain's timestamp is set independently by block proposers. In practice Ethereum, Arbitrum, Base, and Optimism timestamps drift by at most ~5 minutes relative to each other.

For Meridian's `MAX_STALENESS = 1 hour` window, a 5 minute drift is a ~8% error — acceptable. Would become a concern if `MAX_STALENESS` were set below ~15 minutes. No fix needed for v1.

**`WITHDRAW` message type — intra-spoke rebalancing only**
`WITHDRAW` with explicit adapter instructions is used exclusively for intra-spoke rebalancing — moving capital between adapters on the same chain without crossing back to the hub.

Example: Move from Aave Arbitrum → Morpho Arbitrum
- Hub sends WITHDRAW to Arbitrum spoke with source and target adapter
- Spoke withdraws from Aave, deposits into Morpho in same transaction
- No tokens leave the chain — spoke sends CONFIRM_RECEIPT back with updated balance
- No token transfer in CCIP message back to hub

`WITHDRAW_AMOUNT` is for cross-chain user withdrawal recalls — tokens physically travel back to hub.

`AdapterInstruction` updated to include `targetAdapter` field:
- `targetAdapter` non-zero → intra-spoke rebalance, no tokens sent back
- `targetAdapter` zero → cross-chain withdrawal, tokens sent back to hub

This distinction eliminates unnecessary cross-chain hops for same-chain rebalances — cheaper, faster, no CCIP latency for intra-spoke moves.

**`inTransitAssets` accounting — precise decrement via `transitAmounts` mapping**
When hub sends USDC to a spoke via CCIP, `inTransitAssets` is incremented by the exact amount sent. When `CONFIRM_RECEIPT` arrives 20 mins later the hub needs to know exactly how much to decrement — it can't use `spokeBalance` from the message because that includes yield on top of the deposited amount.

Fix: `transitAmounts` mapping stores the exact amount sent per messageId:
```solidity
mapping(bytes32 => uint256) public transitAmounts;
```

On send: `transitAmounts[messageId] = totalAmount`
On confirmation: `inTransitAssets -= transitAmounts[messageId]`, then delete entry

**Full deposit accounting flow with numbers:**

Before deposit:
- idle = 1000, inTransitAssets = 0, spokeBalances[Arbitrum] = 500
- totalAssets = 1500

Hub sends 200 USDC to Arbitrum:
- idle = 800, inTransitAssets = 200, spokeBalances[Arbitrum] = 500
- totalAssets = 800 + 200 + 500 = 1500 ✅ no phantom drop during transit

CONFIRM_RECEIPT arrives — spoke reports spokeBalance = 705 (500 existing + 200 arrived + 5 yield accrued during transit):
- inTransitAssets -= 200 → 0
- spokeBalances[Arbitrum] = 705
- totalAssets = 800 + 0 + 705 = 1505 ✅

The 5 USDC yield accrued during the 20 min transit window correctly appears in totalAssets. No double counting — capital is tracked in inTransitAssets during transit and in spokeBalances after confirmation. Never in both simultaneously.

Agent Strategy — Deterministic Optimiser with AI Risk Gate
Two approaches considered for allocation decisions:
Option 1 — LLM decides allocation directly
Pass market data and constraints to DeepSeek, let it return an allocation. Rejected — LLMs don't guarantee hard numerical constraints are respected. Sum equalling exactly 10,000 bps, min/max per market, chain concentration limits — all of these require validation anyway. An invalid allocation from the model means a fallback is needed, which means the math exists regardless. Adding an LLM in the critical path introduces a failure point with no benefit over pure math for a deterministic optimisation problem.
Option 2 — Greedy optimiser with AI risk gate (chosen)
Two separate concerns handled by the right tool for each:

Allocation — greedy sort by net APY, fill from top respecting constraints. Deterministic, auditable, guaranteed valid output, no external dependency in the critical path.
Risk assessment — DeepSeek reviews market data before optimiser runs. Can veto markets showing anomalous APY, negative protocol news, or exploit signals. Vetoed markets are zeroed out before the optimiser sees them.

Why this separation matters: allocation math has a provably correct answer given the constraints. Risk judgment — "does a 2979% APY signal an exploit or a liquidity imbalance?" — is exactly what a language model is strong at. Each tool does what it is good at.
Failure mode: if DeepSeek is unavailable, the risk gate can be skipped and the optimiser runs on unvetted data. Acceptable for v1 — the on-chain guards in Rebalancer.sol are the last line of defence regardless.

Agent Strategy — Revised: AI Allocation with Deterministic Fallback and Validation
Initial decision was deterministic greedy optimiser with AI risk gate. Revised after reasoning through soft diversification requirements.
Why the revision:
Pure APY maximisation is a clean math problem. But Meridian's goal is risk-adjusted yield with soft diversification — "prefer spreading across chains, split between markets within 100 bps of each other, activate at least one market per chain where viable." These are judgment calls, not hard constraints. Encoding them as math produces complex brittle branching logic. This is exactly where a language model reasons naturally.
Final architecture:

Fetch live APYs — Aave, Compound, Morpho across all chains
Calculate net APY per market after annualised gas and bridge costs
DeepSeek receives net APYs + hard constraints + diversification preferences → returns allocation in JSON
Validate output against hard constraints — sum equals 10000, per market max 6000, per chain max 8000, min 500 per active market
If DeepSeek output is invalid or unavailable → fallback to greedy math optimiser
Encode valid allocation as AllocationProposal and return

Separation of concerns:

DeepSeek — allocation decisions including soft diversification judgment
Math validator — enforces hard on-chain constraints, catches invalid AI output
Greedy fallback — deterministic safety net if AI is unavailable or returns garbage
On-chain Rebalancer guards — final defence, validates again before execution

Diversification rules passed to DeepSeek:

Prefer at least one active market per chain if net APY is positive
Split between markets within 100 bps of each other rather than concentrating
Hard constraints are non-negotiable — AI output rejected if they are violated