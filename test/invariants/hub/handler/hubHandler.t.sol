// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
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

    /// @dev WI-4: every withdrawal id that has ever been queued (Path 2 or Path 3). The
    /// hub exposes no enumeration of pendingWithdrawals, so the handler must capture ids
    /// itself from the WithdrawalQueued event as they're issued. Entries whose
    /// pendingWithdrawals[id].shares has since gone to 0 are settled/cancelled. The
    /// invariants filter on that, not on removing entries from this array.
    bytes32[] public ghostPendingWithdrawalIds;
    bytes32 constant WITHDRAWAL_QUEUED_SIG =
        keccak256("WithdrawalQueued(address,bytes32,uint256,uint256,uint256)");

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

        // Repointing an ALREADY-registered selector to a codeless address is a realistic
        // owner misconfiguration, but it silently blackholes any in-flight or future
        // message to that selector (no contract there to ever send a confirm back),
        // permanently desyncing inTransitAssets in a way no amount of correct hub-side
        // accounting can prevent. That failure mode belongs to addSpoke's own operational
        // safety (out of scope for the WI-4 invariants this handler feeds), so skip it here
        // the same way removeSpoke is already guarded against funded-spoke corruption.
        if (wasRegistered && _spoke.code.length == 0) return;

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

        // WI-6 added an on-chain guard (spokeBalances[selector] == 0 and no in-flight legs)
        // Wrapped in try/catch so the fuzzer also exercises the revert path for a funded
        // or in-flight spoke rather than only the success path.
        vm.prank(owner);
        try hub.removeSpoke(selector) {
            ghostCurrentSpoke[selector] = address(0);
        } catch {}
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
        // only recall if spoke has a non-dust balance, bound(1e6, spokeBalance) panics
        // (max < min) once repeated partial recalls leave sub-1e6 dust behind, which is a
        // reachable state regardless of WI-1/WI-2 (spokeBalance decreases by exact recalled
        // amounts, and can land below 1e6 after several cycles).
        uint256 spokeBalance = hub.spokeBalances(chainSelector);
        if (spokeBalance < 1e6) return;

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

    /// @notice WI-4: a random depositor redeems a random fraction of their shares
    /// @dev May settle synchronously (Path 1/2 in this synchronous harness) or, if the
    ///      spoke's reported balance can't cover the haircut-capped shortfall, revert with
    ///      InsufficientRecallLiquidity: wrapped in try/catch since that is expected,
    ///      fail-closed behavior, not a bug. Captures the issued withdrawal id (if any) from
    ///      the WithdrawalQueued event so the invariants below can sum over real entries.
    function redeemShares(uint256 actorSeed, uint256 fractionBps) public {
        address actor = depositors[actorSeed % depositors.length];
        uint256 shares = hub.balanceOf(actor);
        if (shares == 0) return;
        fractionBps = bound(fractionBps, 1, 10_000);
        uint256 redeemAmount = (shares * fractionBps) / 10_000;
        if (redeemAmount == 0) return;

        vm.recordLogs();
        vm.prank(actor);
        try hub.redeem(redeemAmount, actor, actor) {
            bytes32 id = _lastWithdrawalQueuedId();
            if (id != bytes32(0)) {
                ghostPendingWithdrawalIds.push(id);
            }
        } catch {}
    }

    /// @notice WI-4: settle/cancel maintenance calls so pending entries don't only ever grow
    function attemptSettlement(uint256 idSeed) public {
        if (ghostPendingWithdrawalIds.length == 0) return;
        bytes32 id = ghostPendingWithdrawalIds[
            idSeed % ghostPendingWithdrawalIds.length
        ];
        try hub.attemptSettlement(id) {} catch {}
    }

    function cancelWithdrawal(uint256 idSeed) public {
        if (ghostPendingWithdrawalIds.length == 0) return;
        bytes32 id = ghostPendingWithdrawalIds[
            idSeed % ghostPendingWithdrawalIds.length
        ];
        (, , , , , uint64 requestedAt, , address entryOwner) = hub
            .pendingWithdrawals(id);
        if (entryOwner == address(0)) return;
        vm.warp(block.timestamp + hub.WITHDRAWAL_TIMEOUT() + 1);
        vm.prank(entryOwner);
        try hub.cancelWithdrawal(id) {} catch {}
        requestedAt; // silence unused-var warning
    }

    function _lastWithdrawalQueuedId() internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == WITHDRAWAL_QUEUED_SIG) {
                return logs[i - 1].topics[2];
            }
        }
        return bytes32(0);
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

    function pendingWithdrawalIdsLength() external view returns (uint256) {
        return ghostPendingWithdrawalIds.length;
    }
}
