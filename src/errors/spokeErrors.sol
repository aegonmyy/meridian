// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

///@notice Thrown when no active adapter is found
error NoActiveAdapters();

/// @notice Thrown when a zero address is provided where not allowed
error ZeroAddress();

/// @notice Thrown when a CCIP message originates from an address other than the hub
error NotHub();

/// @notice Thrown when attempting to interact with an adapter that is not registered or has been removed
error AdapterNotFound();

/// @notice Thrown when a CCIP message contains an unrecognised message type
error InvalidMessageType();

/// @notice Thrown when a deposit or withdrawal amount of zero is received
error AmountCannotBeZero();

///@notice Thrown when any of the constructor argument is invalid
error InvalidConstructorArguments();

/// @notice Thrown when retryConfirm is called with an index outside pendingConfirms bounds
error InvalidConfirmIndex();

/// @notice Thrown when retryConfirm is called for an already-resolved pending confirm
error ConfirmAlreadyResolved();

/// @notice Thrown when a token-carrying retryConfirm's USDC is no longer held by the spoke
/// @dev Can happen if deployIdle() redeployed the parked USDC before the retry landed,
///      see WI-2d race note in Spoke NatSpec.
error ConfirmFundsUnavailable();

/// @notice Thrown when setHub is called while pendingConfirms still has unresolved entries
error PendingConfirmsOutstanding();
