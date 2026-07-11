# Meridian

Meridian is a cross-chain USDC yield vault. Users deposit into an ERC4626 vault on Ethereum (the hub), and their capital gets deployed into Aave, Compound, and Morpho across three L2s (the spokes) via Chainlink CCIP. Users never touch the spokes directly, they hold one share token that tracks value across every chain and every market the protocol is deployed into.

Status: testnet, unaudited. This is a capability demonstration, not a live product. Treat every number and every guarantee below as something to verify against the code, not as a promise.

## What's interesting here

- **A three-path async withdrawal engine with claim-time pricing.** Most of the time a withdrawal is instant. When it isn't, because a spoke report is stale or idle cash on the hub can't cover it, the payout is priced at the moment it actually settles, not the moment it was requested. See [docs/withdrawals.md](docs/withdrawals.md).
- **A failure-first CCIP design.** Every inbound message handler assumes a partner adapter can revert, a confirm can fail to send, and a transit leg can go dark. Nothing here trusts happy-path delivery. See [docs/resilience.md](docs/resilience.md).
- **A spoke report sanity band with a quarantine circuit breaker.** A spoke that reports an implausibly large balance gets quarantined instead of trusted, and the vault pauses new deposits and withdrawal requests until an owner resolves it. See [docs/security.md](docs/security.md).
- **Collision-free message identity.** Every cross-chain message id comes from a monotonic nonce, not from hashing message content, so two operations in the same block never collide. See [docs/resilience.md](docs/resilience.md).
- **A storage-preserving module split.** Hub and Spoke were each refactored from one large contract into a storage base plus sibling logic modules, with every storage slot verified unchanged before and after. See [docs/architecture.md](docs/architecture.md).
- **A test suite built to catch exactly this kind of thing.** Invariant fuzzing, slot-pinned regression tests that would break if storage layout ever shifted, and a mainnet-fork integration suite. See [docs/development.md](docs/development.md).

## Architecture

```mermaid
graph TB
    subgraph Ethereum
        User(("User")) -->|deposit / withdraw USDC| HUB[HubVault ERC4626]
        HUB <-->|proposeAllocation, rebalance, recall| RB[Rebalancer]
        AGENT(["Off-chain agent"]) -->|proposeAllocation| AC[AgentConsumer] --> RB
    end

    HUB <-->|DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT| CCIP1{{CCIP}}
    CCIP1 <-->|CONFIRM_RECEIPT, CONFIRM_REBALANCE, CONFIRM_WITHDRAWAL, REPORT_BALANCE| SP1

    subgraph Arbitrum
        SP1[SpokeVault]
        SP1 --> A1[Aave Adapter]
        SP1 --> C1[Compound Adapter]
        SP1 --> M1[Morpho Adapter]
    end

    HUB <-->|DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT| CCIP2{{CCIP}}
    CCIP2 <-->|CONFIRM_RECEIPT, CONFIRM_REBALANCE, CONFIRM_WITHDRAWAL, REPORT_BALANCE| SP2

    subgraph Base
        SP2[SpokeVault]
        SP2 --> A2[Aave Adapter]
        SP2 --> C2[Compound Adapter]
        SP2 --> M2[Morpho Adapter]
    end

    HUB <-->|DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT| CCIP3{{CCIP}}
    CCIP3 <-->|CONFIRM_RECEIPT, CONFIRM_REBALANCE, CONFIRM_WITHDRAWAL, REPORT_BALANCE| SP3

    subgraph Optimism
        SP3[SpokeVault]
        SP3 --> A3[Aave Adapter]
        SP3 --> C3[Compound Adapter]
    end
```
<!-- verified: CCIPHelpers.sol:MessageType for the message names on each edge; HubMessagingModule.sol and SpokeHandlersModule.sol for direction; src/adapters/ for the three adapter contracts; strategy.js:MARKETS.optimism.protocols for Optimism lacking Morpho -->

The hub is the single accounting authority. It holds no strategy logic of its own, it just knows how much USDC is idle, how much is mid-flight, and what each spoke last reported. Spokes are execution arms: they hold no user-facing accounting, they just do what the hub tells them and report back. See [docs/architecture.md](docs/architecture.md) for why this split, not something else.

## Repo map

