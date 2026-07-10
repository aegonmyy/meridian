// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink+/ccip/applications/CCIPReceiver.sol";
import {SpokeStorage} from "./spoke/SpokeStorage.sol";
import {SpokeAdminModule} from "./spoke/SpokeAdminModule.sol";
import {SpokeHandlersModule} from "./spoke/SpokeHandlersModule.sol";
import {SpokeConfirmsModule} from "./spoke/SpokeConfirmsModule.sol";

/// @title SpokeVault
/// @notice Receives CCIP instructions from the HubVault and manages capital deployment
///         into yield protocols (Aave, Compound, Morpho) on a single L2 chain.
/// @dev Deployed once per supported L2 chain (Arbitrum, Base, Optimism).
///      Only the HubVault on Ethereum can send instructions to this contract via CCIP —
///      all other senders are rejected. Users never interact with this contract directly.
///      Capital flow: Hub sends DEPOSIT → spoke deploys into adapters → spoke reports balance back.
///      Four inbound message types: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT.
///      Four outbound message types: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL.
/// @dev R-7 (final step) of the Spoke modularization: all logic now lives in the three
///      sibling modules — SpokeAdminModule (adapter registry, Hub rotation, idle
///      redeployment), SpokeHandlersModule (CCIP inbound entry point + message handlers),
///      SpokeConfirmsModule (outbound confirm/report dispatch + retry queue). All state,
///      structs, events, and cross-module hook declarations live in SpokeStorage
///      (src/spoke/SpokeStorage.sol), which every module inherits directly (sibling
///      inheritance — no module inherits another). This file is now constructor-forwarding
///      only, composing the three modules into the deployed contract.
contract SpokeVault is SpokeAdminModule, SpokeHandlersModule, SpokeConfirmsModule {
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
    // Override-resolution wiring only (no logic) — required because Solidity's C3
    // linearization demands the most-derived contract explicitly disambiguate a
    // function whenever 3+ parallel diamond branches exist and any one of them
    // overrides it, even though only one sibling actually overrides each of these.
    // Pure super-delegation, zero behavior change. Same pattern approved for HUB's
    // R-4 (_deposit/_withdraw/totalAssets vs ERC4626), applied here without
    // re-escalating per that approval covering the identical recurrence.
    // =========================================================================

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override(CCIPReceiver, SpokeHandlersModule) {
        super._ccipReceive(message);
    }
}
