// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../../../src/Spoke.sol";
import {SpokeVaultHandler} from "./handler/spokeHandler.t.sol";
import {IYieldSource} from "../../../src/interfaces/IYieldSource.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

contract SpokeVaultInvariant is StdInvariant, Test {
    SpokeVault public spoke;
    SpokeVaultHandler public handler;

    address public hub;
    address public owner;
    address public usdc;
    address public link;
    address public router;

    uint64 public constant HUB_CHAIN_SELECTOR = 5009297550715157269;

    function setUp() public {
        hub = makeAddr("hub");
        owner = makeAddr("owner");
        usdc = makeAddr("usdc");
        link = makeAddr("link");
        router = makeAddr("router");

        vm.prank(owner);
        spoke = new SpokeVault(
            hub,
            usdc,
            router,
            owner,
            link,
            HUB_CHAIN_SELECTOR
        );

        handler = new SpokeVaultHandler(spoke, owner);
        targetContract(address(handler));
    }

    // =========================================================================
    // Invariants
    // =========================================================================

    /// @dev activeAdapters length never decreases
    function invariant_activeAdaptersLengthNeverDecreases() public view {
        assertGe(spoke.activeAdaptersLength(), 0);
        // length should equal ghost tracker: only grows
        assertEq(
            spoke.activeAdaptersLength(),
            handler.ghostActiveAdaptersLength()
        );
    }

    /// @dev activeAdapters length only increases by 1 per new protocolId
    function invariant_noDuplicatesInActiveAdapters() public view {
        uint256 length = spoke.activeAdaptersLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = spoke.activeAdapters(i);
            for (uint256 j = i + 1; j < length; j++) {
                assertNotEq(
                    id,
                    spoke.activeAdapters(j),
                    "duplicate in activeAdapters"
                );
            }
        }
    }

    /// @dev if exists == true then adapter address is never zero
    function invariant_existsImpliesNonZeroAdapter() public view {
        uint256 length = spoke.activeAdaptersLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = spoke.activeAdapters(i);
            (IYieldSource adapter, bool exists, ) = spoke.adapters(id);
            if (exists) {
                assertNotEq(
                    address(adapter),
                    address(0),
                    "exists but adapter is zero"
                );
            }
        }
    }

    /// @dev if exists == true then id must be in activeAdapters
    function invariant_existsImpliesInActiveAdapters() public view {
        uint256 handlerLength = handler.registeredIdsLength();
        for (uint256 i = 0; i < handlerLength; i++) {
            bytes32 id = handler.registeredIds(i);
            (, bool exists, ) = spoke.adapters(id);
            if (exists) {
                assertTrue(
                    _isInActiveAdapters(id),
                    "exists but not in activeAdapters"
                );
            }
        }
    }

    /// @dev activeAdapters length never exceeds number of unique ids registered
    function invariant_lengthNeverExceedsUniqueIds() public view {
        assertLe(spoke.activeAdaptersLength(), handler.registeredIdsLength());
    }

    // @dev removeAdapter never shrinks activeAdapters array
    function invariant_removeNeverShrinksArray() public view {
        assertEq(
            spoke.activeAdaptersLength(),
            handler.ghostActiveAdaptersLength()
        );
    }

    /// @dev everRegistered is never false after first setAdapter
    function invariant_everRegisteredNeverResets() public view {
        uint256 length = handler.registeredIdsLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = handler.registeredIds(i);
            (, , bool everRegistered) = spoke.adapters(id);
            assertTrue(everRegistered, "everRegistered was reset");
        }
    }

    /// @dev after removeAdapter exists is false but everRegistered stays true
    function invariant_removeOnlyFlipsExists() public view {
        uint256 length = handler.registeredIdsLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = handler.registeredIds(i);
            (, bool exists, bool everRegistered) = spoke.adapters(id);
            if (!exists) {
                assertTrue(
                    everRegistered,
                    "removed adapter lost everRegistered"
                );
            }
        }
    }

    /// @dev removed adapter address is always zero
    function invariant_removedAdapterAddressIsZero() public view {
        uint256 length = handler.registeredIdsLength();
        for (uint256 i = 0; i < length; i++) {
            bytes32 id = handler.registeredIds(i);
            (IYieldSource adapter, bool exists, ) = spoke.adapters(id);
            if (!exists) {
                assertEq(
                    address(adapter),
                    address(0),
                    "removed adapter address not zero"
                );
            }
        }
    }

    // =========================================================================
    // Helper
    // =========================================================================

    function _isInActiveAdapters(bytes32 id) internal view returns (bool) {
        uint256 length = spoke.activeAdaptersLength();
        for (uint256 i = 0; i < length; i++) {
            if (spoke.activeAdapters(i) == id) return true;
        }
        return false;
    }
}
