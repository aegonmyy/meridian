import { ethers } from "ethers";
import dotenv from "dotenv";
dotenv.config();

const GEMINI_KEY   = process.env.GEMINI_API_KEY;
const AGENT_KEY    = "0xe83bbb5223339d634ca6f0eb5225b9a0b611e3038a6eef7a44b66cab1b3907d5";
const AGENT_CONSUMER = "0xe0a30A4EA672023277D80f3dbf752aa6faEDd37e";
const SEPOLIA_RPC  = "https://eth-sepolia.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG";

const MARKETS = {
  arbitrum: {
    chainId: 42161,
    USDC_ADDRESS:   "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    aavePoolAddress:"0x794a61358D6845594F94dc1DB02A252b5b4814aD",
    comet:          "0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf",
    rpc:            "https://arb-mainnet.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    chainSelector:  3478487238524512106n,
    spokeAddress:   "0x212393223bec0BB3fBe652b8e1cc16816A1bbdE9",
    spokeRpc:       "https://arb-sepolia.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    protocols:      ["aave", "compound", "morpho"],
  },
  base: {
    chainId: 8453,
    USDC_ADDRESS:   "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    aavePoolAddress:"0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
    comet:          "0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf",
    rpc:            "https://base-mainnet.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    chainSelector:  10344971235874465080n,
    spokeAddress:   "0x2A835C21fcE662a0D88B1abE91bFBACE5675a025",
    spokeRpc:       "https://base-sepolia.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    protocols:      ["aave", "compound", "morpho"],
  },
  optimism: {
    chainId: 10,
    USDC_ADDRESS:   "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    aavePoolAddress:"0x794a61358D6845594F94dc1DB02A252b5b4814aD",
    comet:          "0x2e44e174f7D53F0212823acC11C01A11d58c5bCB",
    rpc:            "https://opt-mainnet.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    chainSelector:  5224473277236331295n,
    spokeAddress:   "0x536BD638eD067B2026568Ff304D1EC2B82EDF2a8",
    spokeRpc:       "https://opt-sepolia.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    protocols:      ["aave", "compound"],
  },
};

const SPOKE_ABI = ["function getAllocations() view returns (tuple(bytes32 protocolId, uint256 balance)[])"];

const AGENT_CONSUMER_ABI = [
  "function proposeAllocation(tuple(uint256[][] proposedAllocations, uint256[] proposedNetApys, uint256[][] currentAllocations, uint256[] currentNetApys, uint64[] chainSelectors, bytes32[][] protocolIds) calldata proposal) external",
];

// ── APY fetchers ────────────────────────────────────────────────────────────

