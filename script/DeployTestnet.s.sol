// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {HUB} from "../src/Hub.sol";
import {SpokeVault} from "../src/Spoke.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {AgentConsumer} from "../src/AgentConsumer.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Meridian Testnet Deployment — Three-phase script for real networks
//
// This script deploys the full Meridian stack across Ethereum Sepolia (hub)
// and Arbitrum Sepolia (spoke). Each phase targets a single chain and is run
// separately with the matching --rpc-url flag.
//
// Phase 1 — Hub stack on Ethereum Sepolia (DeployHub)
// Phase 2 — Spoke + adapters on Arbitrum Sepolia (DeployArbSpoke)
// Phase 3 — Register spoke on hub, back on Sepolia (RegisterSpoke)
//
// Required .env:
//   DEPLOYER_KEY          — private key, must have ETH on both chains
//   AGENT_ADDRESS         — address of the off-chain agent EOA
//   HUB_ADDRESS           — (phases 2 & 3) address output from phase 1
//   SPOKE_ADDRESS         — (phase 3 only) address output from phase 2
//
// After deployment, fund manually:
//   • Hub contract with Sepolia LINK (CCIP fees for outbound messages)
//   • Spoke contract with Arbitrum Sepolia LINK (CCIP fees for responses)
//   Chainlink faucet: https://faucets.chain.link
//   Circle USDC faucet: https://faucet.circle.com
// ─────────────────────────────────────────────────────────────────────────────

// ─── Shared constants ────────────────────────────────────────────────────────

uint64  constant SEPOLIA_SELECTOR     = 16015286601757825753;
uint64  constant ARB_SEPOLIA_SELECTOR = 3478487238524512106;
uint64  constant BASE_SEPOLIA_SELECTOR = 10344971235874465080;
uint64  constant OP_SEPOLIA_SELECTOR  = 5224473277236331295;

