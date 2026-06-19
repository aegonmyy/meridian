// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";

// =========================================================================
// getAllocations Tests
// Returns AdapterBalances[] — one entry per registered adapter
// Includes inactive adapters as zero-initialized entries
// Array length always equals activeAdapters.length
// =========================================================================

contract GetAllocationsTest is Test {
    SpokeVault public spoke;
    Asset public usdc;
    MockYieldSource public aaveAdapter;
    MockYieldSource public compoundAdapter;
    MockYieldSource public morphoAdapter;

    address public owner;

    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");
    bytes32 public constant MORPHO = keccak256("MORPHO");

    function setUp() public {
        owner = makeAddr("owner");
        usdc = new Asset();

        vm.prank(owner);
        spoke = new SpokeVault(
            makeAddr("hub"),
            address(usdc),
            makeAddr("router"),
            owner,
            makeAddr("link"),
            16015286601757825753
        );

        aaveAdapter = new MockYieldSource(address(usdc));
        compoundAdapter = new MockYieldSource(address(usdc));
        morphoAdapter = new MockYieldSource(address(usdc));
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _depositIntoAdapter(
        MockYieldSource adapter,
        uint256 amount
    ) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount);
    }

    // ── tests ─────────────────────────────────────────────────────────────

    function test_getAllocations_emptyWhenNoAdapters() public view {
        // no adapters registered — returns empty array
        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();
        assertEq(result.length, 0);
    }

    function test_getAllocations_singleAdapter_correctBalance() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));

        // deposit into adapter
        _depositIntoAdapter(aaveAdapter, 5_000e6);

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        assertEq(result.length, 1);
        assertEq(result[0].protocolId, AAVE);
        assertEq(result[0].balance, 5_000e6);
    }

    function test_getAllocations_multipleAdapters_allBalancesCorrect() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        spoke.setAdapter(MORPHO, address(morphoAdapter));
        vm.stopPrank();

        _depositIntoAdapter(aaveAdapter, 3_000e6);
        _depositIntoAdapter(compoundAdapter, 2_000e6);
        _depositIntoAdapter(morphoAdapter, 1_000e6);

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        assertEq(result.length, 3);
        assertEq(result[0].balance, 3_000e6);
        assertEq(result[1].balance, 2_000e6);
        assertEq(result[2].balance, 1_000e6);
    }

    function test_getAllocations_reflectsYield() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));

        _depositIntoAdapter(aaveAdapter, 5_000e6);

        // simulate yield
        aaveAdapter.simulateYield(200e6);

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        assertEq(result[0].balance, 5_200e6);
    }

    function test_getAllocations_removedAdapter_zeroBalance() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        vm.stopPrank();

        _depositIntoAdapter(aaveAdapter, 3_000e6);
        _depositIntoAdapter(compoundAdapter, 2_000e6);

        // remove aave
        vm.prank(owner);
        spoke.removeAdapter(AAVE);

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        // array still length 2 — removed adapter is zero-initialized
        assertEq(result.length, 2);
        // removed adapter entry — protocolId bytes32(0) and balance 0
        assertEq(result[0].protocolId, bytes32(0));
        assertEq(result[0].balance, 0);
        // compound still correct
        assertEq(result[1].protocolId, COMPOUND);
        assertEq(result[1].balance, 2_000e6);
    }

    function test_getAllocations_zeroBalanceWhenNoDeposits() public {
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));

        // no deposits
        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        assertEq(result.length, 1);
        assertEq(result[0].protocolId, AAVE);
        assertEq(result[0].balance, 0);
    }

    function test_getAllocations_arrayLengthMatchesActiveAdapters() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        vm.stopPrank();

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        assertEq(result.length, spoke.activeAdaptersLength());
    }

    function test_getAllocations_arrayLengthUnchangedAfterRemove() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        spoke.removeAdapter(AAVE);
        vm.stopPrank();

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        // array length unchanged after remove — soft delete
        assertEq(result.length, 2);
        assertEq(result.length, spoke.activeAdaptersLength());
    }

    function test_getAllocations_reAddedAdapter_correctBalance() public {
        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.removeAdapter(AAVE);
        // re-add with new adapter
        MockYieldSource newAave = new MockYieldSource(address(usdc));
        spoke.setAdapter(AAVE, address(newAave));
        vm.stopPrank();

        _depositIntoAdapter(newAave, 4_000e6);

        SpokeVault.AdapterBalances[] memory result = spoke.getAllocations();

        // no duplicate — length still 1
        assertEq(result.length, 1);
        assertEq(result[0].protocolId, AAVE);
        assertEq(result[0].balance, 4_000e6);
    }
}
