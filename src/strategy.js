import { ethers } from "ethers";
import dotenv from 'dotenv';
dotenv.config();

const MARKETS = {
    arbitrum: { aavePoolAddress: "0x794a61358D6845594F94dc1DB02A252b5b4814aD", chainId: 42161, USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", comet: "0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e", rpc: "https://ethereum-sepolia-rpc.publicnode.com", chainlinkRouter: "", chainSelector: "", spokeAddress: "" },
    base: { aavePoolAddress: "0xA238Dd80C259a72e81d7e4664317d3e8b36B4DE9", chainId: 8453, USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", comet: "0x...", rpc: "", chainlinkRouter: "", chainSelector: "", spokeAddress: "" },
    optimism: { aavePoolAddress: "0x794a61358D6845594F94dc1DB02A252b5b4814aD", chainId: 10, USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", comet: "0x...", rpc: "", chainlinkRouter: "", chainSelector: "", spokeAddress: "" }
}
async function fetchAaveRates(market) {
    const query = `{
        market(request: { address: "${market.aavePoolAddress}", chainId: ${market.chainId} }) {
            reserves {
                underlyingToken { symbol }
                supplyInfo { apy { value } }
            }
        }
    }`
    const response = await fetch("https://api.v3.aave.com/graphql", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query })
    })

    const data = await response.json()
    const reserves = data.data.market.reserves
    const usdcReserves = reserves.filter(r => r.underlyingToken.symbol === "USDC")
    const best = usdcReserves.reduce((a, b) =>
        parseFloat(a.supplyInfo.apy.value) > parseFloat(b.supplyInfo.apy.value) ? a : b
    )

    return Math.round(parseFloat(best.supplyInfo.apy.value) * 10000)
}

async function fetchMorphoRates(market) {
    const query = `{ markets(first: 5, orderBy: SupplyAssetsUsd, orderDirection: Desc, where: { chainId_in: [${market.chainId}], loanAssetAddress_in: [\"${market.USDC_ADDRESS}\"] }) { items { marketId state { supplyApy netSupplyApy supplyAssetsUsd } } } }`

    const response = await fetch("https://api.morpho.org/graphql", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query })
    })
    const data = await response.json()
    const results = data.data.markets.items.filter(r => r.state.supplyAssetsUsd >= 1000000 && r.state.supplyApy <= 100)

    if (results.length > 1) {
        const best = results.reduce((a, b) => a.state.supplyApy > b.state.supplyApy ? a : b)
        return Math.round(parseFloat(best.state.supplyApy) * 10000)
    } else if (results.length === 0) {
        return 0
    } else {
        return Math.round(parseFloat(results[0].state.supplyApy) * 10000)
    }

}

async function fetchCompoundRates(market) {
    const ABI = [
        "function getSupplyRate(uint utilization) view returns (uint64)",
        "function getUtilization() view returns (uint)"
    ]
    const provider = new ethers.JsonRpcProvider(market.rpc);

    const compound = new ethers.Contract(market.comet, ABI, provider)
    const rawRate = await compound.getSupplyRate(await compound.getUtilization());

}

async function getTotalGas(market) {
    const gasCost = await _getGas(market)
    const bridgeCost = await _getBridgeCost(market)
    return gasCost + bridgeCost
}
async function _getGas(market) {
    const provider = new ethers.JsonRpcProvider(market.rpc);
    const rawFee = Number((await provider.getFeeData()).gasPrice) * 250_000 / 1e18;
    return await _getUsdValue(rawFee)

}

async function _getBridgeCost(market) {
    const getFeeABI = ["function getFee(uint64 destinationChainSelector, tuple(bytes receiver, bytes data, tuple(address token, uint256 amount)[] tokenAmounts, address feeToken, bytes extraArgs) message) view returns (uint256)"]
    const provider = new ethers.JsonRpcProvider(market.rpc);
    const chainlink = new ethers.Contract(market.chainlinkRouter, getFeeABI, provider)
    const message = {
        receiver: "0x0000000000000000000000000000000000000000",
        data: "0x",
        tokenAmounts: [{ token: market.USDC_ADDRESS, amount: 0 }],
        feeToken: ethers.ZeroAddress,
        extraArgs: "0x"
    }
    const bridgeCost = await chainlink.getFee(market.chainSelector, message)
    return await _getUsdValue(bridgeCost)

}

async function _getUsdValue(raw) {
    const etherPrice = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd", {
        method: "GET",
    })
    return (await etherPrice.json()).ethereum.usd * raw
}

