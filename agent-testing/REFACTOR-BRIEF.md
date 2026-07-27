# Migration Brief: permissionless factory, full build with tests

This is a handoff brief for an implementation agent. It covers the full on-chain migration to the
permissionless factory model: the enabling refactor to `src/Rebalancer.sol`, the HubFactory and
SpokeFactory contracts, the Hub registration helper, and complete test coverage. It does not include
the UI or any testnet deployment. Build the deliverables in the numbered order, because the factory
contracts depend on the Rebalancer refactor landing first.

## Ground rules (read before touching anything)

- `src/` is the source of truth. Trust only `src/`. Treat `test/`, `script/`, `agent-testing/*.mjs`,
  `deployed-*.json`, and docs as possibly stale. Read the actual source before asserting behavior.
- The full design context is in `agent-testing/FACTORY-PLAN-V2.md`. The two settled product
  decisions this refactor implements are in its "Decisions locked (2026-07-21)" section:
  1. No managed off-chain agent for now. The hub owner feeds allocation proposals directly from
     their own wallet. There is no AgentConsumer in the per-tenant deploy.
  2. Deposits are fully caveat emptor. No adapter timelock. This means the Spoke timelock work from
     FACTORY-PLAN-V2 §5.4 is explicitly OUT of scope for this brief. Do not touch the Spoke.
- Style, non-negotiable: no em dashes anywhere (code, comments, commit messages, chat). No
  AI-narration comments (no "this function does X", no comments explaining the change to a reviewer).
  Match the existing NatSpec density and voice in `src/Rebalancer.sol`. Commit author must be
  `alameen <aminu0906666@gmail.com>`. No AI co-author trailer.
- Do not touch the withdrawal engine, the accounting core, or any Hub/Spoke module. This refactor is
  confined to `src/Rebalancer.sol` and its tests. If you believe a change outside that file is
  required, stop and report it rather than making it.

## Why these changes (the two blockers, verified against src/)

1. **Rebalancer has no ownership transfer.** `owner` is a bare `address public owner` set once in the
   constructor (`Rebalancer.sol:36`, `146`). The NatSpec on line 35 claims "can be transferred," but
   there is no `transferOwnership`, no setter, nothing. Whoever is passed at construction owns it
   forever. A factory must own the Rebalancer during whitelist wiring and then hand it to the user,
   so this is a hard blocker. The comment is also currently a lie and should stop being one.

2. **AGENT_CONSUMER is mandatory and immutable.** The constructor reverts if `_agentConsumer` is zero
   (`Rebalancer.sol:139-143`), and `_onlyAuthorized` treats it as a second authorized caller
   (`Rebalancer.sol:122`). With no managed agent, there is no AgentConsumer to deploy, and the
   Rebalancer must be deployable and fully operable with the owner as the sole authorized caller.
   Making AGENT_CONSUMER optional also removes the circular Rebalancer/AgentConsumer immutable
   dependency entirely, so none of the CREATE2 or nonce-prediction machinery in FACTORY-PLAN-V2 §1.2
   is needed. That is a deliberate simplification, not an oversight.

## Deliverables (each is a reviewable checkpoint; report after each)

### D1. Rebalancer adopts OpenZeppelin Ownable2Step

- Replace the bare `owner` state and hand-rolled ownership with OZ `Ownable2Step` (which extends
  `Ownable`). Confirm the exact OZ version already vendored in `lib/openzeppelin-contracts` and use
  its API; do not add a new dependency.
- Two-step transfer is required (not plain `Ownable`) because ownership is handed to an anonymous
  user address by a factory, and a fat-fingered `transferOwnership` to a wrong or non-controllable
  address must not be able to brick the stack. The new owner must call `acceptOwnership`.
- `_onlyAuthorized` and every `onlyAuthorized` site must keep working. `owner` reads that other
  code relies on must still resolve (OZ `Ownable` exposes `owner()` as a function, the current code
  exposes `owner` as a public variable getter, also `owner()`; confirm no caller breaks on the
  distinction, including the Hub/Spoke interfaces and the off-chain scripts you can see but not
  trust).
- Remove or correct the now-false "can be transferred" / "Should be a multisig before mainnet"
  NatSpec so it matches reality.

### D2. AGENT_CONSUMER becomes optional

- The constructor must accept `_agentConsumer == address(0)` and still reject a zero `_hub` and (via
  OZ Ownable) a zero owner.