async function fetchAaveRate(market) {
  const query = `{ market(request: { address: "${market.aavePoolAddress}", chainId: ${market.chainId} }) { reserves { underlyingToken { symbol } supplyInfo { apy { value } } } } }`;
  try {
    const res = await fetch("https://api.v3.aave.com/graphql", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const { data } = await res.json();
    const usdc = data.market.reserves.filter(r => r.underlyingToken.symbol === "USDC");
    if (!usdc.length) return 0;
    const best = usdc.reduce((a, b) =>
      parseFloat(a.supplyInfo.apy.value) > parseFloat(b.supplyInfo.apy.value) ? a : b);
    return Math.round(parseFloat(best.supplyInfo.apy.value) * 10000);
  } catch { return 0; }
}

async function fetchMorphoRate(market) {
  const query = `{ markets(first: 5, orderBy: SupplyAssetsUsd, orderDirection: Desc, where: { chainId_in: [${market.chainId}], loanAssetAddress_in: ["${market.USDC_ADDRESS}"] }) { items { state { supplyApy supplyAssetsUsd } } } }`;
  try {
    const res = await fetch("https://api.morpho.org/graphql", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const { data } = await res.json();
    const items = data.markets.items.filter(r => r.state.supplyAssetsUsd >= 1_000_000 && r.state.supplyApy <= 100);
    if (!items.length) return 0;
    const best = items.reduce((a, b) => a.state.supplyApy > b.state.supplyApy ? a : b);
    return Math.round(parseFloat(best.state.supplyApy) * 10000);
  } catch { return 0; }
}

async function fetchCompoundRate(market) {
  const ABI = [
    "function getSupplyRate(uint utilization) view returns (uint64)",
    "function getUtilization() view returns (uint)",
  ];
  try {
    const provider = new ethers.JsonRpcProvider(market.rpc);
    const comet = new ethers.Contract(market.comet, ABI, provider);
    const util = await comet.getUtilization();
    const raw  = await comet.getSupplyRate(util);
    return Math.round(Number(raw) / 1e18 * 31_536_000 * 10_000);
  } catch { return 0; }
}

// ── Spoke allocation reader ──────────────────────────────────────────────────

async function getSpokeAllocations(market) {
  try {
    const provider = new ethers.JsonRpcProvider(market.spokeRpc);
    const spoke = new ethers.Contract(market.spokeAddress, SPOKE_ABI, provider);
    return await spoke.getAllocations();
  } catch { return []; }
}

function allocationToBps(allocs, protocol) {
  const total = allocs.reduce((s, a) => s + Number(a.balance), 0);
  if (total === 0) return 0;
  const id = ethers.keccak256(ethers.toUtf8Bytes(protocol.toUpperCase()));
  const entry = allocs.find(a => a.protocolId === id);
  return entry ? Math.round(Number(entry.balance) / total * 10000) : 0;
}

// ── Gemini ───────────────────────────────────────────────────────────────────

async function askGemini(markets) {
  const systemPrompt = `You are a DeFi yield allocation agent for Meridian, a cross-chain yield aggregator.
Your job is to allocate capital across USDC markets on Arbitrum, Base, and Optimism to maximise risk-adjusted yield.
HARD CONSTRAINTS:
- Total allocation must sum to exactly 10000 basis points
- Maximum 6000 bps per individual market
- Maximum 8000 bps per chain across all its markets combined
- Any active market (allocation > 0) must receive at least 500 bps
- A market can receive exactly 0 — meaning it is skipped entirely
DIVERSIFICATION PREFERENCES:
- Prefer activating at least one market per chain if its net APY is positive
- If two markets have net APYs within 100 bps of each other, prefer splitting
RISK ASSESSMENT:
- Consider recent exploits or security concerns for Aave, Compound, and Morpho
- Reduce or zero out allocation to any market with active risk concerns
You will receive: protocol on chain — net APY in bps, currently allocated bps.
Respond ONLY with valid JSON, no extra text:
{
  "allocations": {
    "arbitrum": { "aave": 0, "compound": 0, "morpho": 0 },
    "base": { "aave": 0, "compound": 0, "morpho": 0 },
    "optimism": { "aave": 0, "compound": 0 }
  },
  "reasoning": "Complete explanation"
}
`;

  const lines = markets.map(m =>
    `${m.protocol} on ${m.chain} — net APY: ${m.netApy} bps, currently: ${m.currentAllocation} bps`
  ).join("\n");

  const res = await fetch(
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent",
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": GEMINI_KEY },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: lines }] }],
        systemInstruction: { parts: [{ text: systemPrompt }] },
        generationConfig: { responseMimeType: "application/json" },
      }),
    }
  );
  const data = await res.json();
  if (!data.candidates) throw new Error(JSON.stringify(data));
  return JSON.parse(data.candidates[0].content.parts[0].text);
}

// ── Encoder ──────────────────────────────────────────────────────────────────

