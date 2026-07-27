# Meridian Factory Plan V2: Permissionless Self-Serve Deployer

This plan replaces `agent-testing/FACTORY-PLAN.md` in full. That prior document is written for a
model we are no longer building: one where we (the platform) own every tenant's stack, operate a
shared fleet, and choose between a "fleet of isolated stacks" (Path A) and a "shared spoke with a
cross-tenant ledger" (Path B). Both of those are discarded here. In particular:

- We do not become the owner of anyone's hub. Ownership goes to the caller.
- There is no shared spoke and no cross-tenant sub-ledger. The entire §2 of the old plan (rewriting
  the Spoke into a hub-scoped ledger) is dropped. Every user gets their own spokes holding their own
  adapter positions, exactly like the single-tenant deployment does today.
- There is no shared agent that we operate on users' behalf by default. If we offer one at all it is
  an opt-in convenience, bounded by each user's own on-chain guards (§5).
- Deposits are open. Meridian hubs are ERC4626 vaults and anyone can deposit into anyone's hub. A
  hub owner registering a malicious adapter is an accepted risk borne by the depositor, not something
  the architecture prevents. Our job is to make that risk legible, not to gate it.

All claims about current behavior below are cited to `src/`. Where the old plan's technical
reasoning is wrong (notably its CREATE2 claim), this document says so directly.

---

## Decisions locked (2026-07-21)

Two product decisions the owner has settled, recorded here so they are not relitigated:

- **No managed off-chain agent for now.** Each hub owner feeds allocation proposals directly from
  their own wallet. There is no shared cross-tenant key and no god-key in the factory product. The
  consequence for the design: `AgentConsumer` is dropped from the per-tenant deploy, the owner's own
  EOA is the authorized caller on their Rebalancer, and the circular
  Rebalancer/AgentConsumer dependency does not need solving at all for launch. A managed-agent
  convenience can be added later as strictly opt-in.
- **Deposits are fully caveat emptor.** No adapter timelock. `setAdapter`/`removeAdapter` stay
  instant and owner-only. A hub owner can swap in a draining adapter after depositors have entered,
  and that loss is borne by the depositor. This is accepted. The mitigation is not on-chain control,
  it is the quality of the due-diligence surface we expose (§4), since that surface is the
  depositor's only defense.

---

## 0. What the code actually is today (verified against src/)

The stack for one tenant, as `agent-testing/deploy.mjs` builds it and as the constructors in `src/`
require it:

- **Hub** (`src/Hub.sol`, storage in `src/hub/HubStorage.sol`). ERC4626 + CCIPReceiver + Ownable +
  Pausable. Constructor args: `(_name, _symbol, _router, _owner, _link, _asset, _rebalancer)`.
  - Immutables that are baked in: `LINK` (`HubStorage.sol:94`), the ERC4626 `asset` (USDC), and the
    CCIPReceiver router. These are **per-chain constants, not per-tenant** (every Sepolia hub uses
    the same LINK, USDC, router).
  - `REBALANCER` is **mutable** (`HubStorage.sol:99`), set post-deploy via `setRebalancer`
    (`HubAdminModule.sol:25`, `onlyOwner`). The constructor explicitly accepts `_rebalancer =
    address(0)` (`HubStorage.sol:461`) so the hub can exist before the rebalancer.
  - `owner` is OZ `Ownable`, so it has `transferOwnership`.
- **Rebalancer** (`src/Rebalancer.sol`). Constructor args `(_hub, _agentConsumer, _owner)`.
  - `HUB` and `AGENT_CONSUMER` are **immutable and per-tenant** (`Rebalancer.sol:28,32`), both
    reject `address(0)` (`Rebalancer.sol:139-143`).
  - `owner` is a **bare `address public owner` with no transfer function**
    (`Rebalancer.sol:36,146`). It does not inherit OZ `Ownable`. There is no `transferOwnership`, no
    setter, nothing. Whoever is passed as `_owner` at construction is the owner forever. This is the
    single biggest blocker to a clean factory handoff and is addressed in §1.
  - Whitelists (`whitelistedChains`, `whitelistedProtocols`) start empty and are populated by
    `addChainToWhitelist` / `addProtocolToWhitelist`, gated `onlyAuthorized` (owner or
    `AGENT_CONSUMER`, `Rebalancer.sol:115-125,311-345`). Until populated, every cross-chain call
    reverts `ChainNotWhitelisted` / `ProtocolNotWhitelisted`.
