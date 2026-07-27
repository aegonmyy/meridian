// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {Rebalancer} from "../../../src/Rebalancer.sol";
import {HubFactory} from "../../../src/factory/HubFactory.sol";
import {SpokeFactory, AdapterSpec, AdapterKind} from "../../../src/factory/SpokeFactory.sol";
import {Asset} from "../../mocks/Asset.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Factory unit tests run against the CCIPLocalSimulator router, the same local harness every
///      other CCIP test in this repo uses. They cover deploy correctness, wiring, LINK funding,
///      ownership handoff, the registry getters, and revert paths for each factory on its own chain.
///      They do NOT drive a cross-chain CCIP round trip: that path is disabled repo-wide
///      (disabled-tests/FullFlowTest.t.sol) and is out of scope here.
contract FactoryTest is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    Asset public usdc;
    HubFactory public hubFactory;
    SpokeFactory public spokeFactory;

    address public user;
    address public other;

    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");

    uint64 public constant HUB_SELECTOR = 5009297550715157269;

    function setUp() public {
        user = makeAddr("user");
        other = makeAddr("other");

        ccipSimulator = new CCIPLocalSimulator();
        (chainSelector, router, , , link, , ) = ccipSimulator.configuration();

        usdc = new Asset();

        hubFactory = new HubFactory(
            address(router),
            address(link),
            address(usdc)
        );
        spokeFactory = new SpokeFactory(
            address(router),
            address(link),
            address(usdc),
            HUB_SELECTOR
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _selectors() internal view returns (uint64[] memory s) {
        s = new uint64[](1);
        s[0] = chainSelector;
    }

    function _protocols() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = AAVE;
        p[1] = COMPOUND;
    }

    function _aaveSpec(
        bytes32 protocolId
    ) internal returns (AdapterSpec memory spec) {
        spec = AdapterSpec({
            kind: AdapterKind.AAVE,
            protocolId: protocolId,
            params: abi.encode(makeAddr("aavePool"), makeAddr("aToken"))
        });
    }

    function _fundAndApproveHub(uint256 amount) internal {
        ccipSimulator.requestLinkFromFaucet(user, amount);
        vm.prank(user);
        link.approve(address(hubFactory), amount);
    }

    function _fundAndApproveSpoke(uint256 amount) internal {
        ccipSimulator.requestLinkFromFaucet(user, amount);
        vm.prank(user);
        link.approve(address(spokeFactory), amount);
    }

    // =========================================================================
    // HubFactory
    // =========================================================================

    function test_createHub_deploysAndWires() public {
        vm.prank(user);
        (address hub, address rebalancer) = hubFactory.createHub(
            "Meridian USDC",
            "mUSDC",
            _selectors(),
            _protocols(),
            0
        );

        assertEq(HUB(hub).REBALANCER(), rebalancer);
        assertEq(address(Rebalancer(rebalancer).HUB()), hub);
        assertEq(Rebalancer(rebalancer).AGENT_CONSUMER(), address(0));
        assertTrue(Rebalancer(rebalancer).whitelistedChains(chainSelector));
        assertTrue(Rebalancer(rebalancer).whitelistedProtocols(AAVE));
        assertTrue(Rebalancer(rebalancer).whitelistedProtocols(COMPOUND));
    }

    function test_createHub_hubOwnershipImmediate() public {
        vm.prank(user);
        (address hub, ) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            0
        );
        assertEq(HUB(hub).owner(), user);
    }

    function test_createHub_rebalancerTwoStepHandoff() public {
        vm.prank(user);
        (, address rebalancer) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            0
        );

        assertEq(Rebalancer(rebalancer).owner(), address(hubFactory));
        assertEq(Rebalancer(rebalancer).pendingOwner(), user);

        vm.prank(user);
        Rebalancer(rebalancer).acceptOwnership();
        assertEq(Rebalancer(rebalancer).owner(), user);
        assertEq(Rebalancer(rebalancer).pendingOwner(), address(0));

        vm.prank(user);
        Rebalancer(rebalancer).addChainToWhitelist(9999);
        assertTrue(Rebalancer(rebalancer).whitelistedChains(9999));
    }

    function test_createHub_onlyCallerCanAcceptRebalancer() public {
        vm.prank(user);
        (, address rebalancer) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            0
        );

        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                other
            )
        );
        Rebalancer(rebalancer).acceptOwnership();
    }

    function test_createHub_factoryRetainsNoAuthority() public {
        vm.prank(user);
        (address hub, address rebalancer) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            0
        );
        vm.prank(user);
        Rebalancer(rebalancer).acceptOwnership();

        assertTrue(HUB(hub).owner() != address(hubFactory));
        assertTrue(Rebalancer(rebalancer).owner() != address(hubFactory));

        vm.prank(address(hubFactory));
        vm.expectRevert(Rebalancer.NotAuthorized.selector);
        Rebalancer(rebalancer).addChainToWhitelist(1);
    }

    function test_createHub_fundsLink() public {
        uint256 amount = 5 ether;
        _fundAndApproveHub(amount);

        vm.prank(user);
        (address hub, ) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            amount
        );
        assertEq(link.balanceOf(hub), amount);
    }

    function test_createHub_revert_linkWithoutApproval() public {
        ccipSimulator.requestLinkFromFaucet(user, 5 ether);
        vm.prank(user);
        vm.expectRevert();
        hubFactory.createHub("n", "s", _selectors(), _protocols(), 5 ether);
    }

    function test_createHub_registry() public {
        vm.prank(user);
        (address hub, ) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            0
        );

        address[] memory byOwner = hubFactory.getHubsByOwner(user);
        assertEq(byOwner.length, 1);
        assertEq(byOwner[0], hub);

        address[] memory all = hubFactory.getAllHubs();
        assertEq(all.length, 1);
        assertEq(all[0], hub);
        assertEq(hubFactory.hubCount(), 1);

        assertEq(hubFactory.getHubsByOwner(other).length, 0);
    }

    // =========================================================================
    // SpokeFactory
    // =========================================================================

    function test_createSpoke_deploysAndRegisters() public {
        address hub = makeAddr("hub");
        AdapterSpec[] memory specs = new AdapterSpec[](2);
        specs[0] = _aaveSpec(AAVE);
        specs[1] = _aaveSpec(COMPOUND);

        vm.prank(user);
        (address spoke, address[] memory adapterAddrs) = spokeFactory
            .createSpoke(hub, specs, 0);

        assertEq(SpokeVault(spoke).HUB(), hub);
        assertEq(SpokeVault(spoke).HUB_CHAIN_SELECTOR(), HUB_SELECTOR);
        assertEq(SpokeVault(spoke).owner(), user);

        (, bool exists0, ) = SpokeVault(spoke).adapters(AAVE);
        assertTrue(exists0);
        (, bool exists1, ) = SpokeVault(spoke).adapters(COMPOUND);
        assertTrue(exists1);
        assertEq(adapterAddrs.length, 2);
        assertTrue(adapterAddrs[0] != address(0));
        assertTrue(adapterAddrs[1] != address(0));
    }

    function test_createSpoke_fundsLink() public {
        uint256 amount = 3 ether;
        _fundAndApproveSpoke(amount);

        address hub = makeAddr("hub");
        AdapterSpec[] memory specs = new AdapterSpec[](1);
        specs[0] = _aaveSpec(AAVE);

        vm.prank(user);
        (address spoke, ) = spokeFactory.createSpoke(hub, specs, amount);
        assertEq(link.balanceOf(spoke), amount);
    }

    function test_createSpoke_revert_zeroHub() public {
        AdapterSpec[] memory specs = new AdapterSpec[](1);
        specs[0] = _aaveSpec(AAVE);
        vm.prank(user);
        vm.expectRevert(SpokeFactory.InvalidHub.selector);
        spokeFactory.createSpoke(address(0), specs, 0);
    }

    function test_createSpoke_revert_linkWithoutApproval() public {
        ccipSimulator.requestLinkFromFaucet(user, 3 ether);
        address hub = makeAddr("hub");
        AdapterSpec[] memory specs = new AdapterSpec[](1);
        specs[0] = _aaveSpec(AAVE);
        vm.prank(user);
        vm.expectRevert();
        spokeFactory.createSpoke(hub, specs, 3 ether);
    }

    function test_createSpoke_registry() public {
        address hub = makeAddr("hub");
        AdapterSpec[] memory specs = new AdapterSpec[](1);
        specs[0] = _aaveSpec(AAVE);

        vm.prank(user);
        (address spoke, ) = spokeFactory.createSpoke(hub, specs, 0);

        address[] memory byOwner = spokeFactory.getSpokesByOwner(user);
        assertEq(byOwner.length, 1);
        assertEq(byOwner[0], spoke);
        assertEq(spokeFactory.getAllSpokes()[0], spoke);
        assertEq(spokeFactory.spokeCount(), 1);
    }

    // =========================================================================
    // Hub addSpokes batch (D7)
    // =========================================================================

    function _freshHub() internal returns (HUB hub) {
        vm.prank(user);
        (address h, ) = hubFactory.createHub(
            "n",
            "s",
            _selectors(),
            _protocols(),
            0
        );
        hub = HUB(h);
    }

    function test_addSpokes_equivalentToSingleCalls() public {
        HUB batchHub = _freshHub();
        HUB singleHub = _freshHub();

        uint64[] memory selectors = new uint64[](2);
        selectors[0] = 111;
        selectors[1] = 222;
        address[] memory addrs = new address[](2);
        addrs[0] = makeAddr("spokeA");
        addrs[1] = makeAddr("spokeB");

        vm.prank(user);
        batchHub.addSpokes(selectors, addrs);

        vm.startPrank(user);
        singleHub.addSpoke(selectors[0], addrs[0]);
        singleHub.addSpoke(selectors[1], addrs[1]);
        vm.stopPrank();

        for (uint256 i = 0; i < selectors.length; i++) {
            (address bSpoke, bool bExists, bool bEver) = batchHub.spokes(
                selectors[i]
            );
            (address sSpoke, bool sExists, bool sEver) = singleHub.spokes(
                selectors[i]
            );
            assertEq(bSpoke, sSpoke);
            assertEq(bExists, sExists);
            assertEq(bEver, sEver);
            assertEq(batchHub.addressToSelector(addrs[i]), selectors[i]);
            assertEq(
                batchHub.addressToSelector(addrs[i]),
                singleHub.addressToSelector(addrs[i])
            );
        }
        assertEq(batchHub.spokeChainSelectors(0), singleHub.spokeChainSelectors(0));
        assertEq(batchHub.spokeChainSelectors(1), singleHub.spokeChainSelectors(1));
    }

    function test_addSpokes_revert_mismatchedLengths() public {
        HUB hub = _freshHub();
        uint64[] memory selectors = new uint64[](2);
        selectors[0] = 111;
        selectors[1] = 222;
        address[] memory addrs = new address[](1);
        addrs[0] = makeAddr("spokeA");

        vm.prank(user);
        vm.expectRevert();
        hub.addSpokes(selectors, addrs);
    }

    function test_addSpokes_revert_notOwner() public {
        HUB hub = _freshHub();
        uint64[] memory selectors = new uint64[](1);
        selectors[0] = 111;
        address[] memory addrs = new address[](1);
        addrs[0] = makeAddr("spokeA");

        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                other
            )
        );
        hub.addSpokes(selectors, addrs);
    }
}
