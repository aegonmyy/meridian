// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "../units/hub/BaseHubTest.t.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {CCIPHelpers} from "../../src/libraries/CCIPHelpers.sol";

/// @notice WI-2 regressions — spoke resilience: idle accounting, capped pulls,
///         defensive fund-touching handlers.
contract WI2_SpokeResilienceTest is BaseHubTest {
    /// @notice Pre-fix: a DEPOSIT instruction referencing a removed adapter hard-reverts
    /// the whole CCIP execution, stranding the entire deposit amount in CCIP limbo
    /// (the simulator surfaces this as the outer sendToSpoke call reverting, since routing
    /// is synchronous). Post-fix: the bad instruction is skipped, its amount stays as spoke
    /// idle, and the confirm still lands with the truthful aggregate.
    function test_wi2_deposit_removedAdapter_doesNotRevertWholeMessage() public {
        vm.prank(owner);
        spoke.removeAdapter(AAVE);

        // must not revert
        _sendToSpoke(5_000e6);

        // funds counted via aggregated balance (idle-inclusive after WI-2b)
        assertEq(hub.spokeBalances(chainSelector), 5_000e6);
    }

    /// @notice Pre-fix: exact-full recall across two adapters can revert on dust /
    /// rounding overflow in the proportional pull loop. Post-fix: min-capped pulls
    /// guarantee the recall always succeeds up to the real available balance.
    function test_wi2_recall_exactFullAcrossTwoAdapters_succeeds() public {
        (MockYieldSource compoundAdapter, bytes32 COMPOUND) = _deployCompoundAdapter();

        // deposit odd amounts across two adapters to create rounding dust potential
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](2);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 3_333_333333, // 3_333.333333 USDC
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        instructions[1] = CCIPHelpers.AdapterInstructions({
            adapter: COMPOUND,
            amount: 1_666_666667,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        uint256 totalDeployed = aaveAdapter.totalAssets() +
            compoundAdapter.totalAssets();

        bytes32 messageId = _generateMessageId(address(hub));
        // full exact recall — must not revert
        _recallFromSpoke(totalDeployed, messageId);

        assertEq(aaveAdapter.totalAssets(), 0);
        assertEq(compoundAdapter.totalAssets(), 0);
    }

    /// @notice Pre-fix: a recall for more than adapters actually hold either reverts or
    /// silently attaches the over-requested amount as the CCIP token amount (which would
    /// fail token transfer). Post-fix: the spoke pulls what it can and truthfully reports
    /// actualPulled via the token envelope — hub accounting reflects reality, not the ask.
    function test_wi2_recall_exceedingRealBalance_returnsPartialTruthfully() public {
        _sendToSpoke(5_000e6); // hub idle 5_000e6 remains, spoke/Aave holds 5_000e6

        uint256 hubIdleBefore = usdc.balanceOf(address(hub));
        uint256 available = aaveAdapter.totalAssets(); // 5_000e6
        uint256 requested = available + 2_000e6; // ask for more than exists

        bytes32 messageId = _generateMessageId(address(hub));
        // must not revert — degrades to partial recall
        _recallFromSpoke(requested, messageId);

        // hub only actually received what was truthfully available
        assertEq(usdc.balanceOf(address(hub)), hubIdleBefore + available);
        assertEq(aaveAdapter.totalAssets(), 0);
    }

    /// @notice Pre-fix: _aggregatedSpokeBalance sums adapter totals only — a direct USDC
    /// transfer to the spoke (e.g. leftover idle from a partial deploy) is invisible to
    /// the hub's accounting. Post-fix: idle is first-class in the aggregate.
    function test_wi2_aggregatedSpokeBalance_countsDirectTransfer() public {
        // simulate idle sitting on spoke (e.g. from a prior deployIdle-eligible state)
        usdc.mint(address(spoke), 1_234e6);

        _triggerReportBalance();

        assertEq(hub.spokeBalances(chainSelector), 1_234e6);
    }
}
