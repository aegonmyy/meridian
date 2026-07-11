// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {HUB} from "../../src/Hub.sol";
import {HubStorage} from "../../src/hub/HubStorage.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {Asset} from "../mocks/Asset.sol";
//import {MockYieldSource} from "../mocks/mockYield.sol";
import {ZeroAddress, SpokeNotFound} from "../../src/errors/hubErrors.sol";

contract HUBTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    HUB public hub;
    Asset public usdc;

    address public owner;
    address public rebalancer;
    address public alice;
    address public attacker;

    uint64 public constant ARBITRUM_SELECTOR = 4949039107694359620;
    uint64 public constant BASE_SELECTOR = 15971525489660198786;
    uint64 public constant OPTIMISM_SELECTOR = 3734403246176062136;

    address public arbitrumSpoke;
    address public baseSpoke;
    address public optimismSpoke;

    function setUp() public {
        owner = makeAddr("owner");
        rebalancer = makeAddr("rebalancer");
        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        arbitrumSpoke = makeAddr("arbitrumSpoke");
        baseSpoke = makeAddr("baseSpoke");
        optimismSpoke = makeAddr("optimismSpoke");

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

        deal(address(link), address(hub), 10 ether);
        usdc.mint(alice, 10_000e6);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _isInSpokeSelectors(uint64 selector) internal view returns (bool) {
        uint256 length = hub.spokeChainSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            if (hub.spokeChainSelectors(i) == selector) return true;
        }
        return false;
    }

    function test_addSpoke_sequence() public {
        address spokeD = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        address spokeE = address(0x00000000000000000000000000000000000007e8);

        vm.startPrank(owner);
        hub.addSpoke(1, makeAddr("spokeA"));
        hub.addSpoke(40526627, makeAddr("spokeB"));
        hub.addSpoke(23804626, makeAddr("spokeC"));
        hub.addSpoke(3600, spokeD);
        hub.removeSpoke(3600);
        hub.addSpoke(10000, spokeD);
        hub.addSpoke(3600, spokeE);
        vm.stopPrank();

        // spokeD is registered under selector 10000 with exists = true
        // isValidSpoke[spokeD] must be true
        assertTrue(hub.isValidSpoke(spokeD), "spokeD should be valid");
    }

    // =========================================================================
    // addSpoke Tests
    // =========================================================================

    function test_addSpoke_newSpoke() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        (address spoke, bool exists, ) = hub.spokes(ARBITRUM_SELECTOR);
        assertTrue(exists);
        assertEq(spoke, arbitrumSpoke);
        assertTrue(hub.isValidSpoke(arbitrumSpoke));
        assertTrue(_isInSpokeSelectors(ARBITRUM_SELECTOR));
        assertEq(hub.spokeChainSelectorsLength(), 1);
    }

    function test_addSpoke_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit HubStorage.SpokeAdded(ARBITRUM_SELECTOR, arbitrumSpoke);

        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
    }

    function test_addSpoke_updateExisting() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        address newSpoke = makeAddr("newArbitrumSpoke");
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, newSpoke);

        (address spoke, bool exists, ) = hub.spokes(ARBITRUM_SELECTOR);
        assertTrue(exists);
        assertEq(spoke, newSpoke);
        assertTrue(hub.isValidSpoke(newSpoke));
        assertEq(hub.spokeChainSelectorsLength(), 1);
    }

    function test_addSpoke_updateExisting_oldAddressInvalidated() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        address newSpoke = makeAddr("newArbitrumSpoke");
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, newSpoke);

        assertFalse(hub.isValidSpoke(arbitrumSpoke));
    }

    function test_addSpoke_multipleSpokes() public {
        vm.startPrank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
        hub.addSpoke(BASE_SELECTOR, baseSpoke);
        hub.addSpoke(OPTIMISM_SELECTOR, optimismSpoke);
        vm.stopPrank();

        assertEq(hub.spokeChainSelectorsLength(), 3);
        assertTrue(_isInSpokeSelectors(ARBITRUM_SELECTOR));
        assertTrue(_isInSpokeSelectors(BASE_SELECTOR));
        assertTrue(_isInSpokeSelectors(OPTIMISM_SELECTOR));
    }

    function test_addSpoke_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        hub.addSpoke(ARBITRUM_SELECTOR, address(0));
    }

    function test_addSpoke_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
    }

    // =========================================================================
    // removeSpoke Tests
    // =========================================================================

    function test_removeSpoke_setsExistsFalse() public {
        vm.startPrank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
        hub.removeSpoke(ARBITRUM_SELECTOR);
        vm.stopPrank();

        (, bool exists, ) = hub.spokes(ARBITRUM_SELECTOR);
        assertFalse(exists);
    }

    function test_removeSpoke_invalidatesAddress() public {
        vm.startPrank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
        hub.removeSpoke(ARBITRUM_SELECTOR);
        vm.stopPrank();

        assertFalse(hub.isValidSpoke(arbitrumSpoke));
    }

    function test_removeSpoke_emitsEvent() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        vm.expectEmit(true, false, false, false);
        emit HubStorage.SpokeRemoved(ARBITRUM_SELECTOR);

        vm.prank(owner);
        hub.removeSpoke(ARBITRUM_SELECTOR);
    }

    function test_removeSpoke_arrayLengthUnchanged() public {
        vm.startPrank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
        hub.addSpoke(BASE_SELECTOR, baseSpoke);
        uint256 lengthBefore = hub.spokeChainSelectorsLength();
        hub.removeSpoke(ARBITRUM_SELECTOR);
        vm.stopPrank();

        assertEq(hub.spokeChainSelectorsLength(), lengthBefore);
    }

    function test_removeSpoke_othersUnaffected() public {
        vm.startPrank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
        hub.addSpoke(BASE_SELECTOR, baseSpoke);
        hub.removeSpoke(ARBITRUM_SELECTOR);
        vm.stopPrank();

        (, bool baseExists, ) = hub.spokes(BASE_SELECTOR);
        assertTrue(baseExists);
        assertTrue(hub.isValidSpoke(baseSpoke));
    }

    function test_removeSpoke_revert_notExists() public {
        vm.prank(owner);
        vm.expectRevert(SpokeNotFound.selector);
        hub.removeSpoke(ARBITRUM_SELECTOR);
    }

    function test_removeSpoke_revert_alreadyRemoved() public {
        vm.startPrank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);
        hub.removeSpoke(ARBITRUM_SELECTOR);
        vm.expectRevert(SpokeNotFound.selector);
        hub.removeSpoke(ARBITRUM_SELECTOR);
        vm.stopPrank();
    }

    function test_removeSpoke_revert_notOwner() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        vm.prank(attacker);
        vm.expectRevert();
        hub.removeSpoke(ARBITRUM_SELECTOR);
    }

    // =========================================================================
    // Deposit Tests
    // =========================================================================

    function test_deposit_mintsShares() public {
        uint256 assets = 1000e6;
        vm.startPrank(alice);
        usdc.approve(address(hub), assets);
        uint256 shares = hub.deposit(assets, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(hub.balanceOf(alice), shares);
    }

    function test_deposit_correctShareAmount() public {
        uint256 assets = 1000e6;
        uint256 expectedShares = hub.previewDeposit(assets);

        vm.startPrank(alice);
        usdc.approve(address(hub), assets);
        uint256 actualShares = hub.deposit(assets, alice);
        vm.stopPrank();

        assertEq(actualShares, expectedShares);
    }

    function test_deposit_updatesTotalAssets() public {
        uint256 assets = 1000e6;

        vm.startPrank(alice);
        usdc.approve(address(hub), assets);
        hub.deposit(assets, alice);
        vm.stopPrank();

        assertEq(hub.totalAssets(), assets);
    }

    function test_deposit_transfersUSDC() public {
        uint256 assets = 1000e6;
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(hub), assets);
        hub.deposit(assets, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore - assets);
        assertEq(usdc.balanceOf(address(hub)), assets);
    }

    function test_deposit_multipleDepositors() public {
        address bob = makeAddr("bob");
        usdc.mint(bob, 10_000e6);

        vm.startPrank(alice);
        usdc.approve(address(hub), 1000e6);
        hub.deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(hub), 2000e6);
        hub.deposit(2000e6, bob);
        vm.stopPrank();

        assertEq(hub.totalAssets(), 3000e6);
        assertGt(hub.balanceOf(alice), 0);
        assertGt(hub.balanceOf(bob), 0);
        assertGt(hub.balanceOf(bob), hub.balanceOf(alice)); // bob deposited more
    }

    function test_deposit_revert_insufficientAllowance() public {
        vm.startPrank(alice);
        // no approval
        vm.expectRevert();
        hub.deposit(1000e6, alice);
        vm.stopPrank();
    }
}
