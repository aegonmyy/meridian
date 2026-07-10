// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink+/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HubStorage} from "./hub/HubStorage.sol";
import {HubAdminModule} from "./hub/HubAdminModule.sol";
import {InvalidMessageType, NotSpoke, SpokeNotFound, ZeroWithdrawal, InsufficientUnreservedIdle, InvalidRecallAmount, InsufficientRecallLiquidity, NoPendingWithdrawal, NotWithdrawalOwner, WithdrawalNotYetCancellable} from "./errors/hubErrors.sol";

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
/// @dev R-1 of the Hub modularization: state, structs, events, constructor, and cross-module
///      hook declarations now live in HubStorage (src/hub/HubStorage.sol). This file still
///      holds all logic as a single contract inheriting HubStorage — later steps (R-2..R-4)
///      move each logical group into its own sibling module (HubAdminModule,
///      HubMessagingModule, HubWithdrawalModule) that also inherits HubStorage directly.
contract HUB is HubAdminModule {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys HubVault with core configuration — forwards to HubStorage
    constructor(
        string memory _name,
        string memory _symbol,
        address _router,
        address _owner,
        address _link,
        address _asset,
        address _rebalancer
    ) HubStorage(_name, _symbol, _router, _owner, _link, _asset, _rebalancer) {}

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
    ) external override onlyRebalancer {
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
    ///      WI-7: whenNotPaused — user deposits pause while any spoke report is quarantined.
    ///      (Whether capital-movement functions like sendToSpoke/recallFromSpoke should also
    ///      be gated is Open Questions #4 — not decided here; only user entry/exit is paused.)
    /// @param caller Address initiating the deposit
    /// @param receiver Address receiving the minted shares
    /// @param assets Amount of USDC being deposited
    /// @param shares Amount of vault shares being minted
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
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
    ///        entry) and dispatch legs. Settlement itself only happens once ALL of this
    ///        entry's legs have landed (pendingLegs == 0) — see _attemptSettleWithdrawal's
    ///        FX-1 NatSpec for why early settlement out of free idle was removed.
    ///      CLAIM-TIME PRICING (user-facing behavioral change from v1): for Path 2/3, the
    ///      amount actually paid out is previewRedeem(shares) recomputed AT SETTLEMENT, not
    ///      the quote taken here. Yield accrued while pending is credited to the withdrawer;
    ///      a loss reported while pending reduces their payout. See _attemptSettleWithdrawal.
    ///      WI-7: whenNotPaused — new withdrawal REQUESTS pause while any spoke report is
    ///      quarantined. Settlement of ALREADY-pending withdrawals (attemptSettlement,
    ///      cancelWithdrawal) is intentionally NOT gated — those must keep working during a
    ///      pause so users with in-flight withdrawals aren't additionally stuck.
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
    ) internal override whenNotPaused {
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
        uint32 legCount;
        for (uint256 i = 0; i < order.length && remaining > 0; i++) {
            uint256 cap = (spokeBalances[order[i]] * (10_000 - RECALL_HAIRCUT_BPS)) / 10_000;
            uint256 leg = remaining < cap ? remaining : cap;
            if (leg > 0) legCount++;
            remaining -= leg;
        }
        if (remaining > 0) {
            revert InsufficientRecallLiquidity(shortfall, shortfall - remaining);
        }

        // Fully coverable — commit BEFORE dispatch, including the final leg count.
        // FX-7: pendingLegs is written HERE, before any leg is dispatched — not after the
        // loop. A leg's confirm can arrive synchronously WHILE this loop is still running
        // for later legs (this test harness; production CCIP always resolves dispatch and
        // confirm-arrival in separate transactions, so this can't happen there). If
        // pendingLegs were still 0 at that moment, the arriving leg's decrement guard
        // (`if (pendingLegs > 0) pendingLegs -= 1`) would silently no-op, and the later
        // post-loop write would stomp pendingLegs back to the full original legCount —
        // permanently overcounting outstanding legs by one per mid-loop arrival, which can
        // never fully reach 0 again once the truly-last leg lands, permanently blocking
        // FX-1's Path 3 settlement gate. Writing here first makes this harness's behavior
        // faithful to production ordering.
        reservedAssets += idleFree;
        pendingWithdrawals[_messageId] = PendingWithdrawal({
            shares: shares,
            quotedAssets: assets,
            reservedIdle: idleFree,
            arrivedAssets: 0,
            pendingLegs: legCount,
            requestedAt: uint64(block.timestamp),
            receiver: receiver,
            owner: owner
        });

        remaining = shortfall;
        for (uint256 i = 0; i < order.length && remaining > 0; i++) {
            uint64 selector = order[i];
            uint256 cap = (spokeBalances[selector] * (10_000 - RECALL_HAIRCUT_BPS)) / 10_000;
            uint256 leg = remaining < cap ? remaining : cap;
            if (leg == 0) continue;
            bytes32 legId = _newMessageId(bytes32(uint256(selector)));
            legToWithdrawal[legId] = _messageId;
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
    function attemptSettlement(bytes32 id) external override {
        _attemptSettleWithdrawal(id);
    }

    /// @notice Core non-reverting settlement attempt — claim-time pricing, freshness/leg
    ///         gated, solvency-gated
    /// @dev FX-1: gating moved INSIDE this function so it holds for every caller, including
    ///      the permissionless external `attemptSettlement`. Previously the freshness/arrival
    ///      gates existed only at the CCIP callback call sites — anyone could call
    ///      `attemptSettlement(id)` directly the instant a Path 2 withdrawal was queued and
    ///      settle at the still-stale price, reopening the exact bug this engine fixed.
    ///      Classification is derived purely from stored state (no separate "which path"
    ///      flag needed): an entry with `pendingLegs > 0 || arrivedAssets > 0` was routed
    ///      through Path 3 (it has, or is expecting, recall legs); otherwise it's a pure
    ///      Path 2 entry.
    ///      - Pure Path 2: defer unless `_allSpokesFresh()` — settlement must use a fully
    ///        refreshed balance picture, not whatever was stale at request time.
    ///      - Path 3: defer unless `pendingLegs == 0` — DECIDED POLICY (see FX-1 escalation):
    ///        no early settlement out of free idle while legs are still outstanding. A
    ///        user's own recalled liquidity is no longer a commons another withdrawer can
    ///        claim first via idle, and settlement timing becomes predictable — once all of
    ///        THIS entry's legs have landed, not whenever idle happens to be sufficient.
    ///      CLAIM-TIME PRICING: payout is previewRedeem(shares) recomputed NOW, not the quote
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

        bool isPathThreeEntry = entry.pendingLegs > 0 || entry.arrivedAssets > 0;
        if (isPathThreeEntry) {
            if (entry.pendingLegs > 0) {
                emit SettlementDeferred(id, payout, 0);
                return;
            }
        } else if (!_allSpokesFresh()) {
            emit SettlementDeferred(id, payout, 0);
            return;
        }

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
    ) public override onlyRebalancer {
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
            // WI-0/WI-6: left false (ordered) — verified against the pinned OffRamp
            // (offRamp/OffRamp.sol, NonceManager.sol) that the premise for flipping this
            // ("a failed/reverting message blocks subsequent same-sender messages on the
            // lane") does not hold. The inbound nonce is incremented in incrementInboundNonce
            // BEFORE trial execution runs, for every UNTOUCHED->{SUCCESS,FAILURE} transition
            // — i.e. the nonce advances on the FIRST EXECUTION ATTEMPT regardless of its
            // outcome, so a message that reverts still unblocks the next one once attempted
            // (which happens automatically/promptly under normal DON operation). The one
            // scenario ordered execution genuinely blocks on is a message that is never
            // attempted at all (stuck UNTOUCHED — a DON/relayer liveness issue, not a
            // contract-level revert); that is an infra concern out-of-order execution would
            // not fully insulate against either for messages still ahead of the stuck one.
            // See docs/operations.md and the executor's final report for the full finding.
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
            transitLegs[_message.messageId] = TransitLeg({
                selector: _chainSelector,
                sentAt: uint64(block.timestamp)
            });
            inTransitToSpoke[_chainSelector] += 1;
            netSentToSpoke[_chainSelector] += totalAmount;
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
    function _newMessageId(bytes32 context) internal override returns (bytes32) {
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
    function _idleBalance() internal view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Checks whether all active spoke balance reports are within MAX_STALENESS
    /// @dev Returns false if no spokes are registered — safe default that prevents
    ///      Path 1 from triggering when there is nothing to be fresh about.
    ///      A spoke with lastReportTimestamp == 0 is always considered stale.
    /// @return True only if every active spoke has reported within the last MAX_STALENESS seconds
    function _allSpokesFresh() internal view override returns (bool) {
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

    /// @notice Applies (or quarantines) a spoke's self-reported balance — the single choke
    ///         point every balance-carrying callback routes through
    /// @dev WI-7 (Issue 7b, Option A). Upside-only sanity band: accept if
    ///      `reported <= netSentToSpoke[selector] * (10000 + MAX_YIELD_BPS) / 10000 + REPORT_DUST`.
    ///      Under-reporting always passes — it deflates share price, the safe direction —
    ///      but a drop exceeding LOSS_ALERT_BPS since the last report emits an informational
    ///      event. On breach: NEVER clamp (clamping corrupts pricing the other direction) —
    ///      quarantine instead. spokeBalances is left untouched, the report is stored in
    ///      quarantinedReports, SuspiciousSpokeReport fires, and deposits/withdrawals pause.
    ///      This function itself never reverts — callers include token-carrying CCIP arrival
    ///      paths (CONFIRM_WITHDRAWAL) that must still deliver their tokens and settle
    ///      regardless of whether the reported BALANCE passes the band.
    /// @param _chainSelector The reporting spoke's chain selector
    /// @param reported The spoke's self-reported aggregate balance
    function _applyReportedBalance(uint64 _chainSelector, uint256 reported) internal {
        uint256 ceiling = (netSentToSpoke[_chainSelector] *
            (10_000 + MAX_YIELD_BPS)) /
            10_000 +
            REPORT_DUST;
        if (reported > ceiling) {
            if (quarantinedReports[_chainSelector] == 0) {
                activeQuarantineCount += 1;
            }
            quarantinedReports[_chainSelector] = reported;
            emit SuspiciousSpokeReport(_chainSelector, reported, ceiling);
            if (!paused()) _pause();
            return;
        }

        uint256 previous = spokeBalances[_chainSelector];
        if (
            previous > 0 &&
            reported < (previous * (10_000 - LOSS_ALERT_BPS)) / 10_000
        ) {
            emit SpokeBalanceDropped(_chainSelector, previous, reported);
        }

        spokeBalances[_chainSelector] = reported;
        emit SpokeBalanceUpdated(_chainSelector, reported);
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
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        _applyReportedBalance(_chainSelector, _message.spokeBalance);
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
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        inTransitAssets -= inTransitAmount[_message.messageId];
        delete inTransitAmount[_message.messageId];
        delete transitLegs[_message.messageId];
        if (inTransitToSpoke[_chainSelector] > 0) {
            inTransitToSpoke[_chainSelector] -= 1;
        }
        _applyReportedBalance(_chainSelector, _message.spokeBalance);
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
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        _applyReportedBalance(_chainSelector, _message.spokeBalance);
        if (pendingWithdrawals[_messageId].shares > 0 && _allSpokesFresh()) {
            try this.attemptSettlement(_messageId) {} catch {}
        }
    }

    /// @notice Handles CONFIRM_WITHDRAWAL from spoke — funds arrived. Three cases:
    ///         (1) a live Path 3 recall leg — credit the arrival and attempt settlement;
    ///         (2) an orphaned leg (withdrawal was cancelled, or its entry is otherwise gone)
    ///             — funds become ordinary idle, informational event only;
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
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        // WI-7: net down by the actual arrival, clamped at 0 — a spoke recalling more than
        // the hub ever sent it is either yield (policed by the band below, not here) or a
        // reporting inconsistency, neither of which should underflow this counter.
        netSentToSpoke[_chainSelector] -= actualAmount > netSentToSpoke[_chainSelector]
            ? netSentToSpoke[_chainSelector]
            : actualAmount;
        _applyReportedBalance(_chainSelector, _message.spokeBalance);

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
