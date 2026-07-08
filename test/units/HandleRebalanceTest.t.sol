// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../src/Hub.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {CCIPHelpers} from "../../src/libraries/CCIPHelpers.sol";

contract HandleRebalanceTest is Test {
    // ── CCIP ──────────────────────────────────────────────────────────────
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    // ── Contracts ─────────────────────────────────────────────────────────
    HUB public hub;
    SpokeVault public spoke;
    Asset public usdc;
    MockYieldSource public aaveAdapter;
    MockYieldSource public compoundAdapter;

    // ── Actors ────────────────────────────────────────────────────────────
    address public owner;
    address public rebalancer;
    address public alice;

    // ── Protocol IDs ──────────────────────────────────────────────────────
    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");

    function setUp() public {
        owner = makeAddr("owner");
        rebalancer = makeAddr("rebalancer");
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
            rebalancer
        );

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

        // register both adapters on spoke
        aaveAdapter = new MockYieldSource(address(usdc));
        compoundAdapter = new MockYieldSource(address(usdc));

        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        vm.stopPrank();

        ccipSimulator.requestLinkFromFaucet(address(hub), 10 ether);
        ccipSimulator.requestLinkFromFaucet(address(spoke), 10 ether);

        // alice deposits — hub gets USDC
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();

        // deploy 5_000 to aave on spoke
        _sendToSpoke(5_000e6);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _buildInstructions(
        bytes32 adapter,
        uint256 amount
    ) internal pure returns (CCIPHelpers.AdapterInstructions[] memory) {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: adapter,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        return instructions;
    }

    function _sendToSpoke(uint256 amount) internal {
        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, _buildInstructions(AAVE, amount));
    }

    function _rebalance(
        bytes32 source,
        bytes32 target,
        uint256 amount
    ) internal {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: source,
            amount: amount,
            targetAdapter: target,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);
    }

    // =========================================================================
    // Happy paths
    // =========================================================================

    function test_handleRebalance_sourceAdapterDecreases() public {
        // aave has 5_000 — move 2_000 to compound
        _rebalance(AAVE, COMPOUND, 2_000e6);
        assertEq(aaveAdapter.totalAssets(), 3_000e6);
    }

    function test_handleRebalance_targetAdapterIncreases() public {
        _rebalance(AAVE, COMPOUND, 2_000e6);
        assertEq(compoundAdapter.totalAssets(), 2_000e6);
    }

    function test_handleRebalance_totalSpokeBalanceUnchanged() public {
        uint256 totalBefore = aaveAdapter.totalAssets() +
            compoundAdapter.totalAssets();
        _rebalance(AAVE, COMPOUND, 2_000e6);
        uint256 totalAfter = aaveAdapter.totalAssets() +
            compoundAdapter.totalAssets();
        assertEq(totalAfter, totalBefore);
    }

    function test_handleRebalance_hubSpokeBalancesUpdated() public {
        uint256 spokeBalanceBefore = hub.spokeBalances(chainSelector);
        _rebalance(AAVE, COMPOUND, 2_000e6);
        // CONFIRM_RECEIPT updates hub spoke balance
        assertEq(hub.spokeBalances(chainSelector), spokeBalanceBefore);
    }

    function test_handleRebalance_lastReportTimestampUpdated() public {
        uint256 timestampBefore = hub.lastReportTimestamp(chainSelector);
        vm.warp(block.timestamp + 30 minutes);
        _rebalance(AAVE, COMPOUND, 2_000e6);
        assertGt(hub.lastReportTimestamp(chainSelector), timestampBefore);
    }

    function test_handleRebalance_totalAssetsUnchanged() public {
        uint256 totalBefore = hub.totalAssets();
        _rebalance(AAVE, COMPOUND, 2_000e6);
        assertEq(hub.totalAssets(), totalBefore);
    }

    function test_handleRebalance_noTokensReturnToHub() public {
        // REBALANCE is intra-spoke — hub USDC balance unchanged
        uint256 hubBalanceBefore = usdc.balanceOf(address(hub));
        _rebalance(AAVE, COMPOUND, 2_000e6);
        assertEq(usdc.balanceOf(address(hub)), hubBalanceBefore);
    }

    function test_handleRebalance_multipleInstructions() public {
        // move 1_000 aave → compound and 500 aave → compound in same message
        // register morpho for second instruction
        MockYieldSource morphoAdapter = new MockYieldSource(address(usdc));
        bytes32 MORPHO = keccak256("MORPHO");
        vm.prank(owner);
        spoke.setAdapter(MORPHO, address(morphoAdapter));

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](2);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 1_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        instructions[1] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 500e6,
            targetAdapter: MORPHO,
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(aaveAdapter.totalAssets(), 3_500e6);
        assertEq(compoundAdapter.totalAssets(), 1_000e6);
        assertEq(morphoAdapter.totalAssets(), 500e6);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_handleRebalance_fullRebalance_sourceGoesToZero() public {
        // move all 5_000 from aave to compound
        _rebalance(AAVE, COMPOUND, 5_000e6);
        assertEq(aaveAdapter.totalAssets(), 0);
        assertEq(compoundAdapter.totalAssets(), 5_000e6);
    }

    function test_handleRebalance_partialRebalance_sourceRetainsRemainder()
        public
    {
        _rebalance(AAVE, COMPOUND, 1_000e6);
        assertEq(aaveAdapter.totalAssets(), 4_000e6);
        assertEq(compoundAdapter.totalAssets(), 1_000e6);
    }

    // =========================================================================
    // Revert paths
    // =========================================================================

    function test_handleRebalance_revert_sourceAdapterNotFound() public {
        // bytes32(0) not registered as adapter
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: keccak256("UNKNOWN"),
            amount: 1_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });

        vm.prank(rebalancer);
        // CCIP delivers but spoke reverts — hub catches ReceiverError
        vm.expectRevert();
        hub.rebalance(chainSelector, instructions);
    }

    function test_handleRebalance_revert_emptyInstructions() public {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](0);

        vm.prank(rebalancer);
        vm.expectRevert();
        hub.rebalance(chainSelector, instructions);
    }

    function test_handleRebalance_revert_zeroAmount() public {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 0,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });

        vm.prank(rebalancer);
        vm.expectRevert();
        hub.rebalance(chainSelector, instructions);
    }
}
