// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink+/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "../libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HubStorage} from "./HubStorage.sol";
import {InvalidMessageType, NotSpoke, SpokeNotFound, InsufficientUnreservedIdle, InvalidRecallAmount} from "../errors/hubErrors.sol";

/// @title HubMessagingModule
/// @notice CCIP outbound dispatch (Rebalancer-facing sendToSpoke/recallFromSpoke/rebalance) and
///         inbound CCIP callback handling (_ccipReceive routing + the four confirm/report
///         handlers), plus the single choke point (_applyReportedBalance) every balance-
///         carrying callback routes through.
/// @dev R-3 of the Hub modularization. Sibling to HubAdminModule and HubWithdrawalModule, all
///      three inherit HubStorage directly and none inherit each other.
///      Implements 3 hooks declared in HubStorage (bodiless `virtual`, `override` here):
///      _newMessageId (called cross-module from HubWithdrawalModule._withdraw),
///      _requestAllBalanceReports (called cross-module via `this._requestAllBalanceReports(...)`
///      from HubWithdrawalModule._withdraw's Path 2), and the 3-arg recallFromSpoke overload
///      (called cross-module via `this.recallFromSpoke(...)` from
///      HubWithdrawalModule._withdraw's Path 3 leg dispatch).
///      Calls 2 hooks implemented in HubWithdrawalModule: _idleBalance (sendToSpoke,
///      idleBalance) and _allSpokesFresh (_handleReportBalanceCallback). Also calls
///      isValidSpoke, implemented in HubAdminModule (hook declared in HubStorage since R-2).
abstract contract HubMessagingModule is HubStorage {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Rebalancer Functions
    // =========================================================================

    /// @notice Sends USDC and deposit instructions to a spoke via CCIP
    /// @dev Only callable by Rebalancer. Encodes a DEPOSIT message. The only message type
    ///      that attaches USDC tokens to the CCIP transfer. Spoke deposits into adapters
    ///      and sends CONFIRM_RECEIPT back. inTransitAssets is incremented here and
    ///      decremented when CONFIRM_RECEIPT arrives.
    /// @param _chainSelector CCIP chain selector of the destination spoke
    /// @param _instructions Array of adapter instructions, protocol id and USDC amount per market
    function sendToSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) revert SpokeNotFound();
        // WI-3: authoritative solvency guard, reservedAssets is idle that a pending
        // withdrawal already depends on. Summed across every instruction, rather than the
        // first alone, so a multi-instruction deposit can't undercount its own total ask.
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
    ///      Sends a WITHDRAW_AMOUNT message: instruction only, no tokens attached outbound.
    ///      Spoke pulls proportionally from its adapters and sends tokens back via CCIP.
    ///      The messageId here matches an existing pendingWithdrawals entry so the arrival
    ///      callback can settle it: this is what distinguishes this overload from the
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

    /// @notice Rebalancer-driven recall: moves capital off an overweight spoke with no
    ///         pendingWithdrawal attached; the arrived tokens simply become hub idle
    /// @dev WI-3 (Issue 5, Option A). This is the missing "move weight off a chain" lever,
    ///      without it the only way capital left a spoke was via a user-triggered Path 3
    ///      withdrawal. The hub derives its own fresh id via _newMessageId (WI-1); callers
    ///      never supply one, since there is no pendingWithdrawal to match against.
    ///      Intended v1 operator flow (see Rebalancer.recallFromSpoke NatSpec for the full
    ///      sequence): off-chain diff → recallFromSpoke per overweight chain → await
    ///      RecallCompleted → proposeAllocation sized to the now-idle funds. The on-chain
    ///      diff engine that would automate this sequencing is explicitly out of scope (v2).
    /// @param _chainSelector CCIP chain selector of the spoke to recall from
    /// @param _amount USDC amount to recall: must be nonzero
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

    /// @notice Returns the USDC balance sitting idle on hub, not deployed or in transit
    /// @dev External view mirror of _idleBalance(), exposed so Rebalancer can pre-check
    ///      solvency before dispatching a proposal (WI-3 friendly pre-check).
    /// @return Idle USDC balance of this contract
    function idleBalance() external view returns (uint256) {
        return _idleBalance();
    }

    /// @notice Sends intra-spoke rebalance instructions to move capital between adapters
    /// @dev Only callable by Rebalancer. Sends a REBALANCE message. Instruction only,
    ///      no tokens attached. Spoke withdraws from source adapter and deposits into target
    ///      adapter on the same chain. No capital leaves the spoke chain.
    ///      Spoke responds with CONFIRM_REBALANCE carrying updated spoke balance.
    ///      The message id is derived internally via the nonce'd _newMessageId helper,
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

    /// @notice Encodes and dispatches a CCIP message to a spoke vault
    /// @dev Handles all outbound message types. Only DEPOSIT messages attach USDC tokens,
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
            // WI-0/WI-6: left false (ordered), verified against the pinned OffRamp
            // (offRamp/OffRamp.sol, NonceManager.sol) that the premise for flipping this
            // ("a failed/reverting message blocks subsequent same-sender messages on the
            // lane") does not hold. The inbound nonce is incremented in incrementInboundNonce
            // before trial execution runs, for every UNTOUCHED->{SUCCESS,FAILURE} transition,
            // so the nonce advances on the first execution attempt regardless of its
            // outcome, so a message that reverts still unblocks the next one once attempted
            // (which happens automatically/promptly under normal DON operation). The one
            // scenario ordered execution does block on is a message that is never
            // attempted at all (stuck UNTOUCHED: a DON or relayer liveness issue, not a
            // contract-level revert); that is an infra concern out-of-order execution would
            // not fully insulate against either for messages still ahead of the stuck one.
            // See docs/operations.md for the full finding.
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
    /// @dev Every id is unique across the hub's lifetime. The incrementing nonce
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

    /// @notice Applies (or quarantines) a spoke's self-reported balance. The single choke
    ///         point every balance-carrying callback routes through
    /// @dev WI-7 (Issue 7b, Option A). Upside-only sanity band: accept if
    ///      `reported <= netSentToSpoke[selector] * (10000 + MAX_YIELD_BPS) / 10000 + REPORT_DUST`.
    ///      Under-reporting always passes: it deflates share price, the safe direction,
    ///      but a drop exceeding LOSS_ALERT_BPS since the last report emits an informational
    ///      event. On breach, never clamp (clamping corrupts pricing the other direction);
    ///      quarantine instead. spokeBalances is left untouched, the report is stored in
    ///      quarantinedReports, SuspiciousSpokeReport fires, and deposits/withdrawals pause.
    ///      This function itself never reverts, callers include token-carrying CCIP arrival
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

    /// @notice Handles CONFIRM_REBALANCE from spoke, updates balance after intra-spoke rebalance
    /// @dev No pending withdrawal involved, just updates accounting.
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

    /// @notice Handles CONFIRM_RECEIPT from spoke, confirms deposit and clears inTransit
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

    /// @notice Handles REPORT_BALANCE from spoke, updates balance and attempts to settle a
    ///         pending Path 2 withdrawal once ALL active spokes are fresh
    /// @dev Spoke sends this in response to a REPORT_BALANCE request from hub. WI-4 fix:
    ///      previously settled on the FIRST spoke's report even with other spokes still
    ///      stale, now gated on _allSpokesFresh() so settlement uses a fully-refreshed
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

    /// @notice Handles CONFIRM_WITHDRAWAL from spoke, funds arrived. Three cases:
    ///         (1) a live Path 3 recall leg: credit the arrival and attempt settlement;
    ///         (2) an orphaned leg (withdrawal was cancelled, or its entry is otherwise
    ///             gone), where funds become ordinary idle and only an event is emitted;
    ///         (3) never a leg at all: a WI-3 Rebalancer-driven recall, funds become idle
    /// @dev Spoke sends this after pulling funds from adapters and transferring USDC back to
    ///      hub. actualAmount is read from destTokenAmounts (the CCIP token envelope), which
    ///      is the ground truth of what arrived. Never from the payload, which carries no amount
    ///      for confirm messages post-WI-2 (see docs/revert-audit.md). legToWithdrawal
    ///      disambiguates case (2) from (3): a leg id is always registered at dispatch time,
    ///      so `legToWithdrawal[id] != 0` proves this WAS a leg (case 1/2); a fresh WI-3 id
    ///      was never registered as a leg (case 3).
    /// @param _message Decoded CCIP message carrying updated spokeBalance and reportTimestamp
    /// @param _chainSelector Source chain selector identifying which spoke sent the message
    /// @param destTokenAmounts Token envelope delivered alongside this message, ground truth
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
        // WI-7: net down by the actual arrival, clamped at 0. A spoke recalling more than
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
            // never a leg, WI-3 Rebalancer-driven recall, funds become ordinary idle
            emit RecallCompleted(_chainSelector, actualAmount);
        }
    }
}
