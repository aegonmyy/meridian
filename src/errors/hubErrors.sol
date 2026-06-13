// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Thrown when no active spokes are registered
error NoActiveSpokes();

/// @notice Thrown when user already has a pending withdrawal
error WithdrawalAlreadyPending();

/// @notice Thrown when a CCIP message contains an unrecognised message type
error InvalidMessageType();

/// @notice Thrown when no pending withdrawal exists for this address
error NoPendingWithdrawal();

/// @notice Thrown when a constructor argument is zero address
error InvalidConstructorArguments();

/// @notice Thrown when caller is not the Rebalancer
error NotRebalancer();

/// @notice Thrown when a CCIP message originates from an unregistered spoke
error NotSpoke();

/// @notice Thrown when a zero address is provided where not allowed
error ZeroAddress();

/// @notice Thrown when withdrawal amount exceeds available assets
error InsufficientAssets();

/// @notice Thrown when spoke is already registered
error SpokeAlreadyRegistered();

/// @notice Thrown when spoke is not registered
error SpokeNotFound();

///@notice Thrown when provided spoke already exists
error SpokeExists();
