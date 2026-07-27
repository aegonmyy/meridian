// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HUB} from "../Hub.sol";
import {Rebalancer} from "../Rebalancer.sol";

/// @title HubFactory
/// @notice Permissionless deployer for a tenant's hub-chain pair, a HubVault and its Rebalancer,
///         wired and funded in one transaction, then handed to the caller.
/// @dev Deploys the Hub with itself as interim owner, deploys the Rebalancer with no AgentConsumer
///      (owner-operated, relies on the optional AGENT_CONSUMER in Rebalancer), sets the rebalancer
///      on the hub, wires the caller's chain and protocol whitelists, optionally forwards LINK, and
///      begins the ownership handoff of both contracts to the caller. The factory retains no
///      authority once createHub returns. Router, LINK, and USDC are per-chain constants stored at
///      construction so callers do not pass them.
///      Hub ownership is OZ Ownable (single step), so its transferOwnership lands immediately on the
///      caller. Rebalancer ownership is OZ Ownable2Step, so the caller completes it with
///      acceptOwnership. Both target msg.sender, so neither can be handed to an address that cannot act.
contract HubFactory {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice CCIP router for the hub chain, passed to every hub this factory deploys
    address public immutable ROUTER;

    /// @notice LINK token for the hub chain, used to fund deployed hubs for CCIP fees
    IERC20 public immutable LINK;

    /// @notice USDC (the ERC4626 asset) for the hub chain, passed to every hub this factory deploys
    address public immutable USDC;

    // =========================================================================
    // Registry
    // =========================================================================

    /// @notice Every hub this factory has created, in creation order
    address[] private allHubs;

    /// @notice Hubs created by each caller, keyed by the owner they were handed to
    mapping(address => address[]) private hubsByOwner;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a required constructor address is zero
    error InvalidConstructorArguments();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted once a hub-chain pair is deployed, wired, and handed to the caller
    /// @param owner Address the hub and rebalancer ownership is being transferred to
    /// @param hub Address of the deployed HubVault
    /// @param rebalancer Address of the deployed Rebalancer
    /// @param chainSelectors Chain selectors whitelisted on the rebalancer at creation
    /// @param protocolIds Protocol identifiers whitelisted on the rebalancer at creation
    /// @param timestamp Block timestamp of creation
    event HubCreated(
        address indexed owner,
        address indexed hub,
        address indexed rebalancer,
        uint64[] chainSelectors,
        bytes32[] protocolIds,
        uint256 timestamp
    );

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _router CCIP router for the hub chain
    /// @param _link LINK token for the hub chain
    /// @param _usdc USDC asset for the hub chain
    constructor(address _router, address _link, address _usdc) {
        if (
            _router == address(0) ||
            _link == address(0) ||
            _usdc == address(0)
        ) revert InvalidConstructorArguments();
        ROUTER = _router;
        LINK = IERC20(_link);
        USDC = _usdc;
    }

    // =========================================================================
    // Core Functions
    // =========================================================================

    /// @notice Deploys and wires a hub-chain pair, then hands it to the caller
    /// @dev Steps: deploy hub (owner = factory, rebalancer = zero), deploy rebalancer
    ///      (agentConsumer = zero), setRebalancer, wire whitelists, forward LINK, transfer ownership.
    ///      If linkAmount is nonzero the caller must have approved this factory for that much LINK.
    /// @param name ERC20 share-token name for the hub
    /// @param symbol ERC20 share-token symbol for the hub
    /// @param chainSelectors CCIP chain selectors to whitelist on the rebalancer
    /// @param protocolIds Protocol identifiers to whitelist on the rebalancer
    /// @param linkAmount LINK to pull from the caller and forward to the hub, or zero to skip
    /// @return hub Address of the deployed HubVault
    /// @return rebalancer Address of the deployed Rebalancer
    function createHub(
        string memory name,
        string memory symbol,
        uint64[] calldata chainSelectors,
        bytes32[] calldata protocolIds,
        uint256 linkAmount
    ) external returns (address hub, address rebalancer) {
        HUB deployedHub = new HUB(
            name,
            symbol,
            ROUTER,
            address(this),
            address(LINK),
            USDC,
            address(0)
        );
        Rebalancer deployedRebalancer = new Rebalancer(
            address(deployedHub),
            address(0),
            address(this)
        );

        deployedHub.setRebalancer(address(deployedRebalancer));

        for (uint256 i = 0; i < chainSelectors.length; i++) {
            deployedRebalancer.addChainToWhitelist(chainSelectors[i]);
        }
        for (uint256 i = 0; i < protocolIds.length; i++) {
            deployedRebalancer.addProtocolToWhitelist(protocolIds[i]);
        }

        if (linkAmount > 0) {
            LINK.safeTransferFrom(msg.sender, address(deployedHub), linkAmount);
        }

        deployedHub.transferOwnership(msg.sender);
        deployedRebalancer.transferOwnership(msg.sender);

        hub = address(deployedHub);
        rebalancer = address(deployedRebalancer);
        allHubs.push(hub);
        hubsByOwner[msg.sender].push(hub);

        emit HubCreated(
            msg.sender,
            hub,
            rebalancer,
            chainSelectors,
            protocolIds,
            block.timestamp
        );
    }

    // =========================================================================
    // Registry Views
    // =========================================================================

    /// @notice Returns every hub created by a given owner
    /// @param owner Address the hubs were handed to at creation
    /// @return List of hub addresses, in creation order
    function getHubsByOwner(
        address owner
    ) external view returns (address[] memory) {
        return hubsByOwner[owner];
    }

    /// @notice Returns every hub this factory has created
    /// @return List of all hub addresses, in creation order
    function getAllHubs() external view returns (address[] memory) {
        return allHubs;
    }

    /// @notice Returns the number of hubs this factory has created
    function hubCount() external view returns (uint256) {
        return allHubs.length;
    }
}
