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

/// @notice Thrown when withdrawal results in zero assets
error ZeroWithdrawal();

/// @notice Thrown when sendToSpoke would ship more idle than is currently unreserved
/// @dev requested: sum of instruction amounts. idle: current idle balance. reserved: reservedAssets.
error InsufficientUnreservedIdle(uint256 requested, uint256 idle, uint256 reserved);

/// @notice Thrown when a recall amount is zero
error InvalidRecallAmount();

/// @notice Thrown when a Path 3 withdrawal's shortfall cannot be fully covered by recalling
///         from active spokes even after planning legs across all of them
/// @dev shortfall: assets - idleFree. coverable: sum of haircut-capped leg amounts found.
///      Fail-closed — the whole _withdraw call reverts, no shares move, nothing locks.
error InsufficientRecallLiquidity(uint256 shortfall, uint256 coverable);

/// @notice Thrown when cancelWithdrawal is called by anyone other than the withdrawal's owner
error NotWithdrawalOwner();

/// @notice Thrown when cancelWithdrawal is called before WITHDRAWAL_TIMEOUT has elapsed
error WithdrawalNotYetCancellable();

/// @notice Thrown when reconcileTransit is called for a messageId with no tracked in-transit amount
error NothingToReconcile();

/// @notice Thrown when reconcileTransit is called before TRANSIT_RECONCILE_DELAY has elapsed
error ReconcileTooEarly();

/// @notice Thrown when removeSpoke is called on a spoke that still has a nonzero reported balance
error SpokeNotDrained();

/// @notice Thrown when removeSpoke is called on a spoke with in-flight DEPOSIT legs
error SpokeHasInFlightLegs();

/// @notice Thrown when accept/rejectQuarantinedReport is called for a selector with no quarantined report
error NoQuarantinedReport();
