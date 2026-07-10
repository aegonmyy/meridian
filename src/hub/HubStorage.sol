// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink+/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CCIPHelpers} from "../libraries/CCIPHelpers.sol";
import {InvalidConstructorArguments, NotRebalancer} from "../errors/hubErrors.sol";

/// @title HubStorage
/// @notice Shared storage, structs, constants, events, constructor, and cross-module hook
///         declarations for the Hub. All state lives here, in the exact declaration order of
///         the pre-split Hub.sol, so storage slot assignment is unaffected by the module split.
/// @dev Every Hub module (HubAdminModule, HubMessagingModule, HubWithdrawalModule) inherits
///      this contract directly (sibling inheritance) — none of them inherit each other. Any
///      function that is called across module boundaries (including via `this.fn()` self-calls
///      used to change msg.sender context) must be declared here as a bodiless `virtual`
///      function and implemented with `override` in its owning module — that is the only way
///      one sibling module's code can see a function implemented in another sibling module.
///      See the executor's final report for the real call-graph derivation of the hook set
///      below (it differs slightly from the plan's suggested starting set, as instructed).
abstract contract HubStorage is ERC4626, CCIPReceiver, Ownable, Pausable {
    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Tracks a queued withdrawal awaiting spoke balance confirmation or fund recall
    /// @dev WI-4 withdrawal engine v2. Created in Path 2 (stale balances) and Path 3
    ///      (insufficient idle). Path 1: no pending withdrawal created — settled synchronously.
    ///      `quotedAssets` is the previewRedeem() value AT REQUEST TIME — reference and recall
    ///      sizing only. It is NOT a promise: settlement recomputes payout via previewRedeem()
    ///      again at claim time (claim-time pricing is the decided v2 semantic — a loss or
    ///      gain reported while a Path 3 recall is in flight changes what the withdrawer
    ///      actually receives). `reservedIdle` is the idle locked at request time
    ///      (`<= quotedAssets`) — `reservedAssets` is decremented by exactly this amount on
    ///      settlement or cancellation, regardless of what payout ends up being.
    ///      `arrivedAssets` accumulates the ACTUAL token amounts (destTokenAmounts — never the
    ///      payload's claimed amount) from each Path 3 recall leg as they land.
    ///      `pendingLegs` counts outstanding Path 3 recall legs — 0 for Path 2 (no legs, just
    ///      a REPORT_BALANCE refresh) and 0 once all Path 3 legs have arrived.
    struct PendingWithdrawal {
        /// @dev Shares transferred to hub contract at queue time — burned on settlement
        uint256 shares;
        /// @dev previewRedeem(shares) at request time — reference & recall sizing only, not a promise
        uint256 quotedAssets;
        /// @dev Idle USDC reserved (locked) at request time — <= quotedAssets
        uint256 reservedIdle;
        /// @dev Sum of ACTUAL recalled token arrivals for this withdrawal's Path 3 legs
        uint256 arrivedAssets;
        /// @dev Outstanding Path 3 recall legs — 0 for Path 2, decrements as legs arrive
        uint32 pendingLegs;
        /// @dev Block timestamp when withdrawal was queued — gates cancelWithdrawal via WITHDRAWAL_TIMEOUT
        uint64 requestedAt;
        /// @dev Address that will receive the USDC on settlement
        address receiver;
        /// @dev Address whose shares were transferred to hub — also the only address that can cancel
        address owner;
    }

    /// @notice Tracks a single outstanding DEPOSIT leg's origin selector and send time
    /// @dev FX-2. Replaces the old parallel `inTransitSince` mapping — reconcileTransit needs
    ///      to know which selector's inTransitToSpoke counter to decrement, and an owner-
    ///      supplied selector parameter would be unverifiable (the stored value is the only
    ///      trustworthy source). Both fields fit one slot.
    struct TransitLeg {
        /// @dev Chain selector the DEPOSIT was sent to
        uint64 selector;
        /// @dev block.timestamp the DEPOSIT was sent — gates TRANSIT_RECONCILE_DELAY
        uint64 sentAt;
    }

    /// @notice Stores spoke vault address and registration status for a chain
    /// @dev `exists` is the source of truth for active status — false means disabled.
    ///      `everRegistered` is write-once — prevents duplicate entries in spokeChainSelectors
    ///      when a spoke is removed then re-added on the same selector.
    struct SpokeInfo {
        /// @dev Address of the SpokeVault contract on the target chain
        address spoke;
        /// @dev True if spoke is currently active — false if disabled via removeSpoke
        bool exists;
        /// @dev True once a selector has been registered — never reset. Guards array deduplication.
        bool everRegistered;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice LINK token used to pay CCIP fees for all outbound messages
    /// @dev Immutable — set once at deployment. Hub must hold sufficient LINK balance.
    IERC20 public immutable LINK;

    /// @notice Address of the Rebalancer contract — sole authorized caller for capital movement
    /// @dev Mutable to resolve circular deployment dependency between Hub and Rebalancer.
    ///      Use setRebalancer() after deployment. Protected by onlyOwner.
    address public REBALANCER;

    /// @notice Ordered list of all chain selectors ever registered as spokes
    /// @dev Soft-delete pattern — entries are never removed. Inactive spokes are
    ///      skipped during iteration via the `exists` flag on SpokeInfo.
    ///      Used to iterate spokeBalances in totalManagedAssets().
    uint64[] public spokeChainSelectors;

    /// @notice Total USDC currently reserved for pending withdrawals
    /// @dev Prevents concurrent withdrawers from being promised the same idle balance.
    ///      Incremented when a withdrawal is queued, decremented on settlement.
    uint256 public reservedAssets;

    /// @notice Maps CCIP chain selector to spoke vault info for that chain
    mapping(uint64 => SpokeInfo) public spokes;

    /// @notice Reverse mapping from spoke address to its registered chain selector
    /// @dev Enables O(1) lookup to prevent the same address being registered on two selectors.
    ///      Deleted when a spoke is removed or updated to a new address.
    mapping(address => uint64) public addressToSelector;

    /// @notice Last reported total balance per spoke chain in USDC
    /// @dev Updated on every CONFIRM_RECEIPT, CONFIRM_REBALANCE, and REPORT_BALANCE message.
    ///      May be slightly stale between reports — staleness bounded by MAX_STALENESS.
    mapping(uint64 => uint256) public spokeBalances;

    /// @notice Unix timestamp of last balance report received per spoke
    /// @dev Compared against block.timestamp to determine staleness before processing withdrawals.
    ///      A spoke with timestamp 0 is treated as stale — triggers Path 2 withdrawal.
    mapping(uint64 => uint256) public lastReportTimestamp;

    /// @notice Pending withdrawals keyed by messageId awaiting async settlement
    /// @dev messageId is derived from a monotonic nonce via _newMessageId — unique
    ///      across the hub's lifetime, so same-block withdrawals never collide.
    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals;

    /// @notice Maps a Path 3 recall leg's messageId back to the withdrawal id it belongs to
    /// @dev Set when a leg is dispatched, read (not deleted) on arrival — deliberately never
    ///      deleted so a late-arriving leg for an already-settled or cancelled withdrawal can
    ///      still be recognized and routed to the orphaned-arrival no-op path instead of being
    ///      silently mistaken for a fresh, unrelated Rebalancer-driven recall (WI-3).
    mapping(bytes32 => bytes32) public legToWithdrawal;

    /// @notice Maximum age of a spoke balance report before it is considered stale
    /// @dev Stale reports trigger Path 2 withdrawal — a REPORT_BALANCE refresh cycle.
    uint256 public constant MAX_STALENESS = 1 hours;

    /// @notice Grace period after which an unsettled withdrawal becomes cancellable
    /// @dev Backstop for a withdrawal stuck in SettlementDeferred (persistent insolvency) or
    ///      a Path 3 recall leg that never arrives. Cancelling returns escrowed shares —
    ///      the user keeps their claim on any later-arriving leg funds via ordinary idle.
    // TUNE: default from the plan — Open Questions #1, not decided further here.
    uint256 public constant WITHDRAWAL_TIMEOUT = 24 hours;

    /// @notice Basis-point haircut applied to a spoke's reported balance when sizing a Path 3 recall leg
    /// @dev Safety margin against stale spokeBalances — never ask a spoke for more than
    ///      (10000 - RECALL_HAIRCUT_BPS)/10000 of what hub believes it holds.
    // TUNE: default from the plan — Open Questions #1, not decided further here.
    uint256 public constant RECALL_HAIRCUT_BPS = 50;

    /// @notice Total USDC currently in CCIP transit — sent to spoke but not yet confirmed
    /// @dev Incremented on DEPOSIT ccipSend, decremented on CONFIRM_RECEIPT callback.
    ///      Included in totalAssets() so share price is not deflated during transit.
    uint256 public inTransitAssets;

    /// @notice Maps CCIP messageId to the amount sent in that transit leg
    /// @dev Used to decrement inTransitAssets precisely on CONFIRM_RECEIPT.
    ///      Deleted after the callback is processed.
    mapping(bytes32 => uint256) public inTransitAmount;

    /// @notice Maps CCIP messageId to the origin selector and send time of that DEPOSIT leg
    /// @dev WI-5/FX-2 — set in _sendToSpoke alongside inTransitAmount. Deleted alongside
    ///      inTransitAmount on both the normal path (_handleDepositCallback) and
    ///      reconciliation (reconcileTransit) — the latter also uses the stored selector to
    ///      decrement inTransitToSpoke, which the old inTransitSince-only design could not do.
    mapping(bytes32 => TransitLeg) public transitLegs;

    /// @notice Minimum age of a stuck in-transit leg before the owner may reconcile it
    /// @dev WI-5 — replaces the removed adjustInTransitAssets. Operational order: attempt
    ///      CCIP manual execution first; reconcile only when the message is provably dead
    ///      (CCIP Explorer confirms permanent FAILURE and manual execution cannot recover
    ///      it). The delay exists so a merely-slow (not dead) message isn't reconciled out
    ///      from under a legitimate in-flight confirm.
    // TUNE: default from the plan — Open Questions #1, not decided further here.
    uint256 public constant TRANSIT_RECONCILE_DELAY = 7 days;

    /// @notice Count of outstanding in-flight DEPOSIT legs per spoke selector
    /// @dev WI-6 — incremented in _sendToSpoke alongside inTransitAmount (one per DEPOSIT
    ///      message sent to that selector), decremented in _handleDepositCallback when that
    ///      selector's CONFIRM_RECEIPT lands. Guards removeSpoke: disabling a spoke while it
    ///      has in-flight legs turns their eventual CONFIRM_RECEIPT into NotSpoke poison
    ///      (the spoke would still be mid-flight but no longer isValidSpoke).
    mapping(uint64 => uint256) public inTransitToSpoke;

    /// @notice Net USDC ever sent to a spoke via DEPOSIT, minus actual USDC ever recalled back
    /// @dev WI-7 — the baseline a spoke's self-reported balance is checked against.
    ///      Incremented in _sendToSpoke for DEPOSIT messages; decremented by the ACTUAL
    ///      arrived amount (destTokenAmounts, never the payload's claimed amount) on every
    ///      CONFIRM_WITHDRAWAL arrival, consistent with WI-4. Clamped at 0 — a spoke cannot
    ///      recall more than the hub believes it ever sent without that surplus itself being
    ///      yield, which the upside band below is what actually polices.
    ///      FX-3: also REBASED (overwritten, not incremented) to the accepted value by
    ///      acceptQuarantinedReport — the band is flat and time-blind, so without a durable
    ///      rebase on accept, genuine cumulative yield eventually exceeds it permanently and
    ///      every honest report after an accept would immediately re-quarantine.
    mapping(uint64 => uint256) public netSentToSpoke;

    /// @notice A quarantined self-reported balance awaiting owner review
    /// @dev WI-7. Set when a report exceeds the upside-only sanity band; spokeBalances is
    ///      left untouched (never clamped — clamping corrupts pricing in the other
    ///      direction). Owner resolves via acceptQuarantinedReport or rejectQuarantinedReport.
    mapping(uint64 => uint256) public quarantinedReports;

    /// @notice Count of spokes currently holding a quarantined report
    /// @dev Used to know when it is safe to unpause — resolving one quarantined spoke must
    ///      not unpause the vault while another remains quarantined.
    uint256 public activeQuarantineCount;

    /// @notice Upside band width, in bps, a spoke's reported balance may exceed netSentToSpoke by
    /// @dev WI-7 (Issue 7b, Option A). Under-reporting (losses) always passes — it deflates
    ///      rather than inflates share price, which is the direction that's safe to trust.
    // TUNE: default from the plan — Open Questions #1, not decided further here.
    uint256 public constant MAX_YIELD_BPS = 2_000;

    /// @notice Flat USDC dust allowance added on top of the MAX_YIELD_BPS band
    /// @dev Absorbs rounding noise for small spokes where a percentage-only band would be
    ///      too tight to be useful.
    // TUNE: default from the plan — Open Questions #1, not decided further here.
    uint256 public constant REPORT_DUST = 100e6;

    /// @notice Bps drop between consecutive reports that triggers an informational event
    /// @dev Not one of the plan's named tunable constants (WITHDRAWAL_TIMEOUT,
    ///      RECALL_HAIRCUT_BPS, TRANSIT_RECONCILE_DELAY, MAX_YIELD_BPS, REPORT_DUST) — the
    ///      plan asks for "an informational event when it drops >X% between reports" without
    ///      specifying X. Judgment call, flagged for review: 500 bps (5%) as a reasonable
    ///      default. Purely informational — never blocks or quarantines anything.
    // TUNE: judgment call, not an explicit plan constant — escalate if this default is wrong.
    uint256 public constant LOSS_ALERT_BPS = 500;

    /// @notice Gas limit supplied to the CCIP router for all outbound messages
    /// @dev Configurable by owner. Default 1_500_000 — covers the most expensive spoke
    ///      operations (deposit → adapter → CONFIRM_RECEIPT CCIP send).
    ///      Increase via setOutboundGasLimit() if messages fail at destination.
    uint32 public outboundGasLimit = 1_500_000;

    /// @notice Monotonic counter used to derive collision-free internal message ids
    /// @dev Incremented for every id produced by _newMessageId. Because it is part of
    ///      the preimage, two operations in the same block (same amount / receiver /
    ///      target) can never share an id — this is the fix for the content-derived
    ///      id collisions that previously corrupted inTransitAmount bookkeeping and
    ///      overwrote pending withdrawals.
    uint256 internal _messageNonce;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a withdrawal cannot be settled immediately and is queued
    /// @dev `id` is required off-chain to call cancelWithdrawal() or attemptSettlement() —
    ///      the hub never exposes a way to enumerate pending withdrawals, so this event is
    ///      the only source of an owner's withdrawal id.
    /// @param owner Address whose shares are held in escrow by hub
    /// @param id The withdrawal id keying this entry in pendingWithdrawals
    /// @param shares Number of shares transferred to hub and locked
    /// @param assets Full USDC value owed to the withdrawer on settlement (quote, not a promise — WI-4 claim-time pricing)
    /// @param _reservedAssets Amount of idle USDC reserved at queue time (0 if none available)
    event WithdrawalQueued(
        address indexed owner,
        bytes32 indexed id,
        uint256 shares,
        uint256 assets,
        uint256 _reservedAssets
    );

    /// @notice Emitted when a queued or synchronous withdrawal is fully settled
    /// @param owner Address whose shares were burned
    /// @param receiver Address that received the USDC
    /// @param assets Amount of USDC transferred to receiver
    /// @param messageId The messageId that keyed this withdrawal in pendingWithdrawals
    event WithdrawalProcessed(
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        bytes32 messageId
    );

    /// @notice Emitted when a new spoke is registered or an existing spoke address is updated
    /// @param spokeSelector CCIP chain selector of the spoke chain
    /// @param spokeAddress Address of the SpokeVault contract on that chain
    event SpokeAdded(
        uint64 indexed spokeSelector,
        address indexed spokeAddress
    );

    /// @notice Emitted when a spoke is disabled via removeSpoke
    /// @param spokeSelector CCIP chain selector of the disabled spoke
    event SpokeRemoved(uint64 indexed spokeSelector);

    /// @notice Emitted when a spoke is disabled via the unsafe forceRemoveSpoke path
    /// @dev Loud by design — the presence of nonzero danglingBalance or danglingInFlightLegs
    ///      signals exactly what was skipped and what operational cleanup remains.
    /// @param spokeSelector CCIP chain selector of the forcibly-disabled spoke
    /// @param danglingBalance spokeBalances[selector] at the moment of removal — now
    ///        instantly excluded from totalManagedAssets()
    /// @param danglingInFlightLegs inTransitToSpoke[selector] at the moment of removal — legs
    ///        whose eventual CONFIRM_RECEIPT will now revert with NotSpoke
    event SpokeForceRemoved(
        uint64 indexed spokeSelector,
        uint256 danglingBalance,
        uint256 danglingInFlightLegs
    );

    /// @notice Emitted whenever a spoke reports its current total balance to hub
    /// @dev Fired on CONFIRM_RECEIPT, CONFIRM_REBALANCE, and REPORT_BALANCE callbacks
    /// @param chainSelector Chain selector of the reporting spoke
    /// @param balance Updated total balance reported by the spoke in USDC
    event SpokeBalanceUpdated(uint64 indexed chainSelector, uint256 balance);

    /// @notice Emitted when hub dispatches a CCIP message to a spoke
    /// @dev ccipMessageId is the bytes32 returned by router.ccipSend() — track it on
    ///      https://ccip.chain.link to monitor delivery status.
    ///      amount is 0 for non-deposit message types.
    /// @param chainSelector Destination chain CCIP selector
    /// @param ccipMessageId CCIP protocol message ID from router.ccipSend()
    /// @param internalMessageId Hub's internal keccak256 message ID
    /// @param amount USDC amount sent (0 for REBALANCE / REPORT_BALANCE)
    event SentToSpoke(
        uint64 indexed chainSelector,
        bytes32 indexed ccipMessageId,
        bytes32 internalMessageId,
        uint256 amount
    );

    /// @notice Emitted when a CONFIRM_WITHDRAWAL arrives that matches no pendingWithdrawal
    /// @dev This is the WI-3 rebalancer-driven recall completion signal — the off-chain
    ///      agent watches for this to sequence "recall from overweight chain, then propose
    ///      allocation to the now-idle funds." The arrived tokens become ordinary hub idle;
    ///      no further hub-side action is needed.
    /// @param chainSelector Chain selector the recall was sourced from
    /// @param amount Actual USDC amount that arrived (from the CCIP token envelope)
    event RecallCompleted(uint64 indexed chainSelector, uint256 amount);

    /// @notice Emitted when a stuck in-transit DEPOSIT leg is reconciled by the owner
    /// @dev WI-5. amount is exactly the tracked inTransitAmount for this id — the owner
    ///      cannot invent or inflate a value.
    /// @param messageId The reconciled leg's internal message id
    /// @param amount The exact amount released from inTransitAssets
    event TransitReconciled(bytes32 indexed messageId, uint256 amount);

    /// @notice Emitted when a spoke's self-reported balance exceeds the upside-only sanity
    ///         band and is quarantined instead of applied
    /// @dev WI-7. spokeBalances[selector] is left untouched; deposits and withdrawals pause.
    /// @param chainSelector The reporting spoke's chain selector
    /// @param reported The rejected, quarantined value
    /// @param ceiling The band ceiling it exceeded (netSentToSpoke-derived)
    event SuspiciousSpokeReport(uint64 indexed chainSelector, uint256 reported, uint256 ceiling);

    /// @notice Emitted when a spoke's reported balance drops sharply between reports
    /// @dev Informational only — under-reporting always passes the band (it deflates share
    ///      price, the safe direction) but a sharp drop is worth an operator's attention.
    /// @param chainSelector The reporting spoke's chain selector
    /// @param previous The previously recorded balance
    /// @param reported The new, lower balance
    event SpokeBalanceDropped(uint64 indexed chainSelector, uint256 previous, uint256 reported);

    /// @notice Emitted when the owner accepts a quarantined report
    /// @param chainSelector The spoke whose quarantined report was accepted
    /// @param amount The value now applied to spokeBalances
    event QuarantinedReportAccepted(uint64 indexed chainSelector, uint256 amount);

    /// @notice Emitted when the owner rejects a quarantined report
    /// @param chainSelector The spoke whose quarantined report was discarded
    /// @param amount The discarded value
    event QuarantinedReportRejected(uint64 indexed chainSelector, uint256 amount);

    /// @notice Emitted when a Path 3 recall leg or stray token arrival matches no live
    ///         pendingWithdrawal — e.g. a leg for a withdrawal that was cancelled, or (as of
    ///         FX-1) a late leg for an id whose entry has already been deleted for any other
    ///         reason. Since FX-1, settlement never happens before all of an entry's legs
    ///         have landed (`pendingLegs == 0`), so a live entry can no longer be settled out
    ///         from under a still-outstanding leg.
    /// @dev Funds become ordinary hub idle — no action needed, this is informational.
    /// @param chainSelector Chain selector the arrival came from
    /// @param amount Actual USDC amount that arrived
    event OrphanedRecallArrival(uint64 indexed chainSelector, uint256 amount);

    /// @notice Emitted when a settlement attempt finds insufficient claimable idle right now
    /// @dev Non-fatal — the entry stays pending and a later confirm (another leg arrival, or
    ///      another REPORT_BALANCE round for Path 2) retries. Never reverts a CCIP execution.
    /// @param id The withdrawal id
    /// @param payout Claim-time payout that would be owed if settled now
    /// @param availableForThisEntry Idle currently claimable by this entry alone
    event SettlementDeferred(bytes32 indexed id, uint256 payout, uint256 availableForThisEntry);

    /// @notice Emitted alongside WithdrawalProcessed when claim-time payout differs from the
    ///         quote taken at request time (yield or loss accrued while the withdrawal was pending)
    /// @param id The withdrawal id
    /// @param quotedAssets previewRedeem(shares) at request time
    /// @param payout Actual previewRedeem(shares) at settlement time
    event WithdrawalRepriced(bytes32 indexed id, uint256 quotedAssets, uint256 payout);

    /// @notice Emitted when a timed-out pending withdrawal is cancelled by its owner
    /// @param id The withdrawal id
    /// @param shares Shares returned to the owner
    event WithdrawalCancelled(bytes32 indexed id, uint256 shares);

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @notice Restricts access to the Rebalancer contract or hub itself
    /// @dev Hub uses `address(this)` when calling recallFromSpoke and _requestAllBalanceReports
    ///      internally via `this.functionName()` to change msg.sender context.
    ///      This is a temporary pattern — visibility will be tightened before mainnet.
    modifier onlyRebalancer() {
        _onlyRebalancer();
        _;
    }

    /// @dev Extracted to reduce bytecode size from modifier inlining
    function _onlyRebalancer() internal view {
        if (msg.sender != REBALANCER && msg.sender != address(this)) {
            revert NotRebalancer();
        }
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys HubVault with core configuration
    /// @dev Parent constructors run before the body — CCIPReceiver validates _router internally.
    ///      _rebalancer can be address(0) at deploy time and set later via setRebalancer()
    ///      to resolve the circular dependency between Hub and Rebalancer deployment.
    /// @param _name ERC20 share token name (e.g. "Meridian USDC")
    /// @param _symbol ERC20 share token symbol (e.g. "mUSDC")
    /// @param _router Chainlink CCIP router address on Ethereum
    /// @param _owner Contract owner — should be a multisig before mainnet deployment
    /// @param _link LINK token address used to pay CCIP fees
    /// @param _asset Underlying asset address (USDC)
    /// @param _rebalancer Rebalancer contract address — pass address(0) to set later
    constructor(
        string memory _name,
        string memory _symbol,
        address _router,
        address _owner,
        address _link,
        address _asset,
        address _rebalancer
    )
        ERC4626(IERC20(_asset))
        Ownable(_owner)
        ERC20(_name, _symbol)
        CCIPReceiver(_router)
    {
        if (
            _router == address(0) ||
            _owner == address(0) ||
            _link == address(0) ||
            _asset == address(0)
        ) revert InvalidConstructorArguments();
        LINK = IERC20(_link);
        REBALANCER = _rebalancer;
    }

    // =========================================================================
    // Cross-Module Hooks
    // =========================================================================
    // Bodiless `virtual` declarations for every function called across module boundaries
    // (including via `this.fn()` self-calls) in the real call graph. Each is implemented
    // with `override` in exactly one module. See the executor's final report for the
    // derivation — this set differs from the plan's suggested starting list because several
    // of the plan's suggested hooks (_attemptSettleWithdrawal, _sendToSpoke,
    // _applyReportedBalance, _spokesByDescendingBalance) turned out to have all their callers
    // within a single owning module (no hook needed), while isValidSpoke,
    // _requestAllBalanceReports, recallFromSpoke(3-arg), and attemptSettlement turned out to
    // need hooks that weren't in the plan's starting list (found via `this.fn()` self-calls
    // and a bare cross-sibling call the plan's list missed).

    /// @dev Hook for isValidSpoke — implemented in HubAdminModule, called cross-module from
    ///      HubMessagingModule._ccipReceive.
    function isValidSpoke(address _spoke) public view virtual returns (bool);

    /// @dev Hook for _idleBalance — implemented in HubWithdrawalModule, called cross-module
    ///      from HubMessagingModule (sendToSpoke, idleBalance).
    function _idleBalance() internal view virtual returns (uint256);

    /// @dev Hook for _allSpokesFresh — implemented in HubWithdrawalModule, called cross-module
    ///      from HubMessagingModule._handleReportBalanceCallback.
    function _allSpokesFresh() internal view virtual returns (bool);

    /// @dev Hook for _newMessageId — implemented in HubMessagingModule, called cross-module
    ///      from HubWithdrawalModule._withdraw.
    function _newMessageId(bytes32 context) internal virtual returns (bytes32);

    /// @dev Hook for _requestAllBalanceReports — implemented in HubMessagingModule, called
    ///      cross-module via `this._requestAllBalanceReports(...)` from
    ///      HubWithdrawalModule._withdraw (Path 2).
    function _requestAllBalanceReports(bytes32 _messageId) public virtual;

    /// @dev Hook for the 3-arg recallFromSpoke overload — implemented in HubMessagingModule,
    ///      called cross-module via `this.recallFromSpoke(...)` from
    ///      HubWithdrawalModule._withdraw (Path 3 leg dispatch).
    function recallFromSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions,
        bytes32 _messageId
    ) external virtual;

    /// @dev Hook for attemptSettlement — implemented in HubWithdrawalModule, called
    ///      cross-module via `this.attemptSettlement(...)` from HubMessagingModule's
    ///      _handleReportBalanceCallback and _handleWithdrawalCallback.
    function attemptSettlement(bytes32 id) external virtual;
}
