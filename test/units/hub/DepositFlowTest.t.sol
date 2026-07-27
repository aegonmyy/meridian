// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "./BaseHubTest.t.sol";
import {MockYieldSource} from "../../mocks/mockYield.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {NotRebalancer, SpokeNotFound} from "../../../src/errors/hubErrors.sol";

/// @notice Tests for sendToSpoke DEPOSIT flow and yield reporting
contract DepositFlowTest is BaseHubTest {

    // =========================================================================
    // sendToSpoke, DEPOSIT flow
    // Hub sends USDC + instructions to spoke via CCIP
    // Spoke deposits into adapter, sends CONFIRM_RECEIPT back
    // =========================================================================

    function test_sendToSpoke_spokeReceivesAndDepositsToAdapter() public {
        // send 5_000 of alice's 10_000 deposit to spoke
        // spoke should deposit it into aave adapter
        _sendToSpoke(5_000e6);
        assertEq(aaveAdapter.totalAssets(), 5_000e6);
    }

    function test_sendToSpoke_confirmReceiptUpdatesSpokeBalances() public {
        // after CONFIRM_RECEIPT arrives hub should know spoke has 5_000
        _sendToSpoke(5_000e6);
        assertEq(hub.spokeBalances(chainSelector), 5_000e6);
    }

    function test_sendToSpoke_decrementsInTransitAfterConfirm() public {
        // inTransit incremented on send, decremented on CONFIRM_RECEIPT
        // since CCIP is synchronous in simulator both happen atomically
        _sendToSpoke(5_000e6);
        assertEq(hub.inTransitAssets(), 0);
    }

    function test_sendToSpoke_totalAssetsUnchangedAfterRoundTrip() public {
        // capital moved from idle to spoke, totalAssets unchanged
        uint256 totalBefore = hub.totalAssets();
        _sendToSpoke(5_000e6);
        assertEq(hub.totalAssets(), totalBefore);
    }

    function test_sendToSpoke_multipleInstructions() public {
        // register compound adapter
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 compound = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(compound, address(compoundAdapter));

        // send 3_000 to aave and 2_000 to compound in one message
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](2);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 3_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        instructions[1] = CCIPHelpers.AdapterInstructions({
            adapter: compound,
            amount: 2_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, instructions);

        assertEq(aaveAdapter.totalAssets(), 3_000e6);
        assertEq(compoundAdapter.totalAssets(), 2_000e6);
        assertEq(hub.spokeBalances(chainSelector), 5_000e6);
    }

    function test_sendToSpoke_revert_notRebalancer() public {
        vm.prank(alice);
        vm.expectRevert(NotRebalancer.selector);
        hub.sendToSpoke(chainSelector, _buildInstructions(AAVE, 1_000e6));
    }

    function test_sendToSpoke_revert_spokeNotFound() public {
        vm.prank(rebalancer);
        vm.expectRevert(SpokeNotFound.selector);
        hub.sendToSpoke(9999, _buildInstructions(AAVE, 1_000e6));
    }

    // =========================================================================
    // Yield flow, REPORT_BALANCE and CONFIRM_RECEIPT carry spoke balance
    // =========================================================================

    function test_confirmReceipt_spokeBalanceEqualsDepositAmount() public {
        // CONFIRM_RECEIPT reports balance at time of deposit, no yield yet
        _sendToSpoke(5_000e6);
        assertEq(hub.spokeBalances(chainSelector), 5_000e6);
    }

    function test_reportBalance_includesYield() public {
        // yield accrues on adapter after deposit
        // REPORT_BALANCE should include it
        _sendToSpoke(5_000e6);
        aaveAdapter.simulateYield(200e6);
        _triggerReportBalance();
        assertEq(hub.spokeBalances(chainSelector), 5_000e6 + 200e6);
    }

    function test_totalAssets_reflectsYieldAfterReportBalance() public {
        // hub sent 5_000 to spoke, 5_000 remains idle
        // after yield + report: totalAssets = 5_000 idle + 5_300 spoke
        _sendToSpoke(5_000e6);
        aaveAdapter.simulateYield(300e6);
        _triggerReportBalance();
        assertEq(hub.totalAssets(), 5_000e6 + 5_300e6);
    }

    function test_reportBalance_matchesConfirmReceiptWhenNoYield() public {
        // no yield between deposit and report: balances should match
        _sendToSpoke(5_000e6);
        uint256 balanceAfterDeposit = hub.spokeBalances(chainSelector);
        _triggerReportBalance();
        assertEq(hub.spokeBalances(chainSelector), balanceAfterDeposit);
    }

    function test_reportBalance_differsFromConfirmReceiptWhenYieldAccrued()
        public
    {
        // yield accrued between deposit and report: report should be higher
        _sendToSpoke(5_000e6);
        uint256 balanceAfterDeposit = hub.spokeBalances(chainSelector);
        aaveAdapter.simulateYield(150e6);
        _triggerReportBalance();
        assertGt(hub.spokeBalances(chainSelector), balanceAfterDeposit);
        assertEq(hub.spokeBalances(chainSelector) - balanceAfterDeposit, 150e6);
    }

    function test_lastReportTimestamp_updatedByConfirmReceipt() public {
        _sendToSpoke(5_000e6);
        assertGt(hub.lastReportTimestamp(chainSelector), 0);
    }

    function test_lastReportTimestamp_updatedByReportBalance() public {
        _sendToSpoke(5_000e6);
        uint256 timestampAfterDeposit = hub.lastReportTimestamp(chainSelector);
        vm.warp(block.timestamp + 30 minutes);
        _triggerReportBalance();
        assertGt(hub.lastReportTimestamp(chainSelector), timestampAfterDeposit);
    }

    function test_inTransitAssets_decrementedAfterConfirmReceipt() public {
        assertEq(hub.inTransitAssets(), 0);
        _sendToSpoke(5_000e6);
        // CCIP synchronous, CONFIRM_RECEIPT already fired
        assertEq(hub.inTransitAssets(), 0);
    }

    function test_accountingIdentity_holdsThroughout() public {
        // identity: totalAssets == idle + inTransit + spokeBalances
        // must hold before, during, and after all operations
        assertEq(
            hub.totalAssets(),
            usdc.balanceOf(address(hub)) +
                hub.inTransitAssets() +
                hub.spokeBalances(chainSelector)
        );

        _sendToSpoke(5_000e6);

        assertEq(
            hub.totalAssets(),
            usdc.balanceOf(address(hub)) +
                hub.inTransitAssets() +
                hub.spokeBalances(chainSelector)
        );

        aaveAdapter.simulateYield(100e6);
        _triggerReportBalance();

        assertEq(
            hub.totalAssets(),
            usdc.balanceOf(address(hub)) +
                hub.inTransitAssets() +
                hub.spokeBalances(chainSelector)
        );
    }
}
