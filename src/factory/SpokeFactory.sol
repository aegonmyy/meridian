// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SpokeVault} from "../Spoke.sol";
import {AaveAdapter} from "../adapters/AaveAdapter.sol";

/// @notice Adapter kinds the factory can deploy. Extend this enum and _deployAdapter together to
///         support new protocols without changing createSpoke's signature.
enum AdapterKind {
    AAVE
}

/// @notice One adapter to deploy and register on the freshly created spoke
/// @param kind Which concrete adapter to deploy
/// @param protocolId Whitelist identifier the spoke registers the adapter under, e.g. keccak256("AAVE")
/// @param params ABI-encoded, kind-specific constructor arguments minus the shared USDC asset. For
///        AAVE this is abi.encode(address aavePool, address aToken).
struct AdapterSpec {
    AdapterKind kind;
    bytes32 protocolId;
    bytes params;
}

/// @title SpokeFactory
/// @notice Permissionless deployer for a tenant's spoke on one L2, a SpokeVault plus the caller's
///         chosen adapters, registered and funded in one transaction, then handed to the caller.
/// @dev Deploys the Spoke with itself as interim owner, deploys and registers each adapter, optionally
///      forwards LINK, and begins the ownership handoff to the caller. Adapters are deployed per spoke
///      because they hold funds and cannot be shared. Router, LINK, USDC, and the hub chain selector
///      are per-chain constants stored at construction. Spoke ownership is OZ Ownable (single step),
///      so its transferOwnership to msg.sender lands immediately.
contract SpokeFactory {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice CCIP router for this L2, passed to every spoke this factory deploys
    address public immutable ROUTER;

    /// @notice LINK token for this L2, used to fund deployed spokes for CCIP fees
    IERC20 public immutable LINK;

    /// @notice USDC (the spoke asset) for this L2, passed to every spoke and its adapters
    address public immutable USDC;

    /// @notice CCIP chain selector of the hub chain this L2's spokes report to
    uint64 public immutable HUB_CHAIN_SELECTOR;

    // =========================================================================
    // Registry
    // =========================================================================

    /// @notice Every spoke this factory has created, in creation order
    address[] private allSpokes;

    /// @notice Spokes created by each caller, keyed by the owner they were handed to
    mapping(address => address[]) private spokesByOwner;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a required constructor address or selector is zero
    error InvalidConstructorArguments();

    /// @notice Thrown when createSpoke is passed a zero hub address
    error InvalidHub();

    /// @notice Thrown when an AdapterSpec names a kind the factory cannot deploy
    error UnsupportedAdapterKind();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted once a spoke is deployed, its adapters registered, and it is handed to the caller
    /// @param owner Address the spoke ownership is being transferred to
    /// @param hub Hub address the spoke was pointed at
    /// @param spoke Address of the deployed SpokeVault
    /// @param chainSelector This L2's CCIP chain selector
    /// @param adapters Addresses of the adapters deployed and registered on the spoke
    event SpokeCreated(
        address indexed owner,
        address indexed hub,
        address indexed spoke,
        uint64 chainSelector,
        address[] adapters
    );

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _router CCIP router for this L2
    /// @param _link LINK token for this L2
    /// @param _usdc USDC asset for this L2
    /// @param _hubChainSelector CCIP chain selector of the hub chain
    constructor(
        address _router,
        address _link,
        address _usdc,
        uint64 _hubChainSelector
    ) {
        if (
            _router == address(0) ||
            _link == address(0) ||
            _usdc == address(0) ||
            _hubChainSelector == 0
        ) revert InvalidConstructorArguments();
        ROUTER = _router;
        LINK = IERC20(_link);
        USDC = _usdc;
        HUB_CHAIN_SELECTOR = _hubChainSelector;
    }

    // =========================================================================
    // Core Functions
    // =========================================================================

    /// @notice Deploys a spoke pointing at an existing hub, registers the caller's adapters, then
    ///         hands the spoke to the caller
    /// @dev The Spoke constructor rejects a zero hub, so hub must be an already-deployed address the
    ///      caller read from their HubCreated event. If linkAmount is nonzero the caller must have
    ///      approved this factory for that much LINK.
    /// @param hub Hub address this spoke reports to
    /// @param adapters Adapters to deploy and register on the spoke
    /// @param linkAmount LINK to pull from the caller and forward to the spoke, or zero to skip
    /// @return spoke Address of the deployed SpokeVault
    /// @return adapterAddrs Addresses of the deployed adapters, in the order of adapters
    function createSpoke(
        address hub,
        AdapterSpec[] calldata adapters,
        uint256 linkAmount
    ) external returns (address spoke, address[] memory adapterAddrs) {
        if (hub == address(0)) revert InvalidHub();

        SpokeVault deployedSpoke = new SpokeVault(
            hub,
            USDC,
            ROUTER,
            address(this),
            address(LINK),
            HUB_CHAIN_SELECTOR
        );

        adapterAddrs = new address[](adapters.length);
        for (uint256 i = 0; i < adapters.length; i++) {
            address adapter = _deployAdapter(adapters[i]);
            adapterAddrs[i] = adapter;
            deployedSpoke.setAdapter(adapters[i].protocolId, adapter);
        }

        if (linkAmount > 0) {
            LINK.safeTransferFrom(
                msg.sender,
                address(deployedSpoke),
                linkAmount
            );
        }

        deployedSpoke.transferOwnership(msg.sender);

        spoke = address(deployedSpoke);
        allSpokes.push(spoke);
        spokesByOwner[msg.sender].push(spoke);

        emit SpokeCreated(
            msg.sender,
            hub,
            spoke,
            HUB_CHAIN_SELECTOR,
            adapterAddrs
        );
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Deploys the concrete adapter for a spec. The shared USDC asset is supplied by the factory;
    ///      only the per-market addresses come from spec.params. Add a branch here when extending
    ///      AdapterKind.
    /// @param spec The adapter to deploy
    /// @return adapter Address of the deployed adapter
    function _deployAdapter(
        AdapterSpec calldata spec
    ) internal returns (address adapter) {
        if (spec.kind == AdapterKind.AAVE) {
            (address aavePool, address aToken) = abi.decode(
                spec.params,
                (address, address)
            );
            adapter = address(new AaveAdapter(aavePool, aToken, USDC));
        } else {
            revert UnsupportedAdapterKind();
        }
    }

    // =========================================================================
    // Registry Views
    // =========================================================================

    /// @notice Returns every spoke created by a given owner
    /// @param owner Address the spokes were handed to at creation
    /// @return List of spoke addresses, in creation order
    function getSpokesByOwner(
        address owner
    ) external view returns (address[] memory) {
        return spokesByOwner[owner];
    }

    /// @notice Returns every spoke this factory has created
    /// @return List of all spoke addresses, in creation order
    function getAllSpokes() external view returns (address[] memory) {
        return allSpokes;
    }

    /// @notice Returns the number of spokes this factory has created
    function spokeCount() external view returns (uint256) {
        return allSpokes.length;
    }
}
