// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../../../../src/Spoke.sol";

// =========================================================================
// Handler
// =========================================================================

contract SpokeVaultHandler is Test {
    SpokeVault public spoke;
    address public owner;

    bytes32[] public registeredIds;
    mapping(bytes32 => bool) public isRegistered;
    mapping(bytes32 => bool) public ghostEverRegistered;

    // ghost variables — track expected state independently
    uint256 public ghostActiveAdaptersLength;

    constructor(SpokeVault _spoke, address _owner) {
        spoke = _spoke;
        owner = _owner;
    }

    function setAdapter(bytes32 id, address adapter) public {
        if (adapter == address(0)) return;
        if (id == bytes32(0)) return;
        bool wasRegistered = isRegistered[id];
        vm.prank(owner);
        spoke.setAdapter(id, adapter);
        if (!wasRegistered) {
            registeredIds.push(id);
            isRegistered[id] = true;
            ghostActiveAdaptersLength++;
            ghostEverRegistered[id] = true;
        }
    }

    function removeAdapter(uint256 idSeed) public {
        if (registeredIds.length == 0) return;
        bytes32 id = registeredIds[idSeed % registeredIds.length];
        (, bool exists, ) = spoke.adapters(id);
        if (!exists) return;
        vm.prank(owner);
        spoke.removeAdapter(id);
        // NOTE: ghost_activeAdaptersLength stays same — array never shrinks
    }

    function registeredIdsLength() external view returns (uint256) {
        return registeredIds.length;
    }
}
