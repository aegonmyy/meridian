// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HubStorage} from "./hub/HubStorage.sol";
import {HubAdminModule} from "./hub/HubAdminModule.sol";
import {HubMessagingModule} from "./hub/HubMessagingModule.sol";
import {ZeroWithdrawal, InsufficientRecallLiquidity, NoPendingWithdrawal, NotWithdrawalOwner, WithdrawalNotYetCancellable} from "./errors/hubErrors.sol";

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
/// @dev R-3 of the Hub modularization: admin (HubAdminModule) and messaging (HubMessagingModule,
///      CCIP dispatch + inbound callback handling) have been extracted into sibling modules.
///      This file still holds withdrawal/ERC4626 logic directly — R-4 moves it into
///      HubWithdrawalModule, leaving this file as constructor-forwarding only.
contract HUB is HubAdminModule, HubMessagingModule {
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
