// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink+/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink+/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {InvalidMessageType, InvalidConstructorArguments, NotRebalancer, NotSpoke, ZeroAddress, SpokeNotFound, SpokeAlreadyRegistered, ZeroWithdrawal, InsufficientUnreservedIdle, InvalidRecallAmount, InsufficientRecallLiquidity, NoPendingWithdrawal, NotWithdrawalOwner, WithdrawalNotYetCancellable} from "./errors/hubErrors.sol";

/// @title HubVault
/// @notice ERC4626 vault on Ethereum — entry point for all user deposits and withdrawals.
///         Users deposit USDC here and receive vault shares representing their proportional
///         ownership of all protocol-managed capital across all chains.
/// @dev Inherits ERC4626, CCIPReceiver, and Ownable. Delegates capital deployment to
///      spoke vaults on L2s via Chainlink CCIP. Share price reflects total managed assets
///      across all spokes including yield accrued on deployed capital.
///      Only the Rebalancer contract can move capital between hub and spokes.
///      Withdrawals are asynchronous when capital is deployed — three paths exist:
///      Path 1 (sync): idle covers withdrawal and all spoke reports are fresh.
///      Path 2 (async): idle covers withdrawal but spoke reports are stale — refreshes first.
///      Path 3 (async): idle insufficient — recalls shortfall from best spoke via CCIP.
contract HUB is ERC4626, CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

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
    uint256 private _messageNonce;

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

    /// @notice Emitted when a Path 3 recall leg or stray token arrival matches no live
    ///         pendingWithdrawal — e.g. a leg for a withdrawal that already settled early
    ///         (claim-time solvency let it pay out before all legs landed) or was cancelled
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
    // Admin Functions
    // =========================================================================

    /// @notice Sets or updates the Rebalancer contract address
    /// @dev Only callable by owner. Allows post-deployment configuration to resolve
    ///      circular dependency — Hub needs Rebalancer address and vice versa.
    ///      No guard against re-setting — owner is trusted to manage this correctly.
    /// @param _rebalancer New Rebalancer contract address
    function setRebalancer(address _rebalancer) external onlyOwner {
        if (_rebalancer == address(0)) revert ZeroAddress();
        REBALANCER = _rebalancer;
    }

    /// @notice Updates the gas limit passed to CCIP router for all outbound messages
    /// @dev Increase if CCIP messages land with execution failure at the spoke.
    ///      Default 1_500_000 covers most operations including adapter deposits + CCIP reply.
    /// @param _gasLimit New gas limit — must be > 0 and reasonable for spoke execution
    function setOutboundGasLimit(uint32 _gasLimit) external onlyOwner {
        outboundGasLimit = _gasLimit;
    }

    /// @notice Emergency: manually correct inTransitAssets when CCIP messages fail
    /// @dev Only use after CCIP Explorer confirms a message has FAILURE state and funds
    ///      cannot be recovered via OffRamp manual execution.
    ///      This does not move USDC — it only corrects Hub's accounting so share prices
    ///      are not artificially inflated by stuck transit amounts.
    /// @param _newAmount New inTransitAssets value — typically 0 after full failure recovery
    function adjustInTransitAssets(uint256 _newAmount) external onlyOwner {
        inTransitAssets = _newAmount;
    }

    /// @notice Registers a new spoke or updates an existing spoke's contract address
    /// @dev Uses `everRegistered` flag to prevent duplicate entries in spokeChainSelectors
    ///      when a selector is removed and re-added. The same address cannot be registered
    ///      on two different selectors simultaneously — enforced via addressToSelector reverse mapping.
    ///      On update: old address is invalidated, new address is mapped.
    /// @param _chainSelector CCIP chain selector identifying the spoke chain
    /// @param _spokeAddress Address of the SpokeVault deployed on that chain
    function addSpoke(
        uint64 _chainSelector,
        address _spokeAddress
    ) external onlyOwner {
        if (_spokeAddress == address(0)) revert ZeroAddress();
        uint64 existingSelector = addressToSelector[_spokeAddress];
        if (existingSelector != 0 && existingSelector != _chainSelector) {
            revert SpokeAlreadyRegistered();
        }
        if (!spokes[_chainSelector].everRegistered) {
            spokeChainSelectors.push(_chainSelector);
            spokes[_chainSelector].everRegistered = true;
            addressToSelector[_spokeAddress] = _chainSelector;
        } else {
            address oldSpoke = spokes[_chainSelector].spoke;
            if (addressToSelector[oldSpoke] == _chainSelector) {
                delete addressToSelector[oldSpoke];
            }
            addressToSelector[_spokeAddress] = _chainSelector;
        }
        spokes[_chainSelector].spoke = _spokeAddress;
        spokes[_chainSelector].exists = true;
        emit SpokeAdded(_chainSelector, _spokeAddress);
    }

    /// @notice Disables a spoke by setting its exists flag to false
    /// @dev Emergency mechanism — does not remove from spokeChainSelectors array.
    ///      Inactive spokes are skipped during iteration via the exists flag.
    ///      Also clears addressToSelector reverse mapping for the spoke address.
    /// @param _chainSelector CCIP chain selector of the spoke to disable
    function removeSpoke(uint64 _chainSelector) external onlyOwner {
        if (spokes[_chainSelector].exists == false) revert SpokeNotFound();
        delete addressToSelector[spokes[_chainSelector].spoke];
        spokes[_chainSelector].exists = false;
        emit SpokeRemoved(_chainSelector);
    }

    /// @notice Returns whether an address is currently a valid active spoke
    /// @dev Checks both the reverse mapping and the exists flag to guard against
    ///      stale entries where address was removed or updated.
    /// @param _spoke Address to check
    /// @return True if _spoke is the currently registered active spoke for its selector
    function isValidSpoke(address _spoke) public view returns (bool) {
        uint64 selector = addressToSelector[_spoke];
        if (selector == 0) return false;
        return spokes[selector].exists && spokes[selector].spoke == _spoke;
    }

    // =========================================================================
    // Rebalancer Functions
    // =========================================================================

    /// @notice Sends USDC and deposit instructions to a spoke via CCIP
    /// @dev Only callable by Rebalancer. Encodes a DEPOSIT message — the only message type
    ///      that attaches USDC tokens to the CCIP transfer. Spoke deposits into adapters
    ///      and sends CONFIRM_RECEIPT back. inTransitAssets is incremented here and
    ///      decremented when CONFIRM_RECEIPT arrives.
    /// @param _chainSelector CCIP chain selector of the destination spoke
    /// @param _instructions Array of adapter instructions — protocol id and USDC amount per market
    function sendToSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) revert SpokeNotFound();
        // WI-3: authoritative solvency guard — reservedAssets is idle that a pending
        // withdrawal already depends on. Summed across all instructions (not just the
        // first) so a multi-instruction deposit can't undercount its own total ask.
        uint256 totalAmount;
        for (uint256 i = 0; i < _instructions.length; i++) {
            totalAmount += _instructions[i].amount;
        }
        uint256 idle = _idleBalance();
        if (idle < reservedAssets + totalAmount) {
            revert InsufficientUnreservedIdle(totalAmount, idle, reservedAssets);
        }
        bytes32 _messageId = _newMessageId(bytes32(uint256(_chainSelector)));
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.DEPOSIT,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    /// @notice Sends a recall instruction to a spoke to return funds to hub via CCIP
    /// @dev Only callable by hub itself, via this.recallFromSpoke in _withdraw's Path 3.
    ///      Sends a WITHDRAW_AMOUNT message — instruction only, no tokens attached outbound.
    ///      Spoke pulls proportionally from its adapters and sends tokens back via CCIP.
    ///      The messageId here matches an existing pendingWithdrawals entry so the arrival
    ///      callback can settle it — this is what distinguishes this overload from the
    ///      Rebalancer-driven one below, which creates no pendingWithdrawal and therefore
    ///      must not accept a caller-supplied id (WI-1 ids are always hub-derived when there
    ///      is nothing external to match against).
    /// @param _chainSelector CCIP chain selector of the target spoke
    /// @param _instructions Single instruction with adapter=bytes32(0) and amount=shortfall
    /// @param _messageId Matches the pendingWithdrawal entry so callback can settle correctly
    function recallFromSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions,
        bytes32 _messageId
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) {
            revert SpokeNotFound();
        }
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.WITHDRAW_AMOUNT,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    /// @notice Rebalancer-driven recall — moves capital off an overweight spoke with no
    ///         pendingWithdrawal attached; the arrived tokens simply become hub idle
    /// @dev WI-3 (Issue 5, Option A). This is the missing "move weight off a chain" lever —
    ///      without it the only way capital left a spoke was via a user-triggered Path 3
    ///      withdrawal. The hub derives its own fresh id via _newMessageId (WI-1); callers
    ///      never supply one, since there is no pendingWithdrawal to match against.
    ///      Intended v1 operator flow (see Rebalancer.recallFromSpoke NatSpec for the full
    ///      sequence): off-chain diff → recallFromSpoke per overweight chain → await
    ///      RecallCompleted → proposeAllocation sized to the now-idle funds. The on-chain
    ///      diff engine that would automate this sequencing is explicitly out of scope (v2).
    /// @param _chainSelector CCIP chain selector of the spoke to recall from
    /// @param _amount USDC amount to recall — must be nonzero
    function recallFromSpoke(
        uint64 _chainSelector,
        uint256 _amount
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) {
            revert SpokeNotFound();
        }
        if (_amount == 0) revert InvalidRecallAmount();
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: _amount,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        bytes32 _messageId = _newMessageId(bytes32(uint256(_chainSelector)));
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.WITHDRAW_AMOUNT,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    /// @notice Returns the USDC balance sitting idle on hub — not deployed or in transit
    /// @dev External view mirror of _idleBalance(), exposed so Rebalancer can pre-check
    ///      solvency before dispatching a proposal (WI-3 friendly pre-check).
    /// @return Idle USDC balance of this contract
    function idleBalance() external view returns (uint256) {
        return _idleBalance();
    }

    /// @notice Sends intra-spoke rebalance instructions to move capital between adapters
    /// @dev Only callable by Rebalancer. Sends a REBALANCE message — instruction only,
    ///      no tokens attached. Spoke withdraws from source adapter and deposits into target
    ///      adapter on the same chain. No capital leaves the spoke chain.
    ///      Spoke responds with CONFIRM_REBALANCE carrying updated spoke balance.
    ///      The message id is derived internally via the nonce'd _newMessageId helper —
    ///      callers no longer supply one (removed in WI-1 to eliminate id collisions).
    /// @param _chainSelector CCIP chain selector of the target spoke
    /// @param _instructions Array specifying source adapter, target adapter, and amount to move
    function rebalance(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) {
            revert SpokeNotFound();
        }
        bytes32 _messageId = _newMessageId(bytes32(uint256(_chainSelector)));
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.REBALANCE,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    // =========================================================================
    // ERC4626 Overrides
    // =========================================================================

    /// @notice Overrides ERC4626._deposit — no additional logic needed beyond standard behaviour
    /// @dev totalPrincipal tracking was removed as it was dead state — totalAssets() via
    ///      totalManagedAssets() is the source of truth for share pricing.
    /// @param caller Address initiating the deposit
    /// @param receiver Address receiving the minted shares
    /// @param assets Amount of USDC being deposited
    /// @param shares Amount of vault shares being minted
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @notice Overrides ERC4626._withdraw to implement the WI-4 three-path async withdrawal engine
    /// @dev Shares are transferred to hub at start and only burned on final settlement.
    ///      No super() call — full flow is owned here.
    ///      messageId is derived from a monotonic nonce via _newMessageId — collision-free.
    ///      Path 1 (sync): idle >= assets AND all spokes fresh → immediate settlement at the
    ///        quote taken this instant (no daylight between quote and settlement).
    ///      Path 2 (async): idle >= assets AND any spoke stale → queue + REPORT_BALANCE;
    ///        settles once ALL spokes report fresh (not on the first report — that was a bug).
    ///      Path 3 (async): idle < assets → reserve available idle, plan recall legs across
    ///        active spokes by descending spokeBalances, haircut-capped
    ///        (RECALL_HAIRCUT_BPS) per leg. If the shortfall cannot be fully planned even
    ///        across every active spoke, the ENTIRE call reverts with
    ///        InsufficientRecallLiquidity — fail-closed, nothing locks, user keeps shares.
    ///        Only if fully coverable does the hub commit (reserve idle, create the pending
    ///        entry) and dispatch legs.
    ///      CLAIM-TIME PRICING (user-facing behavioral change from v1): for Path 2/3, the
    ///      amount actually paid out is previewRedeem(shares) recomputed AT SETTLEMENT, not
    ///      the quote taken here. Yield accrued while pending is credited to the withdrawer;
    ///      a loss reported while pending reduces their payout. See _attemptSettleWithdrawal.
    /// @param caller Address initiating the withdrawal (may differ from owner if approved)
    /// @param receiver Address to receive the USDC
    /// @param owner Address whose shares are being redeemed
    /// @param assets Ignored — recalculated internally via previewRedeem(shares)
    /// @param shares Number of shares to burn
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _transfer(owner, address(this), shares);
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroWithdrawal();
        uint256 idleFree = _idleBalance() - reservedAssets;
        bytes32 _messageId = _newMessageId(bytes32(uint256(uint160(receiver))));

        if (idleFree >= assets) {
            reservedAssets += assets;
            if (_allSpokesFresh()) {
                // Path 1 — synchronous settlement, quote == payout, no entry created
                reservedAssets -= assets;
                _burn(address(this), shares);
                IERC20(asset()).safeTransfer(receiver, assets);
                emit WithdrawalProcessed(owner, receiver, assets, _messageId);
            } else {
                // Path 2 — queue and request fresh spoke balances; settles when all fresh
                pendingWithdrawals[_messageId] = PendingWithdrawal({
                    shares: shares,
                    quotedAssets: assets,
                    reservedIdle: assets,
                    arrivedAssets: 0,
                    pendingLegs: 0,
                    requestedAt: uint64(block.timestamp),
                    receiver: receiver,
                    owner: owner
                });
                this._requestAllBalanceReports(_messageId);
                emit WithdrawalQueued(owner, _messageId, shares, assets, assets);
            }
            return;
        }

        // Path 3 — insufficient idle, plan recall legs across active spokes.
        // Planning is a pure dry run first — no state committed, no CCIP dispatched — so an
        // uncoverable shortfall can revert the ENTIRE call cleanly (fail-closed, nothing locks).
        uint256 shortfall = assets - idleFree;
        uint64[] memory order = _spokesByDescendingBalance();
        uint256 remaining = shortfall;
        for (uint256 i = 0; i < order.length && remaining > 0; i++) {
            uint256 cap = (spokeBalances[order[i]] * (10_000 - RECALL_HAIRCUT_BPS)) / 10_000;
            uint256 leg = remaining < cap ? remaining : cap;
            remaining -= leg;
        }
        if (remaining > 0) {
            revert InsufficientRecallLiquidity(shortfall, shortfall - remaining);
        }

        // Fully coverable — commit and dispatch.
        reservedAssets += idleFree;
        pendingWithdrawals[_messageId] = PendingWithdrawal({
            shares: shares,
            quotedAssets: assets,
            reservedIdle: idleFree,
            arrivedAssets: 0,
            pendingLegs: 0,
            requestedAt: uint64(block.timestamp),
            receiver: receiver,
            owner: owner
        });

        remaining = shortfall;
        uint32 legCount;
        for (uint256 i = 0; i < order.length && remaining > 0; i++) {
            uint64 selector = order[i];
            uint256 cap = (spokeBalances[selector] * (10_000 - RECALL_HAIRCUT_BPS)) / 10_000;
            uint256 leg = remaining < cap ? remaining : cap;
            if (leg == 0) continue;
            bytes32 legId = _newMessageId(bytes32(uint256(selector)));
            legToWithdrawal[legId] = _messageId;
            legCount++;
            remaining -= leg;
            CCIPHelpers.AdapterInstructions[]
                memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
            _instructions[0] = CCIPHelpers.AdapterInstructions({
                adapter: bytes32(0),
                amount: leg,
                targetAdapter: bytes32(0),
                targetAmount: 0
            });
            this.recallFromSpoke(selector, _instructions, legId);
        }
        pendingWithdrawals[_messageId].pendingLegs = legCount;
        emit WithdrawalQueued(owner, _messageId, shares, assets, idleFree);
    }

    /// @notice Cancels a pending withdrawal after WITHDRAWAL_TIMEOUT has elapsed
    /// @dev Backstop for a withdrawal stuck in SettlementDeferred, or a Path 3 leg that never
    ///      arrives. Returns escrowed shares to the owner and releases the reservation.
    ///      Already-arrived leg funds (if any) remain vault idle — correct, since the caller
    ///      got their shares back and thus their proportional claim on those assets too.
    ///      Late-arriving legs after cancellation hit the unknown-leg no-op path in
    ///      _handleWithdrawalCallback (legToWithdrawal still resolves, but
    ///      pendingWithdrawals[id].shares == 0 after this delete) — no special handling needed.
    /// @param id The withdrawal id to cancel
    function cancelWithdrawal(bytes32 id) external {
        PendingWithdrawal memory entry = pendingWithdrawals[id];
        if (entry.shares == 0) revert NoPendingWithdrawal();
        if (msg.sender != entry.owner) revert NotWithdrawalOwner();
        if (block.timestamp <= entry.requestedAt + WITHDRAWAL_TIMEOUT) {
            revert WithdrawalNotYetCancellable();
        }
        reservedAssets -= entry.reservedIdle;
        delete pendingWithdrawals[id];
        _transfer(address(this), entry.owner, entry.shares);
        emit WithdrawalCancelled(id, entry.shares);
    }

    /// @notice Attempts to settle a pending withdrawal at its claim-time price
    /// @dev Permissionless — anyone can nudge a pending withdrawal to retry settlement (also
    ///      called internally, wrapped in try/catch, from the CCIP arrival callbacks so an
    ///      external-call failure here — e.g. safeTransfer to an incompatible receiver — can
    ///      never revert a token-carrying CCIP execution). Never reverts on insolvency; see
    ///      _attemptSettleWithdrawal.
    /// @param id The withdrawal id to attempt settlement for
    function attemptSettlement(bytes32 id) external {
        _attemptSettleWithdrawal(id);
    }

    /// @notice Core non-reverting settlement attempt — claim-time pricing, solvency-gated
    /// @dev CLAIM-TIME PRICING: payout is previewRedeem(shares) recomputed NOW, not the quote
    ///      taken at request time. quotedAssets is reference/sizing only, never a promise —
    ///      this is the decided v2 semantic (yield during flight settles from free idle by
    ///      design; a loss during flight reduces payout).
    ///      SOLVENCY: settles only if idle currently claimable by THIS entry alone (total idle
    ///      minus everyone else's reservation) covers payout — never touches other entries'
    ///      reservations. If not yet solvent, emits SettlementDeferred and returns; the entry
    ///      stays pending for a later retry (another leg arrival, cancellation is the backstop).
    ///      Never reverts on insufficiency — that would poison a token-carrying CCIP message.
    /// @param id The withdrawal id to attempt settlement for
    function _attemptSettleWithdrawal(bytes32 id) internal {
        PendingWithdrawal memory entry = pendingWithdrawals[id];
        if (entry.shares == 0) return; // unknown / already settled / cancelled

        uint256 payout = previewRedeem(entry.shares);
        uint256 idle = _idleBalance();
        uint256 reservedByOthers = reservedAssets - entry.reservedIdle;
        uint256 availableForThisEntry = idle > reservedByOthers
            ? idle - reservedByOthers
            : 0;

        if (availableForThisEntry < payout) {
            emit SettlementDeferred(id, payout, availableForThisEntry);
            return;
        }

        reservedAssets -= entry.reservedIdle;
        delete pendingWithdrawals[id];
        _burn(address(this), entry.shares);
        IERC20(asset()).safeTransfer(entry.receiver, payout);
        emit WithdrawalProcessed(entry.owner, entry.receiver, payout, id);
        if (payout != entry.quotedAssets) {
            emit WithdrawalRepriced(id, entry.quotedAssets, payout);
        }
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Broadcasts REPORT_BALANCE requests to all active spokes
    /// @dev Called in Path 2 when spoke balances are stale. Each spoke responds
    ///      asynchronously with a REPORT_BALANCE message carrying its current balance.
    ///      Marked public with onlyRebalancer so hub can call via this.functionName()
    ///      to update msg.sender context. Will be refactored to internal before mainnet.
    /// @param _messageId Forwarded to spokes so responses can be matched to the pending withdrawal
    function _requestAllBalanceReports(
        bytes32 _messageId
    ) public onlyRebalancer {
        uint64[] memory selectors = spokeChainSelectors;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (!spokes[selectors[i]].exists) continue;
            CCIPHelpers.AdapterInstructions[]
                memory _instructions = new CCIPHelpers.AdapterInstructions[](0);
            CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
                messageType: CCIPHelpers.MessageType.REPORT_BALANCE,
                instructions: _instructions,
                spokeBalance: 0,
                reportTimestamp: block.timestamp,
                messageId: _messageId
            });
            _sendToSpoke(selectors[i], _message);
        }
    }

    /// @notice Returns active spoke selectors ordered by descending reported balance
    /// @dev WI-4 replaces the old single-best-spoke selection — Path 3 now plans legs
    ///      across as many spokes as needed (greedy, largest first) rather than recalling
    ///      everything from one spoke. spokeBalances may be slightly stale; RECALL_HAIRCUT_BPS
    ///      in the caller is the safety margin for that, not this ordering.
    ///      Selection sort — active spoke counts are small by design (a handful per protocol).
    /// @return sorted Active chain selectors, descending by spokeBalances
    function _spokesByDescendingBalance()
        internal
        view
        returns (uint64[] memory sorted)
    {
        uint64[] memory selectors = spokeChainSelectors;
        uint256 n = selectors.length;
        uint64[] memory active = new uint64[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (spokes[selectors[i]].exists) {
                active[count++] = selectors[i];
            }
        }
        sorted = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            sorted[i] = active[i];
        }
        for (uint256 i = 0; i < count; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < count; j++) {
                if (spokeBalances[sorted[j]] > spokeBalances[sorted[maxIdx]]) {
                    maxIdx = j;
                }
            }
            if (maxIdx != i) {
                uint64 tmp = sorted[i];
                sorted[i] = sorted[maxIdx];
                sorted[maxIdx] = tmp;
            }
        }
    }

    /// @notice Encodes and dispatches a CCIP message to a spoke vault
    /// @dev Handles all outbound message types. Only DEPOSIT messages attach USDC tokens —
    ///      all other types (WITHDRAW_AMOUNT, REBALANCE, REPORT_BALANCE) carry instructions only.
    ///      REBALANCE messages use a higher gasLimit (1_000_000) to accommodate multiple
    ///      adapter operations in a single message. All others use 500_000.
    ///      Hub must hold sufficient LINK to pay the CCIP fee.
    /// @param _chainSelector Destination chain selector
    /// @param _message Fully populated CcipMessage to encode and send
    function _sendToSpoke(
        uint64 _chainSelector,
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        uint256 size;
        uint256 totalAmount;
        bool isDeposit = _message.messageType ==
            CCIPHelpers.MessageType.DEPOSIT;
        if (isDeposit) {
            for (uint256 i = 0; i < _message.instructions.length; i++) {
                totalAmount += _message.instructions[i].amount;
            }
        }
        if (totalAmount > 0) {
            size = 1;
        }
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](size);
        if (size == 1) {
            tokenAmount[0] = Client.EVMTokenAmount({
                token: address(asset()),
                amount: totalAmount
            });
        }
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(spokes[_chainSelector].spoke),
            data: CCIPHelpers.encode(_message),
            tokenAmounts: tokenAmount,
            feeToken: address(LINK),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: outboundGasLimit,
                    allowOutOfOrderExecution: false
                })
            )
        });
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(_chainSelector, ccipMessage);
        if (totalAmount > 0) {
            inTransitAssets += totalAmount;
            inTransitAmount[_message.messageId] = totalAmount;
            IERC20(asset()).forceApprove(address(router), totalAmount);
        }
        LINK.forceApprove(address(router), fee);
        bytes32 ccipMessageId = router.ccipSend(_chainSelector, ccipMessage);
        emit SentToSpoke(_chainSelector, ccipMessageId, _message.messageId, totalAmount);
    }

    /// @notice Derives a collision-free internal message id from a monotonic nonce
    /// @dev Every id is unique across the hub's lifetime — the incrementing nonce
    ///      guarantees no two operations (deposits, withdrawals, rebalances, recalls)
    ///      ever share an id, even within a single block. The additional context,
    ///      chainid, and address inputs harden the id against cross-contract reuse.
    /// @param context Caller-supplied disambiguator (e.g. selector or receiver)
    /// @return A unique bytes32 message id
    function _newMessageId(bytes32 context) internal returns (bytes32) {
        return
            keccak256(
                abi.encode(++_messageNonce, context, block.chainid, address(this))
            );
    }

    /// @notice Returns total protocol assets per ERC4626 standard
    /// @dev Overrides ERC4626.totalAssets(). Delegates to totalManagedAssets() which
    ///      aggregates idle + in-transit + all spoke balances. Share price reflects
    ///      real yield-inclusive value as spokes report updated balances.
    function totalAssets() public view override returns (uint256) {
        return totalManagedAssets();
    }

    /// @notice Aggregates total USDC managed across hub and all active spokes
    /// @dev Returns idle only when no spokes registered — inTransitAssets is always
    ///      zero in that state so one SLOAD is saved.
    ///      Spoke balances may lag by up to MAX_STALENESS between reports — this is
    ///      by design and accepted as a v1 tradeoff.
    /// @return total Sum of idle USDC on hub + in-transit USDC + all active spoke balances
    function totalManagedAssets() internal view returns (uint256 total) {
        uint64[] memory selectors = spokeChainSelectors;
        uint256 idle = _idleBalance();
        if (selectors.length == 0) return idle;
        total += idle + inTransitAssets;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (spokes[selectors[i]].exists == false) continue;
            total += spokeBalances[selectors[i]];
        }
        return total;
    }

    /// @notice Entry point for all incoming CCIP messages from registered spokes
    /// @dev Validates sender is a registered active spoke before processing.
    ///      Routes to the appropriate internal handler based on message type:
    ///      CONFIRM_WITHDRAWAL → _handleWithdrawalCallback (funds arrived from spoke)
    ///      REPORT_BALANCE     → _handleReportBalanceCallback (spoke reports balance)
    ///      CONFIRM_RECEIPT    → _handleDepositCallback (spoke confirms deposit)
    ///      CONFIRM_REBALANCE  → _handleRebalanceCallback (spoke confirms intra-rebalance)
    /// @param message Raw CCIP message delivered by the Chainlink router
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        if (!isValidSpoke(abi.decode(message.sender, (address)))) {
            revert NotSpoke();
        }
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.decode(
            message.data
        );
        uint64 _chainSelector = message.sourceChainSelector;
        if (
            _message.messageType == CCIPHelpers.MessageType.CONFIRM_WITHDRAWAL
        ) {
            _handleWithdrawalCallback(
                _message,
                _chainSelector,
                message.destTokenAmounts
            );
        } else if (
            _message.messageType == CCIPHelpers.MessageType.REPORT_BALANCE
        ) {
            _handleReportBalanceCallback(_message, _chainSelector);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.CONFIRM_RECEIPT
        ) {
            _handleDepositCallback(_message, _chainSelector);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.CONFIRM_REBALANCE
        ) {
            _handleRebalanceCallback(_message, _chainSelector);
        } else {
            revert InvalidMessageType();
        }
    }

    /// @notice Returns the USDC balance sitting idle on hub — not deployed or in transit
    /// @return Idle USDC balance of this contract
    function _idleBalance() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Checks whether all active spoke balance reports are within MAX_STALENESS
    /// @dev Returns false if no spokes are registered — safe default that prevents
    ///      Path 1 from triggering when there is nothing to be fresh about.
    ///      A spoke with lastReportTimestamp == 0 is always considered stale.
    /// @return True only if every active spoke has reported within the last MAX_STALENESS seconds
    function _allSpokesFresh() internal view returns (bool) {
        uint64[] memory selectors = spokeChainSelectors;
        if (selectors.length == 0) return false;
        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (spokes[selectors[i]].exists == false) continue;
            if (currentTime > lastReportTimestamp[selectors[i]] + MAX_STALENESS) {
                return false;
            }
        }
        return true;
    }

    // =========================================================================
    // CCIP Callback Handlers
    // =========================================================================

    /// @notice Handles CONFIRM_REBALANCE from spoke — updates balance after intra-spoke rebalance
    /// @dev No pending withdrawal involved — just updates accounting.
    ///      Spoke sends this after successfully moving capital between adapters.
    /// @param _message Decoded CCIP message carrying updated spokeBalance and reportTimestamp
    /// @param _chainSelector Source chain selector identifying which spoke sent the message
    function _handleRebalanceCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector
    ) internal {
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);
    }

    /// @notice Handles CONFIRM_RECEIPT from spoke — confirms deposit and clears inTransit
    /// @dev Spoke sends this after depositing received USDC into adapters.
    ///      Decrements inTransitAssets by the tracked amount for this messageId.
    /// @param _message Decoded CCIP message carrying updated spokeBalance and reportTimestamp
    /// @param _chainSelector Source chain selector identifying which spoke sent the message
    function _handleDepositCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector
    ) internal {
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        inTransitAssets -= inTransitAmount[_message.messageId];
        delete inTransitAmount[_message.messageId];
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);
    }

    /// @notice Handles REPORT_BALANCE from spoke — updates balance and attempts to settle a
    ///         pending Path 2 withdrawal once ALL active spokes are fresh
    /// @dev Spoke sends this in response to a REPORT_BALANCE request from hub. WI-4 fix:
    ///      previously settled on the FIRST spoke's report even with other spokes still
    ///      stale — now gated on _allSpokesFresh() so settlement uses a fully-refreshed
    ///      balance picture. Settlement itself is via attemptSettlement (claim-time pricing,
    ///      non-reverting), wrapped in try/catch so an external-call failure inside
    ///      settlement (e.g. safeTransfer to an incompatible receiver) can never revert this
    ///      CCIP execution.
    /// @param _message Decoded CCIP message carrying updated spokeBalance and reportTimestamp
    /// @param _chainSelector Source chain selector identifying which spoke sent the message
    function _handleReportBalanceCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector
    ) internal {
        bytes32 _messageId = _message.messageId;
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);
        if (pendingWithdrawals[_messageId].shares > 0 && _allSpokesFresh()) {
            try this.attemptSettlement(_messageId) {} catch {}
        }
    }

    /// @notice Handles CONFIRM_WITHDRAWAL from spoke — funds arrived. Three cases:
    ///         (1) a live Path 3 recall leg — credit the arrival and attempt settlement;
    ///         (2) an orphaned leg (withdrawal already settled early or cancelled) — funds
    ///             become ordinary idle, informational event only;
    ///         (3) never a leg at all — a WI-3 Rebalancer-driven recall, funds become idle
    /// @dev Spoke sends this after pulling funds from adapters and transferring USDC back to
    ///      hub. actualAmount is read from destTokenAmounts (the CCIP token envelope) — the
    ///      ground truth of what arrived — never from the payload, which carries no amount
    ///      for confirm messages post-WI-2 (see docs/revert-audit.md). legToWithdrawal
    ///      disambiguates case (2) from (3): a leg id is always registered at dispatch time,
    ///      so `legToWithdrawal[id] != 0` proves this WAS a leg (case 1/2); a fresh WI-3 id
    ///      was never registered as a leg (case 3).
    /// @param _message Decoded CCIP message carrying updated spokeBalance and reportTimestamp
    /// @param _chainSelector Source chain selector identifying which spoke sent the message
    /// @param destTokenAmounts Token envelope delivered alongside this message — ground truth
    function _handleWithdrawalCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector,
        Client.EVMTokenAmount[] memory destTokenAmounts
    ) internal {
        bytes32 _messageId = _message.messageId;
        uint256 actualAmount = destTokenAmounts.length > 0
            ? destTokenAmounts[0].amount
            : 0;
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);

        bytes32 wid = legToWithdrawal[_messageId];
        if (wid != bytes32(0)) {
            if (pendingWithdrawals[wid].shares > 0) {
                pendingWithdrawals[wid].arrivedAssets += actualAmount;
                if (pendingWithdrawals[wid].pendingLegs > 0) {
                    pendingWithdrawals[wid].pendingLegs -= 1;
                }
                try this.attemptSettlement(wid) {} catch {}
            } else {
                emit OrphanedRecallArrival(_chainSelector, actualAmount);
            }
        } else {
            // never a leg — WI-3 Rebalancer-driven recall, funds become ordinary idle
            emit RecallCompleted(_chainSelector, actualAmount);
        }
    }

    // =========================================================================
    // View Helpers
    // =========================================================================

    /// @notice Returns the length of the spokeChainSelectors array
    /// @dev Includes inactive (removed) spokes — length only grows, never shrinks.
    ///      Use spokes[selector].exists to check active status.
    /// @return Length of the spokeChainSelectors array
    function spokeChainSelectorsLength() external view returns (uint256) {
        return spokeChainSelectors.length;
    }
}
