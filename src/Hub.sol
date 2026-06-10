// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title HubVault
/// @notice ERC4626 vault on Ethereum — entry point for all user deposits and withdrawals
/// @dev Inherits ERC4626, CCIPReceiver, and Ownable. Delegates capital deployment to
///      spoke vaults on L2s via Chainlink CCIP. Share price reflects total managed assets
///      across all spokes. Only the Rebalancer can move capital between hub and spokes.

contract HUB is ERC4626, CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Tracks a queued withdrawal awaiting spoke balance confirmation or fund recall
    /// @dev idleBacked true means idle balance is reserved — false means spoke recall in flight
    struct PendingWithdrawal {
        uint256 shares;
        uint256 assets;
        uint256 requestedAt;
        address receiver;
        address owner;
        bool idleBacked;
    }

    /// @notice Stores spoke address and registration status per chain
    /// @dev exists flag is source of truth — used to skip inactive spokes during iteration
    struct SpokeInfo {
        address spoke;
        bool exists;
    }
    /// @notice LINK token address used to pay CCIP fees
    IERC20 public immutable LINK;

    /// @notice Address of the Rebalancer contract — only caller permitted to move capital
    address public immutable REBALANCER;

    /// @notice List of all registered spoke chain selectors
    /// @dev Used to iterate spokeBalances in totalManagedAssets()
    uint64[] public spokeChainSelectors;

    /// @notice Total assets reserved for pending withdrawals backed by idle balance
    /// @dev Prevents over-promising idle balance to concurrent withdrawers
    uint256 public reservedAssets;

    /// @notice Maps chain selector to spoke vault address on that chain
    mapping(uint64 => SpokeInfo) public spokes;

    ///@notice Sole purpose is to determine if a spoke is valid
    mapping(address => bool) public isValidSpoke;

    /// @notice Last reported total balance per spoke chain
    /// @dev Updated on every CONFIRM_RECEIPT and REPORT_BALANCE message from spokes
    mapping(uint64 => uint256) public spokeBalances;

    /// @notice Timestamp of last balance report received per spoke
    /// @dev Used to determine staleness before processing withdrawals
    mapping(uint64 => uint256) public lastReportTimestamp;

    /// @notice Pending withdrawal requests awaiting fresh spoke balances
    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals; //flagged

    /// @notice Maximum age of spoke balance report before considered stale
    uint256 public constant MAX_STALENESS = 1 hours;

    /// @notice USDC currently in CCIP transit — sent but not yet confirmed by spoke
    /// @dev Incremented on ccipSend, decremented on CONFIRM_RECEIPT
    uint256 public inTransitAssets;

    mapping(bytes32 => uint256) public inTransitAmount;

    /// @notice Sum of all user deposits minus withdrawals — used as principal floor
    uint256 public totalPrincipal;

    /// @notice Emitted when a withdrawal is queued pending spoke balance confirmation
    /// @param owner Address whose shares are locked
    /// @param shares Amount of shares locked
    /// @param assets Amount of assets owed
    /// @param idleBacked Whether idle balance is reserved for this withdrawal
    event WithdrawalQueued(
        address indexed owner,
        uint256 shares,
        uint256 assets,
        bool idleBacked
    );

    /// @notice Emitted when a queued withdrawal is completed
    /// @param owner Address whose shares were burned
    /// @param receiver Address that received the USDC
    /// @param assets Amount of USDC transferred
    event WithdrawalProcessed(
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        bytes32 messageId
    );
    event SpokeAdded(
        uint64 indexed spokeSelector,
        address indexed spokeAddress
    );

    /// @notice Emitted when spoke balance is updated from an incoming CCIP message
    /// @param chainSelector Chain selector of the reporting spoke
    /// @param balance Updated spoke balance
    event SpokeBalanceUpdated(uint64 indexed chainSelector, uint256 balance);

    event SpokeRemoved(uint64 indexed spokeSelector);

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

    /// @notice Restricts access to the Rebalancer contract or the hub itself
    /// @dev Hub calls recallFromSpoke internally for user withdrawal path
    modifier onlyRebalancer() {
        _onlyRebalancer();
        _;
    }

    function _onlyRebalancer() internal view {
        if (msg.sender != REBALANCER && msg.sender != address(this)) {
            revert NotRebalancer();
        }
    }

    /// @notice Deploys HubVault with immutable configuration
    /// @dev Parent constructors execute before zero address checks —
    ///      CCIPReceiver validates _router internally.
    /// @param _name ERC20 share token name
    /// @param _symbol ERC20 share token symbol
    /// @param _router Chainlink CCIP router address on Ethereum
    /// @param _owner Contract owner address — should be a multisig before mainnet
    /// @param _link LINK token address for CCIP fee payments
    /// @param _asset USDC token address
    /// @param _rebalancer Rebalancer contract address
    constructor(
        string memory _name,
        string memory _symbol,
        address _router,
        address _owner,
        address _link,
        address _asset,
        address _rebalancer
    )
        ERC4626(IERC20(_asset))
        Ownable(_owner)
        ERC20(_name, _symbol)
        CCIPReceiver(_router)
    {
        if (
            _router == address(0) ||
            _owner == address(0) ||
            _link == address(0) ||
            _asset == address(0) ||
            _rebalancer == address(0)
        ) revert InvalidConstructorArguments();
        LINK = IERC20(_link);
        REBALANCER = _rebalancer;
    }

    /// @notice Registers a new spoke or updates an existing spoke address
    /// @dev If spoke already exists, updates address without pushing to array again.
    /// @param _chainSelector CCIP chain selector for the spoke chain
    /// @param _spokeAddress Address of the SpokeVault on that chain
    function addSpoke(
        uint64 _chainSelector,
        address _spokeAddress
    ) external onlyOwner {
        if (_spokeAddress == address(0)) revert ZeroAddress();
        if (spokes[_chainSelector].exists) {
            spokes[_chainSelector].spoke = _spokeAddress;
            emit SpokeAdded(_chainSelector, _spokeAddress);
            return;
        }
        isValidSpoke[_spokeAddress] = true;
        spokes[_chainSelector].spoke = _spokeAddress;
        spokes[_chainSelector].exists = true;
        spokeChainSelectors.push(_chainSelector);
        emit SpokeAdded(_chainSelector, _spokeAddress);
    }

    /// @notice Disables a spoke by flipping its exists flag to false
    /// @dev Does not remove from spokeChainSelectors array — inactive entries
    ///      skipped during iteration via exists flag. Emergency mechanism.
    /// @param _chainSelector CCIP chain selector of the spoke to disable
    function removeSpoke(uint64 _chainSelector) external onlyOwner {
        if (spokes[_chainSelector].exists == false) revert SpokeNotFound();
        isValidSpoke[spokes[_chainSelector].spoke] = false;
        spokes[_chainSelector].exists = false;
        emit SpokeRemoved(_chainSelector);
    }

    /// @notice Sends USDC and deposit instructions to a spoke via CCIP
    /// @dev Only callable by Rebalancer. Builds DEPOSIT message and delegates to _sendToSpoke.
    /// @param _chainSelector CCIP chain selector of the destination spoke
    /// @param _instructions Array of adapter instructions — adapter id and amount per market
    function sendToSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) revert SpokeNotFound();
        bytes32 _messageId;
        uint256 _amount = _instructions[0].amount;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, _amount)
            mstore(add(ptr, 0x20), timestamp())
            _messageId := keccak256(ptr, 0x40)
            mstore(0x40, add(ptr, 0x40))
        }
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.DEPOSIT,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    /// @notice Sends withdrawal instructions to a spoke via CCIP
    /// @dev Only callable by Rebalancer or hub internally. Uses WITHDRAW_AMOUNT — spoke decides which adapters to pull from.
    /// @param _chainSelector CCIP chain selector of the target spoke
    /// @param _instructions Array with single entry — adapter bytes32(0), amount to recall
    function recallFromSpoke(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions,
        bytes32 _messageId
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) {
            revert SpokeNotFound();
        }
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.WITHDRAW_AMOUNT,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    function rebalance(
        uint64 _chainSelector,
        CCIPHelpers.AdapterInstructions[] memory _instructions,
        bytes32 _messageId
    ) external onlyRebalancer {
        if (!spokes[_chainSelector].exists) {
            revert SpokeNotFound();
        }
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
            messageType: CCIPHelpers.MessageType.REBALANCE,
            instructions: _instructions,
            spokeBalance: 0,
            reportTimestamp: block.timestamp,
            messageId: _messageId
        });
        _sendToSpoke(_chainSelector, _message);
    }

    /// @notice Overrides ERC4626._deposit to track total principal
    /// @dev Increments totalPrincipal before calling super — principal always
    ///      reflects real deposited capital regardless of yield accrual.
    /// @param caller Address initiating the deposit
    /// @param receiver Address receiving the shares
    /// @param assets Amount of USDC being deposited
    /// @param shares Amount of shares being minted
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        totalPrincipal += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /// @notice Overrides ERC4626._withdraw to implement async two-path withdrawal
    /// @dev No super call — full flow owned here. Shares only burned when funds confirmed.
    ///      Path 1: idle covers + fresh → synchronous, standard ERC4626 behaviour
    ///      Path 2: idle covers + stale → queue, trigger REPORT_BALANCE
    ///      Path 3: idle insufficient → queue, recall from spoke
    /// @param caller Address initiating the withdrawal
    /// @param receiver Address receiving the assets
    /// @param owner Address whose shares are being burned
    /// @param assets Amount of USDC to send
    /// @param shares Amount of shares to burn
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _transfer(owner, address(this), shares);
        assets = previewRedeem(shares);
        uint256 idle = _idleBalance() - reservedAssets;
        bytes32 _messageId;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, receiver)
            mstore(add(ptr, 0x20), timestamp())
            _messageId := keccak256(ptr, 0x40)
            mstore(0x40, add(ptr, 0x40))
        }
        if (idle >= assets) {
            reservedAssets += assets;
            if (_allSpokesFresh()) {
                _processWithdrawal(
                    owner,
                    receiver,
                    shares,
                    assets,
                    true,
                    _messageId
                );
            } else {
                pendingWithdrawals[_messageId] = PendingWithdrawal({
                    owner: owner,
                    shares: shares,
                    assets: assets,
                    requestedAt: block.timestamp,
                    receiver: receiver,
                    idleBacked: true
                });
                _requestAllBalanceReports(_messageId);
                emit WithdrawalQueued(owner, shares, assets, true);
            }
        } else {
            pendingWithdrawals[_messageId] = PendingWithdrawal({
                owner: owner,
                shares: shares,
                assets: assets,
                requestedAt: block.timestamp,
                receiver: receiver,
                idleBacked: false
            });
            uint64 _chainSelector = _findBestSpoke();
            CCIPHelpers.AdapterInstructions[]
                memory _instructions = new CCIPHelpers.AdapterInstructions[](1);
            _instructions[0] = CCIPHelpers.AdapterInstructions({
                adapter: bytes32(0),
                amount: assets,
                targetAdapter: bytes32(0),
                targetAmount: 0
            });
            this.recallFromSpoke(_chainSelector, _instructions, _messageId);
            emit WithdrawalQueued(owner, shares, assets, false);
        }
    }

    /// @notice Executes immediate settlement of a withdrawal
    /// @dev Burns shares held by contract, transfers assets to receiver, updates accounting.
    ///      Called on Path 1 (synchronous) and from _ccipReceive when pending withdrawal completes.
    /// @param owner Address whose shares are burned
    /// @param receiver Address receiving the USDC
    /// @param shares Amount of shares to burn
    /// @param assets Amount of USDC to transfer
    function _processWithdrawal(
        address owner,
        address receiver,
        uint256 shares,
        uint256 assets,
        bool idleBacked,
        bytes32 _messageId
    ) internal {
        totalPrincipal -= assets;
        if (idleBacked) {
            reservedAssets -= assets;
        }
        _burn(address(this), shares);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit WithdrawalProcessed(owner, receiver, assets, _messageId);
    }

    /// @notice Sends REPORT_BALANCE messages to all active spokes
    /// @dev Called when withdrawal is queued and balances are stale (Path 2).
    ///      Balance updates arrive asynchronously via _ccipReceive.
    function _requestAllBalanceReports(bytes32 _messageId) internal {
        uint64[] memory selectors = spokeChainSelectors;

        for (uint256 i = 0; i < selectors.length; i++) {
            if (!spokes[selectors[i]].exists) continue;
            CCIPHelpers.AdapterInstructions[]
                memory _instructions = new CCIPHelpers.AdapterInstructions[](0);
            CCIPHelpers.CcipMessage memory _message = CCIPHelpers.CcipMessage({
                messageType: CCIPHelpers.MessageType.REPORT_BALANCE,
                instructions: _instructions,
                spokeBalance: 0,
                reportTimestamp: block.timestamp,
                messageId: _messageId
            });
            _sendToSpoke(selectors[i], _message);
        }
    }

    /// @notice Returns the chain selector of the spoke with the highest reported balance
    /// @dev Used to determine which spoke to recall from for user withdrawals.
    ///      Relies on spokeBalances which may be slightly stale — safe since balances only grow.
    /// @return bestSelector Chain selector of the spoke with highest balance
    function _findBestSpoke() internal view returns (uint64) {
        uint64[] memory selectors = spokeChainSelectors;
        uint64 bestSelector;
        uint256 bestBalance;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (spokes[selectors[i]].exists == false) continue;
            if (spokeBalances[selectors[i]] > bestBalance) {
                bestBalance = spokeBalances[selectors[i]];
                bestSelector = selectors[i];
            }
        }
        return bestSelector;
    }

    /// @notice Builds and sends a CCIP message to a spoke
    /// @dev Handles both pure instruction messages and programmable token transfers.
    ///      If total instruction amount > 0, attaches USDC as tokenAmounts and increments inTransitAssets.
    ///      Fees paid in LINK — contract must hold sufficient LINK balance.
    /// @param _chainSelector Destination chain selector
    /// @param _message Encoded CcipMessage containing type, instructions, and spoke balance
    function _sendToSpoke(
        uint64 _chainSelector,
        CCIPHelpers.CcipMessage memory _message
    ) internal {
        uint256 size;
        uint256 totalAmount;
        for (uint256 i = 0; i < _message.instructions.length; i++) {
            totalAmount += _message.instructions[i].amount;
        }
        if (totalAmount > 0) {
            size = 1;
        }
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](size);
        if (size == 1) {
            tokenAmount[0] = Client.EVMTokenAmount({
                token: address(asset()),
                amount: totalAmount
            });
        }
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(spokes[_chainSelector].spoke),
            data: CCIPHelpers.encode(_message),
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
        uint256 fee = router.getFee(_chainSelector, ccipMessage);
        if (totalAmount > 0) {
            inTransitAssets += totalAmount;
            inTransitAmount[_message.messageId] = totalAmount;
            IERC20(asset()).forceApprove(address(router), totalAmount);
        }

        LINK.forceApprove(address(router), fee);
        router.ccipSend(_chainSelector, ccipMessage);
    }

    /// @notice Returns total assets per ERC4626 standard — delegates to totalManagedAssets
    /// @dev Overrides ERC4626.totalAssets(). Share price reflects real yield-inclusive value.
    function totalAssets() public view override returns (uint256) {
        return totalManagedAssets();
    }

    /// @notice Returns the real total value managed by the protocol across all chains
    /// @dev Sums idle USDC on hub + last reported spoke balances + in-transit assets.
    ///      Spoke balances may be stale by up to MAX_STALENESS — refreshed on every
    ///      CONFIRM_RECEIPT and REPORT_BALANCE message.
    ///      Returns _idleBalance() only if no spokes registered — inTransitAssets
    ///      will always be zero in that state, saving one SLOAD.
    /// @return total The total managed assets in USDC
    function totalManagedAssets() internal view returns (uint256 total) {
        uint64[] memory selectors = spokeChainSelectors;
        uint256 idle = _idleBalance();
        if (selectors.length == 0) return idle;
        total += idle + inTransitAssets;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (spokes[selectors[i]].exists == false) continue;
            total += spokeBalances[selectors[i]];
        }
        return total;
    }

    /// @notice Handles incoming CCIP messages from registered spokes
    /// @dev Validates message origin — only registered spoke addresses accepted.
    ///      Routes CONFIRM_RECEIPT and REPORT_BALANCE to their respective handlers.
    /// @param message Incoming CCIP message struct delivered by the router
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        if (!isValidSpoke[abi.decode(message.sender, (address))]) {
            revert NotSpoke();
        }
        CCIPHelpers.CcipMessage memory _message = CCIPHelpers.decode(
            message.data
        );
        uint64 _chainSelector = message.sourceChainSelector;
        uint256 _amountArrived = _message.instructions[0].amount;
        if (
            _message.messageType == CCIPHelpers.MessageType.CONFIRM_WITHDRAWAL
        ) {
            _handleWithdrawalCallback(_message, _chainSelector, _amountArrived);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.REPORT_BALANCE
        ) {
            _handleReportBalanceCallback(_message, _chainSelector);
        } else if (
            _message.messageType == CCIPHelpers.MessageType.CONFIRM_RECEIPT
        ) {
            _handleDepositCallback(_message, _chainSelector);
        } else {
            revert InvalidMessageType();
        }
    }

    /// @notice Returns the USDC balance currently sitting idle on the hub
    /// @dev Does not include in-transit or spoke-deployed capital
    /// @return USDC balance of this contract

    function _idleBalance() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Checks if all active spoke balance reports are within MAX_STALENESS
    /// @dev Returns false if no spokes registered — safe default, nothing should progress
    /// @return bool True if all spoke reports are fresh enough to trust
    function _allSpokesFresh() internal view returns (bool) {
        uint64[] memory selectors = spokeChainSelectors;
        if (selectors.length == 0) return false;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (spokes[selectors[i]].exists == false) continue;
            if (
                block.timestamp - lastReportTimestamp[selectors[i]] >
                MAX_STALENESS
            ) {
                return false;
            }
        }
        return true;
    }

    function _handleDepositCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector
    ) internal {
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        inTransitAssets -= inTransitAmount[_message.messageId];
        delete inTransitAmount[_message.messageId];
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);
    }

    function _handleReportBalanceCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector
    ) internal {
        bytes32 _messageId = _message.messageId;
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);
        if (pendingWithdrawals[_messageId].shares > 0) {
            _processWithdrawal(
                pendingWithdrawals[_messageId].owner,
                pendingWithdrawals[_messageId].receiver,
                pendingWithdrawals[_messageId].shares,
                pendingWithdrawals[_messageId].assets,
                pendingWithdrawals[_messageId].idleBacked,
                _messageId
            );
            delete pendingWithdrawals[_messageId];
        }
    }

    function _handleWithdrawalCallback(
        CCIPHelpers.CcipMessage memory _message,
        uint64 _chainSelector,
        uint256 _amountArrived
    ) internal {
        bytes32 _messageId = _message.messageId;
        spokeBalances[_chainSelector] = _message.spokeBalance;
        lastReportTimestamp[_chainSelector] = _message.reportTimestamp;
        emit SpokeBalanceUpdated(_chainSelector, _message.spokeBalance);
        totalPrincipal += _amountArrived;
        if (pendingWithdrawals[_messageId].shares > 0) {
            _processWithdrawal(
                pendingWithdrawals[_messageId].owner,
                pendingWithdrawals[_messageId].receiver,
                pendingWithdrawals[_messageId].shares,
                pendingWithdrawals[_messageId].assets,
                pendingWithdrawals[_messageId].idleBacked,
                _messageId
            );
            delete pendingWithdrawals[_messageId];
        }
    }
}
