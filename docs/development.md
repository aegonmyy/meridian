# Development

This document specifies build, test, and contribution conventions for Meridian: the test taxonomy, the storage layout snapshots and their purpose, the conventions required by the module split, and the deploy scripts. It is intended for contributors writing code in this repository; for protocol evaluation, see [docs/architecture.md](architecture.md).

## Prerequisites and build

Meridian uses Foundry, with four git submodules for its Solidity dependencies: `forge-std`, `openzeppelin-contracts`, `chainlink-brownie-contracts`, and `chainlink-local`. <!-- verified: .gitmodules -->

```bash
git clone --recurse-submodules <repo-url>
cd meridian
forge build
forge test
```

If submodules were not pulled at clone time, submodules must be initialized before building: `git submodule update --init --recursive`. The optimizer runs at 1 with `via_ir = true`, tuned for deployed bytecode size over runtime gas; invariant runs default to 100 runs of 150 calls each (`fail_on_revert = true`). <!-- verified: foundry.toml -->

## Test taxonomy

`test/units/` provides per-function coverage, one behavior at a time, organized loosely by contract (`test/units/hub/` for hub-specific setups sharing a common base test contract).

`test/regression/` contains one file per fix campaign item, named after the issue it locks in: `WI1_MessageIdCollisionTest.t.sol`, `FX3_QuarantineRebaselineTest.t.sol`, and so on through WI-1 through WI-7 and FX-1 through FX-8 (not every numbered item has its own file; FX-8, for example, was an operations documentation change with no contract behavior to regression-test, see [docs/operations.md](operations.md)). The naming convention is deliberate: a failing test in this directory should be legible as "the defect from fix N recurred," not merely "an assertion failed." The convention for fixing a defect in this codebase is to write the regression test first, confirm it fails against the pre-fix code, then apply the fix and confirm the test passes, the same failing-test-first discipline followed by the fix campaigns themselves.

`test/invariants/` fuzzes call sequences against live `HUB` and `SpokeVault` instances through handler contracts (`hubHandler.t.sol`, `spokeHandler.t.sol`) and checks properties after every call. Default runs are 100 sequences of 150 calls each per `foundry.toml`. A full verification pass overrides `--fuzz-seed <n>` across multiple seeds, confirming the call count reported in Foundry's summary table is meaningful. Five of the checked invariants are documented in prose in [docs/security.md](security.md); the remainder are narrower registry and bookkeeping consistency checks documented directly in `test/invariants/hub/hubInvariant.sol` and `test/invariants/spoke/spokeInvariant.t.sol`.

`test/integration/` covers multi-contract flows, including `FullFlowTest.t.sol`, the only test in the suite requiring live network access. It forks real Ethereum and Arbitrum mainnet state via `CCIPLocalSimulatorFork` rather than mocking CCIP, exercising real router and token contract behavior rather than a simplified substitute. It requires `ETH_RPC_URL` and `ARBITRUM_RPC_URL`; absent these, it fails cleanly at `setUp()` without affecting any other test in the suite. <!-- verified: test/integration/FullFlowTest.t.sol:setUp -->

```bash
export ETH_RPC_URL=https://your-mainnet-rpc
export ARBITRUM_RPC_URL=https://your-arbitrum-rpc
forge test --match-contract FullFlowTest -vvv
```

## Storage layout snapshots and slot-pinned tests

