// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {Asset} from "../../mocks/Asset.sol";
import {MockYieldSource} from "../../mocks/mockYield.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {NotRebalancer, SpokeNotFound} from "../../../src/errors/hubErrors.sol";

contract DepositFlowTest is Test {
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

    // ── Actors ────────────────────────────────────────────────────────────
    address public owner;
    address public rebalancer;
    address public alice;

    // ── Protocol IDs ──────────────────────────────────────────────────────
    bytes32 public constant AAVE = keccak256("AAVE");

    function setUp() public {
        owner = makeAddr("owner");
        rebalancer = makeAddr("rebalancer");
        alice = makeAddr("alice");

        // CCIP
        ccipSimulator = new CCIPLocalSimulator();
        (chainSelector, router, , , link, , ) = ccipSimulator.configuration();

        // USDC
        usdc = new Asset();

        // Hub
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

        // Spoke — hubChainSelector is same chainSelector in simulator
        vm.prank(owner);
        spoke = new SpokeVault(
            address(hub),
            address(usdc),
            address(router),
            owner,
            address(link),
            chainSelector
        );

        // Register spoke in hub
        vm.prank(owner);
        hub.addSpoke(chainSelector, address(spoke));

        // Deploy and register adapter on spoke
        aaveAdapter = new MockYieldSource(address(usdc));
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));

        // Fund hub with USDC and LINK
        usdc.mint(address(hub), 100_000e6);
        ccipSimulator.requestLinkFromFaucet(address(hub), 10 ether);
        ccipSimulator.requestLinkFromFaucet(address(spoke), 10 ether);

        // Alice deposits so hub has shares in circulation
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    // =========================================================================
    // sendToSpoke — DEPOSIT
    // =========================================================================

    function test_sendToSpoke_spokeReceivesAndDepositsToAdapter() public {
        uint256 amount = 5_000e6;
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        // CCIP delivers instantly in simulator
        // spoke deposited into adapter
        assertEq(aaveAdapter.totalAssets(), amount);
    }

    function test_sendToSpoke_confirmReceiptUpdatesSpokeBalances() public {
        uint256 amount = 5_000e6;
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        // CONFIRM_RECEIPT callback updates spoke balances
        assertEq(hub.spokeBalances(chainSelector), amount);
    }

    function test_sendToSpoke_decrementsInTransitAfterConfirm() public {
        uint256 amount = 5_000e6;
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        // after CONFIRM_RECEIPT inTransitAssets should be back to 0
        assertEq(hub.inTransitAssets(), 0);
    }

    function test_sendToSpoke_revert_notRebalancer() public {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 1000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(alice);
        vm.expectRevert(NotRebalancer.selector);
        hub.sendToSpoke(chainSelector, instructions);
    }

    function test_sendToSpoke_revert_spokeNotFound() public {
        uint64 fakeSeletor = 9999;
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 1000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        vm.expectRevert(SpokeNotFound.selector);
        hub.sendToSpoke(fakeSeletor, instructions);
    }

    function test_sendToSpoke_multipleInstructions() public {
        // register compound adapter
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 compound = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(compound, address(compoundAdapter));

        uint256 aaveAmount = 3_000e6;
        uint256 compoundAmount = 2_000e6;

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](2);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: aaveAmount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        instructions[1] = CCIPHelpers.AdapterInstructions({
            adapter: compound,
            amount: compoundAmount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        assertEq(aaveAdapter.totalAssets(), aaveAmount);
        assertEq(compoundAdapter.totalAssets(), compoundAmount);
        assertEq(hub.spokeBalances(chainSelector), aaveAmount + compoundAmount);
    }

    function test_sendToSpoke_totalAssetsUnchangedAfterRoundTrip() public {
        uint256 totalBefore = hub.totalAssets();

        uint256 amount = 5_000e6;
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        assertEq(hub.totalAssets(), totalBefore);
    }

    function test_withdraw_path3_aliceReceivesUSDC() public {
        _setupPath3();
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assetsToReceive);
    }

    function test_withdraw_path3_aliceSharesBurned() public {
        _setupPath3();
        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(hub.balanceOf(address(hub)), 0);
    }

    function test_withdraw_path3_spokeBalanceUpdated() public {
        _setupPath3();
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);
        uint256 deployAmount = 109_000e6;

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(
            hub.spokeBalances(chainSelector),
            deployAmount - assetsToReceive
        );
    }

    function test_withdraw_path3_totalAssetsDecreasesByWithdrawnAmount()
        public
    {
        _setupPath3();
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);
        uint256 totalAssetsBefore = hub.totalAssets();

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.totalAssets(), totalAssetsBefore - assetsToReceive);
    }

    function test_withdraw_path3_inTransitBackToZero() public {
        _setupPath3();
        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.inTransitAssets(), 0);
    }

    function _setupPath3() internal {
        uint256 deployAmount = 109_000e6;
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: deployAmount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);
    }

    function test_withdraw_path3_partialRedeem() public {
        _setupPath3();

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 halfShares = aliceShares / 2;
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(halfShares);

        vm.prank(alice);
        hub.redeem(halfShares, alice, alice);

        assertEq(hub.balanceOf(alice), aliceShares - halfShares);
        assertEq(hub.balanceOf(address(hub)), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assetsToReceive);
    }
}
