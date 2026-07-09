// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {HubVaultHandler} from "./handler/hubHandler.t.sol";
import {Asset} from "../../mocks/Asset.sol";
import {SpokeVault} from "../../../src/Spoke.sol";

contract HubVaultInvariant is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;
    Asset public usdc;
    HUB public hub;
    HubVaultHandler public handler;
    SpokeVault spoke;
    address public owner;
    address public rebalancer;

    function setUp() public {
        owner = makeAddr("owner");
        rebalancer = makeAddr("rebalancer");

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

        // deploy spoke
        vm.prank(owner);
        spoke = new SpokeVault(
            address(hub),
            address(usdc),
            address(router),
            owner,
            address(link),
            chainSelector
        );

        // register spoke in hub
        vm.prank(owner);
        hub.addSpoke(chainSelector, address(spoke));

        handler = new HubVaultHandler(
            hub,
            owner,
            usdc,
            spoke, // need to deploy spoke first
            rebalancer,
            chainSelector
        );
        targetContract(address(handler));
    }

    // =========================================================================
    // Invariants
    // =========================================================================

    /// @dev spokeChainSelectors length never decreases
    function invariant_spokeChainSelectorsLengthNeverDecreases() public view {
        assertEq(
            hub.spokeChainSelectorsLength(),
            handler.ghostSpokeChainSelectorsLength()
        );
    }

    /// @dev accounting identity always holds
    function invariant_accountingIdentity() public view {
        assertEq(
            hub.totalAssets(),
            usdc.balanceOf(address(hub)) +
                hub.inTransitAssets() +
                _sumSpokeBalances()
        );
    }

    /// @dev WI-4 global invariant 2 — reservedAssets == sum of every live pending
    ///      withdrawal's reservedIdle. "Live" means pendingWithdrawals[id].shares > 0 —
    ///      settled or cancelled entries are deleted and correctly excluded.
    function invariant_reservedAssetsEqualsSumOfPendingReservedIdle()
        public
        view
    {
        assertEq(hub.reservedAssets(), _sumLivePendingReservedIdle());
    }

    /// @dev WI-4 global invariant 2 (second half) — hub's own escrowed share balance
    ///      equals the sum of every live pending withdrawal's shares.
    function invariant_hubShareBalanceEqualsSumOfPendingShares() public view {
        assertEq(hub.balanceOf(address(hub)), _sumLivePendingShares());
    }

    // @dev totalAssets never less than what users deposited minus withdrawn
    // yield can only add so totalAssets >= net deposits
    function invariant_totalAssetsGeNetDeposits() public view {
        assertGe(
            hub.totalAssets(),
            handler.ghostTotalPrincipal() - handler.ghostTotalWithdrawn()
        );
    } //problem

    /// @dev lastReportTimestamp never in the future
    function invariant_reportTimestampNeverInFuture() public view {
        uint256 length = hub.spokeChainSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            uint64 selector = hub.spokeChainSelectors(i);
            assertLe(hub.lastReportTimestamp(selector), block.timestamp);
        }
    }

    /// @dev inTransitAmount entries never exceed totalAssets
    function invariant_inTransitAssetsBounded() public view {
        assertLe(hub.inTransitAssets(), hub.totalAssets());
    }

    /// @dev WI-4 global invariant 3 — inTransitAssets == sum(inTransitAmount[*]), now
    ///      provable since WI-1 removed id collisions (a collision could previously silently
    ///      overwrite one leg's tracked amount, permanently desyncing the two). The
    ///      CCIPLocalSimulator delivers every message synchronously within the same call
    ///      that sends it, so every DEPOSIT's CONFIRM_RECEIPT (and thus its inTransitAmount
    ///      decrement) has already landed by the time any invariant is checked between
    ///      handler calls — inTransitAssets is therefore always fully reconciled to 0
    ///      in this harness. A nonzero value here would mean a leg's amount was tracked but
    ///      never released, exactly the desync this invariant guards against.
    function invariant_inTransitAssetsFullyReconciledBetweenCalls()
        public
        view
    {
        assertEq(hub.inTransitAssets(), 0);
    }

    /// @dev inTransitAssets never exceeds totalAssets
    function invariant_inTransitBounded() public view {
        assertLe(hub.inTransitAssets(), hub.totalAssets());
    }

    /// @dev reservedAssets never exceeds idle balance
    function invariant_reservedAssetsBounded() public view {
        assertLe(hub.reservedAssets(), usdc.balanceOf(address(hub)));
    }

    /// @dev totalSupply > 0 whenever deposits exist
    function invariant_supplyPositiveWhenDepositsExist() public view {
        if (handler.ghostTotalPrincipal() > 0) {
            assertGt(hub.totalSupply(), 0);
        }
    }

    /// @dev no duplicate selectors in spokeChainSelectors array
    function invariant_noDuplicateSelectors() public view {
        uint256 length = hub.spokeChainSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            uint64 selector = hub.spokeChainSelectors(i);
            for (uint256 j = i + 1; j < length; j++) {
                assertNotEq(
                    uint256(selector),
                    uint256(hub.spokeChainSelectors(j)),
                    "duplicate selector in array"
                );
            }
        }
    }

    /// @dev if exists == true then isValidSpoke[spoke] == true
    function invariant_existsImpliesValidSpoke() public view {
        uint256 length = handler.registeredSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            uint64 selector = handler.registeredSelectors(i);
            (address _spoke, bool exists, ) = hub.spokes(selector);
            if (exists) {
                assertTrue(
                    hub.isValidSpoke(_spoke),
                    "exists but isValidSpoke is false"
                );
            }
        }
    }

    /// @dev if exists == false then isValidSpoke[ghostCurrentSpoke] == false
    function invariant_notExistsImpliesInvalidSpoke() public view {
        uint256 length = handler.registeredSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            uint64 selector = handler.registeredSelectors(i);
            (, bool exists, ) = hub.spokes(selector);
            if (!exists) {
                address lastKnownSpoke = handler.ghostCurrentSpoke(selector);
                if (lastKnownSpoke != address(0)) {
                    assertFalse(
                        hub.isValidSpoke(lastKnownSpoke),
                        "not exists but isValidSpoke is true"
                    );
                }
            }
        }
    }

    /// @dev length never exceeds unique selectors registered
    function invariant_lengthNeverExceedsUniqueSelectors() public view {
        assertLe(
            hub.spokeChainSelectorsLength(),
            handler.registeredSelectorsLength()
        );
    }

    /// @dev once registered selector stays in array forever
    function invariant_everRegisteredStaysInArray() public view {
        uint256 length = handler.registeredSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            uint64 selector = handler.registeredSelectors(i);
            if (handler.ghostEverRegistered(selector)) {
                assertTrue(
                    _isInSpokeSelectors(selector),
                    "everRegistered but not in array"
                );
            }
        }
    }

    // =========================================================================
    // Helper
    // =========================================================================

    function _isInSpokeSelectors(uint64 selector) internal view returns (bool) {
        uint256 length = hub.spokeChainSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            if (hub.spokeChainSelectors(i) == selector) return true;
        }
        return false;
    }

    /// @dev totalAssets equals idleBalance when no spokes registered
    function invariant_totalAssetsEqualsIdleWhenNoSpokes() public view {
        if (hub.spokeChainSelectorsLength() == 0) {
            assertEq(hub.totalAssets(), usdc.balanceOf(address(hub)));
        }
    }

    /// @dev share price never drops — convertToAssets monotonically stable
    function invariant_sharePriceNeverDrops() public view {
        if (hub.totalSupply() > 0) {
            uint256 assetsPerShare = hub.convertToAssets(1e6);
            assertGe(assetsPerShare, 1e6 - 1); // allow 1 unit rounding
        }
    }

    /// @dev sum of all depositor balances plus hub's own escrowed balance equals totalSupply
    /// @dev WI-4: shares are transferred to the hub (escrowed, not burned) while a
    ///      withdrawal is pending — hub.balanceOf(address(hub)) must be included or this
    ///      invariant would spuriously fail whenever a Path 2/3 withdrawal is in flight.
    function invariant_sumOfSharesEqualsTotalSupply() public view {
        uint256 totalShares = hub.balanceOf(address(hub));
        for (uint256 i = 0; i < 3; i++) {
            address depositor = handler.depositors(i);
            totalShares += hub.balanceOf(depositor);
        }
        assertEq(totalShares, hub.totalSupply());
    }

    function _sumSpokeBalances() internal view returns (uint256 total) {
        uint256 length = hub.spokeChainSelectorsLength();
        for (uint256 i = 0; i < length; i++) {
            uint64 selector = hub.spokeChainSelectors(i);
            total += hub.spokeBalances(selector);
        }
    }

    /// @dev Sums reservedIdle across every pending withdrawal id the handler has ever
    ///      issued, counting only entries still live (shares > 0 — not yet settled/cancelled).
    function _sumLivePendingReservedIdle() internal view returns (uint256 total) {
        uint256 length = handler.pendingWithdrawalIdsLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = handler.ghostPendingWithdrawalIds(i);
            (uint256 shares, , uint256 reservedIdle, , , , , ) = hub
                .pendingWithdrawals(id);
            if (shares > 0) total += reservedIdle;
        }
    }

    /// @dev Sums shares across every pending withdrawal id the handler has ever issued,
    ///      counting only entries still live (shares > 0).
    function _sumLivePendingShares() internal view returns (uint256 total) {
        uint256 length = handler.pendingWithdrawalIdsLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = handler.ghostPendingWithdrawalIds(i);
            (uint256 shares, , , , , , , ) = hub.pendingWithdrawals(id);
            if (shares > 0) total += shares;
        }
    }
}
