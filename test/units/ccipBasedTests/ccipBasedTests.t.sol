// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {Asset} from "../../mocks/Asset.sol";
import {MockYieldSource} from "../../mocks/mockYield.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {NotRebalancer, SpokeNotFound, ZeroWithdrawal} from "../../../src/errors/hubErrors.sol";

contract DepositFlowTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    HUB public hub;
    SpokeVault public spoke;
    Asset public usdc;
    MockYieldSource public aaveAdapter;

    address public owner;
    address public rebalancer;
    address public alice;

    bytes32 public constant AAVE = keccak256("AAVE");

    function setUp() public {
        owner = makeAddr("owner");
        rebalancer = makeAddr("rebalancer");
        alice = makeAddr("alice");

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
        vm.prank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));

        ccipSimulator.requestLinkFromFaucet(address(hub), 10 ether);
        ccipSimulator.requestLinkFromFaucet(address(spoke), 10 ether);

        // alice deposits — this is the ONLY way hub gets USDC
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _buildInstructions(
        bytes32 adapter,
        uint256 amount
    ) internal pure returns (CCIPHelpers.AdapterInstructions[] memory) {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: adapter,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        return instructions;
    }

    function _sendToSpoke(uint256 amount) internal {
        vm.prank(rebalancer);
        hub.sendToSpoke(chainSelector, _buildInstructions(AAVE, amount));
    }

    function _triggerReportBalance() internal {
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub._requestAllBalanceReports(messageId);
    }

    function _setSpokeBalance(uint64 selector, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(10)));
        vm.store(address(hub), slot, bytes32(amount));
    }

    function _setLastReportTimestamp(
        uint64 selector,
        uint256 timestamp
    ) internal {
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(11)));
        vm.store(address(hub), slot, bytes32(timestamp));
    }

    // =========================================================================
    // sendToSpoke — DEPOSIT flow
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
        // capital moved from idle to spoke — totalAssets unchanged
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
    // Yield flow — REPORT_BALANCE and CONFIRM_RECEIPT carry spoke balance
    // =========================================================================

    function test_confirmReceipt_spokeBalanceEqualsDepositAmount() public {
        // CONFIRM_RECEIPT reports balance at time of deposit — no yield yet
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
        // no yield between deposit and report — balances should match
        _sendToSpoke(5_000e6);
        uint256 balanceAfterDeposit = hub.spokeBalances(chainSelector);
        _triggerReportBalance();
        assertEq(hub.spokeBalances(chainSelector), balanceAfterDeposit);
    }

    function test_reportBalance_differsFromConfirmReceiptWhenYieldAccrued()
        public
    {
        // yield accrued between deposit and report — report should be higher
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
        // CCIP synchronous — CONFIRM_RECEIPT already fired
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

    // =========================================================================
    // _withdraw Path 1 — idle covers + spokes fresh → immediate settlement
    // Setup: set fresh timestamp via vm.store, fresh actor deposits small amount
    // Hub has enough idle from alice's setUp deposit to cover betty's withdrawal
    // =========================================================================

    function test_withdraw_path1_burnsShares() public {
        // fresh timestamp — Path 1 condition met
        _setLastReportTimestamp(chainSelector, block.timestamp);

        // betty deposits small amount — hub has 10_000 idle, easily covers 1_000
        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);
        uint256 totalBefore = hub.totalAssets();

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // shares burned, totalAssets decreased by withdrawn amount
        assertEq(hub.balanceOf(betty), 0);
        assertEq(hub.totalAssets(), totalBefore - assets);
    }

    function test_withdraw_path1_transfersUSDCToReceiver() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);
        uint256 balanceBefore = usdc.balanceOf(betty);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(usdc.balanceOf(betty), balanceBefore + assets);
    }

    function test_withdraw_path1_receiverDifferentFromOwner() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        address receiver = makeAddr("receiver");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, receiver, betty);

        // betty's shares burned, receiver gets USDC
        assertEq(hub.balanceOf(betty), 0);
        assertEq(usdc.balanceOf(receiver), assets);
        assertEq(usdc.balanceOf(betty), 0);
    }

    function test_withdraw_path1_reservedAssetsZeroAfter() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // Path 1 processes immediately — reservedAssets never stays elevated
        assertEq(hub.reservedAssets(), 0);
    }

    function test_withdraw_path1_totalAssetsDecreased() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 totalBefore = hub.totalAssets();
        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.totalAssets(), totalBefore - assets);
    }

    function test_withdraw_path1_fullWithdrawal_totalSupplyZero() public {
        // both alice and betty fully withdraw — totalSupply goes to 0
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        // betty withdraws
        uint256 bettyShares = hub.balanceOf(betty);
        uint256 bettyAssets = hub.previewRedeem(bettyShares);
        vm.prank(betty);
        hub.withdraw(bettyAssets, betty, betty);

        // alice withdraws
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 aliceAssets = hub.previewRedeem(aliceShares);
        vm.prank(alice);
        hub.withdraw(aliceAssets, alice, alice);

        assertEq(hub.totalSupply(), 0);
        assertEq(hub.totalAssets(), 0);
    }

    function test_withdraw_path1_multipleUsers() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        // bob deposits after alice — both withdraw successfully
        address bob = makeAddr("bob");
        usdc.mint(bob, 2_000e6);
        vm.startPrank(bob);
        usdc.approve(address(hub), 2_000e6);
        hub.deposit(2_000e6, bob);
        vm.stopPrank();

        uint256 aliceShares = hub.balanceOf(alice);
        uint256 aliceAssets = hub.previewRedeem(aliceShares);
        uint256 bobShares = hub.balanceOf(bob);
        uint256 bobAssets = hub.previewRedeem(bobShares);

        vm.prank(alice);
        hub.withdraw(aliceAssets, alice, alice);

        vm.prank(bob);
        hub.withdraw(bobAssets, bob, bob);

        assertEq(hub.totalSupply(), 0);
        assertEq(hub.balanceOf(alice), 0);
        assertEq(hub.balanceOf(bob), 0);
    }

    function test_withdraw_path1_callerNotOwner_usesAllowance() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        address operator = makeAddr("operator");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        // betty approves operator to spend her shares
        vm.prank(betty);
        hub.approve(operator, shares);

        vm.prank(operator);
        hub.withdraw(assets, operator, betty);

        assertEq(hub.balanceOf(betty), 0);
        assertEq(usdc.balanceOf(operator), assets);
    }

    function test_withdraw_path1_revert_insufficientAllowance() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        address betty = makeAddr("betty");
        address operator = makeAddr("operator");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        // operator has no approval
        vm.prank(operator);
        vm.expectRevert();
        hub.withdraw(assets, operator, betty);
    }

    function test_withdraw_path1_revert_zeroAmount() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawal.selector);
        hub.withdraw(0, alice, alice);
    }

    function test_withdraw_path1_revert_exceedsBalance() public {
        _setLastReportTimestamp(chainSelector, block.timestamp);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        vm.expectRevert();
        hub.withdraw(assets + 1e6, alice, alice);
    }

    // =========================================================================
    // _allSpokesFresh Tests
    // =========================================================================

    function test_allSpokesFresh_path1WhenFresh() public {
        // fresh timestamp set — _allSpokesFresh returns true
        // idle (10_000) covers alice's shares — Path 1 executes immediately
        _setLastReportTimestamp(chainSelector, block.timestamp);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assets);
        assertEq(hub.reservedAssets(), 0);
    }

    function test_allSpokesFresh_path2WhenStale() public {
        // warp to a safe timestamp first to avoid underflow
        vm.warp(1 days);

        // set stale timestamp — _allSpokesFresh returns false
        // idle covers — Path 2: queue + request report balance
        // CCIP synchronous — report arrives, withdrawal settles
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        // CCIP synchronous — report arrived and withdrawal settled
        assertEq(hub.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assets);
        // timestamp refreshed by report balance callback
        assertGt(
            hub.lastReportTimestamp(chainSelector),
            block.timestamp - 2 hours
        );
    }

    function test_allSpokesFresh_returnsFalseWithNoSpokes() public {
        // fresh hub with no spokes — _allSpokesFresh returns false
        // idle covers — Path 2 but no spokes to send report to
        // withdrawal stays queued indefinitely
        vm.prank(owner);
        HUB freshHub = new HUB(
            "Test",
            "TST",
            address(router),
            owner,
            address(link),
            address(usdc),
            rebalancer
        );
        ccipSimulator.requestLinkFromFaucet(address(freshHub), 10 ether);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(freshHub), 1_000e6);
        freshHub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = freshHub.balanceOf(betty);
        uint256 assets = freshHub.previewRedeem(shares);

        vm.prank(betty);
        freshHub.withdraw(assets, betty, betty);

        // no spokes to report — withdrawal stays queued
        assertEq(freshHub.reservedAssets(), assets);
        assertEq(usdc.balanceOf(betty), 0);
    }

    function test_allSpokesFresh_staleAfterWarp() public {
        // set fresh then warp past MAX_STALENESS — becomes stale
        // CCIP synchronous — Path 2 still settles via report balance
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        vm.warp(block.timestamp + 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        assertEq(hub.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + assets);
        assertGe(hub.lastReportTimestamp(chainSelector), block.timestamp);
    }

    // =========================================================================
    // _findBestSpoke Tests
    // =========================================================================

    function test_findBestSpoke_recallsFromHighestBalance() public {
        // register second spoke — mock address, CCIP will fail to it
        // we only care that hub ATTEMPTS to recall from the highest balance spoke
        uint64 selector2 = 9999;
        address mockSpoke2 = makeAddr("spoke2");
        vm.prank(owner);
        hub.addSpoke(selector2, mockSpoke2);

        // spoke1 balance = 3_000, spoke2 balance = 8_000
        _setSpokeBalance(chainSelector, 3_000e6);
        _setSpokeBalance(selector2, 8_000e6);
        _setLastReportTimestamp(chainSelector, block.timestamp);
        _setLastReportTimestamp(selector2, block.timestamp);

        // drain hub idle below alice's share value — triggers Path 3
        deal(address(usdc), address(hub), 100e6);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        // Path 3 — CCIP to mockSpoke2 will fail since it's not a real contract
        // withdrawal stays queued
        vm.prank(alice);
        try hub.withdraw(assets, alice, alice) {} catch {}

        // withdrawal is queued — reservedAssets > 0
        assertGt(hub.reservedAssets(), 0);
    }

    function test_findBestSpoke_singleSpoke() public {
        // single spoke with balance — Path 3 recalls from it
        _setSpokeBalance(chainSelector, 5_000e6);
        _setLastReportTimestamp(chainSelector, block.timestamp);

        // drain idle below alice's share value
        deal(address(usdc), address(hub), 100e6);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        hub.withdraw(assets, alice, alice);

        // recalled from real spoke — CCIP synchronous — should settle
        assertEq(hub.balanceOf(alice), 0);
    }

    // =========================================================================
    // _withdraw Path 3 — idle insufficient → recall from best spoke
    // Setup: send most of hub USDC to spoke, leave tiny idle
    // alice's shares worth more than idle — triggers Path 3
    // =========================================================================

    function _setupPath3() internal {
        // send 9_000 of alice's 10_000 to spoke — only 1_000 idle remains
        // alice's shares worth 10_000 — idle (1_000) insufficient — Path 3
        _sendToSpoke(9_000e6);
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

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        // spoke sent back assetsToReceive — spoke balance reduced
        assertEq(hub.spokeBalances(chainSelector), 9_000e6 - assetsToReceive);
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

        // recall completed — inTransitAssets back to 0
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

    // =========================================================================
    // _withdraw Path 2 — idle covers + spokes stale → queue + report balance
    // Condition: idle >= assets AND _allSpokesFresh() == false
    // Setup: vm.warp to safe timestamp, set stale lastReportTimestamp via vm.store
    // CCIP synchronous — report arrives and withdrawal settles in same transaction
    // =========================================================================

    function test_withdrawPath2_aliceReceivesCorrectUSDC() public {
        // warp to safe timestamp to avoid underflow when setting stale time
        vm.warp(1 days);
        // set stale timestamp — forces Path 2
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        // fresh actor deposits — hub has enough idle to cover
        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);
        uint256 balanceBefore = usdc.balanceOf(betty);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // CCIP synchronous — report arrived, withdrawal settled
        assertEq(usdc.balanceOf(betty), balanceBefore + assets);
    }

    function test_withdrawPath2_sharesFullyBurned() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // shares burned — betty holds none, hub holds none
        assertEq(hub.balanceOf(betty), 0);
        assertEq(hub.balanceOf(address(hub)), 0);
    }

    function test_withdrawPath2_reservedAssetsZeroAfterSettlement() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // reserved back to 0 after settlement
        assertEq(hub.reservedAssets(), 0);
    }

    function test_withdrawPath2_totalAssetsDecreased() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 totalBefore = hub.totalAssets();
        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        assertEq(hub.totalAssets(), totalBefore - assets);
    }

    function test_withdrawPath2_lastReportTimestampRefreshed() public {
        vm.warp(1 days);
        uint256 staleTimestamp = block.timestamp - 2 hours;
        _setLastReportTimestamp(chainSelector, staleTimestamp);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // report balance callback refreshed the timestamp
        assertGt(hub.lastReportTimestamp(chainSelector), staleTimestamp);
    }

    function test_withdrawPath2_spokeBalancesUpdated() public {
        // send some funds to spoke first so spoke has a real balance to report
        _sendToSpoke(3_000e6);

        vm.warp(1 days);
        // now make it stale
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        uint256 shares = hub.balanceOf(betty);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(betty);
        hub.withdraw(assets, betty, betty);

        // report balance callback updated spokeBalances
        assertEq(hub.spokeBalances(chainSelector), 3_000e6);
        assertGt(
            hub.lastReportTimestamp(chainSelector),
            block.timestamp - 2 hours
        );
    }

    function test_withdrawPath2_multipleUsers_bothSettle() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        // betty and charlie both deposit and withdraw via Path 2
        address betty = makeAddr("betty");
        address charlie = makeAddr("charlie");

        usdc.mint(betty, 1_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 1_000e6);
        hub.deposit(1_000e6, betty);
        vm.stopPrank();

        usdc.mint(charlie, 2_000e6);
        vm.startPrank(charlie);
        usdc.approve(address(hub), 2_000e6);
        hub.deposit(2_000e6, charlie);
        vm.stopPrank();

        uint256 bettyShares = hub.balanceOf(betty);
        uint256 bettyAssets = hub.previewRedeem(bettyShares);

        uint256 charlieShares = hub.balanceOf(charlie);
        uint256 charlieAssets = hub.previewRedeem(charlieShares);

        // each withdrawal independently triggers report balance and settles
        vm.prank(betty);
        hub.withdraw(bettyAssets, betty, betty);

        // after betty's withdrawal timestamp is fresh — charlie goes Path 1
        // warp again to make stale for charlie
        vm.warp(block.timestamp + 2 hours);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        vm.prank(charlie);
        hub.withdraw(charlieAssets, charlie, charlie);

        assertEq(usdc.balanceOf(betty), bettyAssets);
        assertEq(usdc.balanceOf(charlie), charlieAssets);
        assertEq(hub.balanceOf(betty), 0);
        assertEq(hub.balanceOf(charlie), 0);
    }

    function test_withdrawPath2_partialWithdrawal() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        address betty = makeAddr("betty");
        usdc.mint(betty, 2_000e6);
        vm.startPrank(betty);
        usdc.approve(address(hub), 2_000e6);
        hub.deposit(2_000e6, betty);
        vm.stopPrank();

        uint256 totalShares = hub.balanceOf(betty);
        uint256 halfShares = totalShares / 2;
        uint256 halfAssets = hub.previewRedeem(halfShares);

        vm.prank(betty);
        hub.redeem(halfShares, betty, betty);

        // half shares burned, half remain
        assertEq(hub.balanceOf(betty), totalShares - halfShares);
        assertEq(usdc.balanceOf(betty), halfAssets);
    }

    function test_withdrawPath2_revert_zeroAmount() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawal.selector);
        hub.withdraw(0, alice, alice);
    }

    function test_withdrawPath2_revert_exceedsBalance() public {
        vm.warp(1 days);
        _setLastReportTimestamp(chainSelector, block.timestamp - 2 hours);

        uint256 shares = hub.balanceOf(alice);
        uint256 assets = hub.previewRedeem(shares);

        vm.prank(alice);
        vm.expectRevert();
        hub.withdraw(assets + 1e6, alice, alice);
    }

    // =========================================================================
    // recallFromSpoke Tests
    // Hub sends WITHDRAW_AMOUNT to spoke via CCIP
    // Spoke pulls proportionally from adapters and sends tokens back
    // Hub receives CONFIRM_WITHDRAWAL callback and updates accounting
    // =========================================================================

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _generateMessageId(
        address receiver
    ) internal view returns (bytes32) {
        bytes32 messageId;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, receiver)
            mstore(add(ptr, 0x20), timestamp())
            messageId := keccak256(ptr, 0x40)
            mstore(0x40, add(ptr, 0x40))
        }
        return messageId;
    }

    function _recallFromSpoke(uint256 amount, bytes32 messageId) internal {
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        vm.prank(rebalancer);
        hub.recallFromSpoke(chainSelector, instructions, messageId);
    }

    // ── Scenario 1 — no pending withdrawal ────────────────────────────────────

    function test_recallFromSpoke_hubUSDCBalanceIncreases() public {
        // send 5_000 to spoke first
        _sendToSpoke(5_000e6);

        uint256 hubBalanceBefore = usdc.balanceOf(address(hub));
        bytes32 messageId = _generateMessageId(address(hub));

        // recall 3_000 back — no pending withdrawal
        _recallFromSpoke(3_000e6, messageId);

        // hub received 3_000 back from spoke
        assertEq(usdc.balanceOf(address(hub)), hubBalanceBefore + 3_000e6);
    }

    function test_recallFromSpoke_spokeBalanceDecreases() public {
        _sendToSpoke(5_000e6);

        uint256 spokeBalanceBefore = hub.spokeBalances(chainSelector);
        bytes32 messageId = _generateMessageId(address(hub));

        _recallFromSpoke(3_000e6, messageId);

        // spoke reports lower balance after recall
        assertEq(
            hub.spokeBalances(chainSelector),
            spokeBalanceBefore - 3_000e6
        );
    }

    function test_recallFromSpoke_inTransitBackToZero() public {
        _sendToSpoke(5_000e6);

        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(3_000e6, messageId);

        // CONFIRM_WITHDRAWAL arrived — nothing stuck in transit
        assertEq(hub.inTransitAssets(), 0);
    }

    function test_recallFromSpoke_totalAssetsUnchanged() public {
        _sendToSpoke(5_000e6);

        uint256 totalBefore = hub.totalAssets();
        bytes32 messageId = _generateMessageId(address(hub));

        _recallFromSpoke(3_000e6, messageId);

        // capital moved spoke → hub — totalAssets unchanged
        assertEq(hub.totalAssets(), totalBefore);
    }

    // ── Scenario 2 — pending withdrawal exists ────────────────────────────────

    function test_recallFromSpoke_pendingWithdrawal_userReceivesUSDC() public {
        // setup Path 3 — send most funds to spoke, leave tiny idle
        _sendToSpoke(9_000e6);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 aliceShares = hub.balanceOf(alice);
        uint256 assetsToReceive = hub.previewRedeem(aliceShares);

        // alice withdraws — idle insufficient — Path 3 queued
        // recallFromSpoke called internally by hub
        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        // CCIP synchronous — recall completed, withdrawal settled
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

        // reservation cleared after settlement
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
        // send 5_000 to spoke, recall only 2_000 back
        _sendToSpoke(5_000e6);

        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(2_000e6, messageId);

        // spoke still has 3_000 remaining
        assertEq(hub.spokeBalances(chainSelector), 3_000e6);
        assertEq(aaveAdapter.totalAssets(), 3_000e6);
    }

    function test_recallFromSpoke_fullRecall() public {
        // send 5_000 to spoke, recall all 5_000 back
        _sendToSpoke(5_000e6);

        bytes32 messageId = _generateMessageId(address(hub));
        _recallFromSpoke(5_000e6, messageId);

        // spoke balance goes to zero
        assertEq(hub.spokeBalances(chainSelector), 0);
        assertEq(aaveAdapter.totalAssets(), 0);
        // hub has all funds back
        assertEq(usdc.balanceOf(address(hub)), 10_000e6);
    }

    // =========================================================================
    // rebalance Tests
    // Hub sends REBALANCE message to spoke via CCIP
    // Spoke withdraws from source adapter and deposits into target adapter
    // No tokens leave the chain — intra-spoke capital movement
    // Hub receives CONFIRM_RECEIPT callback with updated spoke balance
    // =========================================================================

    function test_rebalance_sourceAdapterDecreases() public {
        // register compound adapter on spoke
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

        // deploy 5_000 to aave on spoke
        _sendToSpoke(5_000e6);
        assertEq(aaveAdapter.totalAssets(), 5_000e6);

        // rebalance 2_000 from aave to compound
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // aave decreased by 2_000
        assertEq(aaveAdapter.totalAssets(), 3_000e6);
    }

    function test_rebalance_targetAdapterIncreases() public {
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

        _sendToSpoke(5_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // compound received 2_000
        assertEq(compoundAdapter.totalAssets(), 2_000e6);
    }

    function test_rebalance_totalSpokeBalanceUnchanged() public {
        // capital moved between adapters — total spoke value unchanged
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

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
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // spoke balance unchanged — same total just different adapter split
        assertEq(hub.spokeBalances(chainSelector), spokeBalanceBefore);
    }

    function test_rebalance_spokeBalancesUpdatedByConfirmReceipt() public {
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

        _sendToSpoke(5_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // CONFIRM_RECEIPT arrived — lastReportTimestamp updated
        assertGt(hub.lastReportTimestamp(chainSelector), 0);
        // spoke balance reflects aggregated balance of all adapters
        assertEq(hub.spokeBalances(chainSelector), 5_000e6);
    }

    function test_rebalance_totalAssetsUnchanged() public {
        // no capital leaves or enters — totalAssets unchanged
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

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
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        assertEq(hub.totalAssets(), totalBefore);
    }

    function test_rebalance_noTokensLeaveSpokeChain() public {
        // REBALANCE is intra-spoke — no USDC should move cross-chain
        // hub USDC balance unchanged
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

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
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // hub USDC unchanged — no cross-chain token transfer
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
        hub.rebalance(chainSelector, instructions, bytes32(0));
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
        hub.rebalance(9999, instructions, bytes32(0));
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
        hub.rebalance(chainSelector, instructions, bytes32(0));
    }

    // =========================================================================
    // Path 3 shortfall fix — hub only recalls shortfall not full amount
    // =========================================================================

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
        // idle reserved during path 3 — cleared after settlement
        _sendToSpoke(9_000e6);

        uint256 aliceShares = hub.balanceOf(alice);

        vm.prank(alice);
        hub.redeem(aliceShares, alice, alice);

        // reservation cleared after CONFIRM_WITHDRAWAL settles
        assertEq(hub.reservedAssets(), 0);
    }

    // =========================================================================
    // REBALANCE — no tokens attached to message
    // =========================================================================

    function test_rebalance_noTokensAttached_inTransitStaysZero() public {
        // register compound adapter
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

        // deploy funds to spoke first
        _sendToSpoke(5_000e6);
        assertEq(hub.inTransitAssets(), 0);

        // rebalance — no tokens should leave hub
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 2_000e6,
            targetAdapter: COMPOUND,
            targetAmount: 0
        });
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // inTransitAssets never incremented — no tokens left hub
        assertEq(hub.inTransitAssets(), 0);
    }

    function test_rebalance_noTokensAttached_hubUSDCUnchanged() public {
        MockYieldSource compoundAdapter = new MockYieldSource(address(usdc));
        bytes32 COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));

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
        bytes32 messageId = keccak256(abi.encode(block.timestamp));
        vm.prank(rebalancer);
        hub.rebalance(chainSelector, instructions, messageId);

        // hub USDC balance unchanged — rebalance is intra-spoke only
        assertEq(usdc.balanceOf(address(hub)), hubUSDCBefore);
    }
}