- **AgentConsumer** (`src/AgentConsumer.sol`). Constructor args `(_rebalancer, _agent, _owner)`.
  `REBALANCER` and `AGENT` are **immutable and per-tenant** (`AgentConsumer.sol:21,26`), both reject
  zero. `owner` is OZ `Ownable` (has transfer).
- **Spoke** (`src/spoke/SpokeStorage.sol`). Constructor args `(_hub, _asset, _router, _owner, _link,
  _hubSelector)`.
  - `HUB` is **mutable** (`SpokeStorage.sol:72`, set via `setHub`, `SpokeAdminModule.sol:71`). But
    the constructor still rejects `_hub == address(0)` (`SpokeStorage.sol:199`), so **the hub
    address must exist before a spoke can be deployed**. This is the multi-chain chicken-and-egg.
  - `ASSET`, `HUB_CHAIN_SELECTOR`, `LINK`, router are immutable and per-chain constants.
  - `owner` is OZ `Ownable` (has transfer).
  - Adapters start empty, registered via `setAdapter` (`SpokeAdminModule.sol:34`, `onlyOwner`).
    `setAdapter` and `removeAdapter` are **instant, no timelock** (`SpokeAdminModule.sol:34-60`).
- **Adapters** (`src/adapters/*.sol`). All immutable-only, no owner. AaveAdapter
  `(_aave, _aToken, _asset)`; CompoundAdapter `(_asset, _compound)`; MorphoAdapter takes 7 args.
  These immutables are **per-market constants** (the Aave pool, the aToken), shared across all
  tenants who use that market. But the adapter **holds the funds** (AaveAdapter.totalAssets() is
  `A_TOKEN.balanceOf(address(this))`, `AaveAdapter.sol:47-49`), so each spoke needs its **own**
  adapter instance. Adapters cannot be shared across tenants.

The **circular immutable dependency**: `Rebalancer.AGENT_CONSUMER` and `AgentConsumer.REBALANCER`
are both immutable and both reject zero, so neither can be deployed first and patched. `deploy.mjs`
resolves this off-chain by predicting the AgentConsumer's CREATE address from the deployer EOA's
nonce (`deploy.mjs:65-73`, `ethers.getCreateAddress({from, nonce: n+1})`), deploying the Rebalancer
with that predicted address, then deploying the AgentConsumer and asserting it landed where
predicted.

---

## 1. HubFactory and SpokeFactory as the core primitive

### 1.1 What replaces deploy.mjs

Two factory contracts, one per chain role:

- **HubFactory** lives on the hub chain. `createHub(params)` deploys the hub-chain trio (Hub,
  Rebalancer, AgentConsumer), wires them, and hands all three to the caller. One transaction.
- **SpokeFactory** lives on each L2. `createSpoke(hub, adapterSpecs, linkAmount)` deploys the Spoke
  plus the caller's chosen adapters, registers the adapters on the spoke, funds LINK, and hands the
  spoke to the caller. One transaction per chain.

Neither factory retains any authority over what it deploys. The caller is the owner of every
contract the moment the transaction returns.

### 1.2 Resolving the circular Rebalancer <-> AgentConsumer dependency on-chain

**First, correct the old plan.** `FACTORY-PLAN.md` §3 step 2 claims CREATE2 "removes" the circular
dependency because "both addresses are computable in a single view call before either is deployed."
**That is wrong.** A CREATE2 address is `keccak256(0xff, deployer, salt, keccak256(initCode))`, and
`initCode` includes the ABI-encoded constructor arguments. The Rebalancer's constructor argument is
the AgentConsumer's address and vice versa, so each contract's initCode hash depends on the other
contract's address, which depends on the other's initCode hash. The two CREATE2 addresses are
mutually recursive and cannot both be solved. CREATE2 does not break this dependency; only removing
the counterparty address from at least one constructor does.

Now the real options, evaluated against the actual constructors:

**Option A (recommended): make AgentConsumer.REBALANCER a one-shot settable, drop it from the
constructor.** Change `AgentConsumer` so `REBALANCER` is storage set once by an `initRebalancer`
call that reverts if already set:

```solidity
address public rebalancer;
function initRebalancer(address _rebalancer) external {
    if (rebalancer != address(0)) revert AlreadyInitialized();
    if (_rebalancer == address(0)) revert InvalidConstructorArguments();
    rebalancer = _rebalancer;
}
```

