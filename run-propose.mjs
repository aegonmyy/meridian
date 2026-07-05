import { ethers } from "ethers";
import dotenv from "dotenv";
dotenv.config();

const GEMINI_KEY = process.env.GEMINI_API_KEY;

const MARKETS = {
  arbitrum: {
    chainId: 42161,
    USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    aavePoolAddress: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
    comet: "0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf", // fixed: old address had no code
    rpc: "https://arb-mainnet.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    protocols: ["aave", "compound", "morpho"],
  },
  base: {
    chainId: 8453,
    USDC_ADDRESS: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    aavePoolAddress: "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5", // fixed: last chars were wrong
    comet: "0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf",
    rpc: "https://base-mainnet.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    protocols: ["aave", "compound", "morpho"],
  },
  optimism: {
    chainId: 10,
    USDC_ADDRESS: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    aavePoolAddress: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
    comet: "0x2e44e174f7D53F0212823acC11C01A11d58c5bCB", // fixed: bad EIP-55 checksum
    rpc: "https://opt-mainnet.g.alchemy.com/v2/tfeWfDNpQFHcrUvZglTOG",
    protocols: ["aave", "compound"],
  },
};

async function fetchAaveRate(market) {
  const query = `{
    market(request: { address: "${market.aavePoolAddress}", chainId: ${market.chainId} }) {
      reserves {
        underlyingToken { symbol }
        supplyInfo { apy { value } }
      }
    }
  }`;
  try {
    const res = await fetch("https://api.v3.aave.com/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const { data } = await res.json();
    const usdc = data.market.reserves.filter(r => r.underlyingToken.symbol === "USDC");
    if (!usdc.length) return 0;
    const best = usdc.reduce((a, b) =>
      parseFloat(a.supplyInfo.apy.value) > parseFloat(b.supplyInfo.apy.value) ? a : b
    );
    return Math.round(parseFloat(best.supplyInfo.apy.value) * 10000);
  } catch {
    return 0;
  }
}

async function fetchMorphoRate(market) {
  const query = `{ markets(first: 5, orderBy: SupplyAssetsUsd, orderDirection: Desc, where: { chainId_in: [${market.chainId}], loanAssetAddress_in: ["${market.USDC_ADDRESS}"] }) { items { state { supplyApy supplyAssetsUsd } } } }`;
  try {
    const res = await fetch("https://api.morpho.org/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const { data } = await res.json();
    const items = data.markets.items.filter(r => r.state.supplyAssetsUsd >= 1_000_000 && r.state.supplyApy <= 100);
    if (!items.length) return 0;
    const best = items.reduce((a, b) => a.state.supplyApy > b.state.supplyApy ? a : b);
    return Math.round(parseFloat(best.state.supplyApy) * 10000);
  } catch {
    return 0;
  }
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
    const raw = await comet.getSupplyRate(util);
    return Math.round(Number(raw) / 1e18 * 31_536_000 * 10_000);
  } catch {
    return 0;
  }
}

async function askGemini(markets) {
  const systemPrompt = `You are a DeFi yield allocation agent for Meridian, a cross-chain yield aggregator.
Your job is to allocate capital across USDC markets on Arbitrum, Base, and Optimism to maximise risk-adjusted yield with soft diversification.
HARD CONSTRAINTS — non-negotiable:
- Total allocation must sum to exactly 10000 basis points
- Maximum 6000 bps per individual market
- Maximum 8000 bps per chain across all its markets combined
- Any active market (allocation > 0) must receive at least 500 bps
- A market can receive exactly 0 — meaning it is skipped entirely
DIVERSIFICATION PREFERENCES:
- Prefer activating at least one market per chain if its net APY is positive
- If two markets have net APYs within 100 bps of each other, prefer splitting
- Avoid unnecessary concentration given the hard caps
RISK ASSESSMENT:
- Consider recent exploits, audits, or security concerns for Aave, Compound, and Morpho
- Flag anomalous APYs that may signal a liquidity issue
- Reduce or zero out allocation to any market with active risk concerns
You will receive market data as: protocol on chain — net APY in bps.
Respond ONLY with valid JSON in this exact shape, no extra text:
{
  "allocations": {
    "arbitrum": { "aave": 0, "compound": 0, "morpho": 0 },
    "base": { "aave": 0, "compound": 0, "morpho": 0 },
    "optimism": { "aave": 0, "compound": 0 }
  },
  "reasoning": "Complete explanation of allocation decisions"
}`;

  const lines = markets.map(m => `${m.protocol} on ${m.chain} — net APY: ${m.netApy} bps`).join("\n");

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent`,
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

async function main() {
  console.log("Fetching live APY rates...\n");
  const markets = [];

  for (const [chain, cfg] of Object.entries(MARKETS)) {
    const [aave, compound, morpho] = await Promise.all([
      fetchAaveRate(cfg),
      fetchCompoundRate(cfg),
      chain !== "optimism" ? fetchMorphoRate(cfg) : Promise.resolve(null),
    ]);

    console.log(`${chain.toUpperCase()}`);
    console.log(`  Aave:     ${aave} bps`);
    console.log(`  Compound: ${compound} bps`);
    if (morpho !== null) console.log(`  Morpho:   ${morpho} bps`);
    console.log();

    markets.push({ chain, protocol: "aave", netApy: aave });
    markets.push({ chain, protocol: "compound", netApy: compound });
    if (morpho !== null) markets.push({ chain, protocol: "morpho", netApy: morpho });
  }

  console.log("Asking Gemini for allocation...\n");
  const proposal = await askGemini(markets);

  console.log("=== PROPOSED ALLOCATION ===\n");
  for (const [chain, protocols] of Object.entries(proposal.allocations)) {
    console.log(`${chain.toUpperCase()}`);
    for (const [protocol, bps] of Object.entries(protocols)) {
      const pct = (bps / 100).toFixed(0);
      console.log(`  ${protocol.padEnd(10)} ${String(bps).padStart(5)} bps  (${pct}%)`);
    }
  }

  const total = Object.values(proposal.allocations)
    .flatMap(p => Object.values(p))
    .reduce((a, b) => a + b, 0);
  console.log(`\n  TOTAL: ${total} bps ${total === 10000 ? "✓" : "✗ INVALID"}\n`);
  console.log("=== REASONING ===\n");
  console.log(proposal.reasoning);
}

main().catch(console.error);
