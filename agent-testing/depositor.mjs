// Multi-user test: generate (or reuse) a fresh depositor key, fund it with gas + USDC from the
// operator key, deposit into the hub, and verify shares minted match the fair share-price.
//   node agent-testing/depositor.mjs <index> <usdcAmount>
import { ethers } from "ethers";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { HUB_CHAIN, ART, ERC20_ABI, wallet, provider, erc20, loadDeployment, fmtUsdc } from "./lib/infra.mjs";

const AT = path.dirname(fileURLToPath(import.meta.url));
const KEYS = path.join(AT, "depositors.json");
const store = fs.existsSync(KEYS) ? JSON.parse(fs.readFileSync(KEYS, "utf8")) : {};

const idx = process.argv[2] ?? "1";
const amountStr = process.argv[3] ?? "2";
const d = loadDeployment();

if (!store[idx]) {
  const w = ethers.Wallet.createRandom();
  store[idx] = { address: w.address, key: w.privateKey };
  fs.writeFileSync(KEYS, JSON.stringify(store, null, 2));
  console.log(`generated depositor #${idx}: ${w.address}`);
}
const dep = store[idx];

const op = wallet(HUB_CHAIN);                       // operator/god-key funds the depositor
const p = provider(HUB_CHAIN);
const usdcOp = new ethers.Contract(HUB_CHAIN.usdc, ERC20_ABI, op);
const amt = ethers.parseUnits(amountStr, 6);

// fund gas
const gasBal = await p.getBalance(dep.address);
if (gasBal < ethers.parseEther("0.01")) {
  const tx = await op.sendTransaction({ to: dep.address, value: ethers.parseEther("0.02") });
  await tx.wait(); console.log(`funded ${dep.address} with 0.02 ETH gas`);
}
// fund USDC
const usdcBal = await usdcOp.balanceOf(dep.address);
if (usdcBal < amt) {
  const tx = await usdcOp.transfer(dep.address, amt); await tx.wait();
  console.log(`funded ${dep.address} with ${fmtUsdc(amt)} USDC`);
}

// snapshot price before
const hubRead = new ethers.Contract(d.hub.hub, ART.HUB.abi, p);
const taBefore = await hubRead.totalAssets();
const tsBefore = await hubRead.totalSupply();
const expectedShares = tsBefore === 0n ? amt : (amt * tsBefore) / taBefore;

// deposit as the depositor
const depW = new ethers.Wallet(dep.key, p);
const usdcDep = new ethers.Contract(HUB_CHAIN.usdc, ERC20_ABI, depW);
const hubDep = new ethers.Contract(d.hub.hub, ART.HUB.abi, depW);
const ap = await usdcDep.approve(d.hub.hub, amt); await ap.wait();
const sharesBefore = await hubRead.balanceOf(dep.address);
const tx = await hubDep.deposit(amt, dep.address); const rc = await tx.wait();
const sharesAfter = await hubRead.balanceOf(dep.address);
const minted = sharesAfter - sharesBefore;

console.log(`\ndepositor #${idx} deposited ${fmtUsdc(amt)} USDC (tx ${tx.hash})`);
console.log(`  totalAssets before ${fmtUsdc(taBefore)} | totalSupply before ${fmtUsdc(tsBefore)}`);
console.log(`  shares minted ${fmtUsdc(minted)} | fair-price expected ${fmtUsdc(expectedShares)}`);
console.log(`  ${minted === expectedShares ? "MATCH: share math correct" : "MISMATCH: investigate"}`);
