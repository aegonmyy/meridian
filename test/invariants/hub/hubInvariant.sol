// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "chainlink-local/ccip/CCIPLocalSimulator.sol";
import {HUB} from "../../../src/Hub.sol";
import {HubVaultHandler} from "./handler/hubHandler.t.sol";

contract HubVaultInvariant is Test {
    CCIPLocalSimulator public ccipSimulator;
    IRouterClient public router;
    LinkToken public link;
    uint64 public chainSelector;

    HUB public hub;
    HubVaultHandler public handler;

    address public owner;
    address public rebalancer;

    function setUp() public {
        owner = makeAddr("owner");
        rebalancer = makeAddr("rebalancer");

        ccipSimulator = new CCIPLocalSimulator();
        (chainSelector, router, , , link, , ) = ccipSimulator.configuration();

        hub = new HUB(
            "Meridian USDC",
            "mUSDC",
            address(router),
            owner,
            address(link),
            makeAddr("usdc"),
            rebalancer
        );

        handler = new HubVaultHandler(hub, owner);
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
            (address spoke, bool exists, ) = hub.spokes(selector);
            if (exists) {
                assertTrue(
                    hub.isValidSpoke(spoke),
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
}
