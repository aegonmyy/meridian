// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {HubStorage} from "./HubStorage.sol";
import {ZeroAddress, SpokeNotFound, SpokeAlreadyRegistered, NothingToReconcile, ReconcileTooEarly, SpokeNotDrained, SpokeHasInFlightLegs, NoQuarantinedReport} from "../errors/hubErrors.sol";

/// @title HubAdminModule
/// @notice Owner-only administrative surface: spoke registry management, misc owner setters,
///         in-transit leg reconciliation, and quarantined-report resolution.
/// @dev R-2 of the Hub modularization. Sibling to HubMessagingModule and HubWithdrawalModule,
///      all three inherit HubStorage directly and none inherit each other. isValidSpoke is
///      declared as a hook in HubStorage (bodiless `virtual`) because HubMessagingModule's
///      _ccipReceive calls it cross-module; this file provides the `override` implementation.
///      No other function here is called across module boundaries.
abstract contract HubAdminModule is HubStorage {
    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Sets or updates the Rebalancer contract address
    /// @dev Only callable by owner. Allows post-deployment configuration to resolve
    ///      circular dependency. Hub needs Rebalancer address and vice versa.
    ///      No guard against re-setting: owner is trusted to manage this correctly.
    /// @param _rebalancer New Rebalancer contract address
    function setRebalancer(address _rebalancer) external onlyOwner {
        if (_rebalancer == address(0)) revert ZeroAddress();
        REBALANCER = _rebalancer;
    }

    /// @notice Updates the gas limit passed to CCIP router for all outbound messages
    /// @dev Increase if CCIP messages land with execution failure at the spoke.
    ///      Default 1_500_000 covers most operations including adapter deposits + CCIP reply.
    /// @param _gasLimit New gas limit: must be > 0 and reasonable for spoke execution
    function setOutboundGasLimit(uint32 _gasLimit) external onlyOwner {
        outboundGasLimit = _gasLimit;
    }

    /// @notice Releases a specific, aged, tracked in-transit leg whose CONFIRM_RECEIPT will
    ///         provably never arrive (dead lane, spoke decommissioned, permanent CCIP failure)
    /// @dev WI-5: replaces the removed adjustInTransitAssets, which let the owner write
    ///      inTransitAssets to any value at all with no evidence, bound, or delay. An unbounded
    ///      write to a share-price input. This can only write down one specific id by its
    ///      exact tracked amount, and only after TRANSIT_RECONCILE_DELAY has passed since it
    ///      was sent. It can never invent value or inflate the vault.
    ///      Operational order: attempt CCIP manual execution first; call this only once the
    ///      message is provably dead. A late CONFIRM_RECEIPT arriving after reconciliation
    ///      is harmless, inTransitAmount[id] is already deleted, so
    ///      `inTransitAssets -= inTransitAmount[id]` in _handleDepositCallback subtracts
    ///      zero and only updates the spoke balance (see WI5 regression tests).
    ///      FX-2: also decrements inTransitToSpoke[selector] for the leg's origin selector
    ///      (read from the stored TransitLeg, never an owner-supplied parameter. The stored
    ///      value is the only trustworthy source). Without this, a reconciled leg, by
    ///      definition one whose confirm will never arrive, left inTransitToSpoke
    ///      permanently nonzero, making the safe removeSpoke path revert
    ///      SpokeHasInFlightLegs forever for that selector even after the spoke was fully
    ///      drained, forcing forceRemoveSpoke as the routine tool for exactly the dead-lane
    ///      scenario this function exists to clean up.
    /// @param messageId The stuck DEPOSIT leg's internal message id
    function reconcileTransit(bytes32 messageId) external onlyOwner {
        uint256 amt = inTransitAmount[messageId];
        if (amt == 0) revert NothingToReconcile();
        TransitLeg memory leg = transitLegs[messageId];
        if (block.timestamp < leg.sentAt + TRANSIT_RECONCILE_DELAY) {
            revert ReconcileTooEarly();
        }
        inTransitAssets -= amt;
        delete inTransitAmount[messageId];
        delete transitLegs[messageId];
        if (inTransitToSpoke[leg.selector] > 0) {
            inTransitToSpoke[leg.selector] -= 1;
        }
        emit TransitReconciled(messageId, amt);
    }

    /// @notice Registers a new spoke or updates an existing spoke's contract address
    /// @dev Uses `everRegistered` flag to prevent duplicate entries in spokeChainSelectors
    ///      when a selector is removed and re-added. The same address cannot be registered
    ///      on two different selectors simultaneously, enforced via addressToSelector reverse mapping.
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

    /// @notice Disables a spoke by setting its exists flag to false: the safe path and the default
    /// @dev WI-6 guard: requires spokeBalances[selector] == 0 and no in-flight legs
    ///      (inTransitToSpoke[selector] == 0). Rationale: removing a funded spoke instantly
    ///      craters totalManagedAssets() by that spoke's reported balance: a mispricing
    ///      window that shortchanges every share until re-registered, and turns any
    ///      still-in-flight CONFIRM_RECEIPT for that selector into NotSpoke poison the moment
    ///      it lands (isValidSpoke() goes false mid-flight). Drain the spoke (recallFromSpoke
    ///      until spokeBalances[selector] == 0) and let in-flight legs land first; only then
    ///      is this safe. For true emergencies where waiting isn't acceptable, see
    ///      forceRemoveSpoke: the unsafe path is intentionally a separate, loudly-named
    ///      function so the safe path stays the default.
    ///      Does not remove from spokeChainSelectors array: inactive spokes are skipped
    ///      during iteration via the exists flag. Also clears addressToSelector.
    /// @param _chainSelector CCIP chain selector of the spoke to disable
    function removeSpoke(uint64 _chainSelector) external onlyOwner {
        if (spokes[_chainSelector].exists == false) revert SpokeNotFound();
        if (spokeBalances[_chainSelector] != 0) revert SpokeNotDrained();
        if (inTransitToSpoke[_chainSelector] != 0) revert SpokeHasInFlightLegs();
        delete addressToSelector[spokes[_chainSelector].spoke];
        spokes[_chainSelector].exists = false;
        emit SpokeRemoved(_chainSelector);
    }

    /// @notice Emergency: disables a spoke without the safety checks removeSpoke enforces
    /// @dev WI-6. Use only when the safe path (removeSpoke) is not viable, e.g.
    ///      the spoke contract itself is compromised and continuing to interact with it
    ///      (even to drain it) is the greater risk. Skipping the checks means:
    ///      (a) totalManagedAssets() instantly drops by spokeBalances[selector]: a real,
    ///      immediate mispricing event against every current shareholder rather than a
    ///      cosmetic one; (b) any CONFIRM_RECEIPT still in flight for this selector will
    ///      revert with NotSpoke on arrival, poisoning that CCIP message permanently. That
    ///      DEPOSIT's inTransitAmount becomes a WI-5 reconcileTransit candidate once its
    ///      TRANSIT_RECONCILE_DELAY has passed, since the confirm can now never land.
    ///      Owner-only, separate from removeSpoke by design so the destructive path is never
    ///      the accidental default.
    /// @param _chainSelector CCIP chain selector of the spoke to forcibly disable
    function forceRemoveSpoke(uint64 _chainSelector) external onlyOwner {
        if (spokes[_chainSelector].exists == false) revert SpokeNotFound();
        delete addressToSelector[spokes[_chainSelector].spoke];
        spokes[_chainSelector].exists = false;
        // FX-5: the dangling values are preserved in the event below for the operator, then
        // zeroed. Without this, re-registering this selector via addSpoke (e.g. pointing it
        // at a freshly redeployed, or confirmed-safe, spoke contract) would instantly
        // resurrect the old, possibly-compromised-or-drained balance into totalAssets(),
        // the new spoke has reported nothing yet and shouldn't inherit its predecessor's
        // number. inTransitToSpoke is zeroed for the same reason: those legs' confirms can
        // never land once the spoke is force-removed (NotSpoke), so the counter would
        // otherwise dangle forever and permanently block the safe removeSpoke path on any
        // future re-add + re-remove cycle for this selector. Any tracked inTransitAmount
        // legs remain independently reachable as reconcileTransit candidates, per the
        // existing NatSpec on this function.
        emit SpokeForceRemoved(
            _chainSelector,
            spokeBalances[_chainSelector],
            inTransitToSpoke[_chainSelector]
        );
        delete spokeBalances[_chainSelector];
        delete inTransitToSpoke[_chainSelector];
    }

    /// @notice Returns whether an address is currently a valid active spoke
    /// @dev Checks both the reverse mapping and the exists flag to guard against
    ///      stale entries where address was removed or updated.
    /// @param _spoke Address to check
    /// @return True if _spoke is the currently registered active spoke for its selector
    function isValidSpoke(address _spoke) public view override returns (bool) {
        uint64 selector = addressToSelector[_spoke];
        if (selector == 0) return false;
        return spokes[selector].exists && spokes[selector].spoke == _spoke;
    }

    /// @notice Owner accepts a quarantined report: applies it to spokeBalances and unpauses
    ///         once no spoke has an outstanding quarantine
    /// @dev WI-7. Use once the owner has independently confirmed the reported balance is
    ///      legitimate (e.g. an outsized but real yield, or a one-off catch-up report after a
    ///      period of stale reporting).
    /// @param _chainSelector The spoke whose quarantined report to accept
    function acceptQuarantinedReport(uint64 _chainSelector) external onlyOwner {
        uint256 amount = quarantinedReports[_chainSelector];
        if (amount == 0) revert NoQuarantinedReport();
        spokeBalances[_chainSelector] = amount;
        // FX-3: rebase the band's baseline to the just-accepted value. The band
        // (netSentToSpoke * (1 + MAX_YIELD_BPS) + REPORT_DUST) is flat and time-blind by
        // design: without this, a spoke's honest cumulative yield eventually exceeds it
        // permanently (e.g. ~2 years at 10% APY with the default MAX_YIELD_BPS), and every
        // subsequent honest report would quarantine again immediately after being accepted:
        // a permanent pause/accept flap. Accepting is an attestation with a durable effect,
        // not a one-off waiver: the owner just independently confirmed this balance is
        // legitimate, so it becomes the new verified baseline the next report is measured
        // against.
        netSentToSpoke[_chainSelector] = amount;
        delete quarantinedReports[_chainSelector];
        if (activeQuarantineCount > 0) activeQuarantineCount -= 1;
        emit QuarantinedReportAccepted(_chainSelector, amount);
        emit SpokeBalanceUpdated(_chainSelector, amount);
        if (activeQuarantineCount == 0 && paused()) _unpause();
    }

    /// @notice Owner rejects a quarantined report: discards it, spokeBalances stays as it
    ///         was before the suspicious report, unpauses once no spoke has an outstanding
    ///         quarantine
    /// @dev WI-7. Use when the report is confirmed bogus (compromised spoke, decoding bug,
    ///      etc.), spokeBalances keeps its last-known-good value.
    /// @param _chainSelector The spoke whose quarantined report to reject
    function rejectQuarantinedReport(uint64 _chainSelector) external onlyOwner {
        uint256 amount = quarantinedReports[_chainSelector];
        if (amount == 0) revert NoQuarantinedReport();
        delete quarantinedReports[_chainSelector];
        if (activeQuarantineCount > 0) activeQuarantineCount -= 1;
        emit QuarantinedReportRejected(_chainSelector, amount);
        if (activeQuarantineCount == 0 && paused()) _unpause();
    }
}
