// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink+/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SpokeStorage} from "./spoke/SpokeStorage.sol";
import {SpokeAdminModule} from "./spoke/SpokeAdminModule.sol";
import {SpokeHandlersModule} from "./spoke/SpokeHandlersModule.sol";
import {InvalidConfirmIndex, ConfirmAlreadyResolved, ConfirmFundsUnavailable} from "./errors/spokeErrors.sol";

/// @title SpokeVault
/// @notice Receives CCIP instructions from the HubVault and manages capital deployment
///         into yield protocols (Aave, Compound, Morpho) on a single L2 chain.
/// @dev Deployed once per supported L2 chain (Arbitrum, Base, Optimism).
///      Only the HubVault on Ethereum can send instructions to this contract via CCIP —
///      all other senders are rejected. Users never interact with this contract directly.
///      Capital flow: Hub sends DEPOSIT → spoke deploys into adapters → spoke reports balance back.
///      Four inbound message types: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT.
///      Four outbound message types: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL.
/// @dev R-6 of the Spoke modularization: admin (SpokeAdminModule) and inbound message
///      handling (SpokeHandlersModule) have been extracted into sibling modules. This file
///      still holds confirm-dispatch logic directly — R-7 moves it into SpokeConfirmsModule,
///      leaving this file as constructor-forwarding only.
contract SpokeVault is SpokeStorage, SpokeAdminModule, SpokeHandlersModule {
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
    // Admin Functions (retryConfirm — moved to SpokeConfirmsModule.sol in R-7)
    // =========================================================================

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

    /// @notice Returns the length of the pendingConfirms array
    /// @return Length of the pendingConfirms array
    function pendingConfirmsLength() external view returns (uint256) {
        return pendingConfirms.length;
    }
}
