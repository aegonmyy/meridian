// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {SpokeStorage} from "./SpokeStorage.sol";
import {ZeroAddress, AdapterNotFound, AmountCannotBeZero, PendingConfirmsOutstanding} from "../errors/spokeErrors.sol";

/// @title SpokeAdminModule
/// @notice Owner-only adapter registry management (setAdapter/removeAdapter), Hub address
///         rotation, idle redeployment, and the adapter-registry view accessors.
/// @dev R-6 of the Spoke modularization. Sibling to SpokeHandlersModule and
///      SpokeConfirmsModule, all three inherit SpokeStorage directly and none inherit each
///      other. No function here is called across module boundaries, so no hooks are
///      implemented in this file.
///      getAllocations/activeAdaptersLength placement is a judgment call: the plan doesn't
///      explicitly assign them; kept here alongside the adapter registry they read, mirroring
///      isValidSpoke's placement in HubAdminModule.
abstract contract SpokeAdminModule is SpokeStorage {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Registers a new yield adapter or updates the contract address of an existing one
    /// @dev Uses `everRegistered` to prevent duplicate protocolId entries in activeAdapters
    ///      when a protocol is removed then re-added. On first registration protocolId is
    ///      pushed to activeAdapters. On update only the adapter address changes.
    ///      Uses forceApprove pattern: adapter contracts may require non-zero allowance resets.
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
    /// @dev Emergency mechanism: instantly stops capital from being deployed to this protocol.
    ///      Does not remove the protocolId from activeAdapters: inactive entries are skipped
    ///      during iteration via the exists flag. No timelock in v1. Owner is trusted.
    ///      Capital already deployed to this adapter is not automatically withdrawn.
    ///      A separate WITHDRAW_AMOUNT instruction from hub is needed to reclaim funds.
    /// @param _protocolId The bytes32 identifier of the protocol to disable
    function removeAdapter(bytes32 _protocolId) external onlyOwner {
        if (!adapters[_protocolId].exists) revert AdapterNotFound();
        adapters[_protocolId].adapter = IYieldSource(address(0));
        adapters[_protocolId].exists = false;
        emit AdapterRemoved(_protocolId);
    }

    /// @notice Updates the Hub address: use when Hub is redeployed with new features
    /// @dev All subsequent CCIP messages will only be accepted from the new Hub address.
    ///      Pending in-flight messages from the old Hub will be rejected on arrival.
    ///      Ensure no critical messages are in-flight before calling.
    /// @param _hub New HubVault address on Ethereum
    /// @dev WI-6 guard: reverts while any pendingConfirms entry is unresolved. A confirm
    ///      queued under the old Hub relationship (messageId semantics, expected sender)
    ///      could resolve incorrectly, or not at all, once HUB is repointed. Resolve or
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
    ///      Races with retryConfirm() on token-carrying confirms, see ConfirmFundsUnavailable.
    /// @param _protocolId Target adapter identifier: must be currently registered and active
    /// @param _amount Amount of spoke idle USDC to deposit
    function deployIdle(bytes32 _protocolId, uint256 _amount) external onlyOwner {
        if (_amount == 0) revert AmountCannotBeZero();
        AdapterInfo memory _adapter = adapters[_protocolId];
        if (!_adapter.exists) revert AdapterNotFound();
        ASSET.forceApprove(address(_adapter.adapter), _amount);
        _adapter.adapter.deposit(_amount);
        emit IdleDeployed(_protocolId, _amount);
    }

    // =========================================================================
    // External View Functions
    // =========================================================================

    /// @notice Returns a snapshot of each registered adapter's current balance
    /// @dev Array length always equals activeAdapters.length, includes removed adapters
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
    /// @dev Includes removed adapters: length only grows, never shrinks.
    ///      Use adapters[id].exists to check whether a specific adapter is still active.
    /// @return Length of the activeAdapters array
    function activeAdaptersLength() external view returns (uint256) {
        return activeAdapters.length;
    }
}
