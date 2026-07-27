// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "./BaseHubTest.t.sol";
import {MockYieldSource} from "../../mocks/mockYield.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {NotRebalancer, SpokeNotFound} from "../../../src/errors/hubErrors.sol";

/// @notice Tests for hub.rebalance, intra-spoke capital movement
/// Hub sends REBALANCE message to spoke via CCIP
/// Spoke withdraws from source adapter and deposits into target adapter
/// No tokens leave the chain, hub USDC and inTransitAssets unchanged
contract RebalanceTest is BaseHubTest {

    function test_rebalance_sourceAdapterDecreases() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);
        assertEq(aaveAdapter.totalAssets(), 5_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(aaveAdapter.totalAssets(), 3_000e6);
    }

    function test_rebalance_targetAdapterIncreases() public {
        (MockYieldSource compoundAdapter, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(compoundAdapter.totalAssets(), 2_000e6);
    }

    function test_rebalance_totalSpokeBalanceUnchanged() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);
        uint256 spokeBalanceBefore = hub.spokeBalances(chainSelector);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(hub.spokeBalances(chainSelector), spokeBalanceBefore);
    }

    function test_rebalance_spokeBalancesUpdatedByConfirmReceipt() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertGt(hub.lastReportTimestamp(chainSelector), 0);
        assertEq(hub.spokeBalances(chainSelector), 5_000e6);
    }

    function test_rebalance_totalAssetsUnchanged() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);
        uint256 totalBefore = hub.totalAssets();

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(hub.totalAssets(), totalBefore);
    }

    function test_rebalance_noTokensLeaveSpokeChain() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);
        uint256 hubUSDCBefore = usdc.balanceOf(address(hub));

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(usdc.balanceOf(address(hub)), hubUSDCBefore);
    }

    function test_rebalance_noTokensAttached_inTransitStaysZero() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);
        assertEq(hub.inTransitAssets(), 0);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(hub.inTransitAssets(), 0);
    }

    function test_rebalance_noTokensAttached_hubUSDCUnchanged() public {
        (, bytes32 COMPOUND) = _deployCompoundAdapter();

        _sendToSpoke(5_000e6);
        uint256 hubUSDCBefore = usdc.balanceOf(address(hub));

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions);

        assertEq(usdc.balanceOf(address(hub)), hubUSDCBefore);
    }

    function test_rebalance_revert_notRebalancer() public {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 1_000e6,
            targetAdapter: keccak256("COMPOUND"),
            targetAmount: 0
        });

        vm.prank(alice);
        vm.expectRevert(NotRebalancer.selector);
        hub.rebalance(chainSelector, instructions);
    }

    function test_rebalance_revert_spokeNotFound() public {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 1_000e6,
            targetAdapter: keccak256("COMPOUND"),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        vm.expectRevert(SpokeNotFound.selector);
        hub.rebalance(9999, instructions);
    }

    function test_rebalance_revert_removedSpoke() public {
        vm.prank(owner);
        hub.removeSpoke(chainSelector);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 1_000e6,
            targetAdapter: keccak256("COMPOUND"),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        vm.expectRevert(SpokeNotFound.selector);
        hub.rebalance(chainSelector, instructions);
    }
}
