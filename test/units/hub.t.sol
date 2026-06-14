// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {HUB} from "../../src/Hub.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {Asset} from "../mocks/Asset.sol";
//import {MockYieldSource} from "../mocks/mockYield.sol";
import {ZeroAddress, SpokeNotFound} from "../../src/errors/hubErrors.sol";

contract HubVaultTest is Test {
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

    // =========================================================================
    // addSpoke Tests
    // =========================================================================

    function test_addSpoke_newSpoke() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        (address spoke, bool exists, ) = hub.spokes(ARBITRUM_SELECTOR);
        assertTrue(exists);
        assertEq(spoke, arbitrumSpoke);
        assertTrue(_isInSpokeSelectors(ARBITRUM_SELECTOR));
        assertEq(hub.spokeChainSelectorsLength(), 1);
    }

    function test_addSpoke_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit HUB.SpokeAdded(ARBITRUM_SELECTOR, arbitrumSpoke);

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
        assertEq(hub.spokeChainSelectorsLength(), 1);
    }

    function test_addSpoke_updateExisting_oldAddressInvalidated() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        address newSpoke = makeAddr("newArbitrumSpoke");
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, newSpoke);
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
    }

    function test_removeSpoke_emitsEvent() public {
        vm.prank(owner);
        hub.addSpoke(ARBITRUM_SELECTOR, arbitrumSpoke);

        vm.expectEmit(true, false, false, false);
        emit HUB.SpokeRemoved(ARBITRUM_SELECTOR);

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
}
