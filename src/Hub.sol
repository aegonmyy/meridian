// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {HubStorage} from "./hub/HubStorage.sol";
import {HubAdminModule} from "./hub/HubAdminModule.sol";
import {HubMessagingModule} from "./hub/HubMessagingModule.sol";
import {HubWithdrawalModule} from "./hub/HubWithdrawalModule.sol";

/// @title HubVault
/// @notice ERC4626 vault on Ethereum, entry point for all user deposits and withdrawals.
///         Users deposit USDC here and receive vault shares representing their proportional
///         ownership of all protocol-managed capital across all chains.
/// @dev Inherits ERC4626, CCIPReceiver, and Ownable. Delegates capital deployment to
///      spoke vaults on L2s via Chainlink CCIP. Share price reflects total managed assets
///      across all spokes including yield accrued on deployed capital.
///      Only the Rebalancer contract can move capital between hub and spokes.
///      Withdrawals are asynchronous when capital is deployed. Three paths exist:
///      Path 1 (sync): idle covers withdrawal and all spoke reports are fresh.
///      Path 2 (async): idle covers withdrawal but spoke reports are stale, refreshes first.
///      Path 3 (async): idle insufficient, recalls shortfall from best spoke via CCIP.
/// @dev R-4 (final step) of the Hub modularization: all logic now lives in the three sibling
///      modules, HubAdminModule (spoke registry, misc admin, quarantine resolution),
///      HubMessagingModule (CCIP dispatch + inbound callbacks), HubWithdrawalModule
///      (ERC4626 deposit/withdraw overrides, the WI-4 three-path withdrawal engine, and
///      share-price accounting). All state, structs, events, and cross-module hook
///      declarations live in HubStorage (src/hub/HubStorage.sol), which every module
///      inherits directly (sibling inheritance, no module inherits another). This file is
///      now constructor-forwarding only, composing the three modules into the deployed
///      contract.
contract HUB is HubAdminModule, HubMessagingModule, HubWithdrawalModule {
    /// @notice Deploys HubVault with core configuration, forwards to HubStorage
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
    // Override-resolution wiring only (no logic): required because Solidity's C3
    // linearization demands the most-derived contract explicitly disambiguate a
    // function whenever 3+ parallel diamond branches exist and any one of them
    // overrides it, even though HubWithdrawalModule is the only sibling that actually
    // overrides these ERC4626 virtuals. Pure super-delegation, zero behavior change.
    // =========================================================================

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override(ERC4626, HubWithdrawalModule) {
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override(ERC4626, HubWithdrawalModule) {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function totalAssets() public view override(ERC4626, HubWithdrawalModule) returns (uint256) {
        return super.totalAssets();
    }
}
