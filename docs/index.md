# Docs Index

One screen map of this documentation set. Every document opens with its own short summary of what it covers and who it's for, so you don't need to have arrived here first, but if you're not sure where to start, pick your reading order below.

## By document

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | System topology, module layout, message protocol, fund location model, share accounting |
| [withdrawals.md](withdrawals.md) | The three-path withdrawal engine, claim-time pricing, multi-leg recall, cancellation |
| [resilience.md](resilience.md) | What happens when a message never arrives, arrives twice, arrives late, or lies |
| [security.md](security.md) | Trust model, roles, invariants, known limitations, audit status |
| [design-decisions.md](design-decisions.md) | What was considered, rejected, and learned, organized by theme |
| [development.md](development.md) | Build, test taxonomy, storage layout snapshots, module conventions, deploy scripts |
| [operations.md](operations.md) | LINK balances, monitoring, recovery paths, Path 2 liveness, UI guidance |
| [revert-audit.md](revert-audit.md) | Every revert reachable inside both `_ccipReceive` entry points, classified |
| [reference/](reference/) | Generated API reference from NatSpec, regenerated, never hand-edited |
| [design-history-audit.md](design-history-audit.md) | Working document behind design-decisions.md, the raw state.md staleness audit |
| [docs-findings.md](docs-findings.md) | Discrepancies found between code and documented behavior while writing this doc set |

## By audience

**Evaluating the protocol.** Start at the [README](../README.md), then [architecture.md](architecture.md), then [withdrawals.md](withdrawals.md). That's the system, its topology, and its hardest mechanism, in three documents.

**Integrating against it.** [withdrawals.md](withdrawals.md) for the exact semantics your integration needs to respect (claim-time pricing especially), then [security.md](security.md) for the trust assumptions you're inheriting, then [reference/](reference/) for exact function signatures.

**Contributing code.** [development.md](development.md) first for build, test conventions, and the module rules, then [design-decisions.md](design-decisions.md) for the reasoning behind the parts you're likely to touch.

## What's deliberately not here

There's no whitepaper and no tokenomics document, Meridian doesn't have a token. There's no audit report, because there hasn't been one yet, see [security.md](security.md) for that stated plainly rather than glossed over.
