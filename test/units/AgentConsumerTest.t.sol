// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {AgentConsumer} from "../../src/AgentConsumer.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {AllocationProposal} from "../../src/interfaces/IRebalancer.sol";

contract AgentConsumerTest is Test {
    AgentConsumer public consumer;
    address public rebalancer;
    address public agent;
    address public owner;
    address public attacker;

    function setUp() public {
        rebalancer = makeAddr("rebalancer");
        agent = makeAddr("agent");
        owner = makeAddr("owner");
        attacker = makeAddr("attacker");

        consumer = new AgentConsumer(rebalancer, agent, owner);
    }

    // ── constructor ───────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(consumer.REBALANCER(), rebalancer);
        assertEq(consumer.AGENT(), agent);
        assertEq(consumer.owner(), owner);
    }

    function test_constructor_revert_zeroRebalancer() public {
        vm.expectRevert(AgentConsumer.InvalidConstructorArguments.selector);
        new AgentConsumer(address(0), agent, owner);
    }

    function test_constructor_revert_zeroAgent() public {
        vm.expectRevert(AgentConsumer.InvalidConstructorArguments.selector);
        new AgentConsumer(rebalancer, address(0), owner);
    }

    // ── proposeAllocation access control ──────────────────────────────────

    function test_proposeAllocation_agentCanCall() public {
        // mock rebalancer to accept any call
        vm.mockCall(
            rebalancer,
            abi.encodeWithSignature(
                "proposeAllocation((uint256[][],uint256[],uint256[][],uint256[],uint64[],bytes32[][]))"
            ),
            abi.encode()
        );

        AllocationProposal memory proposal = _emptyProposal();

        vm.prank(agent);
        consumer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_ownerCanCall() public {
        vm.mockCall(
            rebalancer,
            abi.encodeWithSignature(
                "proposeAllocation((uint256[][],uint256[],uint256[][],uint256[],uint64[],bytes32[][]))"
            ),
            abi.encode()
        );

        AllocationProposal memory proposal = _emptyProposal();

        vm.prank(owner);
        consumer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_revert_notAgent() public {
        AllocationProposal memory proposal = _emptyProposal();

        vm.prank(attacker);
        vm.expectRevert(AgentConsumer.NotAgent.selector);
        consumer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_emitsEvent() public {
        vm.mockCall(
            rebalancer,
            abi.encodeWithSignature(
                "proposeAllocation((uint256[][],uint256[],uint256[][],uint256[],uint64[],bytes32[][]))"
            ),
            abi.encode()
        );

        AllocationProposal memory proposal = _emptyProposal();

        vm.expectEmit(true, false, false, true);
        emit AgentConsumer.AllocationProposed(agent, block.timestamp);

        vm.prank(agent);
        consumer.proposeAllocation(proposal);
    }

    function test_proposeAllocation_forwardsToRebalancer() public {
        // verify rebalancer.proposeAllocation is called
        vm.expectCall(
            rebalancer,
            abi.encodeWithSignature(
                "proposeAllocation((uint256[][],uint256[],uint256[][],uint256[],uint64[],bytes32[][]))"
            )
        );

        vm.mockCall(
            rebalancer,
            abi.encodeWithSignature(
                "proposeAllocation((uint256[][],uint256[],uint256[][],uint256[],uint64[],bytes32[][]))"
            ),
            abi.encode()
        );

        AllocationProposal memory proposal = _emptyProposal();

        vm.prank(agent);
        consumer.proposeAllocation(proposal);
    }

    // ── helper ────────────────────────────────────────────────────────────

    function _emptyProposal()
        internal
        pure
        returns (AllocationProposal memory)
    {
        return
            AllocationProposal({
                proposedAllocations: new uint256[][](0),
                proposedNetApys: new uint256[](0),
                currentAllocations: new uint256[][](0),
                currentNetApys: new uint256[](0),
                chainSelectors: new uint64[](0),
                protocolIds: new bytes32[][](0)
            });
    }
}
