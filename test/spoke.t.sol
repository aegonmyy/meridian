// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SpokeVault} from "../src/Spoke.sol";
import {Asset} from "./mocks/Asset.sol";
import {Link} from "./mocks/Link.sol";

contract spokeTest is Test {
    SpokeVault spoke;
    address public hub;
    Asset public asset;
    address public router;
    address public owner;
    Link public link;
    uint64 public hubSelector;

    function setUp() external {
        hub = makeAddr("hub");
        asset = new Asset();
        router = makeAddr("router");
        owner = makeAddr("owner");
        link = new Link();
        hubSelector = uint64(39);

        spoke = new SpokeVault(
            hub,
            address(asset),
            router,
            owner,
            address(link),
            hubSelector
        );
    }

    function test_testAdapterSetsAndUpdates() public {
        vm.prank(owner);
        spoke.setAdapter(bytes32("adapter1"), makeAddr("adapter1"));
        assert(spoke.activeAdapters(0) == bytes32("adapter1"));
    }
}
