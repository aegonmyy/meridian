// Negative-test battery. Every case is a call that SHOULD revert with a specific error.
// Run as eth_call simulations (no state change, no spend). A test passes if the call reverts
// with the expected custom error; it FAILS if it does not revert, or reverts with a different
// error. This is the "are the guards actually wired" check.
//
//   node agent-testing/probe.mjs
import { ethers } from "ethers";
import {
  HUB_CHAIN, SPOKE_CHAINS, ART, AAVE_ID, provider, chainByName, loadDeployment,
} from "./lib/infra.mjs";

const d = loadDeployment();
const DEAD = "0x000000000000000000000000000000000000dEaD";     // unauthorized caller
const OWNER = "0xF44d83F39578ca49a4d3E994b51455527946822d";    // authorized (owner/agent)
const FAKE = ethers.keccak256(ethers.toUtf8Bytes("FAKE"));     // non-whitelisted protocol
const sel = (n) => BigInt(chainByName(n).ccipSelector);

const mkProposal = (allocs, apys) => ({
  proposedAllocations: allocs.map((a) => [BigInt(a)]),
  proposedNetApys: apys.map((x) => BigInt(x)),
  currentAllocations: allocs.map(() => [0n]),
  currentNetApys: allocs.map(() => 0n),
  chainSelectors: ["arbitrum-sepolia", "base-sepolia", "optimism-sepolia"].map(sel),
  protocolIds: allocs.map(() => [AAVE_ID]),
});
const validProposal = mkProposal([4000, 4000, 2000], [300, 300, 300]);
const instr = [{ adapter: AAVE_ID, amount: 1n, targetAdapter: ethers.ZeroHash, targetAmount: 0n }];

// target: {chain, address, artifact}
const HUB = { chain: HUB_CHAIN, address: d.hub.hub, art: ART.HUB };
const REBAL = { chain: HUB_CHAIN, address: d.hub.rebalancer, art: ART.Rebalancer };
const AC = { chain: HUB_CHAIN, address: d.hub.agentConsumer, art: ART.AgentConsumer };
const ARB_SPOKE = { chain: chainByName("arbitrum-sepolia"), address: d.spokes["arbitrum-sepolia"].spoke, art: ART.SpokeVault };