`docs/layout/` holds `forge inspect <contract> storage-layout` and `methodIdentifiers` snapshots taken before the Hub and Spoke module split (R-0, in the modularization's own commit sequence), the baseline against which every later step in that split was diffed. Any change to `HubStorage.sol`'s or `SpokeStorage.sol`'s declaration order, or to the inheritance order of any module, requires regenerating and diffing this snapshot:

```bash
forge inspect src/Hub.sol:HUB storage-layout --json > /tmp/hub-layout.json
diff <(python3 -m json.tool docs/layout/hub.json) <(python3 -m json.tool /tmp/hub-layout.json)
```

An empty diff (excluding AST node id noise, which changes harmlessly whenever source text shifts) indicates slots are unaffected. A nonempty diff on slot or offset fields indicates a slot has moved, and every test using `vm.store` to set a specific slot directly will silently write to the wrong variable rather than fail visibly. This is the function of the slot-pinned regression tests: several files (`test/units/hub/BaseHubTest.t.sol`, `test/regression/WI5_TransitReconciliationTest.t.sol`, `test/regression/FX2_ReconcileInTransitToSpokeTest.t.sol`, and others) use `vm.store(address(hub), keccak256(abi.encode(...)), value)` to set state otherwise difficult to reach through the public interface, hardcoding the numeric slot a given mapping or variable occupies. <!-- verified: test/units/hub/BaseHubTest.t.sol:_setSpokeBalance, _setLastReportTimestamp, both computing keccak256(abi.encode(selector, slotNumber)) -->

These tests are not incidental; they constitute the proof that a change preserved layout. A failing test of this kind should almost never be resolved by updating the hardcoded slot number, which would mask the exact regression the test exists to catch. The correct response is to restore storage to its prior arrangement, or, if a layout change was genuinely intended, to regenerate the `docs/layout/` snapshots deliberately and update every `vm.store` call site to match, within the same commit, with the reasoning stated explicitly.

## Module conventions

The Hub and Spoke module split (see [docs/architecture.md](architecture.md) for its structure) operates under a small set of rules; deviation from them is the mechanism by which the storage-preservation guarantee would break silently.

- **All state resides in the storage base, and only there.** Every struct, state variable, and event for the Hub resides in `HubStorage.sol`, and for the Spoke in `SpokeStorage.sol`, in the exact order in which each would appear in the original single-file contract. No sibling module declares its own state. This is the complete mechanism keeping storage layout stable: a single owner of every declaration precludes silent reordering.
- **Cross-module calls proceed through hooks, not direct references.** Sibling modules do not inherit one another, so a function in one module requiring access to a function implemented in a different module must go through a bodiless `virtual` declaration in the storage base, implemented with `override` in exactly one module. A requirement to import a sibling module directly to call its function indicates a hook should be added instead. See the "Cross-Module Hooks" section in `HubStorage.sol` and `SpokeStorage.sol` for the existing set and the rationale for each.
- **A hook exists only where the actual call graph requires it.** Hooks should not be added speculatively; the module split's history includes several hooks anticipated by the original plan that proved unnecessary, because every caller remained within one module, and several unplanned hooks a first pass missed, both categories identified only by tracing actual call sites rather than inferring from the split's structure.
- **Genuine ambiguity should be escalated rather than resolved improvisationally.** The module split encountered two recurring categories of problem, relevant if this pattern is extended further: qualified `emit Contract.Event(...)` syntax resolves only an event declared directly on the named contract, never one inherited from a storage base, so a test using that pattern requires its qualifier updated to the actual declaring contract whenever an event relocates; and three-way diamond inheritance, where only one sibling module overrides a base class virtual function (an ERC4626 or CCIPReceiver hook, for example), still forces the most-derived contract to disambiguate explicitly, resolved with a thin, logic-free `super` delegation stub rather than a substantive override. Both are mechanical, well-understood fixes once identified, not indications of a deeper design defect.

## Deploy scripts

`script/DeployTestnet.s.sol` is the live-network deployment script, split into three phases run separately against different `--rpc-url` targets: hub stack on Ethereum Sepolia, spoke plus adapters on the target L2 Sepolia, then registering the spoke on the hub. It requires `DEPLOYER_KEY` and `AGENT_ADDRESS` in the environment, plus the previous phase's output addresses for phases 2 and 3. LINK funding for both hub and spoke is a manual post-deploy step, documented in the script's own header comment. <!-- verified: script/DeployTestnet.s.sol header comment -->

`script/DeployForkSimulation.s.sol` deploys the same full stack, hub, spoke, all three adapters, Rebalancer, AgentConsumer, in one run against forked mainnet state via `CCIPLocalSimulatorFork`, providing local rehearsal of a deployment sequence without testnet gas expenditure or CCIP latency.

Current live testnet addresses are listed in the [README](../README.md#testnet-deployments), sourced from `broadcast/DeployTestnet.s.sol/`, which remains the source of truth if the README table becomes outdated.