function buildProposal(geminiOutput, markets) {
  const proposedAllocations = [];
  const proposedNetApys     = [];
  const currentAllocations  = [];
  const currentNetApys      = [];
  const chainSelectors      = [];
  const protocolIds         = [];

  for (const [chainName, cfg] of Object.entries(MARKETS)) {
    const chainProposed    = [];
    const chainCurrent     = [];
    const chainProtocolIds = [];

    for (const protocol of cfg.protocols) {
      const m = markets.find(x => x.chain === chainName && x.protocol === protocol);
      chainProposed.push(geminiOutput.allocations[chainName][protocol] ?? 0);
      chainCurrent.push(m.currentAllocation);
      chainProtocolIds.push(ethers.keccak256(ethers.toUtf8Bytes(protocol.toUpperCase())));
      proposedNetApys.push(Math.max(0, Math.round(m.netApy)));
      currentNetApys.push(Math.max(0, Math.round(m.currentNetApy ?? 0)));
    }

    proposedAllocations.push(chainProposed);
    currentAllocations.push(chainCurrent);
    protocolIds.push(chainProtocolIds);
    chainSelectors.push(cfg.chainSelector);
  }

  return { proposedAllocations, proposedNetApys, currentAllocations, currentNetApys, chainSelectors, protocolIds };
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("Fetching live APY rates...\n");
  const markets = [];

  for (const [chain, cfg] of Object.entries(MARKETS)) {
    const [aave, compound, morpho, spokeAllocs] = await Promise.all([
      fetchAaveRate(cfg),
      fetchCompoundRate(cfg),
      chain !== "optimism" ? fetchMorphoRate(cfg) : Promise.resolve(null),
      getSpokeAllocations(cfg),
    ]);

    console.log(`${chain.toUpperCase()}`);
    console.log(`  Aave:     ${aave} bps  (current: ${allocationToBps(spokeAllocs, "aave")} bps)`);
    console.log(`  Compound: ${compound} bps  (current: ${allocationToBps(spokeAllocs, "compound")} bps)`);
    if (morpho !== null) console.log(`  Morpho:   ${morpho} bps  (current: ${allocationToBps(spokeAllocs, "morpho")} bps)`);
    console.log();

    markets.push({ chain, protocol: "aave",     netApy: aave,    currentNetApy: aave,    currentAllocation: allocationToBps(spokeAllocs, "aave")     });
    markets.push({ chain, protocol: "compound", netApy: compound, currentNetApy: compound, currentAllocation: allocationToBps(spokeAllocs, "compound") });
    if (morpho !== null)
      markets.push({ chain, protocol: "morpho", netApy: morpho,  currentNetApy: morpho,  currentAllocation: allocationToBps(spokeAllocs, "morpho")   });
  }

  console.log("Asking Gemini for allocation...\n");
  const proposal = await askGemini(markets);

  console.log("=== PROPOSED ALLOCATION ===\n");
  let total = 0;
  for (const [chain, protocols] of Object.entries(proposal.allocations)) {
    console.log(`${chain.toUpperCase()}`);
    for (const [protocol, bps] of Object.entries(protocols)) {
      console.log(`  ${protocol.padEnd(10)} ${String(bps).padStart(5)} bps`);
      total += bps;
    }
  }
  console.log(`\n  TOTAL: ${total} bps ${total === 10000 ? "✓" : "✗ INVALID — aborting"}\n`);

  if (total !== 10000) process.exit(1);

  console.log("=== REASONING ===\n");
  console.log(proposal.reasoning);
  console.log();

  console.log("Building proposal struct...");
  const struct = buildProposal(proposal, markets);
  console.log("chainSelectors:", struct.chainSelectors.map(s => s.toString()));
  console.log("proposedNetApys:", struct.proposedNetApys);
  console.log();

  console.log("Submitting to AgentConsumer on Sepolia...");
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC);
  const wallet   = new ethers.Wallet(AGENT_KEY, provider);
  const consumer = new ethers.Contract(AGENT_CONSUMER, AGENT_CONSUMER_ABI, wallet);

  const tx = await consumer.proposeAllocation(struct);
  console.log("Tx submitted:", tx.hash);
  console.log("Waiting for confirmation...");
  const receipt = await tx.wait();
  console.log(`Confirmed in block ${receipt.blockNumber} — gas used: ${receipt.gasUsed.toString()}`);
  console.log("\nDone. AllocationProposed event should appear in the Operator UI.");
}

main().catch(err => { console.error(err); process.exit(1); });