bytes32 constant AAVE     = keccak256("AAVE");
bytes32 constant COMPOUND = keccak256("COMPOUND");
bytes32 constant MORPHO   = keccak256("MORPHO");

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1 — Hub stack on Ethereum Sepolia
//
// forge script script/DeployTestnet.s.sol:DeployHub \
//   --rpc-url $SEPOLIA_RPC_URL \
//   --broadcast \
//   --verify \
//   -vvv
// ─────────────────────────────────────────────────────────────────────────────
contract DeployHub is Script {
    // Ethereum Sepolia — verified from docs.chain.link/ccip/directory/testnet
    address constant CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant LINK        = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    // Circle testnet USDC on Sepolia — https://faucet.circle.com
    address constant USDC        = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);
        address agent       = vm.envAddress("AGENT_ADDRESS");

        // Pre-compute future contract addresses using current nonce so we can
        // break the Rebalancer ↔ AgentConsumer circular dependency in a single
        // broadcast pass without deploying any placeholder contracts.
        uint256 nonce = vm.getNonce(deployer);
        // nonce+0 → Hub
        // nonce+1 → Rebalancer (needs AgentConsumer address up front)
        // nonce+2 → AgentConsumer (needs Rebalancer address up front)
        address predictedRebalancer    = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedAgentConsumer = vm.computeCreateAddress(deployer, nonce + 2);

        vm.startBroadcast(deployerKey);

        HUB hub = new HUB(
            "Meridian USDC",
            "mUSDC",
            CCIP_ROUTER,
            deployer,
            LINK,
            USDC,
            predictedRebalancer
        );

        Rebalancer rebalancer = new Rebalancer(
            address(hub),
            predictedAgentConsumer,
            deployer
        );

        AgentConsumer agentConsumer = new AgentConsumer(
            address(rebalancer),
            agent,
            deployer
        );

        // Verify nonce prediction matched reality
        require(address(rebalancer)    == predictedRebalancer,    "rebalancer address mismatch");
        require(address(agentConsumer) == predictedAgentConsumer, "agentConsumer address mismatch");

        // Whitelist Arbitrum Sepolia and Base Sepolia spokes + all three protocols
        rebalancer.addChainToWhitelist(ARB_SEPOLIA_SELECTOR);
        rebalancer.addChainToWhitelist(BASE_SEPOLIA_SELECTOR);
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        rebalancer.addProtocolToWhitelist(MORPHO);

        vm.stopBroadcast();

        _writeJson(address(hub), address(rebalancer), address(agentConsumer), agent);
        _printSummary(address(hub), address(rebalancer), address(agentConsumer));
    }

    function _writeJson(
        address hub,
        address rebalancer,
        address agentConsumer,
        address agent
    ) internal {
        string memory json = string.concat(
            "{\n",
            '  "hub": "',          vm.toString(hub),          '",\n',
            '  "rebalancer": "',   vm.toString(rebalancer),   '",\n',
            '  "agentConsumer": "',vm.toString(agentConsumer), '",\n',
            '  "agent": "',        vm.toString(agent),         '"\n',
            "}"
        );
        vm.writeFile("deployed-hub-sepolia.json", json);
        console.log("Addresses written to deployed-hub-sepolia.json");
    }

    function _printSummary(
        address hub,
        address rebalancer,
        address agentConsumer
    ) internal pure {
        console.log("\n=== Hub Deployment Complete (Ethereum Sepolia) ===");
        console.log("Hub:           ", hub);
        console.log("Rebalancer:    ", rebalancer);
        console.log("AgentConsumer: ", agentConsumer);
        console.log("\nNext steps:");
        console.log("  1. Fund Hub with Sepolia LINK  -> https://faucets.chain.link/sepolia");
        console.log("  2. Set HUB_ADDRESS=<hub> in .env");
        console.log("  3. Run DeployArbSpoke on Arbitrum Sepolia");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2 — Arbitrum Sepolia spoke + Aave adapter
//
// forge script script/DeployTestnet.s.sol:DeployArbSpoke \
//   --rpc-url $ARB_SEPOLIA_RPC_URL \
//   --broadcast \
//   --verify \
//   -vvv
//
// Required env: HUB_ADDRESS
// ─────────────────────────────────────────────────────────────────────────────
contract DeployArbSpoke is Script {
    // Arbitrum Sepolia — verified from docs.chain.link/ccip/directory/testnet
    address constant CCIP_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address constant LINK        = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;
    // Circle testnet USDC on Arbitrum Sepolia — same address used by CCIP token pool
    address constant USDC        = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    // Aave V3 Arbitrum Sepolia — from bgd-labs/aave-address-book AaveV3ArbitrumSepolia.sol
    address constant AAVE_POOL   = 0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff;
    address constant AAVE_AUSDC  = 0x460b97BD498E1157530AEb3086301d5225b91216;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);
        address hub         = vm.envAddress("HUB_ADDRESS");

        vm.startBroadcast(deployerKey);

        SpokeVault spoke = new SpokeVault(
            hub,
            USDC,
            CCIP_ROUTER,
            deployer,
            LINK,
            SEPOLIA_SELECTOR
        );

        // Aave V3 is confirmed deployed on Arbitrum Sepolia.
        // Compound V3 and Morpho are not reliably available on Arbitrum Sepolia testnet —
        // add those adapters once you confirm their addresses.
        AaveAdapter aaveAdapter = new AaveAdapter(AAVE_POOL, AAVE_AUSDC, USDC);
        spoke.setAdapter(AAVE, address(aaveAdapter));

        vm.stopBroadcast();

        _writeJson(address(spoke), address(aaveAdapter), hub);
        _printSummary(address(spoke), address(aaveAdapter));
    }

    function _writeJson(
        address spoke,
        address aaveAdapter,
        address hub
    ) internal {
        string memory json = string.concat(
            "{\n",
            '  "arbSpoke": "',      vm.toString(spoke),       '",\n',
            '  "arbAaveAdapter": "', vm.toString(aaveAdapter), '",\n',
            '  "hub": "',           vm.toString(hub),          '"\n',
            "}"
        );
        vm.writeFile("deployed-arb-spoke.json", json);
        console.log("Addresses written to deployed-arb-spoke.json");
    }

    function _printSummary(address spoke, address aaveAdapter) internal pure {
        console.log("\n=== Arbitrum Sepolia Spoke Deployment ===");
        console.log("Spoke:       ", spoke);
        console.log("AaveAdapter: ", aaveAdapter);
        console.log("\nNext steps:");
        console.log("  1. Fund Spoke with Arbitrum Sepolia LINK -> https://faucets.chain.link/arbitrum-sepolia");
        console.log("  2. Set SPOKE_ADDRESS=<spoke> in .env");
        console.log("  3. Run RegisterSpoke on Sepolia");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 4 — Base Sepolia spoke
//
// forge script script/DeployTestnet.s.sol:DeployBaseSpoke \
//   --rpc-url $BASE_SEPOLIA_RPC_URL \
//   --broadcast \
//   -vvv
//
// Required env: HUB_ADDRESS
// ─────────────────────────────────────────────────────────────────────────────
contract DeployBaseSpoke is Script {
    // Base Sepolia — docs.chain.link/ccip/directory/testnet
    address constant CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant LINK        = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    // Circle testnet USDC on Base Sepolia
    address constant USDC        = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);
        address hub         = vm.envAddress("HUB_ADDRESS");

        vm.startBroadcast(deployerKey);

        SpokeVault spoke = new SpokeVault(
            hub,
            USDC,
            CCIP_ROUTER,
            deployer,
            LINK,
            SEPOLIA_SELECTOR
        );

        vm.stopBroadcast();

        string memory json = string.concat(
            "{\n",
            '  "baseSpoke": "', vm.toString(address(spoke)), '",\n',
            '  "hub": "',       vm.toString(hub),            '"\n',
            "}"
        );
        vm.writeFile("deployed-base-spoke.json", json);

        console.log("\n=== Base Sepolia Spoke Deployment ===");
        console.log("Spoke: ", address(spoke));
        console.log("\nNext steps:");
        console.log("  1. Fund Spoke with Base Sepolia LINK -> https://faucets.chain.link/base-sepolia");
        console.log("  2. Run RegisterSpoke with SPOKE_CHAIN_SELECTOR=10344971235874465080");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 5 — OP Sepolia spoke
//
// forge script script/DeployTestnet.s.sol:DeployOptimismSpoke \
//   --rpc-url $OP_SEPOLIA_RPC_URL \
//   --broadcast \
//   -vvv
//
// Required env: HUB_ADDRESS
// NOTE: OP Sepolia selector (5224473277236331295) must be whitelisted on
//       Rebalancer first via WhitelistOpSepolia below.
// ─────────────────────────────────────────────────────────────────────────────
contract DeployOptimismSpoke is Script {
    // OP Sepolia — docs.chain.link/ccip/directory/testnet
    address constant CCIP_ROUTER = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57;
    address constant LINK        = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    // Circle testnet USDC on OP Sepolia
    address constant USDC        = 0x5fd84259d66Cd46123540766Be93DFE6D43130D7;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);
        address hub         = vm.envAddress("HUB_ADDRESS");

        vm.startBroadcast(deployerKey);

        SpokeVault spoke = new SpokeVault(
            hub,
            USDC,
            CCIP_ROUTER,
            deployer,
            LINK,
            SEPOLIA_SELECTOR
        );

        vm.stopBroadcast();

        string memory json = string.concat(
            "{\n",
            '  "opSpoke": "', vm.toString(address(spoke)), '",\n',
            '  "hub": "',     vm.toString(hub),            '"\n',
            "}"
        );
        vm.writeFile("deployed-op-spoke.json", json);

        console.log("\n=== OP Sepolia Spoke Deployment ===");
        console.log("Spoke: ", address(spoke));
        console.log("\nNext steps:");
        console.log("  1. Fund Spoke with OP Sepolia LINK -> https://faucets.chain.link/optimism-sepolia");
        console.log("  2. Run WhitelistOpSepolia on Sepolia (adds OP selector to Rebalancer)");
        console.log("  3. Run RegisterSpoke with SPOKE_CHAIN_SELECTOR=5224473277236331295");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility — Whitelist OP Sepolia on Rebalancer (run on Sepolia)
// OP Sepolia was not whitelisted in Phase 1 — run this before RegisterSpoke.
// ─────────────────────────────────────────────────────────────────────────────
contract WhitelistOpSepolia is Script {
    function run() external {
        uint256 deployerKey     = vm.envUint("DEPLOYER_KEY");
        address rebalancerAddr  = vm.envAddress("REBALANCER_ADDRESS");

        vm.startBroadcast(deployerKey);
        Rebalancer(rebalancerAddr).addChainToWhitelist(OP_SEPOLIA_SELECTOR);
        vm.stopBroadcast();

        console.log("OP Sepolia selector whitelisted on Rebalancer:", OP_SEPOLIA_SELECTOR);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase — Deploy adapters on Base Sepolia and register with spoke
//
// forge script script/DeployTestnet.s.sol:DeployBaseAdapters \
//   --rpc-url $BASE_SEPOLIA_RPC_URL \
//   --broadcast \
//   -vvv
//
// Required env: SPOKE_ADDRESS (Base Sepolia spoke: 0x2A835C21fcE662a0D88B1abE91bFBACE5675a025)
// ─────────────────────────────────────────────────────────────────────────────
contract DeployBaseAdapters is Script {
    address constant USDC       = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // Aave v3 Base Sepolia — confirmed via PoolAddressesProvider 0xd449FeD...
    address constant AAVE_POOL  = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b;
    address constant AAVE_AUSDC = 0xf53B60F4006cab2b3C4688ce41fD5362427A2A66;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address spokeAddr   = vm.envAddress("SPOKE_ADDRESS");

        vm.startBroadcast(deployerKey);

        AaveAdapter aaveAdapter = new AaveAdapter(AAVE_POOL, AAVE_AUSDC, USDC);
        SpokeVault(spokeAddr).setAdapter(AAVE, address(aaveAdapter));

        vm.stopBroadcast();

        console.log("\n=== Base Sepolia Adapters ===");
        console.log("Spoke:       ", spokeAddr);
        console.log("AaveAdapter: ", address(aaveAdapter));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3 — Register spoke on hub (run back on Sepolia)
//
// forge script script/DeployTestnet.s.sol:RegisterSpoke \
//   --rpc-url $SEPOLIA_RPC_URL \
//   --broadcast \
//   -vvv
//
// Required env: HUB_ADDRESS, SPOKE_ADDRESS
// SPOKE_CHAIN_SELECTOR defaults to ARB_SEPOLIA_SELECTOR if not set
// ─────────────────────────────────────────────────────────────────────────────
contract RegisterSpoke is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_KEY");
        address hubAddress   = vm.envAddress("HUB_ADDRESS");
        address spokeAddress = vm.envAddress("SPOKE_ADDRESS");

        // Default to Arbitrum Sepolia selector; override via env for other chains
        uint64 chainSelector = ARB_SEPOLIA_SELECTOR;
        try vm.envUint("SPOKE_CHAIN_SELECTOR") returns (uint256 sel) {
            require(sel <= type(uint64).max, "chain selector overflow");
            // forge-lint: disable-next-line(unsafe-typecast)
            chainSelector = uint64(sel);
        } catch {}

        vm.startBroadcast(deployerKey);
        HUB(hubAddress).addSpoke(chainSelector, spokeAddress);
        vm.stopBroadcast();

        console.log("\n=== Spoke Registered ===");
        console.log("Hub:              ", hubAddress);
        console.log("Spoke:            ", spokeAddress);
        console.log("Chain selector:   ", chainSelector);
        console.log("\nDeployment complete. Users can now deposit USDC into the hub.");
        console.log("Get testnet USDC at https://faucet.circle.com");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility — Redeploy Rebalancer + AgentConsumer (resets 24h cooldown)
//           then points Hub at the new Rebalancer.
//
// forge script script/DeployTestnet.s.sol:RedeployCore \
//   --rpc-url $SEPOLIA_RPC_URL \
//   --broadcast \
//   -vvv
//
// Required env: DEPLOYER_KEY, HUB_ADDRESS, AGENT_ADDRESS
// ─────────────────────────────────────────────────────────────────────────────
contract RedeployCore is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);
        address hubAddr     = vm.envAddress("HUB_ADDRESS");
        address agentAddr   = vm.envAddress("AGENT_ADDRESS");

        uint256 nonce = vm.getNonce(deployer);
        address predictedRebalancer    = vm.computeCreateAddress(deployer, nonce);
        address predictedAgentConsumer = vm.computeCreateAddress(deployer, nonce + 1);

        vm.startBroadcast(deployerKey);

        Rebalancer rebalancer = new Rebalancer(
            hubAddr,
            predictedAgentConsumer,
            deployer
        );

        AgentConsumer agentConsumer = new AgentConsumer(
            address(rebalancer),
            agentAddr,
            deployer
        );

        require(address(rebalancer)    == predictedRebalancer,    "rebalancer address mismatch");
        require(address(agentConsumer) == predictedAgentConsumer, "agentConsumer address mismatch");

        // Whitelist all three chains
        rebalancer.addChainToWhitelist(ARB_SEPOLIA_SELECTOR);
        rebalancer.addChainToWhitelist(BASE_SEPOLIA_SELECTOR);
        rebalancer.addChainToWhitelist(OP_SEPOLIA_SELECTOR);

        // Whitelist all three protocols
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        rebalancer.addProtocolToWhitelist(MORPHO);

        // Point Hub at new Rebalancer
        HUB(hubAddr).setRebalancer(address(rebalancer));

        vm.stopBroadcast();

        console.log("\n=== RedeployCore Complete ===");
        console.log("Hub:           ", hubAddr);
        console.log("Rebalancer:    ", address(rebalancer));
        console.log("AgentConsumer: ", address(agentConsumer));
        console.log("\nUpdate run-live.mjs: AGENT_CONSUMER =", address(agentConsumer));
    }
}
