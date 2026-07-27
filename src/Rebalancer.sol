// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {AllocationMaths} from "./libraries/AllocationMaths.sol";
import {IHub} from "./interfaces/IHub.sol";
import {AllocationProposal} from "./interfaces/IRebalancer.sol";

/// @title Rebalancer
/// @notice Safety layer between the off-chain agent and the HubVault, validates all allocation
///         proposals and intra-spoke rebalance instructions before forwarding to hub.
/// @dev All capital movement flows through this contract. The agent (AgentConsumer) submits
///      proposals; Rebalancer enforces on-chain guards before calling hub functions.
///      Guards enforced in order:
///      1. Access control: only owner or AgentConsumer
///      2. Allocation validity: sum, per-market cap, chain cap, dust floor
///      3. APY threshold: optimal must beat current by >= 50 bps (proposeAllocation only)
///      4. Chain whitelist: all selectors in proposal must be approved
///      5. Protocol whitelist: all protocol ids must be approved
///      6. Max single move: no allocation may exceed 30% of totalAssets
contract Rebalancer {
    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice HubVault contract on Ethereum, target for all capital movement calls
    /// @dev Immutable: set once at deployment. Hub must have this contract as its REBALANCER.
    IHub public immutable HUB;

    /// @notice Address of the AgentConsumer contract, authorized alongside owner to call guards
    /// @dev Immutable, off-chain agent submits proposals through AgentConsumer which calls here.
    address public immutable AGENT_CONSUMER;

    /// @notice Contract owner, authorized to call all functions and manage whitelists
    /// @dev Mutable: can be transferred. Should be a multisig before mainnet.
    address public owner;

    /// @notice Maps CCIP chain selectors to their whitelist status
    /// @dev Only whitelisted chains can receive capital. Managed by owner or agentConsumer.
    mapping(uint64 => bool) public whitelistedChains;

    /// @notice Maps protocol identifiers to their whitelist status
    /// @dev Only whitelisted protocols can receive capital. Key is e.g. keccak256("AAVE").
    mapping(bytes32 => bool) public whitelistedProtocols;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when constructor receives a zero address argument
    error InvalidConstructorArguments();

    /// @notice Thrown when caller is neither owner nor AgentConsumer
    error NotAuthorized();

    /// @notice Thrown when source and target adapter are the same in rebalance()
    error SourceEqualsTarget();

    /// @notice Thrown when rebalance amount is zero
    error ZeroAmount();

    /// @notice Thrown when optimal weighted APY does not exceed current by >= 50 bps
    error BelowThreshold();

    error MaxSingleMoveExceeded(); // kept for ABI compatibility, no longer thrown

    /// @notice Thrown when a chain selector in the proposal is not whitelisted
    error ChainNotWhitelisted();

    /// @notice Thrown when a protocol id in the proposal is not whitelisted
    error ProtocolNotWhitelisted();

    /// @notice Thrown when proposed allocations fail validateAllocation checks
    /// @dev Covers: sum != 10000, market > 6000 bps, chain > 8000 bps, dust < 500 bps
    error InvalidAllocation();

    /// @notice Thrown when a proposal's total requested amount exceeds hub's unreserved idle
    /// @dev WI-3 friendly pre-check, fails legibly before dispatching any per-chain sends,
    ///      instead of a partial dispatch dying deep inside a later chain's CCIP token
    ///      transfer. Mirrors (and is intentionally more conservative than racing with)
    ///      the authoritative guard enforced in HUB.sendToSpoke itself.
    error InsufficientIdleForProposal(uint256 requested, uint256 available);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted after a successful rebalance() or proposeAllocation() execution
    /// @dev RebalanceExecuted is not currently emitted: reserved for future use
    /// @param timestamp Block timestamp of execution
    /// @param weightedApy Optimal weighted APY from the accepted proposal (0 for rebalance())
    event RebalanceExecuted(uint256 timestamp, uint256 weightedApy);

    /// @notice Emitted when a chain selector is added to the whitelist
    /// @param chainSelector The CCIP chain selector that was whitelisted
    event ChainWhitelisted(uint64 chainSelector);

    /// @notice Emitted when a chain selector is removed from the whitelist
    /// @param chainSelector The CCIP chain selector that was removed
    event ChainRemovedFromWhitelist(uint64 chainSelector);

    /// @notice Emitted when a protocol identifier is added to the whitelist
    /// @param protocolId The bytes32 protocol identifier that was whitelisted
    event ProtocolWhitelisted(bytes32 protocolId);

    /// @notice Emitted when a protocol identifier is removed from the whitelist
    /// @param protocolId The bytes32 protocol identifier that was removed
    event ProtocolRemovedFromWhitelist(bytes32 protocolId);

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @notice Restricts access to owner or AgentConsumer
    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    /// @dev Extracted to reduce bytecode size from modifier inlining
    function _onlyAuthorized() internal view {
        if (msg.sender != owner && msg.sender != AGENT_CONSUMER) {
            revert NotAuthorized();
        }
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys the Rebalancer with immutable hub and agent references
    /// @dev All three addresses are required, zero address for any reverts.
    ///      Deploy Rebalancer after Hub is deployed (needs hub address).
    ///      Call hub.setRebalancer(address(this)) after deployment.
    /// @param _hub Address of the HubVault on Ethereum
    /// @param _agentConsumer Address of the AgentConsumer contract
    /// @param _owner Address of the contract owner: should be a multisig before mainnet
    constructor(address _hub, address _agentConsumer, address _owner) {
        if (
            _hub == address(0) ||
            _agentConsumer == address(0) ||
            _owner == address(0)
        ) revert InvalidConstructorArguments();
        HUB = IHub(_hub);
        AGENT_CONSUMER = _agentConsumer;
        owner = _owner;
    }

    // =========================================================================
    // Core Functions
    // =========================================================================

    /// @notice Executes an intra-spoke rebalance, moves capital between adapters on one chain
    /// @dev Guards enforced in order: access control, source != target,
    ///      amount != 0, chain whitelisted, both protocols whitelisted.
    ///      Does not validate APY gain: intra-spoke rebalances are manual operator decisions.
    ///      Does not enforce max single move: amount is absolute not proportional to totalAssets.
    ///      Calls hub.rebalance() which sends a REBALANCE CCIP message to the target spoke.
    /// @param _source bytes32 protocol identifier of the source adapter to withdraw from
    /// @param _target bytes32 protocol identifier of the target adapter to deposit into
    /// @param _amount Amount of USDC to move from source to target in the same spoke
    /// @param _chainSelector CCIP chain selector of the spoke where both adapters live
    function rebalance(
        bytes32 _source,
        bytes32 _target,
        uint256 _amount,
        uint64 _chainSelector
    ) external onlyAuthorized {
        if (_source == _target) revert SourceEqualsTarget();
        if (_amount == 0) revert ZeroAmount();
        if (!whitelistedChains[_chainSelector]) revert ChainNotWhitelisted();
        if (
            whitelistedProtocols[_target] == false ||
            whitelistedProtocols[_source] == false
        ) {
            revert ProtocolNotWhitelisted();
        }
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: _source,
            amount: _amount,
            targetAdapter: _target,
            targetAmount: 0
        });
        // Message id is derived inside the hub via its nonce'd _newMessageId helper
        // (WI-1): the rebalancer no longer derives collision-prone content ids.
        HUB.rebalance(_chainSelector, _instructions);
    }

    /// @notice Recalls capital off an overweight spoke back to hub idle. The "move weight
    ///         off a chain" lever that proposeAllocation alone cannot provide
    /// @dev WI-3 (Issue 5, Option A). Guards: access control, chain whitelisted, amount != 0.
    ///      No pendingWithdrawal is created: the hub just credits the arrived tokens as
    ///      ordinary idle and emits RecallCompleted once the CONFIRM_WITHDRAWAL lands.
    ///
    ///      Intended v1 operator flow (on-chain diff engine is explicitly out of scope, v2):
    ///        1. Off-chain agent computes the desired allocation diff.
    ///        2. For each overweight chain, call recallFromSpoke(selector, amount) to pull
    ///           capital back to hub idle.
    ///        3. Await the hub's RecallCompleted event confirming the funds landed.
    ///        4. Call proposeAllocation() sized against the now-larger idle balance,
    ///           HUB.sendToSpoke's solvency guard (and this contract's own pre-check) will
    ///           reject a proposal sized before the recall actually lands.
    /// @param _chainSelector CCIP chain selector of the spoke to recall from. Must be whitelisted
    /// @param _amount USDC amount to recall: must be nonzero
    function recallFromSpoke(
        uint64 _chainSelector,
        uint256 _amount
    ) external onlyAuthorized {
        if (_amount == 0) revert ZeroAmount();
        if (!whitelistedChains[_chainSelector]) revert ChainNotWhitelisted();
        HUB.recallFromSpoke(_chainSelector, _amount);
    }

    /// @notice Validates and executes a full cross-chain allocation proposal from the agent
    /// @dev Five guards enforced in order; any failure reverts without side effects:
    ///      1. onlyAuthorized: owner or AgentConsumer only
    ///      2. InvalidAllocation: validateAllocation(proposedAllocations) must pass
    ///      3. BelowThreshold: optimal weighted APY must exceed current by >= 50 bps
    ///      4. ChainNotWhitelisted: all chainSelectors in proposal must be approved
    ///      5. ProtocolNotWhitelisted: all protocolIds in proposal must be approved
    ///      On success: calls hub.sendToSpoke() per chain.
    ///      Known limitation: proposedAllocations amounts are in bps but sendToSpoke expects
    ///      absolute USDC amounts: the TODO comment in code flags this conversion gap.
    /// @param proposal The AllocationProposal struct containing current and proposed allocations,
    ///                 APYs, chain selectors, and protocol ids for all target chains
    function proposeAllocation(
        AllocationProposal memory proposal
    ) external onlyAuthorized {
        bool valid = AllocationMaths.validateAllocation(
            proposal.proposedAllocations
        );
        if (!valid) revert InvalidAllocation();

        uint256 currentWeightedApy = AllocationMaths.weightedApy(
            _flatten(proposal.currentAllocations),
            proposal.currentNetApys
        );
        uint256 optimalWeightedApy = AllocationMaths.weightedApy(
            _flatten(proposal.proposedAllocations),
            proposal.proposedNetApys
        );
        bool _shouldRebalance = AllocationMaths.shouldRebalance(
            currentWeightedApy,
            optimalWeightedApy
        );
        if (!_shouldRebalance) revert BelowThreshold();

        for (uint256 i = 0; i < proposal.chainSelectors.length; i++) {
            if (whitelistedChains[proposal.chainSelectors[i]] == false) {
                revert ChainNotWhitelisted();
            }
            for (uint256 j = 0; j < proposal.protocolIds[i].length; j++) {
                if (whitelistedProtocols[proposal.protocolIds[i][j]] == false) {
                    revert ProtocolNotWhitelisted();
                }
            }
        }

        // Sends are sized against deployable idle (idle minus reserved), not totalAssets.
        // Sizing against totalAssets meant a full 10000-bps proposal requested 100% of the
        // vault while being funded only from idle, so any balance already on a spoke (down to
        // a few wei of yield left stranded after a recall) pushed the request above idle and
        // reverted every re-allocation. Denominating the split against deployable idle instead
        // deploys the chosen split of whatever is available to deploy now and is unaffected by
        // balances sitting on spokes. Per-term flooring keeps the sum at or below deployable,
        // so the guard below only trips on a reserved-idle race, never on stranded dust.
        uint256 idle = HUB.idleBalance();
        uint256 reserved = HUB.reservedAssets();
        uint256 deployable = idle > reserved ? idle - reserved : 0;
        if (deployable == 0) revert InsufficientIdleForProposal(0, 0);

        uint256 totalRequested;
        for (uint256 i = 0; i < proposal.protocolIds.length; i++) {
            for (uint256 j = 0; j < proposal.protocolIds[i].length; j++) {
                totalRequested +=
                    (proposal.proposedAllocations[i][j] * deployable) /
                    10_000;
            }
        }
        if (totalRequested > deployable) {
            revert InsufficientIdleForProposal(totalRequested, deployable);
        }

        for (uint256 i = 0; i < proposal.protocolIds.length; i++) {
            CCIPHelpers.AdapterInstructions[]
                memory _instructions = new CCIPHelpers.AdapterInstructions[](
                    proposal.protocolIds[i].length
                );
            for (uint256 j = 0; j < proposal.protocolIds[i].length; j++) {
                _instructions[j] = CCIPHelpers.AdapterInstructions({
                    adapter: proposal.protocolIds[i][j],
                    amount: (proposal.proposedAllocations[i][j] * deployable) /
                        10_000,
                    targetAdapter: bytes32(0),
                    targetAmount: 0
                });
            }
            HUB.sendToSpoke(proposal.chainSelectors[i], _instructions);
        }
    }

    // =========================================================================
    // Whitelist Management
    // =========================================================================

    /// @notice Adds a CCIP chain selector to the whitelist
    /// @dev Capital can only be deployed to whitelisted chains. No-op if already whitelisted.
    /// @param _chainSelector CCIP chain selector to whitelist
    function addChainToWhitelist(
        uint64 _chainSelector
    ) external onlyAuthorized {
        whitelistedChains[_chainSelector] = true;
        emit ChainWhitelisted(_chainSelector);
    }

    /// @notice Removes a CCIP chain selector from the whitelist
    /// @dev Capital already deployed to this chain is not recalled. Only new deployments are blocked.
    ///      Use in combination with a recall instruction to fully exit a chain.
    /// @param _chainSelector CCIP chain selector to remove from whitelist
    function removeChainFromWhitelist(
        uint64 _chainSelector
    ) external onlyAuthorized {
        whitelistedChains[_chainSelector] = false;
        emit ChainRemovedFromWhitelist(_chainSelector);
    }

    /// @notice Adds a protocol identifier to the whitelist
    /// @dev Capital can only be deployed to whitelisted protocols. No-op if already whitelisted.
    /// @param _protocolId bytes32 protocol identifier (e.g. keccak256("AAVE"))
    function addProtocolToWhitelist(
        bytes32 _protocolId
    ) external onlyAuthorized {
        whitelistedProtocols[_protocolId] = true;
        emit ProtocolWhitelisted(_protocolId);
    }

    /// @notice Removes a protocol identifier from the whitelist
    /// @dev Capital already deployed to this protocol is not recalled. Only new deployments are blocked.
    ///      Use spoke.removeAdapter() on the target chain to fully disable a protocol.
    /// @param _protocolId bytes32 protocol identifier to remove from whitelist
    function removeProtocolFromWhitelist(
        bytes32 _protocolId
    ) external onlyAuthorized {
        whitelistedProtocols[_protocolId] = false;
        emit ProtocolRemovedFromWhitelist(_protocolId);
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Flattens a 2D uint256 array into a 1D array for AllocationMaths functions
    /// @dev AllocationMaths.weightedApy expects flat arrays: this converts the nested
    ///      per-chain per-protocol structure of AllocationProposal into a single sequence.
    ///      Order preserved: outer array iterated first, inner array second.
    /// @param arr 2D array where arr[chain][protocol] holds an allocation or APY value
    /// @return flat 1D array concatenating all inner arrays in order
    function _flatten(
        uint256[][] memory arr
    ) internal pure returns (uint256[] memory flat) {
        uint256 total;
        for (uint256 i = 0; i < arr.length; i++) {
            total += arr[i].length;
        }
        flat = new uint256[](total);
        uint256 idx;
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = 0; j < arr[i].length; j++) {
                flat[idx++] = arr[i][j];
            }
        }
    }
}
