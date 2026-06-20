// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseHubTest} from "./BaseHubTest.t.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {NotRebalancer, SpokeNotFound} from "../../../src/errors/hubErrors.sol";

/// @notice Tests for _withdraw Path 3 and recallFromSpoke
/// Path 3 — idle insufficient → recall shortfall from best spoke
/// Setup: send 9_000 to spoke, 1_000 idle remains, alice's shares worth 10_000
contract WithdrawPath3Test is BaseHubTest {

    // =========================================================================
    // _withdraw Path 3 — idle insufficient → recall from best spoke
    // =========================================================================

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

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        // spoke sent back full shortfall — spoke balance goes to 0
        assertEq(hub.spokeBalances(chainSelector), 0);
    }

    function test_withdraw_path3_totalAssetsDecreasesByWithdrawnAmount()
        public
    {
        _setupPath3();

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);
        uint256 totalBefore = hub.totalAssets();

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.totalAssets(), totalBefore - assetsToReceive);
    }

    function test_withdraw_path3_inTransitBackToZero() public {
        _setupPath3();

        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.inTransitAssets(), 0);
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

    function test_withdraw_path3_onlyRecallsShortfall() public {
        // send 9_000 to spoke — hub has 1_000 idle, spoke has 9_000
        _sendToSpoke(9_000e6);

        uint256 idleBefore = usdc.balanceOf(address(hub));
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);
        uint256 shortfall = assetsToReceive - idleBefore;

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        // spoke only sent back shortfall — remaining balance = original - shortfall
        assertEq(hub.spokeBalances(chainSelector), 9_000e6 - shortfall);
    }

    function test_withdraw_path3_reservedAssetsZeroAfterSettlement() public {
        _sendToSpoke(9_000e6);

        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.reservedAssets(), 0);
    }

    // =========================================================================
    // recallFromSpoke Tests
    // Hub sends WITHDRAW_AMOUNT to spoke via CCIP
    // Spoke pulls proportionally from adapters and sends tokens back
    // Hub receives CONFIRM_WITHDRAWAL callback and updates accounting
    // =========================================================================

    // ── Scenario 1 — no pending withdrawal ────────────────────────────────────

    function test_recallFromSpoke_hubUSDCBalanceIncreases() public {
        _sendToSpoke(5_000e6);

        uint256 hubBalanceBefore = usdc.balanceOf(address(hub));
        bytes32 messageId = _generateMessageId(address(hub));

        _recallFromSpoke(3_000e6, messageId);

        assertEq(usdc.balanceOf(address(hub)), hubBalanceBefore + 3_000e6);
    }

    function test_recallFromSpoke_spokeBalanceDecreases() public {
        _sendToSpoke(5_000e6);

        uint256 spokeBalanceBefore = hub.spokeBalances(chainSelector);
        bytes32 messageId = _generateMessageId(address(hub));

        _recallFromSpoke(3_000e6, messageId);

        assertEq(
            hub.spokeBalances(chainSelector),
            spokeBalanceBefore - 3_000e6
        );
    }

    function test_recallFromSpoke_inTransitBackToZero() public {
        _sendToSpoke(5_000e6);

        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(3_000e6, messageId);

        assertEq(hub.inTransitAssets(), 0);
    }

    function test_recallFromSpoke_totalAssetsUnchanged() public {
        _sendToSpoke(5_000e6);

        uint256 totalBefore = hub.totalAssets();
        bytes32 messageId = _generateMessageId(address(hub));

        _recallFromSpoke(3_000e6, messageId);

        assertEq(hub.totalAssets(), totalBefore);
    }

    // ── Scenario 2 — pending withdrawal exists ────────────────────────────────

    function test_recallFromSpoke_pendingWithdrawal_userReceivesUSDC() public {
        _sendToSpoke(9_000e6);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assetsToReceive);
    }

    function test_recallFromSpoke_pendingWithdrawal_sharesFullyBurned() public {
        _sendToSpoke(9_000e6);

        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(hub.balanceOf(address(hub)), 0);
    }

    function test_recallFromSpoke_pendingWithdrawal_reservedAssetsZero()
        public
    {
        _sendToSpoke(9_000e6);

        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.reservedAssets(), 0);
    }

    function test_recallFromSpoke_pendingWithdrawal_totalAssetsDecreased()
        public
    {
        _sendToSpoke(9_000e6);

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);
        uint256 totalBefore = hub.totalAssets();

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        assertEq(hub.totalAssets(), totalBefore - assetsToReceive);
    }

    // ── Revert paths ──────────────────────────────────────────────────────────

    function test_recallFromSpoke_revert_notRebalancer() public {
        _sendToSpoke(5_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: 1_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(alice);
        vm.expectRevert(NotRebalancer.selector);
        hub.recallFromSpoke(chainSelector, instructions, bytes32(0));
    }

    function test_recallFromSpoke_revert_spokeNotFound() public {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: 1_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        vm.expectRevert(SpokeNotFound.selector);
        hub.recallFromSpoke(9999, instructions, bytes32(0));
    }

    function test_recallFromSpoke_revert_removedSpoke() public {
        vm.prank(owner);
        hub.removeSpoke(chainSelector);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: 1_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        vm.expectRevert(SpokeNotFound.selector);
        hub.recallFromSpoke(chainSelector, instructions, bytes32(0));
    }

    // ── Edge cases ────────────────────────────────────────────────────────────

    function test_recallFromSpoke_partialRecall() public {
        _sendToSpoke(5_000e6);

        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(2_000e6, messageId);

        assertEq(hub.spokeBalances(chainSelector), 3_000e6);
        assertEq(aaveAdapter.totalAssets(), 3_000e6);
    }

    function test_recallFromSpoke_fullRecall() public {
        _sendToSpoke(5_000e6);

        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(5_000e6, messageId);

        assertEq(hub.spokeBalances(chainSelector), 0);
        assertEq(aaveAdapter.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(hub)), 10_000e6);
    }
}
