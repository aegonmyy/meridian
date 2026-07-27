// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../src/Hub.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {CCIPHelpers} from "../../src/libraries/CCIPHelpers.sol";

/// @title WI3_TwoPhaseRebalanceTest
/// @notice Integration test for the WI-3 v1 operator flow: recall capital off a spoke,
///         await confirmation, then deploy the now-idle funds back out, end to end,
///         hub <-> spoke, using the real Rebalancer + Hub + Spoke stack over CCIP.
/// @dev NOTE on scope: `CCIPLocalSimulator` (the non-fork local simulator used everywhere
///      else in this test suite outside FullFlowTest) hardcodes a single fixed chain
///      selector for every message it routes, `message.sourceChainSelector` on delivery
///      to the hub is always that one constant, regardless of what destination selector a
///      sender passed to `ccipSend`. Two independently-addressed "chains" (spoke A on
///      selector X, spoke B on selector Y) therefore cannot be faithfully simulated without
///      `CCIPLocalSimulatorFork` against two real RPC forks (the pattern FullFlowTest uses,
///      which requires ETH_RPC_URL/ARBITRUM_RPC_URL env vars not available in this
///      environment). This test instead exercises the full recall -> confirm -> redeploy
///      round trip against a single spoke, moving capital between two adapters (AAVE and
///      COMPOUND) rather than two chains: the mechanics under test (Rebalancer.recallFromSpoke
///      -> CONFIRM_WITHDRAWAL -> RecallCompleted -> sendToSpoke -> CONFIRM_RECEIPT) are
///      identical; only the "two chains" framing had to be adapted to this harness's
///      constraints. See docs/revert-audit.md for this
///      divergence.
contract WI3_TwoPhaseRebalanceTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    HUB public hub;
    Rebalancer public rebalancer;
    Asset public usdc;

    SpokeVault public spoke;
    MockYieldSource public aaveAdapter;
    MockYieldSource public compoundAdapter;

    address public owner;
    address public agentConsumer;
    address public alice;

    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");

    function setUp() public {
        owner = makeAddr("owner");
        agentConsumer = makeAddr("agentConsumer");
        alice = makeAddr("alice");

        ccipSimulator = new CCIPLocalSimulator();
        (chainSelector, router, , , link, , ) = ccipSimulator.configuration();

        usdc = new Asset();

        vm.prank(owner);
        hub = new HUB(
            "Meridian USDC",
            "mUSDC",
            address(router),
            owner,
            address(link),
            address(usdc),
            address(0)
        );

        vm.prank(owner);
        rebalancer = new Rebalancer(address(hub), agentConsumer, owner);

        vm.prank(owner);
        hub.setRebalancer(address(rebalancer));

        vm.prank(owner);
        spoke = new SpokeVault(
            address(hub),
            address(usdc),
            address(router),
            owner,
            address(link),
            chainSelector
        );

        vm.prank(owner);
        hub.addSpoke(chainSelector, address(spoke));

        aaveAdapter = new MockYieldSource(address(usdc));
        compoundAdapter = new MockYieldSource(address(usdc));

        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        vm.stopPrank();

        ccipSimulator.requestLinkFromFaucet(address(hub), 10 ether);
        ccipSimulator.requestLinkFromFaucet(address(spoke), 10 ether);

        vm.startPrank(owner);
        rebalancer.addChainToWhitelist(chainSelector);
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        vm.stopPrank();

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    /// @notice Two-phase rebalance: recall all capital off AAVE back to hub idle, confirm
    /// lands, then deploy that idle into COMPOUND. Demonstrates the WI-3 "move weight off
    /// a chain" lever end to end: capital previously could only leave a spoke via a
    /// user-triggered Path 3 withdrawal.
    function test_wi3_recallThenDeploy_endToEnd() public {
        // phase 0, deploy all capital into AAVE
        CCIPHelpers.AdapterInstructions[]
            memory depositInstructions = new CCIPHelpers.AdapterInstructions[](1);
        depositInstructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 10_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(address(rebalancer));
        hub.sendToSpoke(chainSelector, depositInstructions);

        assertEq(aaveAdapter.totalAssets(), 10_000e6, "aave fully funded");
        assertEq(hub.spokeBalances(chainSelector), 10_000e6, "hub sees spoke balance");
        assertEq(hub.idleBalance(), 0, "hub idle drained");

        // phase 1, recall all capital off the spoke via the new Rebalancer entrypoint
        vm.recordLogs();
        vm.prank(owner);
        rebalancer.recallFromSpoke(chainSelector, 10_000e6);

        assertEq(aaveAdapter.totalAssets(), 0, "aave fully recalled");
        assertEq(hub.idleBalance(), 10_000e6, "recalled funds are hub idle");
        assertEq(hub.spokeBalances(chainSelector), 0, "hub sees spoke drained");

        // RecallCompleted fired: confirms the off-chain agent's sequencing signal exists
        assertTrue(
            _hasRecallCompletedLog(chainSelector, 10_000e6),
            "RecallCompleted not emitted with expected args"
        );

        // phase 2: deploy the now-idle capital into COMPOUND
        CCIPHelpers.AdapterInstructions[]
            memory redeployInstructions = new CCIPHelpers.AdapterInstructions[](1);
        redeployInstructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: COMPOUND,
            amount: 10_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(address(rebalancer));
        hub.sendToSpoke(chainSelector, redeployInstructions);

        assertEq(compoundAdapter.totalAssets(), 10_000e6, "compound fully funded");
        assertEq(hub.spokeBalances(chainSelector), 10_000e6, "hub sees spoke balance again");
        assertEq(hub.idleBalance(), 0, "hub idle drained again");
        assertEq(hub.totalAssets(), 10_000e6, "totalAssets preserved throughout");
    }

    /// @notice Rebalancer.recallFromSpoke reverts if the target chain isn't whitelisted.
    function test_wi3_recallFromSpoke_revert_chainNotWhitelisted() public {
        uint64 unknownSelector = 9999;
        vm.prank(owner);
        vm.expectRevert(Rebalancer.ChainNotWhitelisted.selector);
        rebalancer.recallFromSpoke(unknownSelector, 1_000e6);
    }

    /// @notice Rebalancer.recallFromSpoke reverts on a zero amount.
    function test_wi3_recallFromSpoke_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(Rebalancer.ZeroAmount.selector);
        rebalancer.recallFromSpoke(chainSelector, 0);
    }

    function _hasRecallCompletedLog(
        uint64 selector,
        uint256 amount
    ) internal returns (bool) {
        bytes32 sig = keccak256("RecallCompleted(uint64,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            uint64 loggedSelector = uint64(uint256(logs[i].topics[1]));
            uint256 loggedAmount = abi.decode(logs[i].data, (uint256));
            if (loggedSelector == selector && loggedAmount == amount) {
                return true;
            }
        }
        return false;
    }
}