- When `AGENT_CONSUMER` is zero, `_onlyAuthorized` must authorize the owner only. When it is set,
  behavior is unchanged (owner or AgentConsumer). Do not silently authorize `address(0)` callers:
  a caller of `address(0)` is impossible in practice but the check must not accidentally treat an
  unset AGENT_CONSUMER as a match for anything.
- Keep `AGENT_CONSUMER` immutable (it just may now be zero). Do not add a setter for it in this
  brief; the managed-agent path is a future, opt-in decision and adding a setter now widens the
  trust surface for no current benefit.
- Reconcile the contract-level and constructor NatSpec that currently says all three addresses are
  required.

### D3. Tests: full suite green, new coverage for both changes

- The entire existing forge test suite must pass unchanged in intent. If any existing test encodes
  the OLD behavior (mandatory AgentConsumer, no ownership transfer) and now legitimately must
  change, change it and explain in the report exactly which assertion changed and why, the same way
  the WI-3 test was handled during the dust-lock fix. Do not weaken a test to make it pass.
- Add tests covering:
  - Two-step ownership: transfer initiated, pending owner set, old owner still in control until
    accept, `acceptOwnership` completes the handoff, non-pending caller cannot accept.
  - `onlyAuthorized` sites reject a random caller after transfer, and the new owner is authorized.
  - Deploy with `_agentConsumer == address(0)`: constructor succeeds, owner is authorized, a random
    caller is rejected, and a proposal/rebalance path runs end to end through owner auth.
  - Deploy with a non-zero AgentConsumer still authorizes both owner and AgentConsumer (regression).
  - Constructor still reverts on zero hub and zero owner.
- Run the suite and paste the pass/fail counts in the report. State the count before and after.

### D4. Documentation writeup, house style, plus a doc-worthy-items list

- Add a findings/change entry in the existing style. The model to match is
  `docs/docs-findings.md` and `agent-testing/FINDINGS.md`: comma-driven prose, no em dashes,
  a `<!-- verified: ... -->` trailer citing the exact file and function for every factual claim.
  Record what changed in the Rebalancer, why (the two blockers), and that it is validated by the
  test suite.
- Separately, maintain a short list titled "For the docs later" of things this refactor surfaces
  that we will likely want in the real documentation set but that are not findings, for example:
  the Rebalancer ownership model changing from immutable-owner to Ownable2Step, the meaning of an
  agent-less Rebalancer (owner-operated), and the fact that the circular Rebalancer/AgentConsumer
  dependency no longer exists in the factory path. Keep this list in your report so I can slot it
  into the doc set; do not rewrite the main docs yourself in this brief.

### D5. HubFactory

- New contract, `src/factory/HubFactory.sol` (create the `factory` dir). Immutables it needs are the
  per-chain constants: the CCIP router, LINK, and USDC for the hub chain. Store them once at factory
  construction so a `createHub` caller does not pass them.
- `createHub(string name, string symbol, uint64[] chainSelectors, bytes32[] protocolIds, uint256 linkAmount)`
  must, in one transaction:
  1. Deploy the Hub with `owner = address(this)` (the factory), `rebalancer = address(0)`.
  2. Deploy the Rebalancer with `(hub, agentConsumer = address(0), owner = address(this))`. This
     relies on D2. There is no AgentConsumer.
  3. `hub.setRebalancer(rebalancer)`.
  4. For each selector in `chainSelectors`: `rebalancer.addChainToWhitelist(...)`. For each id in
     `protocolIds`: `rebalancer.addProtocolToWhitelist(...)`. This is the empty-whitelist wiring
     moved on-chain.
  5. If `linkAmount > 0`: pull that much LINK from the caller (caller pre-approves the factory) and
     transfer it to the hub, so the hub is CCIP-funded in the same transaction. If the pull fails,
     the whole tx reverts.
  6. Begin the two-step ownership transfer of BOTH the Hub and the Rebalancer to the caller
     (`transferOwnership(msg.sender)` on each; the caller accepts separately). The factory must not
     retain ownership of anything after this call.
  7. Emit `HubCreated(msg.sender, hub, rebalancer, chainSelectors, protocolIds, block.timestamp)`.
- Provide `getHubsByOwner(address) view returns (address[])` and an enumerable global list of all
  created hubs, backed by storage the factory writes in `createHub`. This is the due-diligence
  registry from FACTORY-PLAN-V2 §4.1.
- The factory retains zero authority over any deployed contract once `createHub` returns. Verify this
  in a test (§D8).

### D6. SpokeFactory

