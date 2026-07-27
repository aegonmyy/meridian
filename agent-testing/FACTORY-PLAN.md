# Factory / Multi-Tenant Plan

This document specifies a recommendation and concrete design for turning Meridian into a
multi-tenant SaaS product: a factory-deployed model instead of the single pooled Hub that exists
today. It assumes familiarity with `docs/architecture.md`, `docs/withdrawals.md`,
`docs/design-decisions.md`, `docs/security.md`, `agent-testing/DECISIONS.md`, and
`agent-testing/FINDINGS.md`. Claims about current code are cited by file and line; nothing below
describes code that has been written, only code that would need to be.

## Recommendation

**Phased path from A to B, not a commitment to either in isolation.** Ship Path A (fleet of
isolated per-user stacks) first, because it requires no protocol change beyond automating a
sequence that already works end to end on live testnet (`agent-testing/deploy.mjs`,
`agent-testing/FINDINGS.md`'s validated-OK table). Do not stop there: Path A's unit economics are
bad enough at small account sizes that it cannot be the SaaS's steady-state architecture, and the
founder's own framing already identifies why. Path B's shared-spoke design is the correct
long-term target, but it requires a real protocol change to `Spoke` with a higher blast radius
than anything found this week (`agent-testing/FINDINGS.md`'s dust-lock and Path-3-stall findings
are both bounded, single-tenant issues; a shared-ledger bug is a cross-tenant fund-safety issue),
so it must sit behind an audit gate, not ship on the strength of testnet validation the way the
current single-tenant deployment did.

The reason this has to be a phased path rather than a pick-one decision: Path A's deploy sequence
*is* the onboarding flow for Path B's Hub-only factory (see §3), and Path A in production is the
only way to learn real per-tenant usage patterns (deposit sizes, withdrawal frequency, rebalance
cadence) before locking in the shared-ledger accounting design in §2. Building B's ledger schema
from guesses about tenant behavior, then discovering the real distribution of account sizes after
launch, is a worse sequencing than building A, operating it, and using what it teaches to size B's
sub-ledger and haircut parameters correctly.

One correction to the framing as given: the founder's framing treats "LINK funding on 4 chains
forever" as a Path A tax that Path B removes. That is only half true. Path B removes it for the
*spoke* side, since all tenants share one spoke per chain and thus one LINK balance per chain
(`agent-testing/deploy.mjs`'s `fundLink` step, run once per spoke today, run once per spoke
forever under B regardless of tenant count). It does not remove it for the *hub* side: every
tenant still gets their own Hub contract in Path B (that is the entire premise of "personal Hub
per user" in the founder's framing), and the Hub is the party that pays CCIP send fees on
`sendToSpoke`, `rebalance`, and `recallFromSpoke` (`src/hub/HubMessagingModule.sol:260-272`, `fee
= router.getFee(...)` then `LINK.forceApprove(router, fee)` before `ccipSend`). So each tenant Hub
still needs its own LINK balance on Sepolia under Path B; what amortizes is the *spoke*-side LINK
(spokes pay LINK for `CONFIRM_RECEIPT`/`CONFIRM_REBALANCE`/`CONFIRM_WITHDRAWAL` responses,
`src/spoke/SpokeConfirmsModule.sol:59,162`) and the CCIP message volume for allocation decisions,
since one shared Rebalancer can batch a rebalance across all tenants' capital in a shared
adapter position in fewer messages than N independent Hubs each running their own allocation
cycle. This is still a real, large improvement (it is the dominant cost driver at low tenant
balances), but it is not "no more per-user LINK funding," and the plan below should not oversell
it that way to the founder.

## 1. Path A vs Path B vs the phased recommendation, justified

**Path A economics, from the actual code.** `agent-testing/DECISIONS.md`'s deploy sequence (§1)
requires, per tenant: one Hub, one Rebalancer, one AgentConsumer, three Spokes, three
AaveAdapters, LINK funding on four chains (`deploy.mjs`'s `LINK_FUND = 3 ether` per contract,
`fundLink` calls for the hub and each spoke), and whitelisting every chain selector and protocol
id on that tenant's own Rebalancer before anything cross-chain works
(`Rebalancer.sol:addChainToWhitelist`/`addProtocolToWhitelist`, gated `onlyAuthorized`,
`Rebalancer.sol:311-345`; `agent-testing/DECISIONS.md` G2). A small depositor's CCIP fee per
`sendToSpoke` call is identical in absolute LINK terms to a large depositor's, since the fee is a
function of message size and destination chain, not amount transferred
(`HubMessagingModule.sol:260`, `router.getFee(_chainSelector, ccipMessage)` — no amount term).
This is the founder's stated problem and it is real: fee-per-message does not scale down with
deposit size, so a fleet-of-vaults SaaS taxes small accounts disproportionately, and every tenant
needs perpetual LINK top-ups on four chains regardless of how much or how little of the vault they
actually use.

**Path A's genuine advantage is not just speed, it is isolation.** Every tenant gets a completely
independent share price, and a bug or exploit in one tenant's Rebalancer, spoke, or adapter cannot
touch another tenant's funds, because nothing is shared. This matters for the calculus: Path A can
ship on the strength of this week's testnet validation (`agent-testing/FINDINGS.md`) because the
blast radius of any remaining bug (the dust-lock, the Path-3 stall) is scoped to one tenant, same
as it is today with the single existing deployment. Path B forfeits this isolation property by
design, which is why it needs a strictly higher bar of assurance before real money touches it.

**Path B's real cost is not "harder to build," it is a new class of bug.** The change described in
§2 introduces a shared mutable data structure (a hub-scoped sub-ledger inside every spoke) that
every tenant's withdrawal path reads and writes. `docs/security.md`'s existing invariant suite (19
hub invariants, 9 spoke invariants, `test/invariants/hub/`, `test/invariants/spoke/`) checks
single-tenant properties like the accounting identity and reservation tracking; none of it today
exercises a scenario where two distinct Hub addresses call the same spoke. A new invariant class
is needed: something like "the sum of every hub's sub-ledger entries for a protocol on a spoke
never exceeds that adapter's real `totalAssets()`," and "no hub's `WITHDRAW_AMOUNT` recall can pull
from an adapter balance attributable to a different hub's sub-ledger entry." Getting this wrong is
not a stranded-dust inconvenience (the class of bug actually found this week); it is one tenant's
deposit becoming reachable by another tenant's withdrawal, i.e. theft. This is why Path B needs a
third-party audit gate that Path A, as an isolated-blast-radius design, does not strictly require
before a first cohort of small testnet-money users.

## 2. Path B: the Spoke data structure change

**What identifies the tenant today, and why it's already free.** `SpokeHandlersModule.sol:42`
already decodes the CCIP sender and checks it: `if (abi.decode(message.sender, (address)) != HUB)
revert NotHub();`. `message.sender` is CCIP's `Client.Any2EVMMessage.sender` field — the address of
the contract that called `ccipSend` on the source chain, ABI-encoded. Under Path B, each tenant's
personal Hub is a distinct deployed contract address, so `message.sender` already distinguishes
tenant A's Hub from tenant B's Hub with zero protocol-level change to the message envelope. No new
field needs to be added to `CCIPHelpers.CcipMessage` (`src/libraries/CCIPHelpers.sol`) to carry a
tenant id explicitly — the sender address *is* the tenant id, for free, as long as every message a
spoke acts on is scoped by that address rather than trusted globally the way `HUB`
(`SpokeStorage.sol:72`, a single mutable `address public HUB`) is today.

**What has to change.** Three things, all in the Spoke:

1. `HUB` (`SpokeStorage.sol:72`) stops being a single trusted address and becomes a registry:
   `mapping(address => bool) public authorizedHubs`, populated by an owner-gated
   `addAuthorizedHub(address hub)` / `removeAuthorizedHub(address hub)` pair analogous to today's
   `setHub` (`SpokeAdminModule.sol`). The `_ccipReceive` check at
   `SpokeHandlersModule.sol:42` changes from `!= HUB` to `!authorizedHubs[sender]`, and every
   handler needs the sender address threaded through as the tenant key for the rest of this list.
   This is the direct answer to the founder's question: yes, `Any2EVMMessage.sender` already gives
   tenant identity for free, but only once the spoke's trust model is changed from "one hardcoded
   address" to "a registry of addresses," since the single hardcoded comparison is exactly what
   makes multi-tenancy impossible today.

2. `adapters[protocolId]` (`SpokeStorage.sol:89`, a flat `mapping(bytes32 => AdapterInfo)`) stays
   as the adapter *registry* (which adapters exist, which are active) but stops being the balance
   *ledger*. Balance moves to a new hub-scoped mapping: `mapping(address hub => mapping(bytes32
   protocolId => uint256 balance)) public hubProtocolBalance`. Every place that today mutates or
   reads adapter balances in aggregate needs a matching per-hub entry: `_handleDeposit`
   (`SpokeHandlersModule.sol:86-109`) increments `hubProtocolBalance[sender][protocolId]` by the
   amount actually deposited into that adapter (not the requested amount — the existing skip-on-
   failure pattern, `DepositInstructionFailed`, already computes the true deployed amount per
   instruction, so this is additive bookkeeping, not a rewrite of the deposit logic itself);
   `_handleWithdrawalWithAmount` (`SpokeHandlersModule.sol:200-262`) must cap what it pulls *per
   adapter* at `min(hubProtocolBalance[sender][protocolId], adapter.totalAssets() proportional
   share)` rather than the adapter's full `totalAssets()`, because today's proportional-pull logic
   (`SpokeHandlersModule.sol:225-248`, weighting by `adapterBalance / _totalSpokeBalance`) sizes
   against the adapter's *global* balance, which under Path B is the sum of every tenant's capital
   in that adapter — a tenant recalling their own funds must not be able to pull disproportionately
   from another tenant's share of the same aggregate Aave position, and the existing "last adapter
   gets the remainder" rounding rule (`SpokeHandlersModule.sol:231-234`) needs the same per-hub
   ceiling applied so it cannot round a tenant into a positive balance that exceeds what they
   actually deposited.

3. `_aggregatedSpokeBalance()` (`SpokeHandlersModule.sol:286-302`), today a single number summing
   spoke idle plus every adapter's `totalAssets()`, becomes hub-scoped:
   `_aggregatedSpokeBalance(address hub)` sums `hubIdle[hub]` (idle also needs to become hub-scoped
   for the same reason: `ASSET.balanceOf(address(this))` today is spoke-global, and under
   multi-tenancy a direct transfer or partial-deposit-skip idle credit belonging to tenant A must
   not be reportable as part of tenant B's balance) plus `hubProtocolBalance[hub][protocolId]`
   across `activeAdapters`. This is the function that ultimately drives every `CONFIRM_RECEIPT`,
   `CONFIRM_REBALANCE`, and `REPORT_BALANCE` payload back to that specific hub
   (`SpokeConfirmsModule.sol` builds these), so scoping it correctly is the single highest-value
   correctness fix in this whole section — an unscoped version of this function is exactly the bug
   that would let one tenant's withdrawal or balance report see another tenant's capital.

**What this buys and what it costs.** It buys real economics: the adapter's on-chain
`totalAssets()` (e.g. the aToken balance) is the sum across every tenant, so the actual Aave
position amortizes gas and slippage the same way a normal pooled vault would, while share
accounting per tenant stays exact because each tenant's Hub only ever sees `totalAssets()` computed
from their own `hubProtocolBalance` slice. It costs a strictly larger attack surface per spoke (one
compromised or buggy accounting path can now touch N tenants instead of one) and a new proportional
-rounding hazard across tenants that the current single-tenant spoke has no reason to have ever
tested for. This is the concrete shape of "much higher-stakes bug class" referenced in the
founder's framing, and it is why §7 gates this behind an audit rather than testnet validation
alone.

## 3. Factory contract design

**What it deploys, and in what order, per tenant.** The factory is one contract,
`WorkspaceFactory`, holding the platform-wide constants that do not vary per tenant (CCIP router
per chain, LINK token per chain, USDC per chain, the shared Spoke addresses under Path B, the
platform fee recipient — see §5) and one entry point, `createWorkspace(address tenantDepositor)`,
that reproduces `agent-testing/deploy.mjs`'s hub sequence programmatically instead of via a
resumable off-chain script:

1. Deploy `HUB` with `rebalancer = address(0)` (this placeholder-then-set path is not the circular
   one; `HubStorage` explicitly allows `rebalancer=0` and a later `setRebalancer` call, per
   `agent-testing/DECISIONS.md` §1 step 1 and `HubAdminModule.sol:25`,
   `setRebalancer` is `onlyOwner`). Owner is set to the **platform's** operator address, not the
   tenant — see §4.
2. Resolve the same circular-immutable dependency `deploy.mjs` resolves off-chain
   (`agent-testing/DECISIONS.md` G1: `Rebalancer.AGENT_CONSUMER` and `AgentConsumer.REBALANCER`
   are both `immutable` and both revert on `address(0)`, so neither can be deployed first and
   patched). On-chain, inside a factory contract, this is actually easier than the off-chain
   nonce-prediction `deploy.mjs` uses (`ethers.getCreateAddress({from, nonce: n+1})`,
   `deploy.mjs:60-61`): the factory can compute its own next `CREATE` address deterministically via
   `address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this),
   bytes1(uint8(factoryNonce+1)))))))` (standard RLP-of-nonce address derivation, the same
   arithmetic `deploy.mjs`'s `getCreateAddress` performs, just executed in Solidity instead of by an
   off-chain script watching a mempool nonce), or more simply avoid CREATE-address prediction
   entirely by using `CREATE2` for both `Rebalancer` and `AgentConsumer` with tenant-derived salts,
   so both addresses are computable in a single view call before either is deployed, with no
   dependency on deployment order or transaction-count timing at all. CREATE2 removes the "a wrong
   nonce silently mis-wires auth" failure mode `agent-testing/DECISIONS.md` flags for the off-chain
   script (a factory doing on-chain nonce prediction inherits the same fragility the off-chain
   script has; CREATE2 does not).
3. Deploy `Rebalancer(hub, predictedOrCreate2AgentConsumer, platformOperator)`.
4. Deploy `AgentConsumer(rebalancer, platformAgentWallet, platformOperator)` — under CREATE2 this
   is a direct deploy at the pre-computed address, not a deploy-then-verify-address step the way
   `deploy.mjs:62-66` has to (`if (agentConsumer.toLowerCase() !== predictedAC...) throw`).
5. `hub.setRebalancer(rebalancer)`.
6. `rebalancer.addChainToWhitelist(selector)` per spoke chain, `rebalancer.addProtocolToWhitelist`
   per protocol — this is gotcha G2 from `agent-testing/DECISIONS.md` (whitelists start empty,
   `Rebalancer.sol:311-345`, and every cross-chain call reverts `ChainNotWhitelisted` /
   `ProtocolNotWhitelisted` until this step runs). The factory should do this in the same
   transaction/deploy batch as the rest, since a partially-wired tenant Hub that silently can't do
   anything cross-chain until a follow-up call is exactly the kind of gap `deploy.mjs`'s resumable-
   step design (`loadDeployment`/`saveDeployment` around every step) exists to protect against for
   a single manual deployment; a factory doing this for N tenants automatically needs the whole
   sequence to either fully succeed or fully revert, not partially land.
7. Under Path A only: also deploy three `SpokeVault`s and three `AaveAdapter`s per tenant
   (`deploy.mjs`'s `deploySpoke`), fund each with LINK, `setAdapter`, and `hub.addSpoke` per spoke
   selector (`agent-testing/DECISIONS.md` §1's L2 sequence, steps 1-4, plus the hub-side
   `addSpoke` in step 9). Under Path B, skip this step entirely: `createWorkspace` instead calls
   each shared spoke's `addAuthorizedHub(newHub)` (§2's new admin function) and `hub.addSpoke`
   against the platform's existing shared spoke addresses, which is a dramatically cheaper and
   faster onboarding step (no new contract deploys, no new LINK funding, on three fewer chains).
8. Fund the new Hub with LINK from a platform-held reserve rather than requiring the tenant to
   source and bridge LINK themselves on day one (this is an operational/billing question, not a
   contract one — see §5 for the fee mechanism that should recoup this cost over time).

**What "in what order" resolves that `deploy.mjs` doesn't already show.** `deploy.mjs` is a
sequential, resumable *script* driven by an EOA across four chains, tolerant of manual retries
between steps (its `d.hub.hub` / `saveDeployment` checkpointing). A factory contract cannot spread
a single tenant's onboarding across four chains atomically — CCIP does not provide synchronous
cross-chain transactions — so `createWorkspace` on Sepinia can only deploy and wire the Hub-side
contracts (steps 1-6, 8) in one transaction. The spoke-side steps (7, Path A only) are a separate,
chain-local transaction per L2, meaning a Path A tenant's onboarding is *necessarily* a multi-
transaction, multi-chain sequence no matter how much of it is automated, exactly as it is today for
the single existing deployment, just triggered by a factory call instead of a hand-run script. The
UI and any onboarding backend needs a state machine that tracks "Hub deployed, Sepolia wiring done,
Arbitrum spoke pending, Base spoke pending, Optimism spoke pending, registration pending" per
tenant under Path A, collapsing to just "Hub deployed and wired" under Path B.

## 4. Ownership / access-control model for a per-user workspace

**The good news, from the code as it stands today: user-facing operations are already
permission-free.** `deposit`, `mint`, `withdraw`, and `redeem` are the standard, unmodified
OpenZeppelin ERC4626 public entry points (`docs/architecture.md`: "Only the internal hooks
`_deposit` and `_withdraw` are overridden; the public entry points... are unmodified"). None of
them carry an `onlyOwner` or similar gate. This means a workspace's `owner()` (the `Ownable` role
inherited by `HubStorage`, `HubStorage.sol:25`) can be set to the **platform's** operator key at
creation time, while the tenant simply calls `deposit`/`withdraw`/`redeem` on their Hub with their
own wallet, with zero code change needed to separate "who deposits" from "who administers." This is
already the shape the founder wants ("the platform retains rebalancing/admin control while the
user is just a depositor") — it just needs the factory to wire ownership that way rather than
handing `owner()` to the tenant.

**What the platform retains (owner-gated today, stays owner-gated, owner = platform):**
`addSpoke`/`removeSpoke`/`forceRemoveSpoke`, `setRebalancer`, `reconcileTransit`,
`acceptQuarantinedReport`/`rejectQuarantinedReport`, `setOutboundGasLimit`
(`HubAdminModule.sol:25,34,59,82,121,143,184,211`), and on the Rebalancer side,
`addChainToWhitelist`/`removeChainFromWhitelist`/`addProtocolToWhitelist`/
`removeProtocolFromWhitelist`, `rebalance`, `recallFromSpoke`, `proposeAllocation`, all gated
`onlyAuthorized` (owner or `AgentConsumer`, `Rebalancer.sol:115-120,163-168,207-210,228-230,
311-345`). The off-chain agent path (`AgentConsumer.onlyAgent`, `AgentConsumer.sol`: `msg.sender !=
AGENT && msg.sender != owner()`) should point at one platform-operated agent wallet shared across
every tenant Hub's Rebalancer under both paths — the founder should not build a per-tenant agent
key, since the allocation decision (which chain, which protocol, what split) is a platform judgment
call, not a tenant one, in both Path A and Path B.

**What the tenant retains:** `deposit`/`mint`/`withdraw`/`redeem`/`previewX` on their own Hub only,
plus the permissionless recovery entry points already public to anyone
(`cancelWithdrawal(ownId)`, `attemptSettlement(id)`, `retryConfirm(index)`, per
`agent-testing/DECISIONS.md`'s interaction-surface table) — these are already scoped by
`msg.sender`/ownership-of-entry checks inside the functions themselves (e.g. `cancelWithdrawal`
requires the caller to be the pending withdrawal's own owner, `docs/withdrawals.md`), so no new
access-control work is needed there; they already behave correctly per-tenant because they are
keyed by withdrawal-entry ownership, not by any Hub-wide role.

**What needs actual new access-control work, beyond "wire owner() to the platform key":** today's
model is a single EOA holding every privileged role at once — Hub owner, Rebalancer owner,
AgentConsumer owner, and `AGENT` (`agent-testing/DECISIONS.md` §2, "the god-key," with the private
key already committed in plaintext to `run-live.mjs` per that same document — flagged again in §8).
A factory deploying N tenant Hubs must not reuse that pattern: the platform operator role should be
a multisig or a timelocked contract, not a single EOA, precisely because it now controls N tenants'
`addSpoke`/`reconcileTransit`/quarantine-resolution surface instead of one. This is a bigger deal
under a factory than it is today, because a single compromised key now endangers every tenant
workspace simultaneously rather than one deployment.

## 5. Billing / fee mechanism

**No fee mechanism of any kind exists in `src/` today** (verified: every "fee" hit in the contracts
is CCIP's own LINK messaging fee — `router.getFee`, `HubMessagingModule.sol:260` — not a Meridian
revenue mechanism; grep across `src/` for anything resembling a management or performance fee
returns nothing). This has to be built from scratch, and where it lives matters because of how
fragile the withdrawal engine already is (`docs/withdrawals.md`'s three-path settlement pricing,
claim-time repricing, and the `SettlementDeferred` gate structure): touching `_attemptSettleWithdrawal`
directly to skim a fee at payout time means adding a new failure mode to a function `docs/design-
decisions.md` already calls "the most significant structural decision" in the whole engine, and
this week's testing already found a real stall bug in that exact function (`docs/docs-findings.md`
item #5). Do not add fee logic there.

**Recommended mechanism: a time-based management fee accrued as share dilution, checkpointed on
every deposit/withdraw call, in the style of Yearn V2's `_assessFees` rather than a withdrawal-time
skim.** Concretely: add a `lastFeeCheckpoint` timestamp and `managementFeeBps` (platform-wide
constant set at factory deploy time, or per-tenant tier if the founder wants pricing plans) to
`HubStorage`. On every `deposit`/`withdraw`/`redeem` call, before the standard ERC4626 logic runs, a
new internal hook computes `elapsed = block.timestamp - lastFeeCheckpoint`, mints
`feeShares = totalSupply() * managementFeeBps * elapsed / (10_000 * 365 days)` to the platform's fee
recipient address, and updates the checkpoint. This dilutes every tenant's share price
proportionally over time (the same mechanism a standard AUM fee uses in any share-based vault) and
requires touching only `_deposit`/`_withdraw` entry points that already run on every user action,
not the async settlement internals. It composes cleanly with claim-time repricing, since the fee
accrual and the withdrawal payout computation are sequential, independent steps rather than the
fee being carved out of a specific payout number.

**A performance fee is a second, separate mechanism, and should be tied to realized yield reports,
not to totalAssets growth generally** (totalAssets can grow from a fresh deposit, which is not
yield and should not be fee-able). The natural hook point is `_applyReportedBalance`
(`HubMessagingModule.sol`, referenced in `docs/design-decisions.md`'s hardening-campaign section as
the sanity-band gate for spoke reports): when a spoke's newly accepted report exceeds the prior
high-water mark tracked for that spoke (a new `highWaterMark[selector]` value, rebased the same way
the sanity band's baseline is rebased on `acceptQuarantinedReport`, per `docs/design-decisions.md`'s
description of that rebase), mint fee shares against `(newBalance - highWaterMark) *
performanceFeeBps / 10_000` before updating `spokeBalances`. This only fires on genuine yield
crossing a new high, not on every report, and does not touch the withdrawal path at all.

**Where the fee recipient address lives:** a single platform-wide treasury address, set once on the
`WorkspaceFactory` and passed into every tenant Hub's constructor as an immutable, not owner-
configurable per tenant (a tenant should not be able to redirect their own workspace's fee
recipient, and the platform should not need N separate treasury-update transactions to change fee
economics later — route the constructor argument through the factory so a factory-level admin
function can update it for future workspaces without needing per-tenant migration for existing
ones' *rate*, while accepting that an already-deployed tenant Hub's *recipient address* is
immutable and fixed at that tenant's creation time, same as every other immutable in this codebase's
existing pattern of "immutable now, replace the whole contract later if it must change").

## 6. UI / indexing changes

**What breaks today, concretely.** `ui/lib/contracts.ts` hardcodes exactly one address per
contract role globally, read from `NEXT_PUBLIC_HUB_ADDRESS` /
`NEXT_PUBLIC_REBALANCER_ADDRESS` / `NEXT_PUBLIC_AGENT_CONSUMER_ADDRESS` /
`NEXT_PUBLIC_{ARB,BASE,OP}_SPOKE_ADDRESS` (`ui/lib/contracts.ts:7-27`), each with a zero-address
fallback. Every hook built on top of this (`ui/hooks/use-hub-events.ts`, consumed by
`ui/app/(app)/dashboard/page.tsx`, `ui/app/(app)/allocations/page.tsx`,
`ui/app/(app)/operator/page.tsx`, `ui/app/(app)/deposit/page.tsx`) watches events against that one
hardcoded address. `ui/hooks/use-ccip-messages.ts` at least takes `hubAddress` as a function
parameter rather than a hardcoded import (`use-ccip-messages.ts:36`), which is the right shape and
the template the other hooks should be refactored toward, but every page that calls it today still
passes the single global address, not a per-workspace one.

**What needs to replace it:**

1. **A registry, on-chain, not just off-chain.** The `WorkspaceFactory` from §3 should expose
   `getWorkspacesForOwner(address depositor) view returns (address[])` or emit a
   `WorkspaceCreated(address indexed tenant, address hub, address rebalancer, address
   agentConsumer, address[] spokes)` event and let an indexer build the mapping (see point 3
   below) rather than trusting an off-chain database as the source of truth for which Hub belongs
   to which user — the factory is the authoritative registry, a database is a cache of it.
2. **A workspace switcher in the UI**, replacing the single global `HUB` constant with a
   per-session selected workspace address, threaded through every hook the way
   `use-ccip-messages.ts` already threads `hubAddress` as a parameter. This is a real, if
   mechanical, refactor of `use-hub-events.ts` and every page listed above, not a config change.
3. **A real indexer instead of hardcoded per-contract hooks.** Today's model (a hook per contract
   address, polling or watching events directly against one known address) does not scale past a
   handful of tenants, since the UI would otherwise need to open a subscription per contract per
   active tenant workspace. A subgraph or equivalent indexer (e.g. Ponder, a custom indexer against
   the factory's `WorkspaceCreated` event plus each spawned Hub/Spoke's events) should index every
   workspace's events under one schema keyed by tenant, and the UI should query that indexer rather
   than watching N sets of contract events directly. Under Path B specifically, this also becomes
   the only practical way to show a tenant their own balance, since a shared spoke's on-chain state
   (§2's `hubProtocolBalance[hub][protocolId]`) is queryable per-hub in principle but doing so by
   direct multi-hop RPC calls per page load, across three L2s, for every tenant, is not a workable
   UI architecture at any real user count.

## 7. Phased implementation roadmap

**Phase 0 (no protocol change, ships now-ish).** Build `WorkspaceFactory` for Path A only:
deploy Hub + Rebalancer + AgentConsumer + three Spokes + three AaveAdapters per tenant, automate
the exact sequence `agent-testing/deploy.mjs` already validated live, with the CREATE2 improvement
from §3 to remove the nonce-prediction fragility `agent-testing/DECISIONS.md` flags. Wire ownership
per §4 (platform multisig owns every tenant Hub/Rebalancer/AgentConsumer; tenant only ever calls
ERC4626 entry points). Add the management-fee mechanism from §5, since it touches only
`_deposit`/`_withdraw` and composes with either path. This phase's risk profile is the same as
today's single-tenant testnet deployment, replicated N times with isolated blast radius per tenant
— it does not need a third-party audit to be more defensible than shipping is already, though a
multisig or timelock on the platform operator role (§4) should be in place before any tenant's real
money is at stake, not deferred to "later."

**Phase 1 (protocol change, gated).** Design and implement §2's shared-ledger Spoke change
(`authorizedHubs` registry, per-hub idle and per-hub-per-protocol balance mappings, scoped
`_aggregatedSpokeBalance`), plus the new cross-tenant invariant class described in §1 (no hub's
sub-ledger sum for a protocol may exceed that adapter's real balance; no hub's recall may pull
another hub's sub-ledger balance). Extend the invariant fuzzing harness
(`test/invariants/spoke/`) to run multi-hub call sequences, not just single-hub ones — this is new
test infrastructure, not an extension of the existing single-tenant suite. **A third-party security
audit is a hard gate before any tenant's real funds route through a shared spoke under this
design** — not a nice-to-have, given that the bug class this phase introduces is fund-theft-shaped,
unlike anything found in this week's single-tenant validation.

**Phase 2 (rollout).** Migrate new tenant onboarding to Path B (shared spokes, personal Hub only),
using the factory's cheaper `createWorkspace` path from §3 step 7's Path-B branch. Existing Path A
tenants from Phase 0 are not forcibly migrated — migrating a live tenant's capital from an isolated
spoke stack to a shared one is itself a cross-chain fund movement with its own risk, and should be
optional/tenant-initiated rather than a platform-forced cutover, at least initially.

**What should not be built at all before real money, regardless of phase:** anything that
resembles today's "god-key" pattern (`agent-testing/DECISIONS.md` §2: one EOA holding Hub owner,
Rebalancer owner, AgentConsumer owner, and `AGENT` simultaneously, with the private key already
committed in plaintext in `run-live.mjs`, per that same document). A factory multiplies the blast
radius of that pattern by the tenant count; it must not survive into a real-money deployment in any
phase.

## 8. Additional risks and considerations found while reading the code, not previously flagged

- **The god-key's private key is already committed in plaintext** (`agent-testing/DECISIONS.md`
  §2 and §5: "The god-key private key is in plaintext in `run-live.mjs`, committed to a repo that
  was briefly pushed to GitHub... Recommend generating a fresh operator key for the new deployment
  and retiring the old one"). This must happen before Phase 0, independent of anything else in this
  plan — a factory built on top of a known-compromised operator key is not meaningfully safer than
  today's single deployment, it is just compromised N times over instead of once.
- **CCIP token-lane enrollment is a per-chain, per-token prerequisite that the factory does not
  control and must verify, not assume.** `agent-testing/DECISIONS.md`'s R1 flags that the entire
  cross-chain deposit path only works if the hub-chain USDC is enrolled in the CCIP lane's token
  pool for each Sepolia-to-L2 lane, and that an earlier deployment may never have actually
  succeeded at this (evidence: "the old hub held 5 USDC idle with all spokeBalances = 0"). A
  factory automating deploys across many tenants does not change this constraint; it just means the
  same lane-enrollment check needs to happen once per chain (already true today, unaffected by
  tenant count) rather than being silently assumed to still hold as the system scales.
- **Path 2's global freshness gate becomes a bigger footgun under Path B.** `docs/security.md`'s
  known-limitations table already flags that `_allSpokesFresh()` requires *every* active spoke to
  have reported recently, so one silent spoke stalls every Path 2 withdrawal system-wide, not just
  withdrawals that would have touched that spoke (`HubWithdrawalModule.sol:_allSpokesFresh`, "loops
  every active selector unconditionally"). Under Path A this affects one tenant's own three spokes.
  Under Path B, if the shared spokes report to each tenant Hub independently (each Hub only cares
  about the freshness of the spokes registered on *that* Hub, which under Path B is still all three
  shared spokes, since every tenant Hub presumably registers the same three shared spokes), the
  blast radius is unchanged per-tenant, but the operational cost of keeping every shared spoke
  reporting fresh now matters to every tenant simultaneously rather than one — a single flaky spoke
  under Path B stalls Path 2 withdrawals for the entire tenant base at once, not just one tenant.
  This raises the operational bar on spoke reporting reliability materially under Path B and is
  worth budgeting for (e.g. a keeper that proactively triggers `REPORT_BALANCE` refreshes rather
  than relying on withdrawal-triggered requests alone).
- **The dust-lock fix and the Path-3 stall finding both need re-verification under Path B, not just
  reused as-is.** The dust-lock fix (`docs/docs-findings.md` item #6, sizing `proposeAllocation`
  sends against deployable idle rather than `totalAssets`) is a Rebalancer-side fix and is
  per-tenant regardless of path, so it should carry over cleanly. The Path-3 stall
  (`docs/docs-findings.md` item #5, a recall settling short because yield accrued mid-flight and no
  idle buffer exists) gets *more* likely to bite under Path B, not less: a shared spoke serving many
  tenants accrues yield continuously regardless of any single tenant's activity, so the gap between
  a Path-3 recall's request-time quote and its claim-time payout is driven by aggregate protocol
  yield velocity across all tenants in that adapter, not just one tenant's own deposit size. A
  standing per-tenant idle buffer (already suggested as a mitigation in the finding) becomes more
  important, not less, once many tenants' yield is compounding through the same adapter continuously.
- **`removeAdapter`/`setAdapter` being instant, no-timelock owner calls
  (`docs/design-decisions.md`'s spoke-design section, `docs/security.md`'s known-limitations table)
  is a bigger deal under Path B than Path A.** Today it is a single-tenant risk (a compromised
  owner key redirects one spoke's adapter). Under Path B's shared spokes, the same instant call
  redirects the adapter for every tenant routed through that spoke simultaneously. This strengthens
  the existing recommendation ("production deployment should use a multisig owner and consider a
  timelock specifically on `setAdapter`") from a good idea to something closer to a Phase-1
  prerequisite, given the shared-spoke blast radius.