async function getGeminiAllocation(markets) {
    const message = []
    const systemPrompt = `You are a DeFi yield allocation agent for Meridian, a cross-chain yield aggregator.
Your job is to allocate capital across 8 USDC markets on Arbitrum, Base, and Optimism to maximise risk-adjusted yield with soft diversification.
HARD CONSTRAINTS — non-negotiable, you must respect all of these:
- Total allocation must sum to exactly 10000 basis points
- Maximum 6000 bps per individual market
- Maximum 8000 bps per chain across all its markets combined
- Any active market (allocation > 0) must receive at least 500 bps
- A market can receive exactly 0 — meaning it is skipped entirely
DIVERSIFICATION PREFERENCES — soft rules, apply judgment:
- Prefer activating at least one market per chain if its net APY is positive
- If two markets have net APYs within 100 bps of each other, prefer splitting between them rather than concentrating in one
- Avoid concentrating more than necessary given the hard caps
RISK ASSESSMENT — before allocating, use your search capability to:
- Check for recent exploits, audits, or security concerns for Aave, Compound, and Morpho
- Flag any anomalous APY that may signal a liquidity issue or exploit
- Reduce or zero out allocation to any market with active risk concerns
You will receive market data as: protocol on chain with BPS of netApy.
Respond ONLY with a valid JSON object in this exact shape, no extra text:
{
    "allocations": {
        "arbitrum": { "aave": 0, "compound": 0, "morpho": 0 },
        "base": { "aave": 0, "compound": 0, "morpho": 0 },
        "optimism": { "aave": 0, "compound": 0 }
    },
    "reasoning": "Complete explanation of your allocation decisions, how constraints are met, risk adjustments made, and anything notable you observed"
}`



    for (let i = 0; i < markets.length; i++) {
        message.push(`${markets[i].protocol} on ${markets[i].chain} with BPS of ${markets[i].netApy}`)
    }
    const userMessage = message.join("\n")
    const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "x-goog-api-key": process.env.GEMINI_API_KEY
        },
        body: JSON.stringify({
            contents: [
                { role: "user", parts: [{ text: userMessage }] }
            ],
            systemInstruction: { parts: [{ text: systemPrompt }] },
            generationConfig: { responseMimeType: "application/json" }
        })
    })
    const data = await response.json()
    const content = data.candidates[0].content.parts[0].text
    console.log(content)
    return JSON.parse(content)
}

async function getAllocationsFromSpoke(market) {
    const ABI = ["function getAllocations() view returns (tuple(bytes32 protocolId, uint256 balance)[])"]
    const provider = new ethers.JsonRpcProvider(market.rpc);
    const spoke = new ethers.Contract(market.spokeAddress, ABI, provider)
    return await spoke.getAllocations()
}

async function getAllocationsForAll() {
    const result = {}
    for (const [chainName, market] of Object.entries(MARKETS)) {
        result[chainName] = await getAllocationsFromSpoke(market)
    }
    return result

}


async function run() {
    const currentAllocation = await getAllocationsForAll()
    const [chainName, market] = Object.entries(MARKETS)
    const markets = []
    for (const [chainName, market] of Object.entries(MARKETS)) {

        const aaveApy = fetchAaveRates(Object.entries(market))
        const compoundApy = fetchCompoundRates(Object.entries(market))
        const totalCost = await getTotalGas(market)
        const aaveNet = calcNetApy(aaveApy, totalCost, 100_000)
        const compoundNet = calcNetApy(compoundApy, totalCost, 100_000)

        markets.push({ chain: chainName, protocol: "aave", netApy: aaveNet, currentAllocation: "0" })
        markets.push({ chain: chainName, protocol: "compound", netApy: compoundNet, currentAllocation: "0" })
        if (chainName != "optimism") {
            const morphoApy = await fetchMorphoRates(Object.entries(market))
            const morphoNet = calcNetApy(morphoApy, totalCost, 100_000)
            markets.push({ chain: chainName, protocol: "morpho", netApy: morphoNet, currentAllocation: "0" })
        }


    }
    const allocation = await getGeminiAllocation(markets)
}

async function calcNetApy(grossApyBps, totalCostUSD, totalAssets) {
    const annualizedCostBps = totalCostUSD / totalAssets * 365 * 10_000
    const netApyBps = grossApyBps - annualizedCostBps
    return netApyBps
}
















// fetchAaveRates(MARKETS.arbitrum)
// fetchMorphoRates(MARKETS.arbitrum)
// fetchCompoundRates(MARKETS.arbitrum)
// const markets = [
//     { chain: "arbitrum", protocol: "aave", netApy: 450 },
//     { chain: "arbitrum", protocol: "compound", netApy: 380 },
//     { chain: "arbitrum", protocol: "morpho", netApy: 420 },
//     { chain: "base", protocol: "aave", netApy: 410 },
//     { chain: "base", protocol: "compound", netApy: 395 },
//     { chain: "base", protocol: "morpho", netApy: 430 },
//     { chain: "optimism", protocol: "aave", netApy: 360 },
//     { chain: "optimism", protocol: "compound", netApy: 340 },
// ]
// getGeminiAllocation(markets)