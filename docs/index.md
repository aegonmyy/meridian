# Docs Index

This document is a one-screen map of the documentation set. Each document opens with a summary of its scope and intended audience, so no document assumes the reader arrived here first. Suggested reading orders by audience follow below.

## By document

| Doc | Scope |
|---|---|
| [architecture.md](architecture.md) | System topology, module layout, message protocol, fund location model, share accounting |
| [withdrawals.md](withdrawals.md) | The three-path withdrawal engine, claim-time pricing, multi-leg recall, cancellation |
| [resilience.md](resilience.md) | Failure handling: message non-delivery, duplication, delayed arrival, and falsified spoke reports |
| [security.md](security.md) | Trust model, roles, invariants, known limitations, audit status |
| [design-decisions.md](design-decisions.md) | Design rationale: alternatives considered, rejected, and superseded, organized by theme |
| [development.md](development.md) | Build, test taxonomy, storage layout snapshots, module conventions, deploy scripts |
| [operations.md](operations.md) | LINK balances, monitoring, recovery paths, Path 2 liveness, UI guidance |
| [revert-audit.md](revert-audit.md) | Every revert reachable inside both `_ccipReceive` entry points, classified |
| [reference/](reference/) | Generated API reference from NatSpec, regenerated, never hand-edited |
| [design-history-audit.md](design-history-audit.md) | Working document behind design-decisions.md, the raw state.md staleness audit |
| [docs-findings.md](docs-findings.md) | Discrepancies identified between code and documented behavior during preparation of this documentation set, flagged for review |

## By audience

**Protocol evaluation.** The [README](../README.md), followed by [architecture.md](architecture.md), followed by [withdrawals.md](withdrawals.md): system overview, topology, and the withdrawal engine.

**Protocol integration.** [withdrawals.md](withdrawals.md) for settlement semantics, particularly claim-time pricing, followed by [security.md](security.md) for the trust model, followed by [reference/](reference/) for function signatures.

**Code contribution.** [development.md](development.md) for build and test conventions and module rules, followed by [design-decisions.md](design-decisions.md) for the rationale behind commonly modified components.

## Out of scope

This documentation set does not include a whitepaper or tokenomics document; Meridian has no token. No audit report exists; see [security.md](security.md) for a complete statement of audit status.
