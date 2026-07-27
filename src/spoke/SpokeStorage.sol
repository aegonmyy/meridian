// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {CCIPReceiver} from "@chainlink+/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {CCIPHelpers} from "../libraries/CCIPHelpers.sol";
import {InvalidConstructorArguments} from "../errors/spokeErrors.sol";

/// @title SpokeStorage
/// @notice Shared storage, structs, constants, events, constructor, and cross-module hook
///         declarations for the Spoke. All state lives here, in the exact declaration order
///         of the pre-split Spoke.sol, so storage slot assignment is unaffected by the
///         module split.
/// @dev Every Spoke module (SpokeAdminModule, SpokeHandlersModule, SpokeConfirmsModule)
///      inherits this contract directly (sibling inheritance). None of them inherit each
///      other. Any function called across module boundaries must be declared here as a
///      bodiless `virtual` function and implemented with `override` in its owning module.
///      That is the only way one sibling module's code can see a function implemented in
///      another. The hook set below is derived from the real call graph.
abstract contract SpokeStorage is CCIPReceiver, Ownable {
    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Stores adapter contract and registration status for a yield protocol
    /// @dev `exists` differentiates unregistered (never seen) vs removed (was active, now disabled).
    ///      `everRegistered` is write-once: prevents duplicate entries in activeAdapters
    ///      when a protocol is removed then re-registered on the same protocolId.
    struct AdapterInfo {
        /// @dev The IYieldSource adapter contract for this protocol. address(0) if removed
        IYieldSource adapter;
        /// @dev True if adapter is currently active: false if disabled via removeAdapter
        bool exists;
        /// @dev True once a protocolId has been registered. Never reset. Guards array deduplication.
        bool everRegistered;
    }

    /// @notice Snapshot of a single adapter's balance, returned by getAllocations()
    struct AdapterBalances {
        /// @dev The bytes32 protocol identifier (e.g. keccak256("AAVE"))
        bytes32 protocolId;
        /// @dev Current total USDC managed by this adapter including accrued yield
        uint256 balance;
    }

    /// @notice A confirm message whose outbound ccipSend failed and is queued for retry
    /// @dev WI-2d reconciliation record. Deliberately minimal, and spokeBalance is not stored
    ///      here, it is recomputed fresh at retry time so a stale snapshot is never resent.
    struct PendingConfirm {
        /// @dev Which outbound message type this confirm is (CONFIRM_RECEIPT, CONFIRM_REBALANCE,
        ///      CONFIRM_WITHDRAWAL, or REPORT_BALANCE response)
        CCIPHelpers.MessageType messageType;
        /// @dev The messageId being confirmed: echoed from the originating hub message
        bytes32 messageId;
        /// @dev USDC amount to attach on retry, 0 for token-less confirms
        uint256 actualAmount;
        /// @dev True once successfully retried: resolved entries are inert
        bool resolved;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Address of the HubVault on Ethereum, sole authorized CCIP message sender
    /// @dev Validated in _ccipReceive for every message. Mutable via setHub() so Hub can
    ///      be redeployed (e.g. to add features) without redeploying all spokes.
    address public HUB;

    /// @notice The ERC20 asset managed by this vault (USDC in v1)
    /// @dev Immutable, single asset per spoke in v1. Multi-asset support deferred to v2.
    IERC20 public immutable ASSET;

    /// @notice CCIP chain selector for Ethereum mainnet, destination for all outbound messages
    /// @dev Immutable: all spoke-to-hub messages use this selector regardless of operation type.
    uint64 public immutable HUB_CHAIN_SELECTOR;

    /// @notice LINK token used to pay CCIP fees for all outbound messages
    /// @dev Immutable: spoke must hold sufficient LINK balance for all response messages.
    IERC20 public immutable LINK;

    /// @notice Maps protocol identifiers to their adapter registration info
    /// @dev Key is an arbitrary bytes32 agreed upon at deployment, e.g. keccak256("AAVE").
    ///      Use setAdapter() to register or update, removeAdapter() to disable.
    mapping(bytes32 => AdapterInfo) public adapters;

    /// @notice Ordered list of all protocol identifiers ever registered, including removed ones
    /// @dev Soft-delete pattern: entries are never removed. Inactive adapters are
    ///      skipped during iteration via the `exists` flag on AdapterInfo.
    ///      Kept small by design, 3 to 5 protocols max per spoke in v1.
    bytes32[] public activeAdapters;

    /// @notice Queue of confirm messages whose outbound ccipSend failed and await retry
    /// @dev WI-2d: see PendingConfirm. Never shrinks; resolved entries stay for history and
    ///      are skipped on retry. Grows only when LINK is exhausted or the router hiccups.
    PendingConfirm[] public pendingConfirms;

    /// @notice Count of pendingConfirms entries not yet resolved
    /// @dev FX-6a: maintained incrementally (incremented in _queueConfirm, decremented in
    ///      retryConfirm on success) so setHub's guard is O(1) instead of linear-scanning
    ///      the append-only pendingConfirms array on every call. The array itself stays
    ///      untouched (history is useful): only this counter changes.
    uint256 public unresolvedConfirmCount;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new adapter is registered or an existing one is updated
    /// @param protocolId The bytes32 identifier for the yield protocol
    /// @param adapter Address of the new IYieldSource adapter contract
    event AdapterSet(bytes32 indexed protocolId, address indexed adapter);

    /// @notice Emitted when an adapter is disabled via removeAdapter
    /// @param protocolId The bytes32 identifier of the disabled protocol
    event AdapterRemoved(bytes32 indexed protocolId);

    /// @notice Emitted when the Hub address is updated via setHub
    /// @param oldHub Previous Hub address
    /// @param newHub New Hub address
    event HubUpdated(address indexed oldHub, address indexed newHub);

    /// @notice Emitted when a single DEPOSIT instruction is skipped instead of reverting
    /// @dev Skip reasons: zero amount, unknown/removed adapter, or adapter.deposit() reverted.
    ///      The instruction's amount is left as spoke idle. Never lost, just undeployed.
    /// @param protocolId The adapter identifier the instruction targeted
    /// @param amount The amount that was left idle
    /// @param reason Raw revert reason bytes, or a short ASCII literal for validation skips
    event DepositInstructionFailed(bytes32 indexed protocolId, uint256 amount, bytes reason);

    /// @notice Emitted when a single REBALANCE instruction is skipped instead of reverting
    /// @param source The source adapter identifier
    /// @param target The target adapter identifier
    /// @param amount The amount that could not be moved
    /// @param reason Raw revert reason bytes, or a short ASCII literal for validation skips
    event RebalanceInstructionFailed(bytes32 indexed source, bytes32 indexed target, uint256 amount, bytes reason);

    /// @notice Emitted whenever a WITHDRAW_AMOUNT recall returns less than the hub requested
    /// @param requested The amount the hub asked for
    /// @param actualPulled The amount actually pulled from idle + adapters
    event RecallShortfall(uint256 requested, uint256 actualPulled);

    /// @notice Emitted when a single adapter's pull fails during a WITHDRAW_AMOUNT recall
    /// @dev FX-6b. Min-capping (pullAmount <= adapter.totalAssets()) already prevents the
    ///      insufficient-balance revert; this covers the residual case. A protocol-level
    ///      condition (paused Aave pool, frozen Comet market) that still reverts withdraw()
    ///      regardless of the requested amount. That adapter's leg is skipped; the loop
    ///      continues with the remaining adapters, and the truthful actualPulled (via
    ///      RecallShortfall if short) still reaches the hub instead of stalling the whole
    ///      recall: the original Issue-1 shape this closes.
    /// @param adapter The protocol identifier whose pull failed
    /// @param attempted The amount that was being pulled from it
    /// @param reason Raw revert reason bytes
    event RecallPullFailed(bytes32 indexed adapter, uint256 attempted, bytes reason);

    /// @notice Emitted when an outbound confirm's ccipSend fails and is queued for retry
    /// @param index Index into pendingConfirms where this record was stored
    /// @param messageType The message type that failed to send
    /// @param messageId The messageId of the failed confirm
    event ConfirmSendFailed(uint256 indexed index, CCIPHelpers.MessageType messageType, bytes32 messageId);

    /// @notice Emitted when a queued confirm is successfully retried via retryConfirm
    /// @param index Index into pendingConfirms that was resolved
    event ConfirmRetried(uint256 indexed index);

    /// @notice Emitted when owner deploys parked spoke idle into a registered adapter
    /// @param protocolId The adapter identifier idle was deployed into
    /// @param amount The amount deployed
    event IdleDeployed(bytes32 indexed protocolId, uint256 amount);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys the SpokeVault with initial chain and protocol configuration
    /// @dev CCIPReceiver validates _router internally, no explicit check needed here.
    ///      Parent constructors run before the zero address checks in the body.
    ///      _hubSelector == 0 is rejected as it would make all outbound CCIP messages fail.
    ///      HUB is mutable post-deployment via setHub(): update when Hub is redeployed.
    /// @param _hub Address of the HubVault on Ethereum mainnet
    /// @param _asset Address of the ERC20 asset this vault manages (USDC)
    /// @param _router Address of the Chainlink CCIP router on this L2 chain
    /// @param _owner Address of the contract owner: should be a multisig before mainnet
    /// @param _link Address of the LINK token on this L2 chain
    /// @param _hubSelector CCIP chain selector for Ethereum mainnet
    constructor(
        address _hub,
        address _asset,
        address _router,
        address _owner,
        address _link,
        uint64 _hubSelector
    ) CCIPReceiver(_router) Ownable(_owner) {
        if (
            _hub == address(0) ||
            _asset == address(0) ||
            _router == address(0) ||
            _link == address(0) ||
            _hubSelector == 0
        ) revert InvalidConstructorArguments();
        HUB = _hub;
        ASSET = IERC20(_asset);
        HUB_CHAIN_SELECTOR = _hubSelector;
        LINK = IERC20(_link);
    }

    // =========================================================================
    // Cross-Module Hooks
    // =========================================================================
    // Bodiless `virtual` declarations for every function called across module boundaries in
    // the real call graph. Each is implemented with `override` in exactly one module. Unlike
    // the plan's suggested starting list of 3 (_aggregatedSpokeBalance, _buildConfirmMessage,
    // _sendOrQueueConfirm), only 2 hooks are actually needed: _buildConfirmMessage's only two
    // callers (retryConfirm, _sendOrQueueConfirm) both end up in SpokeConfirmsModule, same
    // module as its own implementation, so no hook is needed for it. Spoke.sol has no
    // `this.fn()` self-calls (unlike Hub), so no external-function hooks are needed either.

    /// @dev Hook for _aggregatedSpokeBalance, implemented in SpokeHandlersModule, called
    ///      cross-module from SpokeConfirmsModule._buildConfirmMessage.
    function _aggregatedSpokeBalance()
        internal
        view
        virtual
        returns (uint256 aggregatedSpokeBalance);

    /// @dev Hook for _sendOrQueueConfirm, implemented in SpokeConfirmsModule, called
    ///      cross-module from SpokeHandlersModule's four inbound message handlers
    ///      (_handleDeposit, _handleRebalance, _handleWithdrawalWithAmount, _reportBalance).
    function _sendOrQueueConfirm(
        CCIPHelpers.MessageType _type,
        bytes32 _messageId,
        uint256 _tokenAmount
    ) internal virtual;
}
