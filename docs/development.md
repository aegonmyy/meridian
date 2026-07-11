# Development

This document covers building, testing, and contributing to Meridian: what the test taxonomy means, how the storage layout snapshots work and why they exist, the conventions the module split expects contributors to follow, and what the deploy scripts do. It's written for anyone about to write code here, not for evaluating the protocol from the outside, see [docs/architecture.md](architecture.md) for that.

## Prerequisites and build

Meridian uses Foundry, with four git submodules for its Solidity dependencies: `forge-std`, `openzeppelin-contracts`, `chainlink-brownie-contracts`, and `chainlink-local`. <!-- verified: .gitmodules -->

```bash
git clone --recurse-submodules <repo-url>
cd meridian
forge build
forge test
```

If submodules weren't pulled at clone time, `git submodule update --init --recursive` before building. The optimizer runs at 1 with `via_ir = true`, tuned for deployed bytecode size over runtime gas, and invariant runs default to 100 runs times 150 calls per run (`fail_on_revert = true`). <!-- verified: foundry.toml -->

## Test taxonomy

`test/units/` is per-function coverage, one behavior at a time, organized loosely by contract (`test/units/hub/` for hub-specific setups sharing a common base test contract).

`test/regression/` is one file per fix campaign item, named after the issue it locks in: `WI1_MessageIdCollisionTest.t.sol`, `FX3_QuarantineRebaselineTest.t.sol`, and so on through WI-1 through WI-7 and FX-1 through FX-8 (not every numbered item has its own file, FX-8 for instance was an operations documentation change with no contract behavior to regression-test, see [docs/operations.md](operations.md)). The naming convention is deliberate: a failing test here should be readable as "the bug from fix N came back," not just "some assertion failed." When you fix a real bug in this codebase, the convention is to write the regression test *first*, watch it fail against the pre-fix code, then fix the code and watch it pass, the same failing-test-first discipline the fix campaigns themselves followed.

`test/invariants/` fuzzes call sequences against live `HUB` and `SpokeVault` instances through handler contracts (`hubHandler.t.sol`, `spokeHandler.t.sol`) and checks properties after every call. Default runs are 100 sequences of 150 calls each per `foundry.toml`, for a full CI-quality pass, override with `--fuzz-seed <n>` across a few different seeds and check the call count actually hit meaningfully in the summary table Foundry prints. Five of the checked invariants are foundational enough to be documented in prose in [docs/security.md](security.md), the rest are narrower registry and bookkeeping consistency checks best read directly in `test/invariants/hub/hubInvariant.sol` and `test/invariants/spoke/spokeInvariant.t.sol`.

`test/integration/` covers multi-contract flows, including `FullFlowTest.t.sol`, the one test in the whole suite that needs live network access. It forks real Ethereum and Arbitrum mainnet state via `CCIPLocalSimulatorFork` rather than mocking CCIP, because the goal is to exercise real router and token contract behavior, not a simplified stand-in for it. It needs `ETH_RPC_URL` and `ARBITRUM_RPC_URL` set, and fails cleanly at `setUp()` without them, every other test in the suite is unaffected. <!-- verified: test/integration/FullFlowTest.t.sol:setUp -->

```bash
export ETH_RPC_URL=https://your-mainnet-rpc
export ARBITRUM_RPC_URL=https://your-arbitrum-rpc
forge test --match-contract FullFlowTest -vvv
```

## Storage layout snapshots and slot-pinned tests

