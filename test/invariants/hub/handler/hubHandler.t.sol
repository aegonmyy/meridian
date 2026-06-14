// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {HUB} from "../../../../src/Hub.sol";

contract HubVaultHandler is Test {
    HUB public hub;
    address public owner;

    uint64[] public registeredSelectors;
    mapping(uint64 => bool) public isRegistered;
    mapping(uint64 => address) public ghostCurrentSpoke;

    uint256 public ghostSpokeChainSelectorsLength;
    mapping(uint64 => bool) public ghostEverRegistered;

    constructor(HUB _hub, address _owner) {
        hub = _hub;
        owner = _owner;
    }

    function addSpoke(uint64 selector, address spoke) public {
        if (selector == 0) return;
        if (spoke == address(0)) return;
        (address _spoke, , ) = hub.spokes(selector);
        if (hub.isValidSpoke(spoke) && _spoke != spoke) return;

        bool wasRegistered = isRegistered[selector];

        vm.prank(owner);
        hub.addSpoke(selector, spoke);

        if (!wasRegistered) {
            registeredSelectors.push(selector);
            isRegistered[selector] = true;
            ghostSpokeChainSelectorsLength++;
            ghostEverRegistered[selector] = true;
        }

        ghostCurrentSpoke[selector] = spoke;
    }

    function removeSpoke(uint256 selectorSeed) public {
        if (registeredSelectors.length == 0) return;
        uint64 selector = registeredSelectors[
            selectorSeed % registeredSelectors.length
        ];
        (, bool exists, ) = hub.spokes(selector);
        if (!exists) return;

        vm.prank(owner);
        hub.removeSpoke(selector);

        ghostCurrentSpoke[selector] = address(0);
    }

    function registeredSelectorsLength() external view returns (uint256) {
        return registeredSelectors.length;
    }
}