Factory flow, no address prediction anywhere:

1. Deploy AgentConsumer `(agent, factoryAsOwnerForNow)`.
2. Deploy Rebalancer `(hub, agentConsumer, factoryAsOwnerForNow)`.
3. `agentConsumer.initRebalancer(rebalancer)`.

Cost: a small source change to AgentConsumer, losing one immutable (a negligible gas read, and a
one-time-settable variable is a minor, well-understood audit item). This is the least fragile option
because it eliminates all nonce and address prediction. AgentConsumer is the thin forwarder, not the
capital-moving contract, so it is the right one to touch.

**Option B (zero source change): a per-tenant PairDeployer.** The reason `deploy.mjs`'s
nonce-prediction trick cannot simply be ported into the factory is that **the EVM has no opcode for
a contract to read its own account nonce.** The factory cannot name the nonce at which its next
CREATE will land, so it cannot compute the AgentConsumer address the way the off-chain script does.
The workaround is a throwaway helper deployed fresh per tenant whose nonce sequence is known by
construction:

```solidity
contract PairDeployer {
    function deployPair(bytes memory rebalancerInit, bytes memory acInit)
        external returns (address rebalancer, address ac)
    {
        address predictedAc = _createAddress(address(this), 2);
        rebalancer = _create(rebalancerInit_with(predictedAc));
        ac = _create(acInit);
        require(ac == predictedAc);
    }
}
```

A freshly created contract's first CREATE is at nonce 1 and its second at nonce 2, both single-byte
RLP, so `_createAddress(self, 2)` is deterministic. This preserves the exact immutable design of the
current contracts at the cost of an extra contract and the same "wrong nonce silently mis-wires
auth" class of failure the off-chain script has (mitigated here by the `require(ac == predictedAc)`
assertion, same as `deploy.mjs:72`).

**Recommendation: Option A.** The source change is tiny and it deletes an entire class of
deployment-ordering fragility that both `deploy.mjs` and Option B carry. Do not use CREATE2 for this
pair; it does not help.

### 1.3 The ownership-handoff blocker: Rebalancer has no transferOwnership

This is the finding that most changes the factory design and is not mentioned in the old plan.

The factory needs to be the owner of the contracts *during* setup, because the wiring calls are
owner-gated:

- `hub.setRebalancer` is `onlyOwner` (`HubAdminModule.sol:25`). The hub must exist before the
  rebalancer (rebalancer needs hub's address), so the rebalancer address is not known at hub
  construction and `setRebalancer` must run post-deploy. Therefore the factory must own the hub when
  it calls `setRebalancer`, then transfer the hub to the user.
- `rebalancer.addChainToWhitelist` / `addProtocolToWhitelist` are `onlyAuthorized` (owner or
  AgentConsumer, `Rebalancer.sol:311-345`). To wire the user's chosen chains and protocols in the
  same transaction, the factory must be the rebalancer's owner during setup, then transfer.

Hub, AgentConsumer, and Spoke all inherit OZ `Ownable` and support this "own, wire, transfer"
pattern. **The Rebalancer does not.** Its `owner` is a bare address set once in the constructor with
no transfer function (`Rebalancer.sol:36,146`). So the factory literally cannot both wire the
rebalancer's whitelists and end up with the user owning it.

**Required source change: give Rebalancer a real ownership transfer.** Migrate it to OZ `Ownable`
(or `Ownable2Step`, preferred for handing control to an anonymous user, so a fat-fingered address
cannot brick the stack). This is a small, mechanical change that also removes the inconsistency of
one of four contracts rolling its own access control. Alternatively, accept the initial whitelist
sets as constructor array arguments and pass `_owner = user` directly, avoiding the post-deploy
wiring entirely; this is a slightly larger Rebalancer change but a legitimate alternative if you
prefer to keep ownership immutable.

Recommendation: adopt `Ownable2Step` on the Rebalancer, and use two-step acceptance for the final
handoff of all four contracts so ownership is never handed to an address that cannot act.

### 1.4 The single-tenant hub-chain transaction, concretely

`HubFactory.createHub`:

1. Deploy Hub `(name, symbol, router, owner=factory, link, usdc, rebalancer=address(0))`.
2. Deploy AgentConsumer `(agent=user_or_optIn, owner=factory)` (Option A shape).
3. Deploy Rebalancer `(hub, agentConsumer, owner=factory)`.
4. `agentConsumer.initRebalancer(rebalancer)`.
5. `hub.setRebalancer(rebalancer)`.
6. For each chain selector the user chose: `rebalancer.addChainToWhitelist(selector)`. For each
   protocol id: `rebalancer.addProtocolToWhitelist(id)`. This is the empty-whitelist wiring
   (gotcha G2) moved on-chain.
7. Pull `linkAmount` LINK from the caller (pre-approved) and transfer it to the hub, so the hub is
   funded for CCIP in the same transaction rather than left silently unable to message.
8. Transfer (or begin two-step transfer of) Hub, Rebalancer, and AgentConsumer ownership to the
   caller.
9. Emit `HubCreated(owner, hub, rebalancer, agentConsumer, selectors, protocols, block.timestamp)`.

This whole sequence either fully lands or fully reverts, which is the correctness property
`deploy.mjs` had to simulate with resumable checkpoints for a single hand-run deployment.

Note what the factory **cannot** do here: it cannot register spokes, because the spokes do not exist
yet (they are deployed on other chains, and each needs this hub's address). `hub.addSpoke` is a
later, hub-chain transaction (§3).

---

## 2. Immutables vs clone cost

### 2.1 The tension

EIP-1167 minimal proxies cost roughly 41k gas per clone regardless of implementation size, versus
paying ~200 gas per byte of deployed bytecode for a full deploy. The Hub and Spoke are the large
contracts here, so clones are where the gas savings would live. But a vanilla EIP-1167 clone runs no
constructor and can carry no per-clone immutables: the implementation's immutables are fixed in the
implementation's own deployed bytecode, identical for every clone.

### 2.2 Which immutables actually vary per tenant

This is the deciding question, and the answer is favorable in a way the old plan did not analyze:

- **Hub immutables (LINK, USDC, router): per-chain constants, identical for every tenant.** The
  per-tenant values (owner, rebalancer) are already mutable storage. So a single Hub implementation
  per chain *could* back many clones, if the Hub were converted to an initializer pattern.
- **Spoke immutables (ASSET, LINK, router, HUB_CHAIN_SELECTOR): per-chain constants.** Same story.
  `HUB` is already mutable.
- **Rebalancer immutables (HUB, AGENT_CONSUMER): per-tenant.** These are the cross-references and
  they genuinely differ per tenant.
- **AgentConsumer immutables (REBALANCER, AGENT): per-tenant.**
- **Adapter immutables (pool, token): per-market constants**, but adapters hold funds so each spoke
  needs its own instance.

So the contracts whose immutables block cloning are the two small satellites (Rebalancer,
AgentConsumer), not the two large ones. The large ones are blocked from cloning only by using
constructors at all (ERC4626/ERC20 set name, symbol, and asset in constructors), not by per-tenant
immutables.

### 2.3 The three options

**Full deploy per user (no refactor).** Zero source-model risk: every tenant runs the exact
bytecode that was validated live on testnet (`FINDINGS.md`). Highest gas: the user pays to deploy a
full Hub and Rebalancer and AgentConsumer on the hub chain, and a full Spoke plus adapters on each
L2. This is a one-time onboarding cost paid by the user for their own stack.

**Convert Hub and Spoke to initializer-based clones.** This is where the churn and audit risk
concentrate. The Hub is ERC4626 + ERC20 + CCIPReceiver + Ownable + Pausable, split across three
sibling modules with an explicit, load-bearing storage-layout invariant ("All state lives here, in
the exact declaration order... so storage slot assignment is unaffected by the module split,"
`HubStorage.sol:14-16`). To clone it you must swap OZ's constructor-based ERC4626/ERC20/Ownable for
the `Upgradeable` + `Initializable` variants, which reshuffles both storage layout and C3
linearization across the whole module diamond. The Spoke has the same property. This is a deep
rewrite of the two most security-critical contracts in the system, and it invalidates the testnet
validation those exact bytecodes have. For a per-user vault that a user deploys once, the gas saved
does not come close to justifying re-architecting and re-auditing the core accounting contracts.

**Clones-with-immutable-args for the satellites (Solady `LibClone.cloneWithImmutableArgs`).** This
would let the Rebalancer and AgentConsumer keep per-tenant "immutables" (appended to the proxy
bytecode, read via codecopy) while sharing one implementation. But these two contracts are small, so
the full-deploy cost being avoided is small, and the immutable-args reader adds its own complexity
and audit surface to the one part of the stack (the Rebalancer) that gates all capital movement.
Not worth it.

### 2.4 Recommendation: full deploy, no clone refactor, revisit only if onboarding gas is proven
prohibitive on the target chain

Reasoning, grounded in the constructors:

- The refactor cost lands entirely on Hub and Spoke, which are exactly the contracts you least want
  to churn, and cloning them requires abandoning the constructor-based OZ bases the whole module
  split is built around plus the live-validated bytecode.
- The satellites that could be cloned cheaply (Rebalancer, AgentConsumer) are too small for the
  saving to matter.
- A user deploys their stack once and then runs a yield vault. A one-time full-deploy cost is a
  defensible onboarding expense, unlike the Uniswap-pair case where clones matter because thousands
  of identical instances are minted.

Keep the door open: if onboarding gas on the production chain turns out to be prohibitive, the
highest-leverage single move is converting **only the Spoke** to a clone (it is deployed N times per
user, once per chain, so it dominates), and doing that behind an audit. Do not start there.

The two source changes this plan does recommend (AgentConsumer one-shot setter in §1.2, Rebalancer
Ownable2Step in §1.3) are unrelated to cloning and stand on their own.

---

## 3. Multi-chain onboarding UX

### 3.1 The forced ordering, and why

Cross-chain deploys cannot be atomic (CCIP is asynchronous, and these are contract creations, not
messages). The constructors force a strict order:

1. **Hub chain first.** The Spoke constructor rejects `_hub == address(0)`
   (`SpokeStorage.sol:199`), so the hub's address must exist before any spoke is deployed. This is
   the chicken-and-egg: it is resolved simply by deploying the hub first and reading its address
   from the `HubCreated` event.
2. **Each spoke chain, in any order.** `SpokeFactory.createSpoke(hubAddress, adapterSpecs,
   linkAmount)` deploys the Spoke pointing at the known hub, deploys and registers the chosen
   adapters, funds LINK, transfers the spoke to the user, emits `SpokeCreated(owner, hub, spoke,
   selector, adapters)`.
3. **Back to the hub chain to register.** `hub.addSpoke(selector, spokeAddress)` is `onlyOwner`
   (`HubAdminModule.sol:82`) and needs the spoke addresses from step 2. This is the return trip.

So the minimum is: 1 hub-chain tx, then 1 tx per spoke chain, then 1 hub-chain registration tx. With
three spokes that is five transactions across four chains with network switches. This is inherent,
not an artifact of the factory; the single-tenant deployment does the same thing by hand
(`deploy.mjs` `hub` / `spoke` / `register` subcommands).

### 3.2 Making it least painful

- **Collapse each chain's work into one transaction.** All hub-chain setup is one `createHub` call.
  Each spoke chain's Spoke + adapters + setAdapter + LINK funding is one `createSpoke` call. This is
  already the design in §1.
- **Batch the return-trip registration.** `hub.addSpoke` is per-selector. Add a convenience
  `addSpokes(selectors[], addrs[])` to the hub (or let the user, who owns the hub, multicall through
  Multicall3) so all spokes register in one hub-chain transaction instead of one per spoke.
- **Fold LINK funding into the deploy transactions.** Have `createHub` and `createSpoke` pull LINK
  from the caller (pre-approved) and forward it to the freshly deployed contract in the same tx.
  This removes a separate, easily-forgotten step and the "deployed but unfunded, silently cannot
  message" failure mode. The user still needs to *hold* LINK on each chain first; surface that as a
  prerequisite checklist with balances.
- **Make the UI a resumable state machine driven by on-chain state, not local storage.** Because the
  factories emit `HubCreated` / `SpokeCreated` and the hub exposes its spoke registry, the UI can
  reconstruct "hub deployed, Arbitrum spoke deployed, Base spoke pending, registration pending" by
  reading chain state for the connected wallet. A user who closes the tab mid-onboarding, or
  switches machines, resumes exactly where they left off. Do not trust a local database as the
  source of truth; the factory is the registry (§4).
- **On the return trip specifically:** do not try to be clever with pre-registration. One could
  CREATE2 the hub to a deterministic address and let spokes point at the predicted hub before it is
  confirmed, but that adds a footgun (a reverted or differing hub deploy strands every spoke). The
  hub deploys quickly on its own chain; deploy it for real, read its address, proceed. The genuinely
  unavoidable cost is the final `addSpoke` back on the hub chain, and batching it (above) is the
  right mitigation.

### 3.3 The UX flow the user sees

A guided wizard: (1) pick hub chain and share-token name, confirm you hold LINK there, sign
`createHub`. (2) For each L2 you chose: switch network, pick adapters (Aave market, Compound market,
etc.), confirm LINK, sign `createSpoke`. (3) Switch back to hub chain, sign one `addSpokes`
batch. (4) Optionally sign the two-step ownership acceptances if using `Ownable2Step`. Each step is
idempotent and resumable from chain state.

---

## 4. Due-diligence surface for open deposits

Deposits are open, so the only protection a depositor has is information. The factory, an indexer,
and the UI should make vetting a hub as easy as vetting any DeFi vault.

### 4.1 The factory is the authoritative registry

Emit rich creation events and expose view getters so nothing depends on trusting our off-chain
database:

- `HubCreated(owner, hub, rebalancer, agentConsumer, selectors, protocols, timestamp)`.
- `SpokeCreated(owner, hub, spoke, selector, adapters[])`.
- `getHubsByOwner(address) view returns (address[])` and a global enumerable list of all hubs.

An indexer (Ponder, a subgraph, or a custom indexer against these events plus each hub's and spoke's
own events) is the practical query layer; do not have the UI open a subscription per contract per
hub.

### 4.2 What to surface per hub

- **Owner.** The address, whether it is an EOA or a contract (multisig / timelock), and any label or
  ENS. An owner that is a single fresh EOA is a very different risk profile from a multisig.
- **Age and activity.** Creation timestamp, deposit/withdraw event history, rebalance cadence
  (`AllocationProposed` on the AgentConsumer, `SentToSpoke` on the hub). A hub with no activity, or
  one created minutes ago, is unproven.
- **TVL and share price.** `hub.totalAssets()` and the current share price. Note the known caveat
  from `FINDINGS.md`: `totalAssets` is idle + reported `spokeBalances` + inTransit, and lags live
  Aave yield until a fresh `REPORT_BALANCE` (bounded by `MAX_STALENESS = 1 hour`,
  `HubStorage.sol:144`). Surface reported-vs-stale state honestly.
- **Registered adapters and what they point at.** For each spoke, list the adapters and read their
  immutables to show the concrete target: AaveAdapter's `AAVE` pool and `A_TOKEN`
  (`AaveAdapter.sol:14-15`), Compound's `COMPOUND` Comet, Morpho's market params. A depositor can
  then see whether the adapter routes to the real, canonical Aave pool or to some unknown address.
- **Adapter change recency.** `AdapterSet` / `AdapterRemoved` events (`SpokeStorage.sol:116,120`).
  An adapter swapped shortly after deposits arrived is the loudest possible red flag (see §5.4); badge it.
- **Health and safety state.** Paused (`Pausable`), any quarantined report
  (`activeQuarantineCount`, `HubStorage.sol:215`), stale spokes, pending-withdrawal backlog, and
  hub/spoke LINK balances (an unfunded stack cannot process cross-chain operations).
- **Whether the rebalancer is agent-operated and by whom.** Show `AgentConsumer.AGENT`. If it is our
  shared managed-agent address, say so; if it is the owner's own key, say that.

### 4.3 Optional reputation signal, cleanly separated from control

Offer an optional, curated "known-good adapter" registry: a separate contract we maintain that maps
recognized adapter implementations, or recognized `(pool, token)` targets, to a vetted flag. The
indexer reads it and the UI badges a hub as "all adapters recognized" versus "contains an
unrecognized adapter."

Two hard rules keep this a signal and not a gate:

1. **It is never in the deposit path.** Deposits stay open ERC4626 calls. The registry is read by
   the UI, never by any hub or spoke contract. We are not an admin and cannot block a deposit.
2. **It is not exclusive.** Support third-party lists (the token-list model) so we are not the sole
   arbiter of "good." A hub owner is free to use adapters no list recognizes; that just shows up as
   an unbadged, higher-diligence-required hub.

State this separation explicitly in the product so no one mistakes a badge for a guarantee or for
gatekeeping.

---

## 5. Real risk flags for the permissionless model

The god-key from the single-tenant model (`DECISIONS.md` §2: one EOA holding Hub owner, Rebalancer
owner, AgentConsumer owner, and AGENT at once, with its key committed in plaintext) mostly dissolves
here, because each user holds their own keys. But this model introduces new risks, and some are
serious.

### 5.1 Factory-level bugs are systemic

The factory is the one piece of shared, trusted code. A bug in its wiring (owner handed to the wrong
address, rebalancer left unset, whitelists mis-populated, the circular-dep resolution mis-wiring
AgentConsumer, LINK not forwarded) affects **every hub minted after it**, even though the hub and
spoke bytecode is the same live-validated code as today. The factory must be audited as its own
artifact, and the ownership handoff (§1.3) is the highest-risk line in it: a mistake there either
bricks the user's stack or leaves the factory in control of user funds. Two-step ownership with an
explicit accept is a deliberate mitigation. Consider making the factory itself non-upgradeable and
versioned (§5.5) so a compromised or buggy factory cannot be silently repointed.

### 5.2 The per-user Rebalancer / AgentConsumer trust setup, and the returning agent problem

In this model the user is the operator: the AGENT wallet and all owner keys are theirs. That is the
point. But the allocation loop (`AgentConsumer -> Rebalancer.proposeAllocation -> hub.sendToSpoke`)
needs *someone* running an off-chain agent to actually rebalance, and most users will not run one.
Two honest choices:

- **User runs their own agent.** True self-custody, but realistically most vaults will never
  rebalance and will sit in whatever their initial allocation was. A dead vault is a poor product
  but an honest one.
- **We offer an opt-in managed agent.** Convenient, but our agent key then controls the allocation
  of every hub that opted in, which re-introduces a cross-tenant key, a god-key by another name for
  that subset. The critical mitigation is that this key is **bounded by each user's own on-chain
  guards**: the Rebalancer only lets it move funds among the user's whitelisted chains and protocols
  (`Rebalancer.sol:250-259`), only above the 50 bps improvement threshold
  (`Rebalancer.sol:244-248`), and only sized against deployable idle
  (`Rebalancer.sol:269-284`). It **cannot** withdraw to an arbitrary address or exfiltrate funds;
  the worst it can do is churn allocations within the user's own approved venues (wasting LINK and
  crossing spreads). Make it explicitly opt-in, document exactly this bound, and hold the managed
  agent key in a hardened way. Do not repeat the plaintext-committed-key mistake.

Decide this before launch and state it plainly to depositors (§4.2), because "who can move this
vault's capital and to where" is a first-order due-diligence question.

### 5.3 LINK-funding UX failure modes

A hub or spoke with no LINK silently fails at the CCIP send: the hub pays LINK on `sendToSpoke`,
`rebalance`, and `recallFromSpoke` (`HubMessagingModule` fee then `ccipSend`), and spokes pay LINK
on their confirm and report responses (`SpokeConfirmsModule`). An underfunded stack accepts deposits
but cannot deploy them, cannot confirm, and cannot process Path 2/Path 3 withdrawals. The known
Path 3 stall (`docs-findings.md` #5) and dust behavior get worse when a user under-funds and their
operations start failing mid-flight. Mitigations: fold first funding into the deploy tx (§3.2),
monitor LINK balances in the UI and warn loudly, and set the expectation that ongoing LINK top-ups
on every chain are a standing operator responsibility the user now owns. This is a real support
burden that no longer has a platform operator to absorb it.

### 5.4 Malicious-adapter blast radius on depositors

This is the sharpest risk in the whole model and deserves a blunt statement. `setAdapter` and
`removeAdapter` are instant, `onlyOwner`, no timelock (`SpokeAdminModule.sol:34-60`). Funds pass
through the adapter (the adapter holds the aToken and receives USDC on deposit,
`AaveAdapter.sol:35-38`). So a hub owner can, at any time and with no delay, point a spoke's adapter
at a contract that steals deposited funds, including **after** depositors have entered an
honest-looking vault. This is a ready-made rug primitive, and the factory is the machine that mints
it. The permissionless framing accepts that a malicious hub owner is the depositor's own diligence
problem, which is fine as a principle, but "you can be rugged with zero warning by an instant adapter
swap" is a materially worse depositor experience than "you can evaluate a static set of adapters."

Recommendations, in order of how strongly I would push them:

- **Bake an opt-out timelock on `setAdapter` / `removeAdapter` into SpokeFactory-deployed spokes by
  default.** A hub owner who wants depositor trust ships the default (adapter changes are announced
  and delayed); one who opts out is visibly higher-risk. This turns the instant-rug primitive into a
  watchable event and is the single most valuable protection you can offer without becoming a
  gatekeeper.
- At minimum, **badge un-timelocked hubs as higher risk** in the UI and surface every `AdapterSet`
  with its recency (§4.2).
- Surface the adapter target so a depositor can see a non-canonical pool before depositing.

### 5.5 Upgrade / immutability implications

Hubs and spokes are non-upgradeable (immutables, no proxy). A bug discovered after a user deploys
cannot be patched in place; the user must deploy a new stack and migrate funds, which is the
"replace the whole contract" model the codebase already assumes. Under a factory this has a new edge:
you can ship a fixed factory for *new* hubs, but every *existing* hub is frozen, and there is no
mechanism to force or even notify users to migrate. Plan a versioning and deprecation story: version
the factories, mark old-version hubs in the UI, and provide a migration path (deploy new stack,
recall funds to hub idle, withdraw, redeposit into the new hub). Accept that some users will run old,
possibly-buggy versions indefinitely and that their depositors inherit that.

### 5.6 First-depositor inflation, now N times

Every freshly minted hub is a fresh ERC4626 starting at zero supply, which is the classic
donation/inflation attack surface against the first real depositor. OZ v5.6.1 (confirmed in
`lib/openzeppelin-contracts/package.json`) ships the virtual-shares mitigation by default, which
makes this hard but not free at the default zero decimals-offset. In the single-tenant world this
was one vault; in a factory it is one per hub, N times. Confirm the mitigation is in force for the
composed Hub, and consider having `createHub` seed a tiny non-refundable first deposit, or setting a
decimals offset, so no user's first depositor eats an inflation attack.

### 5.7 Liveness with no platform operator

The single-tenant deployment implicitly relied on us keeping spokes reporting fresh and LINK funded.
In the permissionless model that responsibility moves to each user, most of whom will not do it. A
neglected stack strands: stale reports block Path 2 withdrawals (`_allSpokesFresh`,
`HubStorage.sol:488`), unfunded LINK blocks everything, and the Path 3 yield-delta stall
(`docs-findings.md` #5) needs a standing idle buffer the user must choose to keep. Consider offering
optional keepers (report refreshers, LINK top-up automation) as a paid convenience, and set
expectations clearly. This is not a contract risk so much as a "the product will look broken for
inattentive owners, and their depositors will feel it" risk.

### 5.8 Direct opinion: is any of this a bad idea

The factory mechanics are sound and the ownership model is cleaner than the old plan's (the caller
owns their stack, we are not admin, blast radius is per-user). The part I would not ship as-is is the
combination in §5.4: a permissionless minter of non-upgradeable vaults that anyone can deposit into,
where the default configuration lets the owner rug depositors instantly with no timelock and no
warning. That is not "a malicious owner is the depositor's problem," it is "we built and marketed the
rug machine and set its safety to off by default." Ship the opt-out timelock (§5.4) so the trustable
configuration is the default, resolve the managed-agent question (§5.2) explicitly, seed against the
inflation attack (§5.6), and get the factory itself audited (§5.1). With those, the permissionless
model is defensible. Without the §5.4 default, I would not launch open deposits.

---

## 6. Required source changes, collected

Small, and none of them touch the withdrawal engine or the accounting core:

1. **AgentConsumer:** replace the immutable `REBALANCER` with a one-shot `initRebalancer` setter
   (§1.2, Option A) to kill the circular-dependency address prediction.
2. **Rebalancer:** adopt OZ `Ownable2Step` so the factory can wire whitelists and then hand
   ownership to the user (§1.3). Today it has no ownership transfer at all.
3. **Spoke (recommended, depositor protection):** an opt-out timelock on `setAdapter` /
   `removeAdapter` for SpokeFactory-deployed spokes (§5.4).
4. **Hub (convenience):** a batched `addSpokes(selectors[], addrs[])` to collapse the return-trip
   registration into one transaction (§3.2). Optional; Multicall3 achieves the same.

Everything else (Hub, Spoke, adapter accounting, the three withdrawal paths) is deployed as-is, the
same bytecode validated live in `FINDINGS.md`, with no clone refactor (§2.4).
