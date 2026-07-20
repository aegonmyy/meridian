// Fresh Meridian deployment orchestrator — Aave x3 on real testnet CCIP.
// Resumable: writes agent-testing/deployment.json after every step; re-running skips
// finished steps. Sequence + gotchas derived from src/ (see DECISIONS.md §1).
//
// Usage:
//   node agent-testing/deploy.mjs hub          # Sepolia: hub + rebalancer + agentConsumer + wiring
//   node agent-testing/deploy.mjs spoke <name> # one L2: spoke + aave adapter + wiring
//   node agent-testing/deploy.mjs register     # Sepolia: addSpoke for every deployed spoke
//   node agent-testing/deploy.mjs all          # hub, then all spokes, then register
import { ethers } from "ethers";
import {
  INFRA, ART, ERC20_ABI, AAVE_ID, DEPLOYER_KEY, HUB_CHAIN, SPOKE_CHAINS,
  chainByName, provider, wallet, erc20, loadDeployment, saveDeployment, fmtEth,
} from "./lib/infra.mjs";

const LINK_FUND = ethers.parseEther("3"); // LINK per contract for CCIP fees

// Some testnet RPCs (seen on Alchemy OP-Sepolia) return a false revert from eth_estimateGas
// even when the tx is valid (verified by a raw eth_call succeeding). Set GAS_LIMIT to bypass
// estimation with an explicit cap — unused gas is not charged, so a generous value is safe.
const OVERRIDES = process.env.GAS_LIMIT ? { gasLimit: BigInt(process.env.GAS_LIMIT) } : {};

async function deploy(signer, art, args, label) {
  const f = new ethers.ContractFactory(art.abi, art.bytecode, signer);
  console.log(`  deploying ${label} ...`);
  const c = await f.deploy(...args, OVERRIDES);
  await c.waitForDeployment();
  const addr = await c.getAddress();
  console.log(`  ${label} = ${addr}`);
  return addr;
}

async function fundLink(chain, signer, linkAddr, target, amount, label) {
  const link = new ethers.Contract(linkAddr, ERC20_ABI, signer);
  const bal = await link.balanceOf(target);
  if (bal >= amount) {
    console.log(`  ${label} already holds ${fmtEth(bal)} LINK — skip funding`);
    return;
  }
  const tx = await link.transfer(target, amount, OVERRIDES);
  await tx.wait();
  console.log(`  funded ${label} with ${fmtEth(amount)} LINK (tx ${tx.hash})`);
}

async function deployHub() {
  const chain = HUB_CHAIN;
  const signer = wallet(chain);
  const d = loadDeployment();
  console.log(`\n=== HUB CHAIN: ${chain.name} ===`);
  const gas = await provider(chain).getBalance(signer.address);
  console.log(`  deployer ${signer.address} gas=${fmtEth(gas)} ETH`);

  // 1. Hub with rebalancer=0 (circular dep resolved via setRebalancer).
  if (!d.hub.hub) {
    d.hub.hub = await deploy(signer, ART.HUB,
      ["Meridian USDC", "mUSDC", chain.ccipRouter, signer.address, chain.link, chain.usdc, ethers.ZeroAddress],
      "HUB");
    saveDeployment(d);
  } else console.log(`  HUB = ${d.hub.hub} (cached)`);

  // 2+3. Rebalancer + AgentConsumer via counterfactual address prediction (gotcha G1).
  //      Both immutable + revert on zero, so predict AC's address before deploying Rebalancer.
  //      Must run as a pair — if AC fails, the Rebalancer is mis-wired and both are redone.
  if (!d.hub.rebalancer || !d.hub.agentConsumer) {
    const n = await provider(chain).getTransactionCount(signer.address, "pending");
    const predictedAC = ethers.getCreateAddress({ from: signer.address, nonce: n + 1 });
    console.log(`  predicted AgentConsumer @ nonce ${n + 1} = ${predictedAC}`);
    const rebalancer = await deploy(signer, ART.Rebalancer,
      [d.hub.hub, predictedAC, signer.address], "Rebalancer");
    const agentConsumer = await deploy(signer, ART.AgentConsumer,
      [rebalancer, signer.address, signer.address], "AgentConsumer");
    if (agentConsumer.toLowerCase() !== predictedAC.toLowerCase())
      throw new Error(`AC prediction MISS: got ${agentConsumer}, predicted ${predictedAC} — Rebalancer mis-wired, aborting`);
    d.hub.rebalancer = rebalancer;
    d.hub.agentConsumer = agentConsumer;
    saveDeployment(d);
  } else console.log(`  Rebalancer=${d.hub.rebalancer} AgentConsumer=${d.hub.agentConsumer} (cached)`);

  // 4. Wire hub -> rebalancer.
  const hub = new ethers.Contract(d.hub.hub, ART.HUB.abi, signer);
  if (!d.hub.setRebalancer) {
    const tx = await hub.setRebalancer(d.hub.rebalancer); await tx.wait();
    d.hub.setRebalancer = true; saveDeployment(d);
    console.log(`  hub.setRebalancer -> ${d.hub.rebalancer}`);
  }

  // 5. Whitelist all spoke selectors + AAVE protocol (gotcha G2).
  const rebal = new ethers.Contract(d.hub.rebalancer, ART.Rebalancer.abi, signer);
  d.hub.whitelistedChains ??= [];
  for (const s of SPOKE_CHAINS) {
    if (d.hub.whitelistedChains.includes(s.ccipSelector)) continue;
    const tx = await rebal.addChainToWhitelist(BigInt(s.ccipSelector)); await tx.wait();
    d.hub.whitelistedChains.push(s.ccipSelector); saveDeployment(d);
    console.log(`  whitelisted chain ${s.name} (${s.ccipSelector})`);
  }
  if (!d.hub.whitelistedAave) {
    const tx = await rebal.addProtocolToWhitelist(AAVE_ID); await tx.wait();
    d.hub.whitelistedAave = true; saveDeployment(d);
    console.log(`  whitelisted protocol AAVE (${AAVE_ID})`);
  }

  // 6. Fund hub with LINK for outbound CCIP.
  await fundLink(chain, signer, chain.link, d.hub.hub, LINK_FUND, "HUB");
  d.hub.linkFunded = true; saveDeployment(d);
  console.log(`  HUB chain done.`);
}

