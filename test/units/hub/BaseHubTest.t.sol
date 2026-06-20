// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {Asset} from "../../mocks/Asset.sol";
import {MockYieldSource} from "../../mocks/mockYield.sol";
import {CCIPHelpers} from "../../../src/libraries/CCIPHelpers.sol";
import {NotRebalancer, SpokeNotFound, ZeroWithdrawal} from "../../../src/errors/hubErrors.sol";

/// @notice Shared base for all hub unit tests
/// @dev All hub tests inherit this — setUp and helpers live here once
abstract contract BaseHubTest is Test {
    // ── CCIP ──────────────────────────────────────────────────────────────
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    // ── Contracts ─────────────────────────────────────────────────────────
    HUB public hub;
    SpokeVault public spoke;
    Asset public usdc;
    MockYieldSource public aaveAdapter;

    // ── Actors ────────────────────────────────────────────────────────────
    address public owner;
    address public rebalancer;
    address public alice;

    // ── Protocol IDs ──────────────────────────────────────────────────────
    bytes32 public constant AAVE = keccak256("AAVE");

    function setUp() public virtual {
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
    // Shared helpers
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
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(11)));
        vm.store(address(hub), slot, bytes32(amount));
    }

    function _setLastReportTimestamp(
        uint64 selector,
        uint256 timestamp
    ) internal {
        bytes32 slot = keccak256(abi.encode(uint256(selector), uint256(12)));
        vm.store(address(hub), slot, bytes32(timestamp));
    }

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

    function _setupPath3() internal {
        // send 9_000 of alice's 10_000 to spoke — only 1_000 idle remains
        // alice's shares worth 10_000 — idle (1_000) insufficient — Path 3
        _sendToSpoke(9_000e6);
    }

    function _deployCompoundAdapter()
        internal
        returns (MockYieldSource compoundAdapter, bytes32 COMPOUND)
    {
        compoundAdapter = new MockYieldSource(address(usdc));
        COMPOUND = keccak256("COMPOUND");
        vm.prank(owner);
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
    }
}
