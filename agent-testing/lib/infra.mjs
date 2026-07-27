// Shared infra: loads verified testnet addresses, compiled artifacts, and wallet/provider
// helpers. Everything derives from testnet-infra.json (verified on-chain) and out/ (forge build).
import { ethers } from "ethers";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..", "..");
const AT = path.resolve(__dirname, "..");

export const INFRA = JSON.parse(fs.readFileSync(path.join(AT, "testnet-infra.json"), "utf8"));

// The operator god-key already present in the repo (run-live.mjs). It owns Hub, Rebalancer,
// AgentConsumer and is the registered AGENT. Funded on all 4 chains. Testnet only, rotate
// before any mainnet use (see DECISIONS.md SECURITY).
export const DEPLOYER_KEY =
  process.env.DEPLOYER_KEY ||
  "0xe83bbb5223339d634ca6f0eb5225b9a0b611e3038a6eef7a44b66cab1b3907d5";

export const AAVE_ID = ethers.keccak256(ethers.toUtf8Bytes("AAVE"));

// ── Artifacts (forge build output) ──────────────────────────────────────────
function artifact(rel) {
  const j = JSON.parse(fs.readFileSync(path.join(ROOT, "out", rel), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
export const ART = {
  HUB: artifact("Hub.sol/HUB.json"),
  Rebalancer: artifact("Rebalancer.sol/Rebalancer.json"),
  AgentConsumer: artifact("AgentConsumer.sol/AgentConsumer.json"),
  SpokeVault: artifact("Spoke.sol/SpokeVault.json"),
  AaveAdapter: artifact("AaveAdapter.sol/AaveAdapter.json"),
};

// Minimal ERC20 ABI for USDC / LINK reads + transfers/approvals.
export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];

// ── Chain registry ──────────────────────────────────────────────────────────
export const HUB_CHAIN = INFRA.hubChain;
export const SPOKE_CHAINS = INFRA.spokes;
export const ALL_CHAINS = [INFRA.hubChain, ...INFRA.spokes];

export function chainByName(name) {
  const c = ALL_CHAINS.find((c) => c.name === name);
  if (!c) throw new Error(`unknown chain ${name}`);
  return c;
}

export function provider(chain) {
  return new ethers.JsonRpcProvider(chain.rpc);
}
export function wallet(chain, key = DEPLOYER_KEY) {
  return new ethers.Wallet(key, provider(chain));
}
export function erc20(chain, addr, signerOrProvider) {
  return new ethers.Contract(addr, ERC20_ABI, signerOrProvider);
}

// ── Deployment state (resumable) ────────────────────────────────────────────
const STATE_PATH = path.join(AT, "deployment.json");
export function loadDeployment() {
  if (fs.existsSync(STATE_PATH)) return JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  return { hub: {}, spokes: {} };
}
export function saveDeployment(d) {
  fs.writeFileSync(STATE_PATH, JSON.stringify(d, null, 2));
}

export const fmtUsdc = (n) => (Number(n) / 1e6).toFixed(6);
export const fmtEth = (n) => ethers.formatEther(n);
