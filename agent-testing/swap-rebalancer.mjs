// Hot-swap the Rebalancer with the freshly-built (dust-lock-fixed) bytecode. Redeploys
// Rebalancer + its bound AgentConsumer (counterfactual prediction, same as initial deploy),
// points the hub at the new Rebalancer, and re-applies the whitelists (they live on the
// Rebalancer instance). Hub and spokes are untouched. Updates deployment.json in place.
import { ethers } from "ethers";
import {
  HUB_CHAIN, SPOKE_CHAINS, ART, AAVE_ID, provider, wallet, loadDeployment, saveDeployment,
} from "./lib/infra.mjs";

const d = loadDeployment();
const signer = wallet(HUB_CHAIN);
const p = provider(HUB_CHAIN);

async function deploy(art, args, label) {
  const f = new ethers.ContractFactory(art.abi, art.bytecode, signer);
  const c = await f.deploy(...args);
  await c.waitForDeployment();
  const addr = await c.getAddress();
  console.log(`  ${label} = ${addr}`);
  return addr;
}

console.log("Hot-swapping Rebalancer with dust-lock fix...");
console.log(`  old rebalancer = ${d.hub.rebalancer}`);

const n = await p.getTransactionCount(signer.address, "pending");
const predictedAC = ethers.getCreateAddress({ from: signer.address, nonce: n + 1 });
console.log(`  predicted AgentConsumer @ nonce ${n + 1} = ${predictedAC}`);

const rebalancer = await deploy(ART.Rebalancer, [d.hub.hub, predictedAC, signer.address], "Rebalancer");
const agentConsumer = await deploy(ART.AgentConsumer, [rebalancer, signer.address, signer.address], "AgentConsumer");
if (agentConsumer.toLowerCase() !== predictedAC.toLowerCase())
  throw new Error(`AC prediction miss: ${agentConsumer} != ${predictedAC}`);

const hub = new ethers.Contract(d.hub.hub, ART.HUB.abi, signer);
let tx = await hub.setRebalancer(rebalancer); await tx.wait();
console.log(`  hub.setRebalancer -> ${rebalancer}`);

const rebal = new ethers.Contract(rebalancer, ART.Rebalancer.abi, signer);
for (const s of SPOKE_CHAINS) {
  tx = await rebal.addChainToWhitelist(BigInt(s.ccipSelector)); await tx.wait();
  console.log(`  whitelisted ${s.name}`);
}
tx = await rebal.addProtocolToWhitelist(AAVE_ID); await tx.wait();
console.log(`  whitelisted AAVE`);

d.hub.rebalancerPrev = d.hub.rebalancer;
d.hub.agentConsumerPrev = d.hub.agentConsumer;
d.hub.rebalancer = rebalancer;
d.hub.agentConsumer = agentConsumer;
d.hub.rebalancerFixed = true;
saveDeployment(d);
console.log("Done. New Rebalancer live, hub repointed, whitelists reapplied.");
