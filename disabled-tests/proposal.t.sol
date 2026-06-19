// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {Rebalancer} from "../../../src/Rebalancer.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {AllocationProposal} from "../../../src/interfaces/IRebalancer.sol";

// =========================================================================
// proposeAllocation Tests
// 7 guards validated in order before capital is deployed
// All tests use same RebalancerTest setUp — full CCIP stack available
// =========================================================================

// ── Helpers ───────────────────────────────────────────────────────────────
contract ProposalTest is Test {
    function _buildValidProposal()
        internal
        view
        returns (AllocationProposal memory)
    {
        // valid proposal — one chain, two markets, sums to 10000
        // optimal weighted apy 400 bps vs current 300 bps — gain of 100 bps above threshold
        uint256[][] memory proposed = new uint256[][](1);
        proposed[0] = new uint256[](2);
        proposed[0][0] = 6_000; // 60% aave
        proposed[0][1] = 4_000; // 40% compound

        uint256[][] memory current = new uint256[][](1);
        current[0] = new uint256[](2);
        current[0][0] = 5_000;
        current[0][1] = 5_000;

        uint256[] memory proposedApys = new uint256[](2);
        proposedApys[0] = 500; // aave 5%
        proposedApys[1] = 200; // compound 2%

        uint256[] memory currentApys = new uint256[](2);
        currentApys[0] = 300;
        currentApys[1] = 300;

        uint64[] memory selectors = new uint64[](1);
        selectors[0] = chainSelector;

        bytes32[][] memory protocolIds = new bytes32[][](1);
        protocolIds[0] = new bytes32[](2);
        protocolIds[0][0] = AAVE;
        protocolIds[0][1] = COMPOUND;

        return
            AllocationProposal({
                proposedAllocations: proposed,
                proposedNetApys: proposedApys,
                currentAllocations: current,
                currentNetApys: currentApys,
                chainSelectors: selectors,
                protocolIds: protocolIds
            });
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    function test_proposeAllocation_happyPath_capitalDeployed() public {
        AllocationProposal memory proposal = _buildValidProposal();

        // hub has 10_000 idle — proposal deploys it
        vm.prank(owner);
        rebalancer.proposeAllocation(proposal);

        // spoke received funds
        assertGt(aaveAdapter.totalAssets() + compoundAdapter.totalAssets(), 0);
    }

    function test_proposeAllocation_updatesLastRebalanceTimestamp() public {
        AllocationProposal memory proposal = _buildValidProposal();
        uint256 before = rebalancer.lastRebalanceTimestamp();

        vm.prank(owner);
        rebalancer.proposeAllocation(proposal);

        assertGt(rebalancer.lastRebalanceTimestamp(), before);
    }

    function test_proposeAllocation_cooldownTriggersAfterSuccess() public {
        AllocationProposal memory proposal = _buildValidProposal();

        vm.prank(owner);
        rebalancer.proposeAllocation(proposal);

        vm.prank(owner);
        vm.expectRevert(Rebalancer.CooldownNotElapsed.selector);
        rebalancer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_agentConsumerCanCall() public {
        AllocationProposal memory proposal = _buildValidProposal();

        vm.prank(agentConsumer);
        rebalancer.proposeAllocation(proposal);

        assertGt(aaveAdapter.totalAssets() + compoundAdapter.totalAssets(), 0);
    }

    function test_proposeAllocation_succeedsAfterCooldownElapsed() public {
        AllocationProposal memory proposal = _buildValidProposal();

        vm.prank(owner);
        rebalancer.proposeAllocation(proposal);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(owner);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 1 — Access control ──────────────────────────────────────────────

    function test_proposeAllocation_revert_notAuthorized() public {
        AllocationProposal memory proposal = _buildValidProposal();

        vm.prank(attacker);
        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 2 — Cooldown ────────────────────────────────────────────────────

    function test_proposeAllocation_revert_cooldownNotElapsed() public {
        AllocationProposal memory proposal = _buildValidProposal();

        vm.prank(owner);
        rebalancer.proposeAllocation(proposal);

        vm.warp(block.timestamp + 12 hours); // only 12 hours — not enough

        vm.prank(owner);
        vm.expectRevert(Rebalancer.CooldownNotElapsed.selector);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 3 — Validate allocation ─────────────────────────────────────────

    function test_proposeAllocation_revert_invalidAllocation_badSum() public {
        AllocationProposal memory proposal = _buildValidProposal();
        // break the sum — 9000 instead of 10000
        proposal.proposedAllocations[0][0] = 5_000;
        proposal.proposedAllocations[0][1] = 4_000;

        vm.prank(owner);
        vm.expectRevert(Rebalancer.InvalidAllocation.selector);
        rebalancer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_revert_invalidAllocation_dustAllocation()
        public
    {
        AllocationProposal memory proposal = _buildValidProposal();
        // 499 bps — below minimum
        proposal.proposedAllocations[0][0] = 499;
        proposal.proposedAllocations[0][1] = 9_501;

        vm.prank(owner);
        vm.expectRevert(Rebalancer.InvalidAllocation.selector);
        rebalancer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_revert_invalidAllocation_marketExceeds6000()
        public
    {
        AllocationProposal memory proposal = _buildValidProposal();
        // 6001 bps — exceeds market max
        proposal.proposedAllocations[0][0] = 6_001;
        proposal.proposedAllocations[0][1] = 3_999;

        vm.prank(owner);
        vm.expectRevert(Rebalancer.InvalidAllocation.selector);
        rebalancer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_revert_invalidAllocation_chainExceeds8000()
        public
    {
        // two chains — chain 1 has 8001 bps
        uint256[][] memory proposed = new uint256[][](2);
        proposed[0] = new uint256[](2);
        proposed[1] = new uint256[](1);
        proposed[0][0] = 6_000;
        proposed[0][1] = 2_001; // chain 1 = 8001
        proposed[1][0] = 1_999; // chain 2 = 1999

        uint256[][] memory current = new uint256[][](2);
        current[0] = new uint256[](2);
        current[1] = new uint256[](1);
        current[0][0] = 4_000;
        current[0][1] = 2_000;
        current[1][0] = 4_000;

        uint256[] memory proposedApys = new uint256[](3);
        proposedApys[0] = 500;
        proposedApys[1] = 400;
        proposedApys[2] = 300;

        uint256[] memory currentApys = new uint256[](3);
        currentApys[0] = 300;
        currentApys[1] = 300;
        currentApys[2] = 300;

        // register second chain
        uint64 selector2 = 9999;
        vm.prank(owner);
        rebalancer.addChainToWhitelist(selector2);

        uint64[] memory selectors = new uint64[](2);
        selectors[0] = chainSelector;
        selectors[1] = selector2;

        bytes32[][] memory protocolIds = new bytes32[][](2);
        protocolIds[0] = new bytes32[](2);
        protocolIds[1] = new bytes32[](1);
        protocolIds[0][0] = AAVE;
        protocolIds[0][1] = COMPOUND;
        protocolIds[1][0] = AAVE;

        AllocationProposal memory proposal = AllocationProposal({
            proposedAllocations: proposed,
            proposedNetApys: proposedApys,
            currentAllocations: current,
            currentNetApys: currentApys,
            chainSelectors: selectors,
            protocolIds: protocolIds
        });

        vm.prank(owner);
        vm.expectRevert(Rebalancer.InvalidAllocation.selector);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 4 — Should rebalance ────────────────────────────────────────────

    function test_proposeAllocation_revert_belowThreshold() public {
        AllocationProposal memory proposal = _buildValidProposal();

        // optimal gain of only 10 bps — below 50 threshold
        proposal.proposedNetApys[0] = 310; // was 500
        proposal.proposedNetApys[1] = 310; // was 200
        // current is 300/300 — weighted 300
        // proposed weighted = 310 — gain only 10 bps

        vm.prank(owner);
        vm.expectRevert(Rebalancer.BelowThreshold.selector);
        rebalancer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_revert_optimalWorseThanCurrent() public {
        AllocationProposal memory proposal = _buildValidProposal();

        // flip — proposed worse than current
        proposal.proposedNetApys[0] = 100;
        proposal.proposedNetApys[1] = 100;
        // current 300/300 weighted 300 — proposed 100/100 weighted 100

        vm.prank(owner);
        vm.expectRevert(Rebalancer.BelowThreshold.selector);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 5 — Chain whitelist ─────────────────────────────────────────────

    function test_proposeAllocation_revert_chainNotWhitelisted() public {
        AllocationProposal memory proposal = _buildValidProposal();
        proposal.chainSelectors[0] = 9999; // not whitelisted

        vm.prank(owner);
        vm.expectRevert(Rebalancer.ChainNotWhitelisted.selector);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 6 — Protocol whitelist ──────────────────────────────────────────

    function test_proposeAllocation_revert_protocolNotWhitelisted() public {
        AllocationProposal memory proposal = _buildValidProposal();
        proposal.protocolIds[0][0] = MORPHO; // not whitelisted

        vm.prank(owner);
        vm.expectRevert(Rebalancer.ProtocolNotWhitelisted.selector);
        rebalancer.proposeAllocation(proposal);
    }

    // ── Guard 7 — Max single move ─────────────────────────────────────────────

    function test_proposeAllocation_revert_maxSingleMoveExceeded() public {
        AllocationProposal memory proposal = _buildValidProposal();

        // 60% allocation on 10_000 total assets = 6_000e6
        // max single move = 30% of 10_000 = 3_000e6
        // 6000 bps * 10_000e6 / 10000 = 6_000e6 > 3_000e6 — exceeds max
        // already set in valid proposal — 6000 bps aave
        // but totalAssets is 10_000 so 6000 bps = 6_000e6 > 3_000e6 max
        // this should fail

        vm.prank(owner);
        vm.expectRevert(Rebalancer.MaxSingleMoveExceeded.selector);
        rebalancer.proposeAllocation(proposal);
    }
}
