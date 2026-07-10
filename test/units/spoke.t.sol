// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {SpokeStorage} from "../../src/spoke/SpokeStorage.sol";
//removed BurnMintERC677Helper
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {ZeroAddress, AdapterNotFound} from "../../src/errors/spokeErrors.sol";

contract spokeTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    // ── Contracts ─────────────────────────────────────────────────────────
    SpokeVault public spoke;
    Asset public usdc;
    MockYieldSource public aaveAdapter;
    MockYieldSource public compoundAdapter;
    MockYieldSource public morphoAdapter;

    // ── Actors ────────────────────────────────────────────────────────────
    address public hub;
    address public owner;
    address public alice;
    address public attacker;

    // ── Protocol IDs ──────────────────────────────────────────────────────
    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");
    bytes32 public constant MORPHO = keccak256("MORPHO");

    // ── Hub chain selector (mock) ──────────────────────────────────────────
    uint64 public constant HUB_CHAIN_SELECTOR = 5009297550715157269; // Ethereum mainnet

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        // Actors
        hub = makeAddr("hub");
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        // CCIP local simulator
        ccipSimulator = new CCIPLocalSimulator();
        (chainSelector, router,,, link,,) = ccipSimulator.configuration();

        // Deploy mock USDC
        usdc = new Asset();

        // Fund hub and alice with USDC
        usdc.mint(hub, 1_000_000e6);
        usdc.mint(alice, 10_000e6);

        // Fund spoke with LINK for CCIP fees
        // (done after spoke deployment below)

        // Deploy SpokeVault
        vm.prank(owner);
        spoke = new SpokeVault(hub, address(usdc), address(router), owner, address(link), HUB_CHAIN_SELECTOR);

        // Fund spoke with LINK
        deal(address(link), address(spoke), 10 ether);

        // Deploy mock adapters
        aaveAdapter = new MockYieldSource(address(usdc));
        compoundAdapter = new MockYieldSource(address(usdc));
        morphoAdapter = new MockYieldSource(address(usdc));
    }

    function test_setAdapter_newAdapter() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        (IYieldSource adapter, bool exists,) = spoke.adapters(AAVE);
        assertTrue(exists);
        assertEq(address(adapter), address(aaveAdapter));
        assertTrue(_isInActiveAdapters(AAVE));
        assertEq(spoke.activeAdaptersLength(), 1);
    }

    function test_setAdapter_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit SpokeStorage.AdapterSet(AAVE, address(aaveAdapter));
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
    }

    function test_setAdapter_updateExisting() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        MockYieldSource newAave = new MockYieldSource(address(usdc));
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(newAave));
        (IYieldSource adapter, bool exists,) = spoke.adapters(AAVE);
        assertTrue(exists);
        assertEq(address(adapter), address(newAave));
        assertEq(spoke.activeAdaptersLength(), 1); // no duplicate
    }

    function test_setAdapter_updateExisting_oldAddressGone() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        MockYieldSource newAave = new MockYieldSource(address(usdc));
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(newAave));
        (IYieldSource adapter,,) = spoke.adapters(AAVE);
        assertNotEq(address(adapter), address(aaveAdapter));
    }

    function test_setAdapter_afterRemove_noDuplicate() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.removeAdapter(AAVE);
        spoke.setAdapter(AAVE, address(compoundAdapter)); // re-register
        vm.stopPrank();
        assertEq(spoke.activeAdaptersLength(), 1); // no duplicate
        assertTrue(_isInActiveAdapters(AAVE));
        (, bool exists,) = spoke.adapters(AAVE);
        assertTrue(exists);
    }

    function test_setAdapter_multipleAdapters() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        spoke.setAdapter(MORPHO, address(morphoAdapter));
        vm.stopPrank();
        assertEq(spoke.activeAdaptersLength(), 3);
        assertTrue(_isInActiveAdapters(AAVE));
        assertTrue(_isInActiveAdapters(COMPOUND));
        assertTrue(_isInActiveAdapters(MORPHO));
    }

    function test_setAdapter_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        spoke.setAdapter(AAVE, address(0));
    }

    function test_setAdapter_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        spoke.setAdapter(AAVE, address(aaveAdapter));
    }

    // =========================================================================
    // removeAdapter Tests
    // =========================================================================
    function test_removeAdapter_setsExistsFalse() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.removeAdapter(AAVE);
        vm.stopPrank();
        (, bool exists,) = spoke.adapters(AAVE);
        assertFalse(exists);
    }

    function test_removeAdapter_zerosAdapterAddress() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.removeAdapter(AAVE);
        vm.stopPrank();
        (IYieldSource adapter,,) = spoke.adapters(AAVE);
        assertEq(address(adapter), address(0));
    }

    function test_removeAdapter_emitsEvent() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        vm.expectEmit(true, false, false, false);
        emit SpokeStorage.AdapterRemoved(AAVE);
        vm.prank(owner);
        spoke.removeAdapter(AAVE);
    }

    function test_removeAdapter_arrayLengthUnchanged() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        uint256 lengthBefore = spoke.activeAdaptersLength();
        spoke.removeAdapter(AAVE);
        vm.stopPrank();
        assertEq(spoke.activeAdaptersLength(), lengthBefore);
    }

    function test_removeAdapter_revert_notExists() public {
        vm.prank(owner);
        vm.expectRevert(AdapterNotFound.selector);
        spoke.removeAdapter(AAVE);
    }

    function test_removeAdapter_revert_alreadyRemoved() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.removeAdapter(AAVE);
        vm.expectRevert(AdapterNotFound.selector);
        spoke.removeAdapter(AAVE);
        vm.stopPrank();
    }

    function test_removeAdapter_revert_notOwner() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        vm.prank(attacker);
        vm.expectRevert();
        spoke.removeAdapter(AAVE);
    }

    function test_removeAdapter_reAdd_existsAgain() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.removeAdapter(AAVE);
        spoke.setAdapter(AAVE, address(compoundAdapter));
        vm.stopPrank();
        (, bool exists,) = spoke.adapters(AAVE);
        assertTrue(exists);
        assertEq(spoke.activeAdaptersLength(), 1); // no duplicate
    }

    function test_removeAdapter_othersUnaffected() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        spoke.removeAdapter(AAVE);
        vm.stopPrank();
        (, bool compoundExists,) = spoke.adapters(COMPOUND);
        assertTrue(compoundExists);
        assertTrue(_isInActiveAdapters(COMPOUND));
    }

    /// @dev Returns true if protocolId is present in activeAdapters array
    function _isInActiveAdapters(bytes32 id) internal view returns (bool) {
        uint256 length = spoke.activeAdaptersLength();
        for (uint256 i = 0; i < length; i++) {
            if (spoke.activeAdapters(i) == id) return true;
        }
        return false;
    }
}
