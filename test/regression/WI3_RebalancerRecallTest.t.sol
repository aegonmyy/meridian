// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../src/Hub.sol";
import {SpokeVault} from "../../src/Spoke.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";
import {Asset} from "../mocks/Asset.sol";
import {MockYieldSource} from "../mocks/mockYield.sol";
import {CCIPHelpers} from "../../src/libraries/CCIPHelpers.sol";
import {AllocationProposal} from "../../src/interfaces/IRebalancer.sol";
import {InsufficientUnreservedIdle} from "../../src/errors/hubErrors.sol";

/// @notice WI-3 regressions. proposeAllocation now sizes sends against deployable idle
///         (idle minus reserved), not totalAssets, so a re-allocation no longer reverts when
///         capital is already deployed. sendToSpoke still enforces reservedAssets so idle a
///         pending withdrawal depends on cannot be shipped.
contract WI3_RebalancerRecallTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    HUB public hub;
    SpokeVault public spoke;
    Rebalancer public rebalancer;
    Asset public usdc;
    MockYieldSource public aaveAdapter;
    MockYieldSource public compoundAdapter;

    address public owner;
    address public agentConsumer;
    address public alice;

    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");

    function setUp() public {
        owner = makeAddr("owner");
        agentConsumer = makeAddr("agentConsumer");
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
            address(0)
        );

        vm.prank(owner);
        rebalancer = new Rebalancer(address(hub), agentConsumer, owner);

        vm.prank(owner);
        hub.setRebalancer(address(rebalancer));

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
        compoundAdapter = new MockYieldSource(address(usdc));

        vm.startPrank(owner);
        spoke.setAdapter(AAVE, address(aaveAdapter));
        spoke.setAdapter(COMPOUND, address(compoundAdapter));
        vm.stopPrank();

        ccipSimulator.requestLinkFromFaucet(address(hub), 10 ether);
        ccipSimulator.requestLinkFromFaucet(address(spoke), 10 ether);

        vm.startPrank(owner);
        rebalancer.addChainToWhitelist(chainSelector);
        rebalancer.addProtocolToWhitelist(AAVE);
        rebalancer.addProtocolToWhitelist(COMPOUND);
        vm.stopPrank();

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 10_000e6);
        hub.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    /// @notice With capital already deployed, a re-allocation sizes its split against deployable
    /// idle, not totalAssets, and succeeds. Pre-fix this reverted at the sizing gate
    /// (InsufficientIdleForProposal(10_000e6, 1_000e6)) because a full proposal was sized at
    /// 100% of totalAssets while only idle backs the sends. Here 90% is deployed, 1_000e6 idle
    /// remains, and the proposal deploys exactly that 1_000e6 (both legs target the real spoke,
    /// so the local simulator delivers them), leaving idle at zero.
    function test_wi3_proposeAllocation_partlyDeployed_sizesAgainstIdle() public {
        // 90% deployed, 1_000e6 idle remains
        vm.prank(address(rebalancer));
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 9_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        hub.sendToSpoke(chainSelector, instructions);
        assertEq(hub.idleBalance(), 1_000e6, "setup: 1000e6 idle");

        // valid proposal, both legs on the real spoke: AAVE 6000 + COMPOUND 2000, then AAVE 2000
        uint256[][] memory proposed = new uint256[][](2);
        proposed[0] = new uint256[](2);
        proposed[0][0] = 6_000;
        proposed[0][1] = 2_000;
        proposed[1] = new uint256[](1);
        proposed[1][0] = 2_000;

        uint256[][] memory current = new uint256[][](2);
        current[0] = new uint256[](2);
        current[1] = new uint256[](1);

        uint256[] memory proposedApys = new uint256[](3);
        proposedApys[0] = 500;
        proposedApys[1] = 400;
        proposedApys[2] = 300;
        uint256[] memory currentApys = new uint256[](3);

        uint64[] memory selectors = new uint64[](2);
        selectors[0] = chainSelector;
        selectors[1] = chainSelector;

        bytes32[][] memory protocolIds = new bytes32[][](2);
        protocolIds[0] = new bytes32[](2);
        protocolIds[0][0] = AAVE;
        protocolIds[0][1] = COMPOUND;
        protocolIds[1] = new bytes32[](1);
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
        rebalancer.proposeAllocation(proposal);

        // deployed exactly the 1_000e6 idle (not 10_000e6 totalAssets), so idle is now zero
        assertEq(hub.idleBalance(), 0, "deployed the deployable idle, not totalAssets");
    }

    /// @notice A fully-deployed vault has nothing to deploy. proposeAllocation rejects the
    /// proposal up front rather than firing CCIP sends carrying zero USDC.
    function test_wi3_proposeAllocation_fullyDeployed_revertsNoIdle() public {
        // deploy 100% of the vault, leaving zero idle
        vm.prank(address(rebalancer));
        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 10_000e6,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        hub.sendToSpoke(chainSelector, instructions);

        AllocationProposal memory proposal = _buildValidProposal();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Rebalancer.InsufficientIdleForProposal.selector,
                0,
                0
            )
        );
        rebalancer.proposeAllocation(proposal);
    }

    /// @notice Pre-fix: sendToSpoke has no idea reservedAssets exists — a rebalancer can
    /// ship idle a pending withdrawal is relying on to settle. This directly demonstrates
    /// the missing guard by simulating a large reservation (as if a pending withdrawal
    /// exists) via storage, then attempting to ship idle beyond what's actually unreserved.
    function test_wi3_sendToSpoke_ignoresReservedAssets_bug() public {
        // simulate a pending withdrawal reserving 9_000e6 of the 10_000e6 idle
        _setReservedAssets(9_000e6);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: AAVE,
            amount: 5_000e6, // only 1_000e6 is actually unreserved
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(address(rebalancer));
        // must revert post-fix — pre-fix this succeeds and ships reserved idle
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientUnreservedIdle.selector,
                5_000e6,
                10_000e6,
                9_000e6
            )
        );
        hub.sendToSpoke(chainSelector, instructions);
    }

    function _setReservedAssets(uint256 amount) internal {
        // reservedAssets is storage slot 8 on HUB (verified via forge inspect storage-layout)
        vm.store(address(hub), bytes32(uint256(8)), bytes32(amount));
    }

    /// @dev Two chains so the proposal obeys AllocationMaths' per-chain 8000bps cap while
    ///      still summing to a full 10000bps grand total: chain1 = 8000bps (6000 aave +
    ///      2000 compound), chain2 = 2000bps (aave only). Chain2's selector only needs to
    ///      be whitelisted in Rebalancer — it need not be a real registered hub spoke,
    ///      since the WI-3 pre-check reverts before any per-chain dispatch is attempted.
    function _buildValidProposal()
        internal
        returns (AllocationProposal memory)
    {
        uint64 secondSelector = 9999;
        vm.prank(owner);
        rebalancer.addChainToWhitelist(secondSelector);

        uint256[][] memory proposed = new uint256[][](2);
        proposed[0] = new uint256[](2);
        proposed[0][0] = 6_000; // chain1 aave
        proposed[0][1] = 2_000; // chain1 compound
        proposed[1] = new uint256[](1);
        proposed[1][0] = 2_000; // chain2 aave

        uint256[][] memory current = new uint256[][](2);
        current[0] = new uint256[](2);
        current[0][0] = 5_000;
        current[0][1] = 3_000;
        current[1] = new uint256[](1);
        current[1][0] = 2_000;

        uint256[] memory proposedApys = new uint256[](3);
        proposedApys[0] = 500;
        proposedApys[1] = 400;
        proposedApys[2] = 300;

        uint256[] memory currentApys = new uint256[](3);
        currentApys[0] = 300;
        currentApys[1] = 300;
        currentApys[2] = 300;

        uint64[] memory selectors = new uint64[](2);
        selectors[0] = chainSelector;
        selectors[1] = secondSelector;

        bytes32[][] memory protocolIds = new bytes32[][](2);
        protocolIds[0] = new bytes32[](2);
        protocolIds[0][0] = AAVE;
        protocolIds[0][1] = COMPOUND;
        protocolIds[1] = new bytes32[](1);
        protocolIds[1][0] = AAVE;

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
}
