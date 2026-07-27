// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {CCIPHelpers} from "../libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SpokeStorage} from "./SpokeStorage.sol";
import {NotHub, InvalidMessageType} from "../errors/spokeErrors.sol";

/// @title SpokeHandlersModule
/// @notice CCIP inbound entry point (_ccipReceive routing) and the four inbound message
///         handlers (_handleDeposit, _handleRebalance, _handleWithdrawalWithAmount,
///         _reportBalance), plus the aggregated-balance view they all ultimately report.
/// @dev R-6 of the Spoke modularization. Sibling to SpokeAdminModule and SpokeConfirmsModule,
///      all three inherit SpokeStorage directly and none inherit each other.
///      Implements the _aggregatedSpokeBalance hook declared in SpokeStorage (bodiless
///      `virtual`, `override` here), called cross-module from
///      SpokeConfirmsModule._buildConfirmMessage.
///      Calls the _sendOrQueueConfirm hook implemented in SpokeConfirmsModule (pre-declared
///      in SpokeStorage, no new hook needed here).
abstract contract SpokeHandlersModule is SpokeStorage {
    using SafeERC20 for IERC20;

    // =========================================================================
    // CCIP Entry Point
    // =========================================================================

    /// @notice Entry point for all incoming CCIP messages from the HubVault
    /// @dev Overrides CCIPReceiver._ccipReceive. Router authenticity is checked by the
    ///      base CCIPReceiver contract before this function is called.
    ///      Hub origin is validated by decoding message.sender and comparing to HUB.
    ///      Routes to the correct internal handler based on CCIPHelpers.MessageType:
    ///      DEPOSIT          → _handleDeposit (deploy USDC into adapters)
    ///      REBALANCE        → _handleRebalance (move capital between adapters)
    ///      REPORT_BALANCE   → _reportBalance (respond with current aggregated balance)
    ///      WITHDRAW_AMOUNT  → _handleWithdrawalWithAmount (pull funds and send back to hub)
    /// @param message The raw CCIP message struct delivered by the Chainlink router
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal virtual override {
        if (abi.decode(message.sender, (address)) != HUB) revert NotHub();
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.decode(
            message.data
        );

        if (_message.messageType == CCIPHelpers.MessageType.DEPOSIT) {
            _handleDeposit(_message);
        } else if (_message.messageType == CCIPHelpers.MessageType.REBALANCE) {
            _handleRebalance(_message);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.REPORT_BALANCE
        ) {
            _reportBalance(_message);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.WITHDRAW_AMOUNT
        ) {
            _handleWithdrawalWithAmount(_message);
        } else {
            revert InvalidMessageType();
        }
    }

    // =========================================================================
    // Internal Message Handlers
    // =========================================================================

    /// @notice Handles DEPOSIT, deploys received USDC into specified yield adapters
    /// @dev Iterates instructions array depositing into each specified adapter.
    ///      Allocation validation (bps constraints, chain cap, dust floor) is enforced
    ///      upstream in the Rebalancer contract before the message is sent, not repeated here.
    ///      After depositing, sends CONFIRM_RECEIPT back to hub carrying the new aggregated
    ///      spoke balance so hub can update spokeBalances[] and decrement inTransitAssets.
    ///      Uses forceApprove to handle USDT-like tokens that revert on non-zero allowance.
    /// @dev WI-2c: instructions are no longer all-or-nothing. Because the DEPOSIT's tokens
    ///      arrive as a single lump-sum CCIP transfer covering every instruction's amount
    ///      combined, a hard revert on one bad instruction would roll back the whole transfer
    ///      and strand every valid instruction's amount in CCIP limbo too (see docs/revert-audit.md
    ///      #5-#7). Each instruction is now independently attempted: zero amount, an unknown/
    ///      removed adapter, or a reverting adapter.deposit() call are all skipped with a
    ///      DepositInstructionFailed event, leaving that instruction's amount as spoke idle
    ///      (which _aggregatedSpokeBalance now counts, so hub accounting stays exact, WI-2b).
    ///      The outbound CONFIRM_RECEIPT itself never hard-reverts the handler either, see
    ///      _sendOrQueueConfirm (WI-2d).
    /// @param _message Decoded CCIP message containing adapter instructions with protocol ids and amounts
    function _handleDeposit(CCIPHelpers.CcipMessage memory _message) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            bytes32 protocolId = _message.instructions[i].adapter;
            uint256 amount = _message.instructions[i].amount;
            if (amount == 0) {
                emit DepositInstructionFailed(protocolId, amount, bytes("zero amount"));
                continue;
            }
            AdapterInfo memory _adapter = adapters[protocolId];
            if (!_adapter.exists) {
                emit DepositInstructionFailed(protocolId, amount, bytes("adapter not found"));
                continue;
            }
            ASSET.forceApprove(address(_adapter.adapter), amount);
            try _adapter.adapter.deposit(amount) {
                // success, funds now deployed
            } catch (bytes memory reason) {
                ASSET.forceApprove(address(_adapter.adapter), 0);
                emit DepositInstructionFailed(protocolId, amount, reason);
            }
        }
        _sendOrQueueConfirm(CCIPHelpers.MessageType.CONFIRM_RECEIPT, _message.messageId, 0);
    }

    /// @notice Handles REBALANCE, moves capital between adapters on this spoke chain
    /// @dev Intra-spoke operation: no USDC leaves this chain. Withdraws from source adapter
    ///      and deposits into target adapter for each instruction in the message.
    ///      Both source and target adapters must be registered and active.
    ///      After rebalancing, sends CONFIRM_REBALANCE back to hub carrying updated spoke balance
    ///      so hub can refresh spokeBalances[] and lastReportTimestamp[].
    ///      Note: the @dev comment in the original incorrectly described this as a withdrawal,
    ///      this handler does NOT send tokens back to hub.
    /// @dev WI-2c: no CCIP tokens are attached to REBALANCE, but the loop performs real
    ///      adapter.withdraw/deposit calls: a hard revert on one bad instruction would
    ///      unwind an earlier instruction's already-executed move within the same call frame
    ///      and permanently block the CONFIRM_REBALANCE the hub is waiting on for a balance
    ///      refresh (docs/revert-audit.md #10-#13). Each instruction is now independently
    ///      attempted: zero amount, unknown/removed adapter, or a reverting withdraw/deposit
    ///      call are skipped with a RebalanceInstructionFailed event. The source pull is
    ///      clamped to the source adapter's real balance to remove the most common revert
    ///      cause outright.
    /// @param _message Decoded CCIP message with instructions specifying source adapter,
    ///                 target adapter, and amount to move for each operation
    function _handleRebalance(
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            bytes32 sourceId = _message.instructions[i].adapter;
            bytes32 targetId = _message.instructions[i].targetAdapter;
            uint256 amount = _message.instructions[i].amount;
            if (amount == 0) {
                emit RebalanceInstructionFailed(sourceId, targetId, amount, bytes("zero amount"));
                continue;
            }
            AdapterInfo memory _sourceAdapter = adapters[sourceId];
            AdapterInfo memory _targetAdapter = adapters[targetId];
            if (!_sourceAdapter.exists || !_targetAdapter.exists) {
                emit RebalanceInstructionFailed(sourceId, targetId, amount, bytes("adapter not found"));
                continue;
            }

            uint256 sourceTotal = _sourceAdapter.adapter.totalAssets();
            uint256 pullAmount = amount > sourceTotal ? sourceTotal : amount;
            if (pullAmount == 0) {
                emit RebalanceInstructionFailed(sourceId, targetId, amount, bytes("source empty"));
                continue;
            }

            try _sourceAdapter.adapter.withdraw(pullAmount) {
            } catch (bytes memory reason) {
                emit RebalanceInstructionFailed(sourceId, targetId, amount, reason);
                continue;
            }

            ASSET.forceApprove(address(_targetAdapter.adapter), pullAmount);
            try _targetAdapter.adapter.deposit(pullAmount) {
            } catch (bytes memory reason) {
                ASSET.forceApprove(address(_targetAdapter.adapter), 0);
                // pulled funds stay on spoke as idle, not lost, just undeployed
                emit RebalanceInstructionFailed(sourceId, targetId, pullAmount, reason);
            }
        }
        _sendOrQueueConfirm(CCIPHelpers.MessageType.CONFIRM_REBALANCE, _message.messageId, 0);
    }

    /// @notice Handles WITHDRAW_AMOUNT: pulls requested USDC from adapters and sends back to hub
    /// @dev Called during Path 3 hub withdrawals when hub idle is insufficient to cover a user
    ///      withdrawal. Hub sends the shortfall amount, and the spoke pulls proportionally from all
    ///      active adapters weighted by their current balance, then sends the USDC back to hub
    ///      via a programmable token transfer (CONFIRM_WITHDRAWAL + tokens attached).
    ///      Proportional withdrawal preserves allocation ratios across adapters.
    ///      Last adapter receives remainder to avoid dust from integer division.
    ///      Hub uses messageId in CONFIRM_WITHDRAWAL to match the pending withdrawal and settle it.
    /// @dev WI-2b/2c rewrite. Spoke idle is drained first (up to the full request), then any
    ///      remaining shortfall is pulled proportionally from active adapters. Each adapter
    ///      pull is capped at that adapter's real totalAssets(). Including the last adapter's
    ///      remainder, which removes both the exact-full-recall wei-overflow revert and the
    ///      Morpho mulDivDown-report-vs-round-up-withdraw mismatch by construction (never asks
    ///      an adapter for more than it reports holding). The division-by-zero on an empty
    ///      spoke is guarded. The CCIP token amount and RecallShortfall event always reflect
    ///      the truthful actualPulled, never the hub's requested amount. The hub must trust
    ///      only the delivered token envelope (destTokenAmounts), consistent with WI-4.
    ///      If actualPulled == 0 a token-less CONFIRM_WITHDRAWAL is still sent so the hub
    ///      learns the true state instead of waiting forever on a message that never comes.
    ///      FX-6b: each adapter's withdraw() is now wrapped in try/catch. Min-capping already
    ///      prevents the insufficient-balance revert, but not a protocol-level condition
    ///      (paused Aave pool, frozen Comet market) that still reverts regardless of amount.
    ///      Without the wrap, that hard-reverted the whole handler, no confirm was ever
    ///      sent, and the hub's withdrawal stalled exactly like the original Issue-1 shape.
    ///      On failure: skip that adapter's leg (emit RecallPullFailed), continue the loop,
    ///      and let the already-truthful actualPulled confirm report whatever was pulled.
    /// @param _message Decoded CCIP message with single instruction. Amount is the shortfall to recall
    function _handleWithdrawalWithAmount(
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        uint256 amountRequested = _message.instructions[0].amount;

        // spoke idle drains first
        uint256 idleBalance = ASSET.balanceOf(address(this));
        uint256 totalPulled = idleBalance >= amountRequested
            ? amountRequested
            : idleBalance;
        uint256 remaining = amountRequested - totalPulled;

        if (remaining > 0) {
            bytes32[] memory _adapters = activeAdapters;
            uint256 _totalSpokeBalance;
            uint256 _lastIndex;
            bool anyActive;
            for (uint256 i = 0; i < _adapters.length; i++) {
                if (!adapters[_adapters[i]].exists) continue;
                _totalSpokeBalance += adapters[_adapters[i]].adapter.totalAssets();
                _lastIndex = i;
                anyActive = true;
            }

            if (anyActive && _totalSpokeBalance > 0) {
                uint256 pulledFromAdapters;
                for (uint256 i = 0; i < _adapters.length; i++) {
                    if (!adapters[_adapters[i]].exists) continue;
                    uint256 adapterBalance = adapters[_adapters[i]].adapter.totalAssets();
                    uint256 pullAmount;
                    if (i == _lastIndex) {
                        uint256 want = remaining - pulledFromAdapters;
                        pullAmount = want > adapterBalance ? adapterBalance : want;
                    } else {
                        uint256 proportional = (remaining * adapterBalance) /
                            _totalSpokeBalance;
                        pullAmount = proportional > adapterBalance
                            ? adapterBalance
                            : proportional;
                    }
                    if (pullAmount == 0) continue;
                    bytes32 protocolId = _adapters[i];
                    try adapters[protocolId].adapter.withdraw(pullAmount) {
                        pulledFromAdapters += pullAmount;
                    } catch (bytes memory reason) {
                        emit RecallPullFailed(protocolId, pullAmount, reason);
                    }
                }
                totalPulled += pulledFromAdapters;
            }
        }

        if (totalPulled < amountRequested) {
            emit RecallShortfall(amountRequested, totalPulled);
        }

        _sendOrQueueConfirm(
            CCIPHelpers.MessageType.CONFIRM_WITHDRAWAL,
            _message.messageId,
            totalPulled
        );
    }

    /// @notice Handles REPORT_BALANCE, responds to hub's balance refresh request
    /// @dev Called during Path 2 hub withdrawals when spoke reports are stale.
    ///      Hub sends REPORT_BALANCE carrying a messageId matching the queued pending withdrawal.
    ///      Spoke responds with current aggregated balance so hub can update spokeBalances[],
    ///      refresh lastReportTimestamp[], and settle the pending withdrawal.
    ///      No tokens are moved: this is an accounting-only message.
    /// @param _message Decoded CCIP message, messageId is forwarded back to hub for withdrawal matching
    function _reportBalance(CCIPHelpers.CcipMessage memory _message) internal {
        _sendOrQueueConfirm(CCIPHelpers.MessageType.REPORT_BALANCE, _message.messageId, 0);
    }

    // =========================================================================
    // Internal View Helpers
    // =========================================================================

    /// @notice Sums spoke idle USDC plus totalAssets() across all currently active adapters
    /// @dev WI-2b: idle is first-class. A direct USDC transfer, or leftover from a partial
    ///      DEPOSIT skip / WITHDRAW_AMOUNT shortfall, is now counted, previously invisible
    ///      to the hub. Skips adapters where exists == false, removed adapters report zero.
    ///      Called before every outbound message to give hub an accurate spoke snapshot.
    ///      Value may lag slightly if adapters accrue yield between reports, accepted v1 tradeoff.
    /// @return aggregatedSpokeBalance Idle USDC plus total USDC managed across all active adapters
    function _aggregatedSpokeBalance()
        internal
        view
        virtual
        override
        returns (uint256 aggregatedSpokeBalance)
    {
        aggregatedSpokeBalance = ASSET.balanceOf(address(this));
        bytes32[] memory _activeAdapters = activeAdapters;
        uint256 _length = _activeAdapters.length;
        for (uint256 i = 0; i < _length; i++) {
            if (adapters[_activeAdapters[i]].exists == false) continue;
            aggregatedSpokeBalance += adapters[_activeAdapters[i]]
                .adapter
                .totalAssets();
        }
    }
}
