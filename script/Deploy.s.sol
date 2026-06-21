// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CCIPLocalSimulatorFork, Register} from "chainlink-local/ccip/CCIPLocalSimulatorFork.sol";

import {HUB} from "../src/Hub.sol";
import {SpokeVault} from "../src/Spoke.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {AgentConsumer} from "../src/AgentConsumer.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {compoundAdapter} from "../src/adapters/CompoundAdapter.sol";
import {morphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {CCIPHelpers} from "../src/libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy
/// @notice Deploys the full Meridian protocol stack across forked Ethereum + L2 chains
/// @dev Uses CCIPLocalSimulatorFork for multi-chain simulation in a single Foundry run.
///      Run with:
///      forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL -vvv
///
///      Required env vars:
///        ETH_RPC_URL      — Ethereum mainnet fork RPC
///        ARBITRUM_RPC_URL — Arbitrum mainnet fork RPC
///        BASE_RPC_URL     — Base mainnet fork RPC
///        OPTIMISM_RPC_URL — Optimism mainnet fork RPC
///        DEPLOYER_KEY     — Private key for deployment
///        AGENT_ADDRESS    — Address of the off-chain agent wallet

contract Deploy is Script {

    // =========================================================================
    // Chain Selectors (Chainlink CCIP mainnet)
    // =========================================================================
    uint64 constant ARBITRUM_SELECTOR = 4949039107694359620;
    uint64 constant BASE_SELECTOR     = 15971525489660198786;
    uint64 constant OPTIMISM_SELECTOR = 3734403246176062136;
    uint64 constant ETH_SELECTOR      = 5009297550715157269;

    // =========================================================================
    // Mainnet Addresses — Ethereum
    // =========================================================================
    address constant ETH_CCIP_ROUTER  = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address constant ETH_LINK         = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant ETH_USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // =========================================================================
    // Mainnet Addresses — Arbitrum
    // =========================================================================
    address constant ARB_CCIP_ROUTER  = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address constant ARB_LINK         = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address constant ARB_USDC         = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_AAVE_POOL    = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant ARB_AAVE_AUSDC   = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address constant ARB_COMPOUND     = 0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e;
    address constant ARB_MORPHO       = 0x6B13c060CfF5f99dB49A31b3c7FA97a4E8E1A82d;

    // Morpho USDC/WETH market params on Arbitrum
    address constant ARB_MORPHO_LOAN_TOKEN       = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant ARB_MORPHO_COLLATERAL_TOKEN = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant ARB_MORPHO_ORACLE           = 0xb0341374f5C6cA3a7A75E2cD5B41CD5c9D4ba76E;
    address constant ARB_MORPHO_IRM              = 0x9b8C989Ff27E948F55B53bb19b3Cc1947852dDA2;
    uint256 constant ARB_MORPHO_LLTV             = 860000000000000000; // 86%

    // =========================================================================
    // Mainnet Addresses — Base
    // =========================================================================
    address constant BASE_CCIP_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address constant BASE_LINK        = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address constant BASE_USDC        = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_AAVE_POOL   = 0xA238Dd80C259a72e81d7e4664317d3e8b36B4DE9;
    address constant BASE_AAVE_AUSDC  = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant BASE_COMPOUND    = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address constant BASE_MORPHO      = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFc;

    address constant BASE_MORPHO_LOAN_TOKEN       = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
    address constant BASE_MORPHO_COLLATERAL_TOKEN = 0x4200000000000000000000000000000000000006; // WETH
    address constant BASE_MORPHO_ORACLE           = 0x543E9cCF95B4DB3a45f3A3C79E6A6892fB2Dfb7F;
    address constant BASE_MORPHO_IRM              = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 constant BASE_MORPHO_LLTV             = 860000000000000000; // 86%

    // =========================================================================
    // Mainnet Addresses — Optimism
    // =========================================================================
    address constant OP_CCIP_ROUTER   = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    address constant OP_LINK          = 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;
    address constant OP_USDC          = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant OP_AAVE_POOL     = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant OP_AAVE_AUSDC    = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e;
    address constant OP_COMPOUND      = 0x2e44e174f7D53F0212823acC11C01A11d58c5bCb;

    // =========================================================================
    // Protocol IDs
    // =========================================================================
    bytes32 constant AAVE     = keccak256("AAVE");
    bytes32 constant COMPOUND = keccak256("COMPOUND");
    bytes32 constant MORPHO   = keccak256("MORPHO");

    // =========================================================================
    // Deployed Addresses (populated during run)
    // =========================================================================
    HUB           public hub;
    Rebalancer    public rebalancer;
    AgentConsumer public agentConsumer;

    SpokeVault public arbSpoke;
    SpokeVault public baseSpoke;
    SpokeVault public opSpoke;

    AaveAdapter    public arbAave;
    compoundAdapter public arbCompound;
    morphoAdapter   public arbMorpho;

    AaveAdapter    public baseAave;
    compoundAdapter public baseCompound;
    morphoAdapter   public baseMorpho;

    AaveAdapter     public opAave;
    compoundAdapter public opCompound;

    // =========================================================================
    // Forks
    // =========================================================================
    uint256 public ethFork;
    uint256 public arbFork;
    uint256 public baseFork;
    uint256 public opFork;

    CCIPLocalSimulatorFork public ccipSimulator;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address agent = vm.envAddress("AGENT_ADDRESS");

        // ─── Create forks ──────────────────────────────────────────────────
        ethFork  = vm.createFork(vm.envString("ETH_RPC_URL"));
        arbFork  = vm.createFork(vm.envString("ARBITRUM_RPC_URL"));
        baseFork = vm.createFork(vm.envString("BASE_RPC_URL"));
        opFork   = vm.createFork(vm.envString("OPTIMISM_RPC_URL"));

        // ─── Deploy CCIP simulator on Ethereum fork ────────────────────────
        vm.selectFork(ethFork);
        ccipSimulator = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipSimulator));

        // ─── 1. Deploy Hub on Ethereum ─────────────────────────────────────
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        hub = new HUB(
            "Meridian USDC",
            "mUSDC",
            ETH_CCIP_ROUTER,
            deployer,
            ETH_LINK,
            ETH_USDC,
            address(0) // rebalancer set after
        );
        console.log("Hub deployed:", address(hub));

        // ─── 2. Deploy Rebalancer ──────────────────────────────────────────
        rebalancer = new Rebalancer(address(hub), address(0), deployer);
        // AgentConsumer deployed next — set after
        console.log("Rebalancer deployed:", address(rebalancer));

        // ─── 3. Deploy AgentConsumer ───────────────────────────────────────
        agentConsumer = new AgentConsumer(address(rebalancer), agent, deployer);
        console.log("AgentConsumer deployed:", address(agentConsumer));

        // ─── 4. Wire Hub → Rebalancer ─────────────────────────────────────
        hub.setRebalancer(address(rebalancer));
        console.log("Hub rebalancer set");

        // ─── 5. Wire Rebalancer → AgentConsumer ───────────────────────────
        // redeploy rebalancer with correct agentConsumer
        rebalancer = new Rebalancer(address(hub), address(agentConsumer), deployer);
        hub.setRebalancer(address(rebalancer));
        console.log("Rebalancer redeployed with AgentConsumer:", address(rebalancer));

        // ─── 6. Whitelist chains and protocols ────────────────────────────
        rebalancer.addChainToWhitelist(ARBITRUM_SELECTOR);
        rebalancer.addChainToWhitelist(BASE_SELECTOR);
        rebalancer.addChainToWhitelist(OPTIMISM_SELECTOR);
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        rebalancer.addProtocolToWhitelist(MORPHO);
        console.log("Chains and protocols whitelisted");

        // ─── 7. Fund Hub with USDC and LINK ───────────────────────────────
        deal(ETH_USDC, deployer, 1_000_000e6);
        IERC20(ETH_USDC).approve(address(hub), 1_000_000e6);
        hub.deposit(1_000_000e6, deployer);
        console.log("Hub funded: 1,000,000 USDC deposited");

        deal(ETH_LINK, address(hub), 100 ether);
        console.log("Hub funded: 100 LINK");

        vm.stopBroadcast();

        // ─── 8. Deploy Arbitrum Spoke + Adapters ──────────────────────────
        vm.selectFork(arbFork);
        vm.startBroadcast(deployerKey);

        arbSpoke = new SpokeVault(
            address(hub),
            ARB_USDC,
            ARB_CCIP_ROUTER,
            deployer,
            ARB_LINK,
            ETH_SELECTOR
        );
        console.log("Arbitrum Spoke deployed:", address(arbSpoke));

        arbAave = new AaveAdapter(ARB_AAVE_POOL, ARB_AAVE_AUSDC, ARB_USDC);
        arbCompound = new compoundAdapter(ARB_USDC, ARB_COMPOUND);
        arbMorpho = new morphoAdapter(
            ARB_USDC,
            ARB_MORPHO,
            ARB_MORPHO_LOAN_TOKEN,
            ARB_MORPHO_COLLATERAL_TOKEN,
            ARB_MORPHO_ORACLE,
            ARB_MORPHO_IRM,
            ARB_MORPHO_LLTV
        );
        console.log("Arbitrum adapters deployed");

        arbSpoke.setAdapter(AAVE,     address(arbAave));
        arbSpoke.setAdapter(COMPOUND, address(arbCompound));
        arbSpoke.setAdapter(MORPHO,   address(arbMorpho));
        console.log("Arbitrum adapters registered");

        deal(ARB_LINK, address(arbSpoke), 100 ether);
        console.log("Arbitrum Spoke funded: 100 LINK");

        vm.stopBroadcast();

        // ─── 9. Deploy Base Spoke + Adapters ──────────────────────────────
        vm.selectFork(baseFork);
        vm.startBroadcast(deployerKey);

        baseSpoke = new SpokeVault(
            address(hub),
            BASE_USDC,
            BASE_CCIP_ROUTER,
            deployer,
            BASE_LINK,
            ETH_SELECTOR
        );
        console.log("Base Spoke deployed:", address(baseSpoke));

        baseAave = new AaveAdapter(BASE_AAVE_POOL, BASE_AAVE_AUSDC, BASE_USDC);
        baseCompound = new compoundAdapter(BASE_USDC, BASE_COMPOUND);
        baseMorpho = new morphoAdapter(
            BASE_USDC,
            BASE_MORPHO,
            BASE_MORPHO_LOAN_TOKEN,
            BASE_MORPHO_COLLATERAL_TOKEN,
            BASE_MORPHO_ORACLE,
            BASE_MORPHO_IRM,
            BASE_MORPHO_LLTV
        );
        console.log("Base adapters deployed");

        baseSpoke.setAdapter(AAVE,     address(baseAave));
        baseSpoke.setAdapter(COMPOUND, address(baseCompound));
        baseSpoke.setAdapter(MORPHO,   address(baseMorpho));
        console.log("Base adapters registered");

        deal(BASE_LINK, address(baseSpoke), 100 ether);
        console.log("Base Spoke funded: 100 LINK");

        vm.stopBroadcast();

        // ─── 10. Deploy Optimism Spoke + Adapters ─────────────────────────
        vm.selectFork(opFork);
        vm.startBroadcast(deployerKey);

        opSpoke = new SpokeVault(
            address(hub),
            OP_USDC,
            OP_CCIP_ROUTER,
            deployer,
            OP_LINK,
            ETH_SELECTOR
        );
        console.log("Optimism Spoke deployed:", address(opSpoke));

        opAave = new AaveAdapter(OP_AAVE_POOL, OP_AAVE_AUSDC, OP_USDC);
        opCompound = new compoundAdapter(OP_USDC, OP_COMPOUND);
        console.log("Optimism adapters deployed");

        opSpoke.setAdapter(AAVE,     address(opAave));
        opSpoke.setAdapter(COMPOUND, address(opCompound));
        console.log("Optimism adapters registered");

        deal(OP_LINK, address(opSpoke), 100 ether);
        console.log("Optimism Spoke funded: 100 LINK");

        vm.stopBroadcast();

        // ─── 11. Register Spokes on Hub ───────────────────────────────────
        vm.selectFork(ethFork);
        vm.startBroadcast(deployerKey);

        hub.addSpoke(ARBITRUM_SELECTOR, address(arbSpoke));
        hub.addSpoke(BASE_SELECTOR,     address(baseSpoke));
        hub.addSpoke(OPTIMISM_SELECTOR, address(opSpoke));
        console.log("Spokes registered on Hub");

        vm.stopBroadcast();

        // ─── 12. Print all deployed addresses ─────────────────────────────
        _printAddresses(agent);

        // ─── 13. Write addresses to JSON ──────────────────────────────────
        _writeJson();
    }

    function _printAddresses(address agent) internal view {
        console.log("\n=== Deployed Addresses ===");
        console.log("Hub:           ", address(hub));
        console.log("Rebalancer:    ", address(rebalancer));
        console.log("AgentConsumer: ", address(agentConsumer));
        console.log("Agent wallet:  ", agent);
        console.log("");
        console.log("Arbitrum Spoke:  ", address(arbSpoke));
        console.log("Arbitrum Aave:   ", address(arbAave));
        console.log("Arbitrum Cmpd:   ", address(arbCompound));
        console.log("Arbitrum Morpho: ", address(arbMorpho));
        console.log("");
        console.log("Base Spoke:      ", address(baseSpoke));
        console.log("Base Aave:       ", address(baseAave));
        console.log("Base Cmpd:       ", address(baseCompound));
        console.log("Base Morpho:     ", address(baseMorpho));
        console.log("");
        console.log("Optimism Spoke:  ", address(opSpoke));
        console.log("Optimism Aave:   ", address(opAave));
        console.log("Optimism Cmpd:   ", address(opCompound));
        console.log("==========================\n");
    }

    function _writeJson() internal {
        string memory json = string.concat(
            '{\n',
            '  "hub": "',             vm.toString(address(hub)),           '",\n',
            '  "rebalancer": "',      vm.toString(address(rebalancer)),    '",\n',
            '  "agentConsumer": "',   vm.toString(address(agentConsumer)), '",\n',
            '  "arbSpoke": "',        vm.toString(address(arbSpoke)),      '",\n',
            '  "baseSpoke": "',       vm.toString(address(baseSpoke)),     '",\n',
            '  "opSpoke": "',         vm.toString(address(opSpoke)),       '",\n',
            '  "arbAave": "',         vm.toString(address(arbAave)),       '",\n',
            '  "arbCompound": "',     vm.toString(address(arbCompound)),   '",\n',
            '  "arbMorpho": "',       vm.toString(address(arbMorpho)),     '",\n',
            '  "baseAave": "',        vm.toString(address(baseAave)),      '",\n',
            '  "baseCompound": "',    vm.toString(address(baseCompound)),  '",\n',
            '  "baseMorpho": "',      vm.toString(address(baseMorpho)),    '",\n',
            '  "opAave": "',          vm.toString(address(opAave)),        '",\n',
            '  "opCompound": "',      vm.toString(address(opCompound)),    '"\n',
            '}'
        );
        vm.writeFile("deployed.json", json);
        console.log("Deployed addresses written to deployed.json");
    }
}
