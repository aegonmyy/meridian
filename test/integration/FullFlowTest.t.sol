// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "chainlink-local/ccip/CCIPLocalSimulatorFork.sol";

import {HUB} from "../../src/Hub.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {AgentConsumer} from "../../src/AgentConsumer.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {compoundAdapter} from "../../src/adapters/CompoundAdapter.sol";
import {morphoAdapter} from "../../src/adapters/MorphoAdapter.sol";
import {CCIPHelpers} from "../../src/libraries/CCIPHelpers.sol";
import {AllocationProposal} from "../../src/interfaces/IRebalancer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FullFlowTest
/// @notice End-to-end integration test for the full Meridian protocol flow
/// @dev Uses CCIPLocalSimulatorFork with real mainnet forks for Ethereum and Arbitrum.
///      Tests the complete path:
///      1. Alice deposits USDC into Hub
///      2. Agent submits allocation proposal
///      3. Rebalancer validates and calls Hub.sendToSpoke
///      4. Hub sends DEPOSIT CCIP message to Arbitrum spoke
///      5. CCIPLocalSimulatorFork routes message to Arbitrum fork
///      6. Spoke deposits into Aave adapter
///      7. Spoke sends CONFIRM_RECEIPT back to Ethereum
///      8. CCIPLocalSimulatorFork routes message to Ethereum fork
///      9. Hub updates spokeBalances, clears inTransitAssets
///      10. Assert all accounting invariants hold
///
///      Run with:
///      forge test --match-contract FullFlowTest --fork-url $ETH_RPC_URL -vvv
///
///      Required env vars:
///        ETH_RPC_URL      — Ethereum mainnet RPC
///        ARBITRUM_RPC_URL — Arbitrum mainnet RPC
contract FullFlowTest is Test {

    // =========================================================================
    // Chain Selectors
    // =========================================================================
    uint64 constant ETH_SELECTOR      = 5009297550715157269;
    uint64 constant ARBITRUM_SELECTOR = 4949039107694359620;

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

    // =========================================================================
    // Protocol IDs
    // =========================================================================
    bytes32 constant AAVE     = keccak256("AAVE");
    bytes32 constant COMPOUND = keccak256("COMPOUND");

    // =========================================================================
    // Contracts
    // =========================================================================
    CCIPLocalSimulatorFork public ccipSimulator;

    HUB            public hub;
    Rebalancer     public rebalancer;
    AgentConsumer  public agentConsumer;
    SpokeVault     public arbSpoke;
    AaveAdapter    public arbAave;
    compoundAdapter public arbCompound;

    // =========================================================================
    // Actors
    // =========================================================================
    address public owner;
    address public agent;
    address public alice;

    // =========================================================================
    // Forks
    // =========================================================================
    uint256 public ethFork;
    uint256 public arbFork;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        owner = makeAddr("owner");
        agent = makeAddr("agent");
        alice = makeAddr("alice");

        // create forks
        ethFork = vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        arbFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"));

        // deploy CCIP simulator — make persistent across forks
        ccipSimulator = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipSimulator));

        // ── deploy on Ethereum fork ──────────────────────────────────────
        vm.selectFork(ethFork);

        vm.startPrank(owner);
        hub = new HUB(
            "Meridian USDC",
            "mUSDC",
            ETH_CCIP_ROUTER,
            owner,
            ETH_LINK,
            ETH_USDC,
            address(0)
        );

        rebalancer = new Rebalancer(address(hub), address(0), owner);
        agentConsumer = new AgentConsumer(address(rebalancer), agent, owner);

        // redeploy rebalancer with real agentConsumer
        rebalancer = new Rebalancer(address(hub), address(agentConsumer), owner);
        hub.setRebalancer(address(rebalancer));

        rebalancer.addChainToWhitelist(ARBITRUM_SELECTOR);
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        vm.stopPrank();

        // fund hub with LINK for CCIP fees
        deal(ETH_LINK, address(hub), 100 ether);

        // alice deposits USDC into hub
        deal(ETH_USDC, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(ETH_USDC).approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();

        console.log("Hub deployed on Ethereum:", address(hub));
        console.log("Hub totalAssets:", hub.totalAssets());

        // ── deploy on Arbitrum fork ──────────────────────────────────────
        vm.selectFork(arbFork);

        vm.startPrank(owner);
        arbSpoke = new SpokeVault(
            address(hub),
            ARB_USDC,
            ARB_CCIP_ROUTER,
            owner,
            ARB_LINK,
            ETH_SELECTOR
        );

        arbAave     = new AaveAdapter(ARB_AAVE_POOL, ARB_AAVE_AUSDC, ARB_USDC);
        arbCompound = new compoundAdapter(ARB_USDC, ARB_COMPOUND);

        arbSpoke.setAdapter(AAVE,     address(arbAave));
        arbSpoke.setAdapter(COMPOUND, address(arbCompound));
        vm.stopPrank();

        deal(ARB_LINK, address(arbSpoke), 100 ether);

        console.log("Arbitrum Spoke deployed:", address(arbSpoke));

        // ── register spoke on hub ────────────────────────────────────────
        vm.selectFork(ethFork);
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, address(arbSpoke));

        console.log("Spoke registered on Hub");
    }

    // =========================================================================
    // Test 1 — Full deposit flow: hub → spoke → CONFIRM_RECEIPT → hub
    // =========================================================================

    function test_fullFlow_depositAndConfirm() public {
        vm.selectFork(ethFork);

        uint256 totalBefore = hub.totalAssets();
        uint256 idleBefore  = IERC20(ETH_USDC).balanceOf(address(hub));

        // agent submits allocation — send 6_000 USDC (6000 bps) to Aave on Arbitrum
        CCIPHelpers.AdapterInstructions[] memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 6_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(address(rebalancer));
        hub.sendToSpoke(ARBITRUM_SELECTOR, instructions);

        // hub should have decremented idle and incremented inTransit
        assertEq(IERC20(ETH_USDC).balanceOf(address(hub)), idleBefore - 6_000e6, "hub idle after send");
        assertEq(hub.inTransitAssets(), 6_000e6, "inTransit after send");
        assertEq(hub.totalAssets(), totalBefore, "totalAssets unchanged during transit");

        console.log("CCIP message sent — routing to Arbitrum...");

        // route DEPOSIT message to Arbitrum
        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);

        // spoke should have deposited into Aave
        assertGt(arbAave.totalAssets(), 0, "Aave adapter received funds");
        assertApproxEqAbs(arbAave.totalAssets(), 6_000e6, 100, "Aave adapter balance");
        console.log("Spoke deposited into Aave:", arbAave.totalAssets());

        // route CONFIRM_RECEIPT back to Ethereum
        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        // hub should have cleared inTransit and updated spokeBalances
        assertEq(hub.inTransitAssets(), 0, "inTransit cleared after confirm");
        assertApproxEqAbs(hub.spokeBalances(ARBITRUM_SELECTOR), 6_000e6, 100, "spoke balance updated");
        assertApproxEqAbs(hub.totalAssets(), totalBefore, 100, "totalAssets preserved after round trip");

        console.log("Hub spokeBalances updated:", hub.spokeBalances(ARBITRUM_SELECTOR));
        console.log("Hub inTransitAssets:", hub.inTransitAssets());
    }

    // =========================================================================
    // Test 2 — Full proposeAllocation flow via AgentConsumer → Rebalancer → Hub → Spoke
    // =========================================================================

    function test_fullFlow_proposeAllocation() public {
        vm.selectFork(ethFork);

        uint256 totalAssets = hub.totalAssets(); // 10_000e6

        // build allocation proposal — 6000 bps to Aave, 4000 bps to Compound on Arbitrum
        uint256[][] memory proposedAllocations = new uint256[][](1);
        proposedAllocations[0] = new uint256[](2);
        proposedAllocations[0][0] = 6000; // AAVE — 60%
        proposedAllocations[0][1] = 4000; // COMPOUND — 40%

        uint256[] memory proposedNetApys = new uint256[](2);
        proposedNetApys[0] = 500; // 5% net APY for Aave
        proposedNetApys[1] = 400; // 4% net APY for Compound

        uint256[][] memory currentAllocations = new uint256[][](1);
        currentAllocations[0] = new uint256[](2);
        currentAllocations[0][0] = 0;
        currentAllocations[0][1] = 0;

        uint256[] memory currentNetApys = new uint256[](2);
        currentNetApys[0] = 0;
        currentNetApys[1] = 0;

        uint64[] memory chainSelectors = new uint64[](1);
        chainSelectors[0] = ARBITRUM_SELECTOR;

        bytes32[][] memory protocolIds = new bytes32[][](1);
        protocolIds[0] = new bytes32[](2);
        protocolIds[0][0] = AAVE;
        protocolIds[0][1] = COMPOUND;

        AllocationProposal memory proposal = AllocationProposal({
            proposedAllocations: proposedAllocations,
            proposedNetApys: proposedNetApys,
            currentAllocations: currentAllocations,
            currentNetApys: currentNetApys,
            chainSelectors: chainSelectors,
            protocolIds: protocolIds
        });

        // warp past cooldown
        vm.warp(block.timestamp + 25 hours);

        uint256 aaveExpected    = (6000 * totalAssets) / 10_000; // 6_000e6
        uint256 compoundExpected = (4000 * totalAssets) / 10_000; // 4_000e6

        // agent submits via AgentConsumer
        vm.prank(agent);
        agentConsumer.proposeAllocation(proposal);

        console.log("Proposal submitted — routing DEPOSIT messages...");
        console.log("Expected Aave deposit:", aaveExpected);
        console.log("Expected Compound deposit:", compoundExpected);

        // hub sent two DEPOSIT messages — one for Aave, one for Compound
        // proposeAllocation sends one message per chain with all instructions
        assertEq(hub.inTransitAssets(), aaveExpected + compoundExpected, "inTransit = total sent");

        // route to Arbitrum
        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);

        assertApproxEqAbs(arbAave.totalAssets(),     aaveExpected,     100, "Aave received correct amount");
        assertApproxEqAbs(arbCompound.totalAssets(), compoundExpected, 100, "Compound received correct amount");
        console.log("Aave adapter balance:", arbAave.totalAssets());
        console.log("Compound adapter balance:", arbCompound.totalAssets());

        // route CONFIRM_RECEIPT back
        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        assertEq(hub.inTransitAssets(), 0, "inTransit cleared");
        assertApproxEqAbs(
            hub.spokeBalances(ARBITRUM_SELECTOR),
            aaveExpected + compoundExpected,
            100,
            "spoke balance = total deployed"
        );
        assertApproxEqAbs(hub.totalAssets(), totalAssets, 100, "totalAssets preserved");

        console.log("Final hub spokeBalances:", hub.spokeBalances(ARBITRUM_SELECTOR));
    }

    // =========================================================================
    // Test 3 — Intra-spoke rebalance: Aave → Compound on Arbitrum
    // =========================================================================

    function test_fullFlow_rebalance() public {
        // first deposit into Aave
        vm.selectFork(ethFork);
        CCIPHelpers.AdapterInstructions[] memory depositInstructions = new CCIPHelpers.AdapterInstructions[](1);
        depositInstructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 6_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(address(rebalancer));
        hub.sendToSpoke(ARBITRUM_SELECTOR, depositInstructions);

        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);
        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        console.log("Initial Aave balance:", arbAave.totalAssets());

        // warp past cooldown
        vm.warp(block.timestamp + 25 hours);

        // rebalance 2_000 from Aave to Compound
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        CCIPHelpers.AdapterInstructions[] memory rebalanceInstructions = new CCIPHelpers.AdapterInstructions[](1);
        rebalanceInstructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });

        vm.prank(address(rebalancer));
        hub.rebalance(ARBITRUM_SELECTOR, rebalanceInstructions, messageId);

        // no tokens should have left hub
        assertEq(hub.inTransitAssets(), 0, "inTransit stays 0 for rebalance");

        // route REBALANCE to Arbitrum
        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);

        assertApproxEqAbs(arbAave.totalAssets(),     4_000e6, 100, "Aave decreased by 2_000");
        assertApproxEqAbs(arbCompound.totalAssets(), 2_000e6, 100, "Compound increased by 2_000");
        console.log("After rebalance — Aave:", arbAave.totalAssets(), "Compound:", arbCompound.totalAssets());

        // route CONFIRM_REBALANCE back to Ethereum
        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        // spoke balance unchanged — same total just different split
        assertApproxEqAbs(hub.spokeBalances(ARBITRUM_SELECTOR), 6_000e6, 100, "spoke total unchanged");
        console.log("Hub spoke balance after rebalance:", hub.spokeBalances(ARBITRUM_SELECTOR));
    }

    // =========================================================================
    // Test 4 — Path 3 withdrawal: idle insufficient → recall from spoke
    // =========================================================================

    function test_fullFlow_path3Withdrawal() public {
        // deploy 9_000 to spoke — only 1_000 idle remains
        vm.selectFork(ethFork);
        CCIPHelpers.AdapterInstructions[] memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 9_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(address(rebalancer));
        hub.sendToSpoke(ARBITRUM_SELECTOR, instructions);

        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);
        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        // set fresh report timestamp so _allSpokesFresh passes
        // (CCIP simulator sets it — just confirm)
        assertGt(hub.lastReportTimestamp(ARBITRUM_SELECTOR), 0, "report timestamp set");

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 aliceAssets = hub.previewRedeem(aliceShares);
        uint256 idleBalance = IERC20(ETH_USDC).balanceOf(address(hub));

        console.log("Alice shares:", aliceShares);
        console.log("Alice assets:", aliceAssets);
        console.log("Hub idle:", idleBalance);

        // alice withdraws — idle (1_000) < assets (10_000) → Path 3
        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        // hub should have sent WITHDRAW_AMOUNT to spoke
        console.log("Withdrawal queued — routing recall to Arbitrum...");

        // route WITHDRAW_AMOUNT to Arbitrum
        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);

        // spoke withdrew from Aave — check adapter decreased
        uint256 spokeAaveAfter = arbAave.totalAssets();
        console.log("Arbitrum Aave after recall:", spokeAaveAfter);

        // route CONFIRM_WITHDRAWAL back to Ethereum — triggers settlement
        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        // alice should have received her USDC
        assertApproxEqAbs(
            IERC20(ETH_USDC).balanceOf(alice),
            aliceAssets,
            100,
            "alice received correct USDC"
        );
        assertEq(hub.balanceOf(alice), 0, "alice shares burned");
        assertEq(hub.reservedAssets(), 0, "reservedAssets cleared");
        assertEq(hub.inTransitAssets(), 0, "inTransit cleared");

        console.log("Alice received:", IERC20(ETH_USDC).balanceOf(alice));
        console.log("Hub totalAssets after withdrawal:", hub.totalAssets());
    }

    // =========================================================================
    // Test 5 — Accounting invariant holds throughout full flow
    // =========================================================================

    function test_fullFlow_accountingInvariant() public {
        vm.selectFork(ethFork);

        // identity: totalAssets == idle + inTransit + spokeBalances
        _assertAccountingIdentity("initial");

        // deposit to spoke
        CCIPHelpers.AdapterInstructions[] memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 5_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(address(rebalancer));
        hub.sendToSpoke(ARBITRUM_SELECTOR, instructions);

        _assertAccountingIdentity("after sendToSpoke");

        vm.selectFork(arbFork);
        ccipSimulator.switchChainAndRouteMessage(arbFork);

        vm.selectFork(ethFork);
        ccipSimulator.switchChainAndRouteMessage(ethFork);

        _assertAccountingIdentity("after CONFIRM_RECEIPT");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _assertAccountingIdentity(string memory label) internal {
        vm.selectFork(ethFork);
        uint256 idle         = IERC20(ETH_USDC).balanceOf(address(hub));
        uint256 inTransit    = hub.inTransitAssets();
        uint256 spokeBalance = hub.spokeBalances(ARBITRUM_SELECTOR);
        uint256 total        = hub.totalAssets();

        console.log(label);
        console.log("  idle:", idle);
        console.log("  inTransit:", inTransit);
        console.log("  spokeBalance:", spokeBalance);
        console.log("  totalAssets:", total);

        assertApproxEqAbs(
            total,
            idle + inTransit + spokeBalance,
            100,
            string.concat("accounting identity: ", label)
        );
    }
}
