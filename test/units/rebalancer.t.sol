// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../src/Hub.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {CCIPHelpers} from "../../src/libraries/CCIPHelpers.sol";
import {AllocationProposal} from "../../src/interfaces/IRebalancer.sol";

contract RebalancerTest is Test {
    // ── CCIP ──────────────────────────────────────────────────────────────
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    // ── Contracts ─────────────────────────────────────────────────────────
    HUB public hub;
    SpokeVault public spoke;
    Rebalancer public rebalancer;
    Asset public usdc;
    MockYieldSource public aaveAdapter;
    MockYieldSource public compoundAdapter;

    // ── Actors ────────────────────────────────────────────────────────────
    address public owner;
    address public agentConsumer;
    address public alice;
    address public attacker;

    // ── Protocol IDs ──────────────────────────────────────────────────────
    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");
    bytes32 public constant MORPHO = keccak256("MORPHO");

    function setUp() public {
        owner = makeAddr("owner");
        agentConsumer = makeAddr("agentConsumer");
        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        ccipSimulator = new CCIPLocalSimulator();
        (chainSelector, router, , , link, , ) = ccipSimulator.configuration();

        usdc = new Asset();

        // deploy rebalancer first — hub needs its address

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
        spoke = new SpokeVault(
            address(hub),
            address(usdc),
            address(router),
            owner,
            address(link),
            chainSelector
        );
        vm.prank(owner);
        hub.setRebalancer(address(rebalancer));

        // update hub rebalancer — need to redeploy hub with correct rebalancer
        // simplest: redeploy hub with correct rebalancer address

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

        // whitelist chains and protocols
        vm.startPrank(owner);
        rebalancer.addChainToWhitelist(chainSelector);
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        vm.stopPrank();

        // alice deposits
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();

        // deploy 5_000 to aave so spoke has capital to rebalance
        vm.prank(address(rebalancer));
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 5_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        hub.sendToSpoke(chainSelector, instructions);

        // warp past cooldown so first rebalance can execute
        vm.warp(block.timestamp + 25 hours);
    }

    // =========================================================================
    // Whitelist management
    // =========================================================================

    function test_addChainToWhitelist_setsMapping() public {
        uint64 newSelector = 9999;
        vm.prank(owner);
        rebalancer.addChainToWhitelist(newSelector);
        assertTrue(rebalancer.whitelistedChains(newSelector));
    }

    function test_addChainToWhitelist_emitsEvent() public {
        uint64 newSelector = 9999;
        vm.expectEmit(true, false, false, false);
        emit Rebalancer.ChainWhitelisted(newSelector);
        vm.prank(owner);
        rebalancer.addChainToWhitelist(newSelector);
    }

    function test_removeChainFromWhitelist_unsetsMapping() public {
        vm.prank(owner);
        rebalancer.removeChainFromWhitelist(chainSelector);
        assertFalse(rebalancer.whitelistedChains(chainSelector));
    }

    function test_removeChainFromWhitelist_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Rebalancer.ChainRemovedFromWhitelist(chainSelector);
        vm.prank(owner);
        rebalancer.removeChainFromWhitelist(chainSelector);
    }

    function test_addProtocolToWhitelist_setsMapping() public {
        vm.prank(owner);
        rebalancer.addProtocolToWhitelist(MORPHO);
        assertTrue(rebalancer.whitelistedProtocols(MORPHO));
    }

    function test_addProtocolToWhitelist_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Rebalancer.ProtocolWhitelisted(MORPHO);
        vm.prank(owner);
        rebalancer.addProtocolToWhitelist(MORPHO);
    }

    function test_removeProtocolFromWhitelist_unsetsMapping() public {
        vm.prank(owner);
        rebalancer.removeProtocolFromWhitelist(AAVE);
        assertFalse(rebalancer.whitelistedProtocols(AAVE));
    }

    function test_removeProtocolFromWhitelist_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Rebalancer.ProtocolRemovedFromWhitelist(AAVE);
        vm.prank(owner);
        rebalancer.removeProtocolFromWhitelist(AAVE);
    }

    function test_whitelist_revert_notAuthorized() public {
        vm.startPrank(attacker);
        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        rebalancer.addChainToWhitelist(9999);

        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        rebalancer.removeChainFromWhitelist(chainSelector);

        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        rebalancer.addProtocolToWhitelist(MORPHO);

        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        rebalancer.removeProtocolFromWhitelist(AAVE);
        vm.stopPrank();
    }

    function test_agentConsumer_canManageWhitelist() public {
        // agentConsumer is also authorized
        vm.prank(agentConsumer);
        rebalancer.addChainToWhitelist(9999);
        assertTrue(rebalancer.whitelistedChains(9999));
    }

    // =========================================================================
    // rebalance — happy path
    // =========================================================================

    function test_rebalance_happyPath_sourceDecreases() public {
        vm.prank(owner);
        rebalancer.rebalance(AAVE, COMPOUND, 2_000e6, chainSelector);
        assertEq(aaveAdapter.totalAssets(), 3_000e6);
    }

    function test_rebalance_happyPath_targetIncreases() public {
        vm.prank(owner);
        rebalancer.rebalance(AAVE, COMPOUND, 2_000e6, chainSelector);
        assertEq(compoundAdapter.totalAssets(), 2_000e6);
    }

    function test_rebalance_updatesLastRebalanceTimestamp() public {
        uint256 before = rebalancer.lastRebalanceTimestamp();
        vm.prank(owner);
        rebalancer.rebalance(AAVE, COMPOUND, 2_000e6, chainSelector);
        assertGt(rebalancer.lastRebalanceTimestamp(), before);
    }

    function test_rebalance_cooldownTriggersAfterSuccess() public {
        vm.prank(owner);
        rebalancer.rebalance(AAVE, COMPOUND, 2_000e6, chainSelector);

        // immediately after — should revert
        vm.prank(owner);
        vm.expectRevert(Rebalancer.CooldownNotElapsed.selector);
        rebalancer.rebalance(AAVE, COMPOUND, 1_000e6, chainSelector);
    }

    function test_rebalance_succeedsAfterCooldownElapsed() public {
        vm.prank(owner);
        rebalancer.rebalance(AAVE, COMPOUND, 2_000e6, chainSelector);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(owner);
        rebalancer.rebalance(COMPOUND, AAVE, 1_000e6, chainSelector);

        assertEq(compoundAdapter.totalAssets(), 1_000e6);
        assertEq(aaveAdapter.totalAssets(), 4_000e6);
    }

    function test_rebalance_agentConsumerCanCall() public {
        vm.prank(agentConsumer);
        rebalancer.rebalance(AAVE, COMPOUND, 2_000e6, chainSelector);
        assertEq(compoundAdapter.totalAssets(), 2_000e6);
    }

    // =========================================================================
    // rebalance — revert paths
    // =========================================================================

    function test_rebalance_revert_notAuthorized() public {
        vm.prank(attacker);
        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        rebalancer.rebalance(AAVE, COMPOUND, 1_000e6, chainSelector);
    }

    function test_rebalance_revert_cooldownNotElapsed() public {
        vm.prank(owner);
        rebalancer.rebalance(AAVE, COMPOUND, 1_000e6, chainSelector);

        vm.prank(owner);
        vm.expectRevert(Rebalancer.CooldownNotElapsed.selector);
        rebalancer.rebalance(AAVE, COMPOUND, 1_000e6, chainSelector);
    }

    function test_rebalance_revert_sourceEqualsTarget() public {
        vm.prank(owner);
        vm.expectRevert(Rebalancer.SourceEqualsTarget.selector);
        rebalancer.rebalance(AAVE, AAVE, 1_000e6, chainSelector);
    }

    function test_rebalance_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(Rebalancer.ZeroAmount.selector);
        rebalancer.rebalance(AAVE, COMPOUND, 0, chainSelector);
    }

    function test_rebalance_revert_chainNotWhitelisted() public {
        uint64 unknownSelector = 9999;
        vm.prank(owner);
        vm.expectRevert(Rebalancer.ChainNotWhitelisted.selector);
        rebalancer.rebalance(AAVE, COMPOUND, 1_000e6, unknownSelector);
    }

    function test_rebalance_revert_sourceProtocolNotWhitelisted() public {
        vm.prank(owner);
        vm.expectRevert(Rebalancer.ProtocolNotWhitelisted.selector);
        rebalancer.rebalance(MORPHO, COMPOUND, 1_000e6, chainSelector);
    }

    function test_rebalance_revert_targetProtocolNotWhitelisted() public {
        vm.prank(owner);
        vm.expectRevert(Rebalancer.ProtocolNotWhitelisted.selector);
        rebalancer.rebalance(AAVE, MORPHO, 1_000e6, chainSelector);
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_constructor_revert_zeroHub() public {
        vm.expectRevert(Rebalancer.InvalidConstructorArguments.selector);
        new Rebalancer(address(0), agentConsumer, owner);
    }

    function test_constructor_revert_zeroAgentConsumer() public {
        vm.expectRevert(Rebalancer.InvalidConstructorArguments.selector);
        new Rebalancer(address(hub), address(0), owner);
    }

    function test_constructor_revert_zeroOwner() public {
        vm.expectRevert(Rebalancer.InvalidConstructorArguments.selector);
        new Rebalancer(address(hub), agentConsumer, address(0));
    }
}