| Path | What's there |
|---|---|
| `src/hub/` | Hub storage base plus the three sibling modules (admin, messaging, withdrawal) that make up `HUB` |
| `src/spoke/` | Spoke storage base plus the three sibling modules (admin, handlers, confirms) that make up `SpokeVault` |
| `src/libraries/` | `CCIPHelpers` (message codec) and `AllocationMaths` (pure allocation validation math) |
| `src/adapters/` | Aave, Compound, and Morpho adapters, one `IYieldSource` implementation each |
| `src/Rebalancer.sol`, `src/AgentConsumer.sol` | Off-chain agent entry point and on-chain allocation guardrails |
| `script/` | Deployment scripts, testnet and fork simulation |
| `test/units/` | Per-function unit tests |
| `test/regression/` | One test file per fix campaign item (WI-1 through WI-7, FX-1 through FX-8), named after the issue it locks in |
| `test/invariants/` | Foundry invariant fuzzing over Hub and Spoke handlers |
| `test/integration/` | Multi-contract flows, including the mainnet-fork end-to-end test |
| `docs/` | This documentation set, plus `docs/reference/` (generated API reference) and `docs/layout/` (storage layout snapshots from the module split) |

## Quickstart

```bash
git clone --recurse-submodules <repo-url>
cd meridian
forge build
forge test
```

If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive` before building.

The full suite runs without any network access except one test, `test/integration/FullFlowTest.t.sol`, which forks live Ethereum and Arbitrum mainnet state and needs `ETH_RPC_URL` and `ARBITRUM_RPC_URL` set. Without them that one test fails at `setUp()` and every other test still passes. <!-- verified: FullFlowTest.t.sol:setUp, vm.envString("ETH_RPC_URL") -->

```bash
export ETH_RPC_URL=https://your-mainnet-rpc
export ARBITRUM_RPC_URL=https://your-arbitrum-rpc
forge test --match-contract FullFlowTest -vvv
```

Deployment scripts live in `script/`, `DeployTestnet.s.sol` for the live testnet deployment below, `DeployForkSimulation.s.sol` for local fork-based rehearsal. See [docs/development.md](docs/development.md) for the full build, test, and deploy walkthrough.

## Docs

| Doc | Covers |
|---|---|
| [docs/index.md](docs/index.md) | One-screen map of this doc set and suggested reading order by audience |
| [docs/architecture.md](docs/architecture.md) | System topology, module layout, message protocol, fund location model |
| [docs/withdrawals.md](docs/withdrawals.md) | The three-path withdrawal engine, claim-time pricing, multi-leg recalls, cancellation |
| [docs/resilience.md](docs/resilience.md) | The failure-design story, what happens when a message never arrives, arrives twice, arrives late, or lies |
| [docs/security.md](docs/security.md) | Trust model, roles, invariants, known limitations, audit status |
| [docs/design-decisions.md](docs/design-decisions.md) | What was considered, rejected, and learned, a modernized version of the original design log |
| [docs/development.md](docs/development.md) | Build, test taxonomy, storage layout snapshots, module conventions for contributors |
| [docs/operations.md](docs/operations.md) | Operational runbook items, in-transit reconciliation, confirm retries |
| [docs/revert-audit.md](docs/revert-audit.md) | The systematic revert-path review that motivated the defensive receiver pattern |
| [docs/reference/](docs/reference/) | Generated API reference (forge doc output), regenerated from NatSpec, not hand-edited |

## Testnet deployments

All addresses below are the most recent deployment recorded in `broadcast/DeployTestnet.s.sol/`. Only the Aave adapter is live on any spoke today, Compound and Morpho adapters exist in source but have not been deployed to testnet. <!-- verified: broadcast/DeployTestnet.s.sol/*/run-latest.json, cross-checked against every timestamped run file per chain for the most recent CREATE per contract -->

| Chain | Contract | Address |
|---|---|---|
| Ethereum Sepolia | HUB | `0xff30cb7dced182eb4b4424e88f4347077a097b37` |
| Ethereum Sepolia | Rebalancer | `0x76f9547b8bd1f77bfe988535a559321a657e7acd` |
| Ethereum Sepolia | AgentConsumer | `0xe0a30a4ea672023277d80f3dbf752aa6faedd37e` |
| Arbitrum Sepolia | SpokeVault | `0x7871dd7e4826123c9f4f18565d9f874132ec2348` |
| Arbitrum Sepolia | AaveAdapter | `0x22e1a6ed534d015f8ef51238ee43c10b754b321c` |
| Base Sepolia | SpokeVault | `0xc69dddb4e33d0cef7a08ac171f877e1e1018b107` |
| Base Sepolia | AaveAdapter | `0x458a708cb6b4bf8ea21e9089f195fad2ab61ef05` |
| Optimism Sepolia | SpokeVault | `0x2a835c21fce662a0d88b1abe91bfbace5675a025` |

These addresses come from repeated redeploys during development and may be stale by the time you read this. Treat `broadcast/DeployTestnet.s.sol/` as the source of truth, this table is a convenience snapshot of it.

## Disclaimer

Meridian is unaudited software running on testnet only. Nothing here is financial advice, and nothing here should hold mainnet funds until an independent security review has happened. See [docs/security.md](docs/security.md) for the honest list of what's known to be unfinished.
