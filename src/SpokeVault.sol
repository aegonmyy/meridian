// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {CCIPReceiver} from "@chainlink/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";

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
    /// @dev exists flag differentiates unregistered vs removed adapters
    ///      and gates iteration in _reportBalance
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
    IERC20 public immutable ASSET;

    /// @notice CCIP chain selector for the hub chain (Ethereum mainnet)
    /// @dev Used as destination selector when sending messages back to the hub
    uint64 public immutable HUB_CHAIN_SELECTOR;

    /// @notice LINK token used to pay CCIP fees
    /// @dev Spoke must hold sufficient LINK balance for outbound messages
    IERC20 public immutable LINK;

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
    error invalidConstructorArguments();

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
    /// @param _link Address of the LINK token on this chain
    /// @param _hubSelector Chainlink CCIP chain selector for Ethereum mainnet
    constructor(
        address _hub,
        address _asset,
        address _router,
        address _owner,
        address _link,
        uint64 _hubSelector
    ) CCIPReceiver(_router) Ownable(_owner) {
        if (
            _hub == address(0) ||
            _asset == address(0) ||
            _router == address(0) ||
            _link == address(0) ||
            _hubSelector == 0
        ) revert invalidConstructorArguments();
        HUB = _hub;
        ASSET = IERC20(_asset);
        HUB_CHAIN_SELECTOR = _hubSelector;
        LINK = IERC20(_link);
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
    ///      Emergency mechanism — use to instantly disable a compromised protocol.
    ///      No timelock in v1. Production deployments should use a multisig owner.
    /// @param _protocolId The bytes32 identifier of the protocol to disable
    function removeAdapter(bytes32 _protocolId) external onlyOwner {
        if (!adapters[_protocolId].exists) revert AdapterNotFound();
        adapters[_protocolId].adapter = IYieldSource(address(0));
        adapters[_protocolId].exists = false;
        emit AdapterRemoved(_protocolId);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /// @notice Entry point for all incoming CCIP messages from the HubVault
    /// @dev Overrides CCIPReceiver._ccipReceive. Router check handled by base contract.
    ///      Hub origin check enforced here by decoding message.sender.
    ///      Decodes the custom payload via CCIPHelpers and routes to the correct handler.
    /// @param message The incoming CCIP message struct delivered by the router
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        if (abi.decode(message.sender, (address)) != HUB) revert NotHub();
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.decode(
            message.data
        );

        if (_message.messageType == CCIPHelpers.MessageType.DEPOSIT) {
            _handleDeposit(_message);
        } else if (_message.messageType == CCIPHelpers.MessageType.WITHDRAW) {
            _handleWithdrawal(_message);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.REPORT_BALANCE
        ) {
            _reportBalance();
        } else {
            revert InvalidMessageType();
        }
    }

    /// @notice Deposits received USDC into the specified yield adapter
    /// @dev Validates adapter is active and amount is non-zero before depositing.
    ///      Uses forceApprove to handle tokens like USDT that revert on non-zero allowance.
    ///      Allocation validation (bps constraints) is upstream in the Rebalancer —
    ///      by the time this message arrives the allocation has already been validated on-chain.
    /// @param _message The decoded CCIP message containing adapter id and amount
    function _handleDeposit(CCIPHelpers.CcipMessage memory _message) internal {
        uint256 _tokenAmount;
        if (_message.instructions.length == 0) revert InvalidMessageType();
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            if (_message.instructions[i].amount == 0)
                revert AmountCannotBeZero();
            AdapterInfo memory _adapter = adapters[
                _message.instructions[i].adapter
            ];
            if (!_adapter.exists) revert AdapterNotFound();
            ASSET.forceApprove(
                address(_adapter.adapter),
                _message.instructions[i].amount
            );
            _adapter.adapter.deposit(_message.instructions[i].amount);
        }
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](1);

        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: _tokenAmount
        });
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.CONFIRM_RECEIPT,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance()
                })
            ),
            tokenAmounts: tokenAmount,
            feeToken: address(LINK),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: 200_000,
                    allowOutOfOrderExecution: false
                })
            )
        });
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(HUB_CHAIN_SELECTOR, ccipMessage);
        LINK.forceApprove(address(router), fee);
        router.ccipSend(HUB_CHAIN_SELECTOR, ccipMessage);
    }

    /// @notice Withdraws USDC from the specified adapter and sends funds back to the hub via CCIP
    /// @dev Withdraws from adapter, builds a PTT (Programmable Token Transfer) back to hub.
    ///      Sends CONFIRM_RECEIPT message alongside the USDC so hub can decrement inTransitAssets.
    ///      LINK balance must be sufficient to cover the CCIP fee.
    /// @param _message The decoded CCIP message containing adapter id and amount
    function _handleWithdrawal(
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        uint256 _tokenAmount;
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            if (_message.instructions[i].amount == 0)
                revert AmountCannotBeZero();
            AdapterInfo memory _adapter = adapters[
                _message.instructions[i].adapter
            ];
            if (!_adapter.exists) revert AdapterNotFound();
            _tokenAmount += _message.instructions[i].amount;
            _adapter.adapter.withdraw(_message.instructions[i].amount);
        }
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](1);
        tokenAmount[0] = Client.EVMTokenAmount({
            token: address(ASSET),
            amount: _tokenAmount
        });
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: _tokenAmount
        });
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.CONFIRM_RECEIPT,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance()
                })
            ),
            tokenAmounts: tokenAmount,
            feeToken: address(LINK),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: 200_000,
                    allowOutOfOrderExecution: false
                })
            )
        });
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(HUB_CHAIN_SELECTOR, ccipMessage);
        ASSET.forceApprove(address(router), _tokenAmount);
        LINK.forceApprove(address(router), fee);
        router.ccipSend(HUB_CHAIN_SELECTOR, ccipMessage);
    }

    /// @notice Sums balances across all active adapters and reports total to the hub via CCIP
    /// @dev Iterates activeAdapters array, skipping entries, sums totalAssets() from each adapter.
    ///      Sends results back to hub as a REPORT_BALANCE message.
    ///      LINK balance must be sufficient to cover the ccip fee.
    function _reportBalance() internal {
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](0);
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: 0
        });
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.REPORT_BALANCE,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance()
                })
            ),
            tokenAmounts: tokenAmount,
            feeToken: address(LINK),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: 200_000,
                    allowOutOfOrderExecution: false
                })
            )
        });
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(HUB_CHAIN_SELECTOR, ccipMessage);
        LINK.forceApprove(address(router), fee);
        router.ccipSend(HUB_CHAIN_SELECTOR, ccipMessage);
    }

    function _aggregatedSpokeBalance() internal view returns (uint256) {
        bytes32[] memory _activeAdapters = activeAdapters;
        uint256 _length = _activeAdapters.length;
        if (_length == 0) revert NoActiveAdapters();
        uint256 aggregatedSpokeBalance;
        for (uint256 i = 0; i < _length; i++) {
            if (adapters[_activeAdapters[i]].exists == false) continue;
            aggregatedSpokeBalance += adapters[_activeAdapters[i]]
                .adapter
                .totalAssets();
        }
        return aggregatedSpokeBalance;
    }
}
