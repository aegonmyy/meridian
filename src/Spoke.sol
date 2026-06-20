// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {CCIPReceiver} from "@chainlink+/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink+/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink+/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {ZeroAddress, NotHub, AdapterNotFound, InvalidMessageType, AmountCannotBeZero, InvalidConstructorArguments} from "./errors/spokeErrors.sol";

/// @title SpokeVault
/// @notice Receives CCIP instructions from the HubVault and manages capital deployment
///         into yield protocols (Aave, Compound, Morpho) on a single L2 chain.
/// @dev Deployed once per supported L2 chain (Arbitrum, Base, Optimism).
///      Only the HubVault on Ethereum can send instructions to this contract via CCIP —
///      all other senders are rejected. Users never interact with this contract directly.
///      Capital flow: Hub sends DEPOSIT → spoke deploys into adapters → spoke reports balance back.
///      Four inbound message types: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT.
///      Four outbound message types: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL.
contract SpokeVault is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Stores adapter contract and registration status for a yield protocol
    /// @dev `exists` differentiates unregistered (never seen) vs removed (was active, now disabled).
    ///      `everRegistered` is write-once — prevents duplicate entries in activeAdapters
    ///      when a protocol is removed then re-registered on the same protocolId.
    struct AdapterInfo {
        /// @dev The IYieldSource adapter contract for this protocol — address(0) if removed
        IYieldSource adapter;
        /// @dev True if adapter is currently active — false if disabled via removeAdapter
        bool exists;
        /// @dev True once a protocolId has been registered — never reset. Guards array deduplication.
        bool everRegistered;
    }

    /// @notice Snapshot of a single adapter's balance — returned by getAllocations()
    struct AdapterBalances {
        /// @dev The bytes32 protocol identifier (e.g. keccak256("AAVE"))
        bytes32 protocolId;
        /// @dev Current total USDC managed by this adapter including accrued yield
        uint256 balance;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Address of the HubVault on Ethereum — sole authorized CCIP message sender
    /// @dev Immutable — set once at deployment. Validated in _ccipReceive for every message.
    address public immutable HUB;

    /// @notice The ERC20 asset managed by this vault (USDC in v1)
    /// @dev Immutable — single asset per spoke in v1. Multi-asset support deferred to v2.
    IERC20 public immutable ASSET;

    /// @notice CCIP chain selector for Ethereum mainnet — destination for all outbound messages
    /// @dev Immutable — all spoke-to-hub messages use this selector regardless of operation type.
    uint64 public immutable HUB_CHAIN_SELECTOR;

    /// @notice LINK token used to pay CCIP fees for all outbound messages
    /// @dev Immutable — spoke must hold sufficient LINK balance for all response messages.
    IERC20 public immutable LINK;

    /// @notice Maps protocol identifiers to their adapter registration info
    /// @dev Key is an arbitrary bytes32 agreed upon at deployment, e.g. keccak256("AAVE").
    ///      Use setAdapter() to register or update, removeAdapter() to disable.
    mapping(bytes32 => AdapterInfo) public adapters;

    /// @notice Ordered list of all protocol identifiers ever registered, including removed ones
    /// @dev Soft-delete pattern — entries are never removed. Inactive adapters are
    ///      skipped during iteration via the `exists` flag on AdapterInfo.
    ///      Kept small by design — 3 to 5 protocols max per spoke in v1.
    bytes32[] public activeAdapters;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new adapter is registered or an existing one is updated
    /// @param protocolId The bytes32 identifier for the yield protocol
    /// @param adapter Address of the new IYieldSource adapter contract
    event AdapterSet(bytes32 indexed protocolId, address indexed adapter);

    /// @notice Emitted when an adapter is disabled via removeAdapter
    /// @param protocolId The bytes32 identifier of the disabled protocol
    event AdapterRemoved(bytes32 indexed protocolId);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploys the SpokeVault with immutable chain and protocol configuration
    /// @dev CCIPReceiver validates _router internally — no explicit check needed here.
    ///      Parent constructors run before the zero address checks in the body.
    ///      _hubSelector == 0 is rejected as it would make all outbound CCIP messages fail.
    /// @param _hub Address of the HubVault on Ethereum mainnet
    /// @param _asset Address of the ERC20 asset this vault manages (USDC)
    /// @param _router Address of the Chainlink CCIP router on this L2 chain
    /// @param _owner Address of the contract owner — should be a multisig before mainnet
    /// @param _link Address of the LINK token on this L2 chain
    /// @param _hubSelector CCIP chain selector for Ethereum mainnet
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
        ) revert InvalidConstructorArguments();
        HUB = _hub;
        ASSET = IERC20(_asset);
        HUB_CHAIN_SELECTOR = _hubSelector;
        LINK = IERC20(_link);
    }

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
    /// @param _message Decoded CCIP message containing adapter instructions with protocol ids and amounts
    function _handleDeposit(CCIPHelpers.CcipMessage memory _message) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            if (_message.instructions[i].amount == 0) {
                revert AmountCannotBeZero();
            }
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
            memory tokenAmount = new Client.EVMTokenAmount[](0);
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](0);
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.CONFIRM_RECEIPT,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance(),
                    reportTimestamp: block.timestamp,
                    messageId: _message.messageId
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

    /// @notice Handles REBALANCE — moves capital between adapters on this spoke chain
    /// @dev Intra-spoke operation — no USDC leaves this chain. Withdraws from source adapter
    ///      and deposits into target adapter for each instruction in the message.
    ///      Both source and target adapters must be registered and active.
    ///      After rebalancing, sends CONFIRM_REBALANCE back to hub carrying updated spoke balance
    ///      so hub can refresh spokeBalances[] and lastReportTimestamp[].
    ///      Note: the @dev comment in the original incorrectly described this as a withdrawal —
    ///      this handler does NOT send tokens back to hub.
    /// @param _message Decoded CCIP message with instructions specifying source adapter,
    ///                 target adapter, and amount to move for each operation
    function _handleRebalance(
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            if (_message.instructions[i].amount == 0) {
                revert AmountCannotBeZero();
            }
            AdapterInfo memory _sourceAdapter = adapters[
                _message.instructions[i].adapter
            ];
            AdapterInfo memory _targetAdapter = adapters[
                _message.instructions[i].targetAdapter
            ];
            if (
                _sourceAdapter.exists == false || _targetAdapter.exists == false
            ) revert AdapterNotFound();
            _sourceAdapter.adapter.withdraw(_message.instructions[i].amount);
            ASSET.forceApprove(
                address(_targetAdapter.adapter),
                _message.instructions[i].amount
            );
            _targetAdapter.adapter.deposit(_message.instructions[i].amount);
        }
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](0);
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: 0,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.CONFIRM_REBALANCE,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance(),
                    reportTimestamp: block.timestamp,
                    messageId: _message.messageId
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

    /// @notice Handles WITHDRAW_AMOUNT — pulls requested USDC from adapters and sends back to hub
    /// @dev Called during Path 3 hub withdrawals when hub idle is insufficient to cover a user
    ///      withdrawal. Hub sends the shortfall amount — spoke pulls proportionally from all
    ///      active adapters weighted by their current balance, then sends the USDC back to hub
    ///      via a programmable token transfer (CONFIRM_WITHDRAWAL + tokens attached).
    ///      Proportional withdrawal preserves allocation ratios across adapters.
    ///      Last adapter receives remainder to avoid dust from integer division.
    ///      Hub uses messageId in CONFIRM_WITHDRAWAL to match the pending withdrawal and settle it.
    /// @param _message Decoded CCIP message with single instruction — amount is the shortfall to recall
    function _handleWithdrawalWithAmount(
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        if (_message.instructions.length == 0) revert InvalidMessageType();
        bytes32[] memory _adapters = activeAdapters;
        if (_adapters.length == 0) revert AdapterNotFound();
        uint256 amountRequested = _message.instructions[0].amount;

        // first pass — compute total spoke balance for proportional withdrawal
        uint256 _totalSpokeBalance;
        uint256 _lastIndex;
        for (uint256 i = 0; i < _adapters.length; i++) {
            if (!adapters[_adapters[i]].exists) continue;
            _totalSpokeBalance += adapters[_adapters[i]].adapter.totalAssets();
            _lastIndex = i;
        }

        // second pass — withdraw proportionally, last adapter absorbs rounding remainder
        uint256 totalPulled;
        for (uint256 i = 0; i < _adapters.length; i++) {
            if (!adapters[_adapters[i]].exists) continue;
            uint256 pullAmount;
            if (i == _lastIndex) {
                pullAmount = amountRequested - totalPulled;
            } else {
                pullAmount =
                    (amountRequested *
                        adapters[_adapters[i]].adapter.totalAssets()) /
                    _totalSpokeBalance;
            }
            adapters[_adapters[i]].adapter.withdraw(pullAmount);
            totalPulled += pullAmount;
        }

        // send USDC + CONFIRM_WITHDRAWAL back to hub
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](1);
        tokenAmount[0] = Client.EVMTokenAmount({
            token: address(ASSET),
            amount: amountRequested
        });
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
        _instructions[0] = CCIPHelpers.AdapterInstructions({
            adapter: bytes32(0),
            amount: amountRequested,
            targetAdapter: bytes32(0),
            targetAmount: 0
        });
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.CONFIRM_WITHDRAWAL,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance(),
                    reportTimestamp: block.timestamp,
                    messageId: _message.messageId
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
        ASSET.forceApprove(address(router), amountRequested);
        LINK.forceApprove(address(router), fee);
        router.ccipSend(HUB_CHAIN_SELECTOR, ccipMessage);
    }

    /// @notice Handles REPORT_BALANCE — responds to hub's balance refresh request
    /// @dev Called during Path 2 hub withdrawals when spoke reports are stale.
    ///      Hub sends REPORT_BALANCE carrying a messageId matching the queued pending withdrawal.
    ///      Spoke responds with current aggregated balance so hub can update spokeBalances[],
    ///      refresh lastReportTimestamp[], and settle the pending withdrawal.
    ///      No tokens are moved — this is an accounting-only message.
    /// @param _message Decoded CCIP message — messageId is forwarded back to hub for withdrawal matching
    function _reportBalance(CCIPHelpers.CcipMessage memory _message) internal {
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](0);
        CCIPHelpers.AdapterInstructions[]
            memory _instructions = new CCIPHelpers.AdapterInstructions[](0);
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: CCIPHelpers.encode(
                CCIPHelpers.CcipMessage({
                    messageType: CCIPHelpers.MessageType.REPORT_BALANCE,
                    instructions: _instructions,
                    spokeBalance: _aggregatedSpokeBalance(),
                    reportTimestamp: block.timestamp,
                    messageId: _message.messageId
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

    // =========================================================================
    // Internal View Helpers
    // =========================================================================

    /// @notice Sums totalAssets() across all currently active adapters
    /// @dev Skips adapters where exists == false — removed adapters report zero balance.
    ///      Called before every outbound message to give hub an accurate spoke snapshot.
    ///      Value may lag slightly if adapters accrue yield between reports — accepted v1 tradeoff.
    /// @return aggregatedSpokeBalance Total USDC managed across all active adapters including yield
    function _aggregatedSpokeBalance()
        internal
        view
        returns (uint256 aggregatedSpokeBalance)
    {
        bytes32[] memory _activeAdapters = activeAdapters;
        uint256 _length = _activeAdapters.length;
        if (_length == 0) return 0;
        for (uint256 i = 0; i < _length; i++) {
            if (adapters[_activeAdapters[i]].exists == false) continue;
            aggregatedSpokeBalance += adapters[_activeAdapters[i]]
                .adapter
                .totalAssets();
        }
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
