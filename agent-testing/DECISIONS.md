# Meridian testnet validation: flow, decisions, risks

Reconstructed **only from `src/`** (per instruction: `test/`, `script/`, `run-live.mjs`,
`deployed-*.json`, `broadcast/`, docs, and memory were all treated as untrusted and several
were confirmed stale/scrambled). Infra addresses in `testnet-infra.json` were read off the
old deployment's on-chain immutables, which are known-good.

## 1. True deploy + wiring sequence (derived from constructors + admin fns in src/)

**Sepolia (hub chain):**
1. `HUB(name, symbol, router, owner, link, asset=USDC, rebalancer=address(0))`.
   HubStorage allows `rebalancer=0` and set-later (comment at HubStorage constructor).
2. **Predict** the AgentConsumer address counterfactually (deployer address + nonce, RLP/CREATE).
3. `Rebalancer(hub, predictedAgentConsumer, owner)`.
4. `AgentConsumer(rebalancer, agent, owner)`, **must land at the predicted address**.
5. `hub.setRebalancer(rebalancer)`.
6. `rebalancer.addChainToWhitelist(selector)` × each spoke selector.
7. `rebalancer.addProtocolToWhitelist(keccak256("AAVE"))` (+ COMPOUND/MORPHO if used).
8. Fund hub with LINK (CCIP fees).
9. After spokes exist: `hub.addSpoke(selector, spokeAddr)` × each.

**Each L2 spoke:**
1. `SpokeVault(hub, asset=USDC_L2, router_L2, owner, link_L2, hubSelector=16015286601757825753)`.
2. `AaveAdapter(aavePool, aUsdc, asset=USDC_L2)`.
3. `spoke.setAdapter(keccak256("AAVE"), adapter)`.
4. Fund spoke with LINK (CCIP confirm fees).

### Two non-obvious gotchas the scripts would have hidden
- **G1: circular immutable dependency.** `Rebalancer.AGENT_CONSUMER` and
  `AgentConsumer.REBALANCER` are both `immutable` and both revert on `address(0)`. Neither can
  be placeholder-then-fixed. The only correct wiring is counterfactual address prediction of
  AgentConsumer before deploying Rebalancer. A wrong nonce silently mis-wires auth.
  (Hub↔Rebalancer is the easy case: `rebalancer=0` then `setRebalancer`.)
- **G2: whitelists start empty.** `proposeAllocation` / `rebalance` / `recallFromSpoke` all
  revert `ChainNotWhitelisted` / `ProtocolNotWhitelisted` until owner whitelists every
  selector and protocolId. Nothing cross-chain works before step 6–7.

## 2. Interaction surface (who can call what)

- **Permissionless (any funded key):** ERC4626 `deposit`/`mint`/`withdraw`/`redeem` on the hub;
  `cancelWithdrawal(ownId)`, `attemptSettlement(id)`, `retryConfirm(index)` recovery paths; all reads.
- **Owner OR AgentConsumer(AGENT|owner) only:** `proposeAllocation`, `rebalance`,
  `recallFromSpoke`, all hub admin (`addSpoke`, `setOutboundGasLimit`, `reconcileTransit`,
  quarantine accept/reject, `forceRemoveSpoke`), spoke admin (`setAdapter`, `setHub`, `deployIdle`).
- **The god-key.** Hub owner = Rebalancer owner = AgentConsumer owner = AgentConsumer AGENT =
  a single EOA `0xF44d…822d`. **Its private key is already committed in `run-live.mjs`**
  (`0xe83bbb52…`). Every privileged path funnels through it. A throwaway agent key can only
  exercise the deposit/withdraw surface, never the cross-chain machinery. See SECURITY below.

## 3. Decisions (mine, as delegate) + alternatives

| # | Decision | Alternatives considered | Why |
|---|---|---|---|
| D1 | **Aave-only** adapters (user-confirmed after the availability finding below) | Compound + Morpho too | Availability matrix (verified 2026-07-19): Compound V3 has no Sepolia deployments (mainnet-only); Morpho exists only on Base Sepolia among our chains and needs a live USDC market. Only Aave exists on all three. "All three on real testnet" is physically impossible. The novel/risky part of Meridian is the cross-chain orchestration + withdrawal engine (protocol-agnostic); adapters are ~40-line shims. Aave x3 validates the entire real machinery; Compound/Morpho adapter logic belongs in fork unit tests. User picked "Aave x3 on real testnet". |
| D2 | **Aave on all three spokes**: Arb, Base, and OP | Skip OP; OP spoke-only | OP-Sepolia Aave does exist (pool 0xb502…, USDC underlying 0x5fd8… matches the OP spoke asset exactly). All three chains get a full Aave adapter. Base gas is low (0.017 ETH), monitor; top up from another chain if a spoke+adapter deploy runs short. |
| D3 | Reuse the **existing god-key** as the privileged "operator agent"; generate **2 fresh keys** as independent depositors, funded from the god-key | Ask user for separate keys | Key is already present + funded on all 4 chains; user said keys were "needed" and this satisfies it with zero new secrets. Fresh depositor keys exercise multi-user share accounting. |
| D4 | **Guardrails**: agents may call any read + deposit/withdraw + recovery + proposeAllocation/rebalance/recall. **Forbidden without an explicit isolated test:** `renounceOwnership`, `transferOwnership`, `forceRemoveSpoke`, `setOutboundGasLimit` to extreme values | Full unrestricted autonomy | Prevent an agent from bricking the fresh deployment in a way that needs a full redeploy, while still allowing every value-flow and recovery path to be exercised. |

## 4. Feasibility risk that may cap what "workable" can mean

**R1: cross-chain USDC transferability (the crux).** Hub asset is Sepolia USDC
`0x1c7D…7238`; each spoke's asset is that chain's *different* native testnet USDC. The DEPOSIT
path (`hub.sendToSpoke`) attaches USDC to a CCIP message. This only works if that exact USDC
is enrolled in the CCIP lane's token pool (CCTP or lane pool) for each Sepolia→L2 lane. If it
is not, every cross-chain deposit reverts and the core protocol is bricked *regardless of
Meridian's own code*. Signal: the old hub held 5 USDC idle with **all spokeBalances = 0**. The
cross-chain deposit path may never have succeeded. This is the #1 hypothesis for the agents
to prove or disprove, and if it fails, the fix is a token-model change (e.g. vault asset =
CCIP-BnM, or CCTP-USDC everywhere), which is a design decision for the user, not a testnet nit.

## 5. SECURITY notes (flagged, not blocking)

- The god-key private key is in plaintext in `run-live.mjs`, committed to a repo that was
  briefly pushed to GitHub. Treat it as compromised for any real value; fine for testnet.
  Recommend generating a fresh operator key for the new deployment and retiring the old one.
- Alchemy API keys and a Gemini API key are likewise committed. Same caveat.
