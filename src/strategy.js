import { ethers } from "ethers";

const MARKETS = {
    arbitrum: { aavePoolAddress: "0x794a61358D6845594F94dc1DB02A252b5b4814aD", chainId: 42161, USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", comet: "0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e", rpc: "https://ethereum-sepolia-rpc.publicnode.com", chainlinkRouter: "", chainSelector: "" },
    base: { aavePoolAddress: "0xA238Dd80C259a72e81d7e4664317d3e8b36B4DE9", chainId: 8453, USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", comet: "0x...", rpc: "", chainlinkRouter: "", chainSelector: "" },
    optimism: { aavePoolAddress: "0x794a61358D6845594F94dc1DB02A252b5b4814aD", chainId: 10, USDC_ADDRESS: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", comet: "0x...", rpc: "", chainlinkRouter: "", chainSelector: "" }
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
    // console.log(await _getGasCostUsd(provider))
    // return Math.round(Number(rawRate) / 1e18 * 31_536_000 * 10_000)
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
// fetchAaveRates(MARKETS.arbitrum)
// fetchMorphoRates(MARKETS.arbitrum)
// fetchCompoundRates(MARKETS.arbitrum)