`docs/layout/` holds `forge inspect <contract> storage-layout` and `methodIdentifiers` snapshots taken before the Hub and Spoke module split (R-0, in the modularization's own commit sequence), the baseline every later step in that split was diffed against. If you ever touch `HubStorage.sol` or `SpokeStorage.sol`'s declaration order, or the inheritance order of any module, regenerate and diff:

```bash
forge inspect src/Hub.sol:HUB storage-layout --json > /tmp/hub-layout.json
diff <(python3 -m json.tool docs/layout/hub.json) <(python3 -m json.tool /tmp/hub-layout.json)
```

An empty diff (ignoring AST node id noise, which changes harmlessly whenever source text shifts) means slots are unaffected. A nonempty diff on slot or offset fields means something moved, and every test using `vm.store` to poke a specific slot directly will silently start writing to the wrong variable, not fail loudly. That's exactly what the slot-pinned regression tests are for: several files (`test/units/hub/BaseHubTest.t.sol`, `test/regression/WI5_TransitReconciliationTest.t.sol`, `test/regression/FX2_ReconcileInTransitToSpokeTest.t.sol`, and others) use `vm.store(address(hub), keccak256(abi.encode(...)), value)` to set state that would otherwise be hard to reach through the public interface, hardcoding the numeric slot a given mapping or variable lives at. <!-- verified: test/units/hub/BaseHubTest.t.sol:_setSpokeBalance, _setLastReportTimestamp, both computing keccak256(abi.encode(selector, slotNumber)) -->

These tests are not incidental, they're the actual proof that a change preserved layout. If one of them starts failing, the correct response is almost never to update the hardcoded slot number to make it pass again, that's masking the exact regression the test exists to catch. The correct response is to fix whatever moved storage back to where it was, or, if a layout change was genuinely intended, to regenerate the `docs/layout/` snapshots deliberately and update every `vm.store` call site to match, in the same commit, with the reasoning stated plainly.

## Module conventions

The Hub and Spoke module split (see [docs/architecture.md](architecture.md) for the shape of it) works under a small set of rules, and deviating from them is how the storage-preservation guarantee breaks silently.

- **All state lives in the storage base, and only there.** Every struct, every state variable, every event for the Hub lives in `HubStorage.sol`, for the Spoke in `SpokeStorage.sol`, in the exact order they'd have appeared in the original single-file contract. No sibling module declares its own state. This is the entire mechanism that keeps storage layout stable, one owner of every declaration means nothing can silently reorder.
- **Cross-module calls go through hooks, not direct references.** Sibling modules don't inherit each other, so a function in one module that needs to call a function implemented in a different module has to go through a bodiless `virtual` declaration in the storage base, implemented with `override` in exactly one module. If you find yourself wanting to import a sibling module directly to call its function, that's the signal to add a hook instead. See the "Cross-Module Hooks" section in `HubStorage.sol` and `SpokeStorage.sol` for the existing set and why each one exists.
- **A hook only exists if the real call graph needs it.** Don't add a hook speculatively, the module split's own history includes several hooks the original plan expected that turned out unnecessary because every caller stayed inside one module, and a few unplanned ones a first pass missed, both found only by tracing actual call sites, not by guessing from the shape of the split.
- **Escalate rather than improvise around a genuine ambiguity.** The module split hit two categories of problem worth naming, because they'll likely recur if this pattern extends further: qualified `emit Contract.Event(...)` syntax only resolves an event declared directly on the named contract, never one inherited from a storage base, so any test using that pattern needs its qualifier updated to the actual declaring contract when an event moves; and a 3-way diamond inheritance where only one sibling module overrides a base class virtual function (an ERC4626 or CCIPReceiver hook, for instance) still forces the most-derived contract to explicitly disambiguate, resolved with a thin, logic-free `super` delegation stub, not a real override. Both are mechanical, well-understood fixes once you've seen them once, not signs of a deeper design problem.

## Deploy scripts

`script/DeployTestnet.s.sol` is the live-network deployment script, split into three phases run separately against different `--rpc-url` targets: hub stack on Ethereum Sepolia, spoke plus adapters on the target L2 Sepolia, then registering the spoke back on the hub. It expects `DEPLOYER_KEY` and `AGENT_ADDRESS` in the environment, plus the previous phase's output addresses for phases 2 and 3. LINK funding for both hub and spoke is a manual post-deploy step, this is documented directly in the script's own header comment. <!-- verified: script/DeployTestnet.s.sol header comment -->

`script/DeployForkSimulation.s.sol` deploys the same full stack, hub, spoke, all three adapters, Rebalancer, AgentConsumer, in one run against forked mainnet state via `CCIPLocalSimulatorFork`, for local rehearsal of a deployment sequence without spending real testnet gas or waiting on real CCIP latency.

See the [README](../README.md#testnet-deployments) for the current live testnet addresses, sourced from `broadcast/DeployTestnet.s.sol/`, which is the actual source of truth if the README table has gone stale.
