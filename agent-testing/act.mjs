// Meridian interaction CLI. Drives real testnet txns against the fresh deployment.
//
//   node agent-testing/act.mjs status
//   node agent-testing/act.mjs deposit <usdc>            deposit USDC into the hub
//   node agent-testing/act.mjs allocate                  push 100% of idle to Aave across spokes (40/40/20)
//   node agent-testing/act.mjs recall <chain> <usdc>     pull USDC from a spoke back to hub idle
//   node agent-testing/act.mjs redeem <shares|all>       burn shares, withdraw USDC
//
// GAS_LIMIT env bypasses eth_estimateGas (needed for the OP-Sepolia RPC).
import { ethers } from "ethers";
import {
  HUB_CHAIN, SPOKE_CHAINS, ART, ERC20_ABI, AAVE_ID,
  provider, wallet, erc20, loadDeployment, fmtUsdc, fmtEth,
} from "./lib/infra.mjs";

const d = loadDeployment();
const OVERRIDES = process.env.GAS_LIMIT ? { gasLimit: BigInt(process.env.GAS_LIMIT) } : {};
const usdc6 = (n) => ethers.parseUnits(String(n), 6);

function hubW() { return new ethers.Contract(d.hub.hub, ART.HUB.abi, wallet(HUB_CHAIN)); }
function rebalW() { return new ethers.Contract(d.hub.rebalancer, ART.Rebalancer.abi, wallet(HUB_CHAIN)); }
const chain = (name) => SPOKE_CHAINS.find((s) => s.name === name);

async function status() {
  const hp = provider(HUB_CHAIN);
  const hub = new ethers.Contract(d.hub.hub, ART.HUB.abi, hp);
  const usdc = erc20(HUB_CHAIN, HUB_CHAIN.usdc, hp);
  const link = erc20(HUB_CHAIN, HUB_CHAIN.link, hp);
  console.log(`HUB ${d.hub.hub} (Sepolia)`);
  console.log(`  totalAssets     ${fmtUsdc(await hub.totalAssets())} USDC`);
  console.log(`  totalSupply     ${fmtUsdc(await hub.totalSupply())} shares`);
  console.log(`  idle            ${fmtUsdc(await hub.idleBalance())} USDC`);
  console.log(`  reserved        ${fmtUsdc(await hub.reservedAssets())} USDC`);
  console.log(`  inTransit       ${fmtUsdc(await hub.inTransitAssets())} USDC`);
  console.log(`  USDC held       ${fmtUsdc(await usdc.balanceOf(d.hub.hub))}`);
  console.log(`  LINK held       ${fmtEth(await link.balanceOf(d.hub.hub))}`);
  for (const s of SPOKE_CHAINS) {
    const meta = d.spokes[s.name];
    const spokeBal = await hub.spokeBalances(BigInt(s.ccipSelector));
    const inFlight = await hub.inTransitToSpoke(BigInt(s.ccipSelector));
    const lastReport = await hub.lastReportTimestamp(BigInt(s.ccipSelector));
    const sp = provider(s);
    const sIdle = await erc20(s, s.usdc, sp).balanceOf(meta.spoke);
    const sAave = await erc20(s, s.aUsdc, sp).balanceOf(meta.aaveAdapter);
    const sLink = await erc20(s, s.link, sp).balanceOf(meta.spoke);
    console.log(`SPOKE ${s.name}  ${meta.spoke}`);
    console.log(`  hub.spokeBalances ${fmtUsdc(spokeBal)} | inTransitToSpoke ${inFlight} | lastReport ${lastReport}`);
    console.log(`  on-chain: idle USDC ${fmtUsdc(sIdle)} | in Aave ${fmtUsdc(sAave)} | LINK ${fmtEth(sLink)}`);
  }
}

async function deposit(amountStr) {
  const w = wallet(HUB_CHAIN);
  const usdc = new ethers.Contract(HUB_CHAIN.usdc, ERC20_ABI, w);
  const amt = usdc6(amountStr);
  const bal = await usdc.balanceOf(w.address);
  if (bal < amt) throw new Error(`have ${fmtUsdc(bal)} USDC, need ${fmtUsdc(amt)}`);
  const allow = await usdc.allowance(w.address, d.hub.hub);
  if (allow < amt) {
    const a = await usdc.approve(d.hub.hub, amt); await a.wait();
    console.log(`approved ${fmtUsdc(amt)} USDC`);
  }
  const tx = await hubW().deposit(amt, w.address);
  const rc = await tx.wait();
  console.log(`deposit ${fmtUsdc(amt)} USDC -> hub. tx ${tx.hash} block ${rc.blockNumber}`);
}

// Fixed first allocation: 40% Arb, 40% Base, 20% OP, all to Aave. Sums to 10000 bps.
async function allocate() {
  const hp = provider(HUB_CHAIN);
  const hub = new ethers.Contract(d.hub.hub, ART.HUB.abi, hp);
  // Sends are sized against deployable idle (idle minus reserved), matching the Rebalancer.
  const idle = await hub.idleBalance();
  const reserved = await hub.reservedAssets();
  const total = idle > reserved ? idle - reserved : 0n;
  if (total === 0n) throw new Error("no deployable idle - deposit or recall first");
  const order = ["arbitrum-sepolia", "base-sepolia", "optimism-sepolia"];
  const bps = { "arbitrum-sepolia": 4000, "base-sepolia": 4000, "optimism-sepolia": 2000 };
  const proposal = {
    proposedAllocations: order.map((n) => [BigInt(bps[n])]),
    proposedNetApys: order.map(() => 300n),          // positive so it clears the 50bps threshold
    currentAllocations: order.map(() => [0n]),
    currentNetApys: order.map(() => 0n),
    chainSelectors: order.map((n) => BigInt(chain(n).ccipSelector)),
    protocolIds: order.map(() => [AAVE_ID]),
  };
  for (const n of order) console.log(`  ${n}: ${bps[n]} bps -> ${fmtUsdc(total * BigInt(bps[n]) / 10000n)} USDC`);
  const tx = await rebalW().proposeAllocation(proposal, OVERRIDES);
  const rc = await tx.wait();
  console.log(`allocate submitted. tx ${tx.hash} block ${rc.blockNumber}`);
  console.log(`trace with: node agent-testing/trace.mjs ${tx.hash}`);
}

async function recall(name, amountStr) {
  const c = chain(name);
  if (!c) throw new Error(`unknown chain ${name}`);
  const tx = await rebalW().recallFromSpoke(BigInt(c.ccipSelector), usdc6(amountStr), OVERRIDES);
  const rc = await tx.wait();
  console.log(`recall ${amountStr} USDC from ${name}. tx ${tx.hash} block ${rc.blockNumber}`);
}

async function redeem(sharesStr) {
  const w = wallet(HUB_CHAIN);
  const hub = hubW();
  const shares = sharesStr === "all" ? await hub.balanceOf(w.address) : usdc6(sharesStr);
  const tx = await hub.redeem(shares, w.address, w.address);
  const rc = await tx.wait();
  console.log(`redeem ${fmtUsdc(shares)} shares. tx ${tx.hash} block ${rc.blockNumber}`);
}

const [cmd, a, b] = process.argv.slice(2);
const run = { status: () => status(), deposit: () => deposit(a), allocate: () => allocate(),
  recall: () => recall(a, b), redeem: () => redeem(a) }[cmd];
if (!run) { console.log("cmds: status | deposit <usdc> | allocate | recall <chain> <usdc> | redeem <shares|all>"); process.exit(1); }
run().then(() => console.log("done")).catch((e) => { console.error("ERR:", e.shortMessage || e.message || e); process.exit(1); });
