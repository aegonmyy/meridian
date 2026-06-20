// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {HUB} from "../../../../src/Hub.sol";
import {Asset} from "../../../mocks/Asset.sol";
import {SpokeVault} from "../../../../src/Spoke.sol";
import {CCIPHelpers} from "../../../../src/libraries/CCIPHelpers.sol";

contract HubVaultHandler is Test {
    HUB public hub;
    address public owner;
    Asset public usdc;
    uint64[] public registeredSelectors;
    mapping(uint64 => bool) public isRegistered;
    mapping(uint64 => address) public ghostCurrentSpoke;

    uint256 public ghostSpokeChainSelectorsLength;
    mapping(uint64 => bool) public ghostEverRegistered;
    address[] public depositors;
    mapping(address => uint256) public ghostDepositedAmount;
    uint256 public ghostTotalPrincipal;
    uint256 public ghostTotalDeposits;

    SpokeVault public spoke;

    address public rebalancer;
    uint64 public chainSelector;

    bytes32 public constant AAVE = keccak256("AAVE");
    bytes32 public constant COMPOUND = keccak256("COMPOUND");
    bytes32[] public protocolIds;

    // ghost variables
    uint256 public ghostTotalWithdrawn;
    uint256 public ghostTotalSentToSpokes;
    uint256 public ghostTotalRecalledFromSpokes;

    //uint256 public ghost_pendingWithdrawalsCount;

    //mapping(address => uint256) public ghost_userDeposited;
    // mapping(address => uint256) public ghost_userShares;

    constructor(
        HUB _hub,
        address _owner,
        Asset _usdc,
        SpokeVault _spoke,
        address _rebalancer,
        uint64 _chainSelector
    ) {
        hub = _hub;
        owner = _owner;
        usdc = _usdc;
        spoke = _spoke;
        rebalancer = _rebalancer;
        chainSelector = _chainSelector;

        // create bounded set of depositors
        depositors.push(makeAddr("alice"));
        depositors.push(makeAddr("bob"));
        depositors.push(makeAddr("charlie"));
        protocolIds.push(AAVE);
        protocolIds.push(COMPOUND);
        // fund them
        uint256 existingLength = _hub.spokeChainSelectorsLength();
        ghostSpokeChainSelectorsLength = existingLength;
        for (uint256 i = 0; i < existingLength; i++) {
            uint64 selector = _hub.spokeChainSelectors(i);
            registeredSelectors.push(selector);
            isRegistered[selector] = true;
            ghostEverRegistered[selector] = true;
            (address spokeAddr,,) = _hub.spokes(selector);
            ghostCurrentSpoke[selector] = spokeAddr;
        }
        for (uint256 i = 0; i < depositors.length; i++) {
            usdc.mint(depositors[i], 1_000_000e6);
            vm.prank(depositors[i]);
            usdc.approve(address(hub), type(uint256).max);
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) public {
        address actor = depositors[actorSeed % depositors.length];
        amount = bound(amount, 1, 100_000e6);

        vm.prank(actor);
        hub.deposit(amount, actor);

        ghostDepositedAmount[actor] += amount;
        ghostTotalDeposits += amount;
        ghostTotalDeposits++;
    }

    function addSpoke(uint64 selector, address _spoke) public {
        if (selector == 0) return;
        if (_spoke == address(0)) return;
        if (
            hub.addressToSelector(_spoke) != 0 &&
            hub.addressToSelector(_spoke) != selector
        ) return;

        bool wasRegistered = isRegistered[selector];

        vm.prank(owner);
        hub.addSpoke(selector, _spoke);

        if (!wasRegistered) {
            registeredSelectors.push(selector);
            isRegistered[selector] = true;
            ghostSpokeChainSelectorsLength++;
            ghostEverRegistered[selector] = true;
        }

        ghostCurrentSpoke[selector] = _spoke;
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

    function sendToSpoke(uint256 protocolSeed, uint256 amount) public {
        // only send if hub has idle balance
        uint256 idle = usdc.balanceOf(address(hub));
        if (idle == 0) return;
        if (idle < 1e6) return;
        amount = bound(amount, 1e6, idle);
        bytes32 protocol = protocolIds[protocolSeed % protocolIds.length];

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: protocol,
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        vm.prank(rebalancer);
        try hub.sendToSpoke(chainSelector, instructions) {
            ghostTotalSentToSpokes += amount;
        } catch {}
    }

    function recallFromSpoke(uint256 amount) public {
        // only recall if spoke has balance
        uint256 spokeBalance = hub.spokeBalances(chainSelector);
        if (spokeBalance == 0) return;

        amount = bound(amount, 1e6, spokeBalance);

        CCIPHelpers.AdapterInstructions[]
            memory instructions = new CCIPHelpers.AdapterInstructions[](1);
        instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });

        bytes32 messageId;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amount)
            mstore(add(ptr, 0x20), timestamp())
            messageId := keccak256(ptr, 0x40)
            mstore(0x40, add(ptr, 0x40))
        }

        vm.prank(rebalancer);
        try hub.recallFromSpoke(chainSelector, instructions, messageId) {
            ghostTotalRecalledFromSpokes += amount;
        } catch {}
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function depositorsLength() external view returns (uint256) {
        return depositors.length;
    }

    function registeredSelectorsLength() external view returns (uint256) {
        return registeredSelectors.length;
    }
}
