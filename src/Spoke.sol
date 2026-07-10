// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink+/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {SpokeStorage} from "./spoke/SpokeStorage.sol";
import {ZeroAddress, NotHub, AdapterNotFound, InvalidMessageType, AmountCannotBeZero, InvalidConfirmIndex, ConfirmAlreadyResolved, ConfirmFundsUnavailable, PendingConfirmsOutstanding} from "./errors/spokeErrors.sol";

/// @title SpokeVault
/// @notice Receives CCIP instructions from the HubVault and manages capital deployment
///         into yield protocols (Aave, Compound, Morpho) on a single L2 chain.
/// @dev Deployed once per supported L2 chain (Arbitrum, Base, Optimism).
///      Only the HubVault on Ethereum can send instructions to this contract via CCIP —
///      all other senders are rejected. Users never interact with this contract directly.
///      Capital flow: Hub sends DEPOSIT → spoke deploys into adapters → spoke reports balance back.
///      Four inbound message types: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT.
///      Four outbound message types: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL.
/// @dev R-5 of the Spoke modularization: state, structs, events, constructor, and cross-module
///      hook declarations now live in SpokeStorage (src/spoke/SpokeStorage.sol). This file
///      still holds all logic as a single contract inheriting SpokeStorage — R-6/R-7 move
///      each logical group into its own sibling module (SpokeAdminModule, SpokeHandlersModule,
///      SpokeConfirmsModule) that also inherits SpokeStorage directly.
contract SpokeVault is SpokeStorage {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys the SpokeVault with initial chain and protocol configuration — forwards to SpokeStorage
    constructor(
        address _hub,
        address _asset,
        address _router,
        address _owner,
        address _link,
        uint64 _hubSelector
    ) SpokeStorage(_hub, _asset, _router, _owner, _link, _hubSelector) {}

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Registers a new yield adapter or updates the contract address of an existing one
    /// @dev Uses `everRegistered` to prevent duplicate protocolId entries in activeAdapters
    ///      when a protocol is removed then re-added. On first registration protocolId is
    ///      pushed to activeAdapters. On update only the adapter address changes.
    ///      Uses forceApprove pattern — adapter contracts may require non-zero allowance resets.
    /// @param _protocolId Arbitrary bytes32 identifier for the protocol (e.g. keccak256("AAVE"))
    /// @param _adapter Address of the IYieldSource adapter implementing deposit/withdraw/totalAssets
    function setAdapter(
        bytes32 _protocolId,
        address _adapter
    ) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        if (!adapters[_protocolId].everRegistered) {
            activeAdapters.push(_protocolId);
            adapters[_protocolId].everRegistered = true;
        }
        adapters[_protocolId].adapter = IYieldSource(_adapter);
        adapters[_protocolId].exists = true;
        emit AdapterSet(_protocolId, _adapter);
    }

    /// @notice Disables a yield adapter by setting its exists flag to false
    /// @dev Emergency mechanism — instantly stops capital from being deployed to this protocol.
    ///      Does not remove the protocolId from activeAdapters — inactive entries are skipped
    ///      during iteration via the exists flag. No timelock in v1 — owner is trusted.
    ///      Capital already deployed to this adapter is NOT automatically withdrawn.
    ///      A separate WITHDRAW_AMOUNT instruction from hub is needed to reclaim funds.
    /// @param _protocolId The bytes32 identifier of the protocol to disable
    function removeAdapter(bytes32 _protocolId) external onlyOwner {
        if (!adapters[_protocolId].exists) revert AdapterNotFound();
        adapters[_protocolId].adapter = IYieldSource(address(0));
        adapters[_protocolId].exists = false;
        emit AdapterRemoved(_protocolId);
    }

    /// @notice Updates the Hub address — use when Hub is redeployed with new features
    /// @dev All subsequent CCIP messages will only be accepted from the new Hub address.
    ///      Pending in-flight messages from the old Hub will be rejected on arrival.
    ///      Ensure no critical messages are in-flight before calling.
    /// @param _hub New HubVault address on Ethereum
    /// @dev WI-6 guard: reverts while any pendingConfirms entry is unresolved. A confirm
    ///      queued under the old Hub relationship (messageId semantics, expected sender)
    ///      could resolve incorrectly — or not at all — after HUB is repointed. Resolve or
    ///      wait out every queued confirm via retryConfirm() before rotating Hub.
    function setHub(address _hub) external onlyOwner {
        if (_hub == address(0)) revert ZeroAddress();
        if (unresolvedConfirmCount != 0) revert PendingConfirmsOutstanding();
        emit HubUpdated(HUB, _hub);
        HUB = _hub;
    }

    /// @notice Deploys parked spoke idle USDC into a registered adapter
    /// @dev v1: onlyOwner. Spoke idle can accumulate from partial DEPOSIT skips (WI-2c),
    ///      shortfalls left over after a WITHDRAW_AMOUNT recall, or direct transfers.
    ///      This lets an operator redeploy that idle instead of it sitting unproductively.
    ///      Races with retryConfirm() on token-carrying confirms — see ConfirmFundsUnavailable.
    /// @param _protocolId Target adapter identifier — must be currently registered and active
    /// @param _amount Amount of spoke idle USDC to deposit
    function deployIdle(bytes32 _protocolId, uint256 _amount) external onlyOwner {
        if (_amount == 0) revert AmountCannotBeZero();
        AdapterInfo memory _adapter = adapters[_protocolId];
        if (!_adapter.exists) revert AdapterNotFound();
        ASSET.forceApprove(address(_adapter.adapter), _amount);
        _adapter.adapter.deposit(_amount);
        emit IdleDeployed(_protocolId, _amount);
    }

    /// @notice Retries a previously-failed confirm send
    /// @dev Permissionless — anyone can pay gas to unstick the queue. Rebuilds the confirm
    ///      message fresh (spokeBalance recomputed at call time, not from the failure moment)
    ///      and resends. Token-carrying confirms re-verify the USDC is still held by this
    ///      contract — if deployIdle() redeployed it in the interim, this reverts with
    ///      ConfirmFundsUnavailable rather than attempting to send tokens the spoke no longer
    ///      holds (WI-2d's documented conservative choice for the retryConfirm/deployIdle race).
    /// @param index Index into pendingConfirms to retry
    function retryConfirm(uint256 index) external {
        if (index >= pendingConfirms.length) revert InvalidConfirmIndex();
        PendingConfirm memory pc = pendingConfirms[index];
        if (pc.resolved) revert ConfirmAlreadyResolved();
        if (pc.actualAmount > 0 && ASSET.balanceOf(address(this)) < pc.actualAmount) {
            revert ConfirmFundsUnavailable();
        }

        Client.EVM2AnyMessage memory ccipMessage = _buildConfirmMessage(
            pc.messageType,
            pc.messageId,
            pc.actualAmount
        );
        IRouterClient router = IRouterClient(getRouter());
        if (pc.actualAmount > 0) {
            ASSET.forceApprove(address(router), pc.actualAmount);
        }
        uint256 fee = router.getFee(HUB_CHAIN_SELECTOR, ccipMessage);
        LINK.forceApprove(address(router), fee);
        router.ccipSend(HUB_CHAIN_SELECTOR, ccipMessage);

        pendingConfirms[index].resolved = true;
        if (unresolvedConfirmCount > 0) {
            unresolvedConfirmCount -= 1;
        }
        emit ConfirmRetried(index);
    }

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
    ) internal override {
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

    /// @notice Handles DEPOSIT — deploys received USDC into specified yield adapters
    /// @dev Iterates instructions array depositing into each specified adapter.
    ///      Allocation validation (bps constraints, chain cap, dust floor) is enforced
    ///      upstream in the Rebalancer contract before the message is sent — not repeated here.
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
    ///      (which _aggregatedSpokeBalance now counts, so hub accounting stays exact — WI-2b).
    ///      The outbound CONFIRM_RECEIPT itself never hard-reverts the handler either — see
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
                // success — funds now deployed
            } catch (bytes memory reason) {
                ASSET.forceApprove(address(_adapter.adapter), 0);
                emit DepositInstructionFailed(protocolId, amount, reason);
            }
        }
        _sendOrQueueConfirm(CCIPHelpers.MessageType.CONFIRM_RECEIPT, _message.messageId, 0);
    }

    /// @notice Handles REBALANCE — moves capital between adapters on this spoke chain
    /// @dev Intra-spoke operation — no USDC leaves this chain. Withdraws from source adapter
    ///      and deposits into target adapter for each instruction in the message.
    ///      Both source and target adapters must be registered and active.
    ///      After rebalancing, sends CONFIRM_REBALANCE back to hub carrying updated spoke balance
    ///      so hub can refresh spokeBalances[] and lastReportTimestamp[].
    ///      Note: the @dev comment in the original incorrectly described this as a withdrawal —
    ///      this handler does NOT send tokens back to hub.
    /// @dev WI-2c: no CCIP tokens are attached to REBALANCE, but the loop performs real
    ///      adapter.withdraw/deposit calls — a hard revert on one bad instruction would
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
                // pulled funds stay on spoke as idle — not lost, just undeployed
                emit RebalanceInstructionFailed(sourceId, targetId, pullAmount, reason);
            }
        }
        _sendOrQueueConfirm(CCIPHelpers.MessageType.CONFIRM_REBALANCE, _message.messageId, 0);
    }

    /// @notice Handles WITHDRAW_AMOUNT — pulls requested USDC from adapters and sends back to hub
    /// @dev Called during Path 3 hub withdrawals when hub idle is insufficient to cover a user
    ///      withdrawal. Hub sends the shortfall amount — spoke pulls proportionally from all
    ///      active adapters weighted by their current balance, then sends the USDC back to hub
    ///      via a programmable token transfer (CONFIRM_WITHDRAWAL + tokens attached).
    ///      Proportional withdrawal preserves allocation ratios across adapters.
    ///      Last adapter receives remainder to avoid dust from integer division.
    ///      Hub uses messageId in CONFIRM_WITHDRAWAL to match the pending withdrawal and settle it.
    /// @dev WI-2b/2c rewrite. Spoke idle is drained first (up to the full request), then any
    ///      remaining shortfall is pulled proportionally from active adapters. Each adapter
    ///      pull is capped at that adapter's real totalAssets() — including the last adapter's
    ///      remainder — which removes both the exact-full-recall wei-overflow revert and the
    ///      Morpho mulDivDown-report-vs-round-up-withdraw mismatch by construction (never asks
    ///      an adapter for more than it reports holding). The division-by-zero on an empty
    ///      spoke is guarded. The CCIP token amount and RecallShortfall event always reflect
    ///      the truthful actualPulled, never the hub's requested amount — the hub must trust
    ///      only the delivered token envelope (destTokenAmounts), consistent with WI-4.
    ///      If actualPulled == 0 a token-less CONFIRM_WITHDRAWAL is still sent so the hub
    ///      learns the true state instead of waiting forever on a message that never comes.
    ///      FX-6b: each adapter's withdraw() is now wrapped in try/catch. Min-capping already
    ///      prevents the insufficient-balance revert, but not a protocol-level condition
    ///      (paused Aave pool, frozen Comet market) that still reverts regardless of amount
    ///      — without the wrap, that hard-reverted the whole handler, no confirm was ever
    ///      sent, and the hub's withdrawal stalled exactly like the original Issue-1 shape.
    ///      On failure: skip that adapter's leg (emit RecallPullFailed), continue the loop,
    ///      and let the already-truthful actualPulled confirm report whatever was pulled.
    /// @param _message Decoded CCIP message with single instruction — amount is the shortfall to recall
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

    /// @notice Handles REPORT_BALANCE — responds to hub's balance refresh request
    /// @dev Called during Path 2 hub withdrawals when spoke reports are stale.
    ///      Hub sends REPORT_BALANCE carrying a messageId matching the queued pending withdrawal.
    ///      Spoke responds with current aggregated balance so hub can update spokeBalances[],
    ///      refresh lastReportTimestamp[], and settle the pending withdrawal.
    ///      No tokens are moved — this is an accounting-only message.
    /// @param _message Decoded CCIP message — messageId is forwarded back to hub for withdrawal matching
    function _reportBalance(CCIPHelpers.CcipMessage memory _message) internal {
        _sendOrQueueConfirm(CCIPHelpers.MessageType.REPORT_BALANCE, _message.messageId, 0);
    }

    // =========================================================================
    // Internal Confirm Dispatch Helpers (WI-2d)
    // =========================================================================

    /// @notice Builds the outbound CCIP message for any confirm/report type
    /// @dev spokeBalance is always computed fresh at call time — critical for retryConfirm,
    ///      which must never resend a stale snapshot from the moment of original failure.
    ///      Instructions are always empty for confirm messages: none of the hub-side handlers
    ///      read the instructions field on a confirm — settlement trusts only the token
    ///      envelope (destTokenAmounts) and spokeBalance, consistent with WI-4's "trust the
    ///      token envelope, never the payload's claimed amount."
    /// @param _type The outbound message type
    /// @param _messageId The messageId being confirmed/reported
    /// @param _tokenAmount USDC to attach — 0 for token-less messages
    function _buildConfirmMessage(
        CCIPHelpers.MessageType _type,
        bytes32 _messageId,
        uint256 _tokenAmount
    ) internal view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmount = new Client.EVMTokenAmount[](
            _tokenAmount > 0 ? 1 : 0
        );
        if (_tokenAmount > 0) {
            tokenAmount[0] = Client.EVMTokenAmount({
                token: address(ASSET),
                amount: _tokenAmount
            });
        }
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](0);
        // _tokenAmount (if any) is still sitting in spoke idle at this point in execution —
        // it only actually leaves once the router pulls it as part of this same ccipSend.
        // Subtract it so the reported balance reflects post-transfer state, not a snapshot
        // that double-counts funds already committed to leave in this very message.
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(HUB),
                data: CCIPHelpers.encode(
                    CCIPHelpers.CcipMessage({
                        messageType: _type,
                        instructions: _instructions,
                        spokeBalance: _aggregatedSpokeBalance() - _tokenAmount,
                        reportTimestamp: block.timestamp,
                        messageId: _messageId
                    })
                ),
                tokenAmounts: tokenAmount,
                feeToken: address(LINK),
                // WI-0/WI-6: left false (ordered) — see the matching NatSpec in
                // HUB._sendToSpoke for the full finding. The premise that motivated
                // flipping this ("a reverting message blocks subsequent same-sender
                // messages") does not hold against the pinned OffRamp/NonceManager: the
                // inbound nonce advances on the first execution attempt regardless of
                // success or failure, so a reverting message does not block the next one
                // once attempted.
                extraArgs: Client._argsToBytes(
                    Client.EVMExtraArgsV2({
                        gasLimit: 200_000,
                        allowOutOfOrderExecution: false
                    })
                )
            });
    }

    /// @notice Attempts to send a confirm/report message; queues it for retry on failure
    /// @dev WI-2d. This is the mechanism that prevents a LINK-exhaustion or router failure
    ///      on the outbound leg from rolling back the fund-touching work already done in the
    ///      calling handler (docs/revert-audit.md #8, #14, #19, #20). getFee and ccipSend are
    ///      both external calls, wrapped in try/catch — any failure degrades to a queued
    ///      PendingConfirm + ConfirmSendFailed event rather than reverting.
    ///      NatSpec-documented observability contract: the hub cannot observe a spoke-side
    ///      failure it was never told about. This queue plus its events, together with
    ///      permissionless retryConfirm(), IS the observability contract — the WI-5 hub-side
    ///      per-message transit reconciliation is the last resort if a confirm truly never
    ///      lands (e.g. spoke abandoned).
    /// @param _type The outbound message type
    /// @param _messageId The messageId being confirmed/reported
    /// @param _tokenAmount USDC to attach — 0 for token-less messages
    function _sendOrQueueConfirm(
        CCIPHelpers.MessageType _type,
        bytes32 _messageId,
        uint256 _tokenAmount
    ) internal override {
        Client.EVM2AnyMessage memory ccipMessage = _buildConfirmMessage(
            _type,
            _messageId,
            _tokenAmount
        );
        IRouterClient router = IRouterClient(getRouter());
        if (_tokenAmount > 0) {
            ASSET.forceApprove(address(router), _tokenAmount);
        }
        try router.getFee(HUB_CHAIN_SELECTOR, ccipMessage) returns (uint256 fee) {
            LINK.forceApprove(address(router), fee);
            try router.ccipSend(HUB_CHAIN_SELECTOR, ccipMessage) returns (bytes32) {
                // sent successfully
            } catch {
                _queueConfirm(_type, _messageId, _tokenAmount);
            }
        } catch {
            _queueConfirm(_type, _messageId, _tokenAmount);
        }
    }

    /// @notice Persists a failed confirm send for later retry
    /// @param _type The outbound message type
    /// @param _messageId The messageId being confirmed/reported
    /// @param _tokenAmount USDC to attach on retry — 0 for token-less messages
    function _queueConfirm(
        CCIPHelpers.MessageType _type,
        bytes32 _messageId,
        uint256 _tokenAmount
    ) internal {
        pendingConfirms.push(
            PendingConfirm({
                messageType: _type,
                messageId: _messageId,
                actualAmount: _tokenAmount,
                resolved: false
            })
        );
        unresolvedConfirmCount += 1;
        emit ConfirmSendFailed(pendingConfirms.length - 1, _type, _messageId);
    }

    // =========================================================================
    // Internal View Helpers
    // =========================================================================

    /// @notice Sums spoke idle USDC plus totalAssets() across all currently active adapters
    /// @dev WI-2b: idle is first-class. A direct USDC transfer, or leftover from a partial
    ///      DEPOSIT skip / WITHDRAW_AMOUNT shortfall, is now counted — previously invisible
    ///      to the hub. Skips adapters where exists == false — removed adapters report zero.
    ///      Called before every outbound message to give hub an accurate spoke snapshot.
    ///      Value may lag slightly if adapters accrue yield between reports — accepted v1 tradeoff.
    /// @return aggregatedSpokeBalance Idle USDC plus total USDC managed across all active adapters
    function _aggregatedSpokeBalance()
        internal
        view
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

    /// @notice Returns the length of the pendingConfirms array
    /// @return Length of the pendingConfirms array
    function pendingConfirmsLength() external view returns (uint256) {
        return pendingConfirms.length;
    }

    // =========================================================================
    // External View Functions
    // =========================================================================

    /// @notice Returns a snapshot of each registered adapter's current balance
    /// @dev Array length always equals activeAdapters.length — includes removed adapters
    ///      as zero-initialized entries (protocolId == bytes32(0), balance == 0).
    ///      Callers should filter by protocolId != bytes32(0) to skip removed entries.
    ///      Off-chain agents use this to observe current allocation before proposing rebalances.
    /// @return balances Array of AdapterBalances structs ordered by registration sequence
    function getAllocations()
        external
        view
        returns (AdapterBalances[] memory balances)
    {
        bytes32[] memory _activeAdapters = activeAdapters;
        uint256 _length = _activeAdapters.length;
        balances = new AdapterBalances[](_length);
        if (_length == 0) return balances;
        for (uint256 i = 0; i < _length; i++) {
            if (adapters[_activeAdapters[i]].exists == false) continue;
            balances[i] = AdapterBalances({
                protocolId: _activeAdapters[i],
                balance: adapters[_activeAdapters[i]].adapter.totalAssets()
            });
        }
    }

    /// @notice Returns the length of the activeAdapters array
    /// @dev Includes removed adapters — length only grows, never shrinks.
    ///      Use adapters[id].exists to check whether a specific adapter is still active.
    /// @return Length of the activeAdapters array
    function activeAdaptersLength() external view returns (uint256) {
        return activeAdapters.length;
    }
}