const T = [
  // ── Rebalancer access control ──
  ["Rebalancer.proposeAllocation from stranger", REBAL, "proposeAllocation", [validProposal], DEAD, "NotAuthorized"],
  ["Rebalancer.recallFromSpoke from stranger", REBAL, "recallFromSpoke", [sel("optimism-sepolia"), 1n], DEAD, "NotAuthorized"],
  ["Rebalancer.addChainToWhitelist from stranger", REBAL, "addChainToWhitelist", [999n], DEAD, "NotAuthorized"],
  // ── Rebalancer input validation (as owner) ──
  ["Rebalancer.rebalance source==target", REBAL, "rebalance", [AAVE_ID, AAVE_ID, 1n, sel("arbitrum-sepolia")], OWNER, "SourceEqualsTarget"],
  ["Rebalancer.rebalance zero amount", REBAL, "rebalance", [AAVE_ID, FAKE, 0n, sel("arbitrum-sepolia")], OWNER, "ZeroAmount"],
  ["Rebalancer.rebalance chain not whitelisted", REBAL, "rebalance", [AAVE_ID, FAKE, 1n, 999n], OWNER, "ChainNotWhitelisted"],
  ["Rebalancer.rebalance protocol not whitelisted", REBAL, "rebalance", [AAVE_ID, FAKE, 1n, sel("arbitrum-sepolia")], OWNER, "ProtocolNotWhitelisted"],
  ["Rebalancer.recallFromSpoke zero amount", REBAL, "recallFromSpoke", [sel("arbitrum-sepolia"), 0n], OWNER, "ZeroAmount"],
  ["Rebalancer.recallFromSpoke chain not whitelisted", REBAL, "recallFromSpoke", [999n, 1n], OWNER, "ChainNotWhitelisted"],
  ["Rebalancer.proposeAllocation sum!=10000", REBAL, "proposeAllocation", [mkProposal([4000, 4000, 1000], [300, 300, 300])], OWNER, "InvalidAllocation"],
  ["Rebalancer.proposeAllocation market>6000", REBAL, "proposeAllocation", [mkProposal([7000, 2000, 1000], [300, 300, 300])], OWNER, "InvalidAllocation"],
  ["Rebalancer.proposeAllocation below threshold", REBAL, "proposeAllocation", [mkProposal([4000, 4000, 2000], [0, 0, 0])], OWNER, "BelowThreshold"],
  ["Rebalancer.proposeAllocation exceeds idle", REBAL, "proposeAllocation", [validProposal], OWNER, "InsufficientIdleForProposal"],
  // ── AgentConsumer access control ──
  ["AgentConsumer.proposeAllocation from stranger", AC, "proposeAllocation", [validProposal], DEAD, "NotAgent"],
  // ── Hub access control + validation ──
  ["Hub.addSpoke from stranger", HUB, "addSpoke", [sel("arbitrum-sepolia"), DEAD], DEAD, "OwnableUnauthorizedAccount"],
  ["Hub.setOutboundGasLimit from stranger", HUB, "setOutboundGasLimit", [1n], DEAD, "OwnableUnauthorizedAccount"],
  ["Hub.sendToSpoke from non-rebalancer", HUB, "sendToSpoke", [sel("arbitrum-sepolia"), instr], DEAD, "NotRebalancer"],
  ["Hub.addSpoke zero address", HUB, "addSpoke", [sel("arbitrum-sepolia"), ethers.ZeroAddress], OWNER, "ZeroAddress"],
  ["Hub.setRebalancer zero address", HUB, "setRebalancer", [ethers.ZeroAddress], OWNER, "ZeroAddress"],
  // ── Spoke access control + validation ──
  ["Spoke.setAdapter from stranger", ARB_SPOKE, "setAdapter", [AAVE_ID, DEAD], DEAD, "OwnableUnauthorizedAccount"],
  ["Spoke.setHub from stranger", ARB_SPOKE, "setHub", [DEAD], DEAD, "OwnableUnauthorizedAccount"],
  ["Spoke.deployIdle from stranger", ARB_SPOKE, "deployIdle", [AAVE_ID, 1n], DEAD, "OwnableUnauthorizedAccount"],
  ["Spoke.setAdapter zero address", ARB_SPOKE, "setAdapter", [AAVE_ID, ethers.ZeroAddress], OWNER, "ZeroAddress"],
  // ── ERC4626 limits ──
  ["Hub.redeem more than owned", HUB, "redeem", [1000000000n, OWNER, OWNER], OWNER, "ERC4626ExceededMaxRedeem"],
  ["Hub.withdraw more than owned", HUB, "withdraw", [1000000000n, OWNER, OWNER], OWNER, "ERC4626ExceededMaxWithdraw"],
];

function revertData(e) {
  return e?.data ?? e?.info?.error?.data ?? e?.error?.data ?? e?.value ?? null;
}

async function run() {
  let pass = 0, fail = 0;
  for (const [name, tgt, fn, args, from, expect] of T) {
    const iface = new ethers.Interface(tgt.art.abi);
    const data = iface.encodeFunctionData(fn, args);
    const p = provider(tgt.chain);
    let got = "(did NOT revert)";
    let ok = false;
    try {
      await p.call({ to: tgt.address, from, data });
    } catch (e) {
      const rd = revertData(e);
      if (rd && rd !== "0x") {
        try { got = iface.parseError(rd)?.name ?? rd; }
        catch { got = rd.slice(0, 10); }
      } else {
        got = (e.shortMessage || e.message || "revert").slice(0, 40);
      }
      ok = got === expect;
    }
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}\n        expect ${expect} | got ${got}`);
    ok ? pass++ : fail++;
  }
  console.log(`\n${pass}/${T.length} passed, ${fail} failed`);
}
run().catch((e) => { console.error(e); process.exit(1); });
