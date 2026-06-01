// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {CCIPReceiver} from "@chainlink/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SpokeVault
/// @notice Receives CCIP messages from the hub and manages capital deployment into yield protocols
/// @dev Deployed on each L2 spoke chain (Arbitrum, Base, Optimism).
///      Only the HubVault on Ethereum can send instructions to this contract via CCIP.
///      Users never interact with this contract directly.
contract SpokeVault is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Stores adapter contract and registration status for a protocol
    /// @dev exists flag is used to differentiate unregistered vs removed adapters
    ///      and to skip inactive entries when iterating activeAdapters
    struct AdapterInfo {
        IYieldSource adapter;
        bool exists;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Address of the HubVault on Ethereum
    /// @dev Immutable — set once at deployment. All CCIP messages must originate from this address.
    address public immutable HUB;

    /// @notice The asset managed by this vault (USDC in v1)
    /// @dev Immutable — single asset per spoke in v1. Multi-asset support deferred to v2.
    IERC20 public immutable asset;

    /// @notice Maps protocol identifiers to their adapter info
    /// @dev Key is an arbitrary bytes32 agreed upon at deployment e.g. keccak256("AAVE").
    ///      Use setAdapter to register, removeAdapter to disable.
    mapping(bytes32 => AdapterInfo) public adapters;

    /// @notice List of all registered protocol identifiers, including removed ones
    /// @dev Not pruned on removal — use adapters[id].exists to check active status.
    ///      Kept small by design (3–5 protocols max per spoke).
    bytes32[] public activeAdapters;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new adapter is registered or an existing one is updated
    /// @param protocolId The bytes32 identifier for the protocol
    /// @param adapter The address of the adapter contract
    event AdapterSet(bytes32 indexed protocolId, address indexed adapter);

    /// @notice Emitted when an adapter is disabled
    /// @param protocolId The bytes32 identifier for the protocol
    event AdapterRemoved(bytes32 indexed protocolId);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when a CCIP message originates from an address other than the hub
    error NotHub();

    ///@notice Thrown when unexpected message is gotten
    error unknownMessage();

    /// @notice Thrown when attempting to remove an adapter that is not registered
    error AdapterNotFound();

    /// @notice Thrown when a CCIP message contains an unrecognised message type
    error InvalidMessageType();

    ///@notice Thrown when amount is zero
    error amountCannotBeZero();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys the SpokeVault and sets immutable configuration
    /// @dev _router is passed to CCIPReceiver which validates it internally.
    ///      Parent constructor executes before the zero address checks below —
    ///      we rely on CCIPReceiver to validate _router itself.
    /// @param _hub Address of the HubVault on Ethereum
    /// @param _asset Address of the ERC20 asset (USDC)
    /// @param _router Address of the Chainlink CCIP router on this chain
    /// @param _owner Address of the contract owner (should be a multisig before mainnet)
    constructor(
        address _hub,
        address _asset,
        address _router,
        address _owner
    ) CCIPReceiver(_router) Ownable(_owner) {
        if (_hub == address(0) || _asset == address(0) || _router == address(0))
            revert ZeroAddress();
        HUB = _hub;
        asset = IERC20(_asset);
    }

    // =========================================================================
    // External Functions
    // =========================================================================

    /// @notice Registers a new adapter or updates an existing one for a protocol
    /// @dev If the protocol already exists, only the adapter address is updated —
    ///      the protocolId is not pushed to activeAdapters again (no duplicates).
    ///      If registering for the first time, protocolId is added to activeAdapters.
    /// @param _protocolId Arbitrary bytes32 identifier for the protocol
    /// @param _adapter Address of the IYieldSource adapter contract
    function setAdapter(
        bytes32 _protocolId,
        address _adapter
    ) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        if (adapters[_protocolId].exists) {
            adapters[_protocolId].adapter = IYieldSource(_adapter);
            emit AdapterSet(_protocolId, _adapter);
            return;
        }
        activeAdapters.push(_protocolId);
        adapters[_protocolId].adapter = IYieldSource(_adapter);
        adapters[_protocolId].exists = true;
        emit AdapterSet(_protocolId, _adapter);
    }

    /// @notice Disables an adapter by flipping its exists flag to false
    /// @dev Does not remove the protocolId from activeAdapters array.
    ///      Inactive entries are skipped during iteration using the exists flag.
    ///      This is an emergency mechanism — use to disable a compromised protocol.
    /// @param _protocolId The bytes32 identifier of the protocol to remove
    function removeAdapter(bytes32 _protocolId) external onlyOwner {
        if (!adapters[_protocolId].exists) revert AdapterNotFound();
        adapters[_protocolId].adapter = IYieldSource(address(0));
        adapters[_protocolId].exists = false;
        emit AdapterRemoved(_protocolId);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Handles incoming CCIP messages from the HubVault
    /// @dev Overrides CCIPReceiver._ccipReceive. Router check is handled by base contract.
    ///      Hub check is enforced here by decoding message.sender.
    ///      Routes to deposit, withdraw, or report balance based on message type.
    /// @param message The incoming CCIP message struct
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        if (abi.decode(message.sender, (address)) != HUB) revert NotHub();
        CCIPHelpers.CCIPMessage memory _message = CCIPHelpers.decode(
            message.data
        );

        if (_message.messageType == CCIPHelpers.MessageType.DEPOSIT) {
            _handleDeposit(_message);
        } else if (_message.messageType == CCIPHelpers.MessageType.WITHDRAW) {
            _handleWithdrawal(_message);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.REPORT_BALANCE
        ) {
            _reportBalance(_message);
        } else {
            revert unknownMessage();
        }
    }

    function _handleDeposit(CCIPHelpers.CCIPMessage memory _message) internal {
        AdapterInfo memory _adapter = adapters[_message.adapter];
        if (_adapter.exists == false) revert AdapterNotFound();
        if (_message.amount == 0) revert amountCannotBeZero();
        asset.approve((address(_adapter.adapter)), _message.amount);
        (_adapter.adapter).deposit(_message.amount);
    }

    function _handleWithdrawal(
        CCIPHelpers.CCIPMessage memory _message
    ) internal {}

    function _reportBalance(CCIPHelpers.CCIPMessage memory _message) internal {}
}