- New contract, `src/factory/SpokeFactory.sol`. Immutables: this L2's CCIP router, LINK, USDC, and
  the hub chain's CCIP selector (`HUB_CHAIN_SELECTOR`), all per-chain constants.
- `createSpoke(address hub, AdapterSpec[] adapters, uint256 linkAmount)` must, in one transaction:
  1. Deploy the Spoke with `(hub, asset = USDC, router, owner = address(this), link, hubSelector)`.
     The Spoke constructor rejects a zero hub, so `hub` must be a real, already-deployed address; the
     caller passes the hub address from their earlier `HubCreated` event.
  2. For each `AdapterSpec`: deploy the concrete adapter (Aave to start; design `AdapterSpec` so
     other adapter kinds can be added without changing the signature, e.g. an enum kind plus an
     encoded params blob) and register it with `spoke.setAdapter(...)`.
  3. If `linkAmount > 0`: pull LINK from the caller and fund the spoke, same pattern as the hub.
  4. Begin two-step ownership transfer of the Spoke to the caller.
  5. Emit `SpokeCreated(msg.sender, hub, spoke, thisChainSelector, adapterAddresses[])`.
- Same registry getters as the HubFactory, keyed for spokes.
- Adapters are deployed per spoke (they hold funds, cannot be shared). Confirm this against
  `AaveAdapter` before wiring.

### D7. Hub registration helper (return-trip batching)

- The forced onboarding order (FACTORY-PLAN-V2 §3.1) means spokes are registered on the hub AFTER
  they exist on their own chains, by the hub owner, via `hub.addSpoke` which is `onlyOwner`. Add a
  batched `addSpokes(uint64[] selectors, address[] spokeAddrs)` to the Hub admin path so all spokes
  register in one hub-chain transaction.
- This must be strictly additive: a thin loop over the existing single `addSpoke` logic with a
  length-match check. Do not alter existing `addSpoke` behavior, storage, or any other Hub logic.
  This is the one sanctioned Hub change in this brief. If it cannot be done without touching existing
  logic or storage layout, stop and report before proceeding.

### D8. Full test coverage for the factory

- Unit tests for HubFactory and SpokeFactory on a single forked chain each:
  - `createHub` deploys hub + rebalancer, sets the rebalancer on the hub, wires exactly the passed
    chains and protocols, funds the hub with the passed LINK, and leaves the factory owning nothing.
  - After `createHub`, the caller (and only the caller) can accept ownership of hub and rebalancer,
    and after acceptance can call the owner-gated functions.
  - `createSpoke` deploys the spoke pointing at the given hub, deploys and registers each adapter,
    funds LINK, and hands the spoke to the caller.
  - The registry getters return what was created, keyed by owner.
  - Revert paths: LINK pull without approval reverts the whole tx, mismatched `addSpokes` array
    lengths revert, zero hub to `createSpoke` reverts.
- `addSpokes` batch test: registering N spokes in one call equals N single `addSpoke` calls.
- Do NOT attempt a full cross-chain CCIP end-to-end test across forks. That path was never made to
  pass locally (`disabled-tests/FullFlowTest.t.sol`), and asserting it here would be dishonest. Test
  each chain's factory behavior on its own fork, and the wiring/ownership/registry correctness that
  is verifiable without a live CCIP round trip. State this boundary explicitly in your report.
- Whole suite green. Report before/after pass counts including the new factory tests.

## Out of scope (do not do these)

- The UI. Contracts and tests only.
- Any Spoke change beyond what SpokeFactory needs to deploy and wire one; specifically NO adapter
  timelock (decision: caveat emptor).
- Any AgentConsumer work, including the `initRebalancer` setter (moot: AGENT_CONSUMER is optional and
  the circular dependency is gone).
- Any clone / proxy refactor of Hub or Spoke (FACTORY-PLAN-V2 §2.4: full deploy per user).
- The optional curated adapter-reputation registry (FACTORY-PLAN-V2 §4.3). Later, off-chain.
- Deploying anything to a testnet. This is source + tests + docs only.

## Definition of done

D1 and D2 in `src/Rebalancer.sol`; D5 and D6 as new factory contracts; D7 the additive Hub batch
helper; D3 and D8 with the whole suite green and before/after counts reported; D4 written in house
style with the doc-worthy list, extended to cover the factory contracts and their design decisions.
Report each deliverable as you complete it so I can review incrementally rather than all at the end.
Build in numbered order; the factory contracts (D5, D6) depend on the Rebalancer refactor (D1, D2).