async function deploySpoke(name) {
  const chain = chainByName(name);
  const signer = wallet(chain);
  const d = loadDeployment();
  if (!d.hub.hub) throw new Error("deploy hub first");
  d.spokes[name] ??= {};
  const s = d.spokes[name];
  console.log(`\n=== SPOKE: ${chain.name} ===`);
  const gas = await provider(chain).getBalance(signer.address);
  console.log(`  deployer gas=${fmtEth(gas)} ETH`);

  if (!s.spoke) {
    s.spoke = await deploy(signer, ART.SpokeVault,
      [d.hub.hub, chain.usdc, chain.ccipRouter, signer.address, chain.link, BigInt(HUB_CHAIN.ccipSelector)],
      "SpokeVault");
    saveDeployment(d);
  } else console.log(`  SpokeVault = ${s.spoke} (cached)`);

  if (!s.aaveAdapter) {
    s.aaveAdapter = await deploy(signer, ART.AaveAdapter,
      [chain.aavePool, chain.aUsdc, chain.usdc], "AaveAdapter");
    saveDeployment(d);
  } else console.log(`  AaveAdapter = ${s.aaveAdapter} (cached)`);

  const spoke = new ethers.Contract(s.spoke, ART.SpokeVault.abi, signer);
  if (!s.setAdapter) {
    const tx = await spoke.setAdapter(AAVE_ID, s.aaveAdapter, OVERRIDES); await tx.wait();
    s.setAdapter = true; saveDeployment(d);
    console.log(`  spoke.setAdapter(AAVE) -> ${s.aaveAdapter}`);
  }

  await fundLink(chain, signer, chain.link, s.spoke, LINK_FUND, "SpokeVault");
  s.linkFunded = true; saveDeployment(d);
  console.log(`  ${name} spoke done.`);
}

async function registerSpokes() {
  const chain = HUB_CHAIN;
  const signer = wallet(chain);
  const d = loadDeployment();
  const hub = new ethers.Contract(d.hub.hub, ART.HUB.abi, signer);
  console.log(`\n=== REGISTER SPOKES on hub ===`);
  for (const sc of SPOKE_CHAINS) {
    const s = d.spokes[sc.name];
    if (!s?.spoke) { console.log(`  ${sc.name}: not deployed, skip`); continue; }
    if (s.registered) { console.log(`  ${sc.name}: already registered`); continue; }
    const tx = await hub.addSpoke(BigInt(sc.ccipSelector), s.spoke); await tx.wait();
    s.registered = true; saveDeployment(d);
    console.log(`  addSpoke(${sc.name}, ${s.spoke})`);
  }
  console.log(`  registration done.`);
}

const [cmd, arg] = process.argv.slice(2);
try {
  if (cmd === "hub") await deployHub();
  else if (cmd === "spoke") await deploySpoke(arg);
  else if (cmd === "register") await registerSpokes();
  else if (cmd === "all") {
    await deployHub();
    for (const s of SPOKE_CHAINS) await deploySpoke(s.name);
    await registerSpokes();
  } else {
    console.log("usage: node deploy.mjs [hub | spoke <name> | register | all]");
    process.exit(1);
  }
  console.log("\nOK");
} catch (e) {
  console.error("\nDEPLOY ERROR:", e.message || e);
  process.exit(1);
}
