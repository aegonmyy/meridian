// SPD,Licens,Identifier: MIT
pragma solidity 0.8.33;

import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {AllocationMaths} from "./libraries/AllocationMaths.sol";
import {IHub} from "./interfaces/IHub.sol";

contract Rebalancer {
    IHub public immutable HUB;
    address public immutable AGENT_CONSUMER;
    address public owner;
    uint256 public lastRebalanceTimestamp;
    uint256 public constant COOLDOWN = 24 hours;
    uint256 public constant MAX_SINGLE_MOVE_BPS = 3_000;
    mapping(uint64 => bool) public whitelistedChains;
    mapping(bytes32 => bool) public whitelistedProtocols;

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        if (msg.sender != owner && msg.sender != AGENT_CONSUMER) {
            revert NotAuthorized();
        }
    }

    struct AllocationProposal {
        uint256[][] proposedAllocations;
        uint256[] proposedNetApys;
        uint256[][] currentAllocations;
        uint256[] currentNetApys;
        uint64[] chainSelectors;
        bytes32[][] protocolIds;
    }

    error InvalidConstructorArguments();
    error NotAuthorized();
    error CooldownNotElapsed();
    error BelowThreshold();
    error MaxSingleMoveExceeded();
    error ChainNotWhitelisted();
    error ProtocolNotWhitelisted();
    error InvalidAllocation();

    event RebalanceExecuted(uint256 timestamp, uint256 weightedApy);
    event ChainWhitelisted(uint64 chainSelector);
    event ChainRemovedFromWhitelist(uint64 chainSelector);
    event ProtocolWhitelisted(bytes32 protocolId);
    event ProtocolRemovedFromWhitelist(bytes32 protocolId);

    constructor(address _hub, address _agentConsumer, address _owner) {
        HUB = IHub(_hub);
        AGENT_CONSUMER = _agentConsumer;
        owner = _owner;
    }

    function proposeAllocation(
        AllocationProposal memory proposal
    ) external onlyAuthorized {
        if (block.timestamp - lastRebalanceTimestamp < COOLDOWN) {
            revert CooldownNotElapsed();
        }
        bool valid = AllocationMaths.validateAllocation(
            proposal.proposedAllocations
        );
        if (!valid) revert InvalidAllocation();
        uint256 currentWeightedApy = AllocationMaths.weightedApy(
            _flatten(proposal.currentAllocations),
            proposal.currentNetApys
        );
        uint256 optimalWeightedApy = AllocationMaths.weightedApy(
            _flatten(proposal.proposedAllocations),
            proposal.proposedNetApys
        );
        bool rebalance = AllocationMaths.shouldRebalance(
            currentWeightedApy,
            optimalWeightedApy
        );

        if (!rebalance) revert BelowThreshold();

        for (uint256 i = 0; i < proposal.chainSelectors.length; i++) {
            if (whitelistedChains[proposal.chainSelectors[i]] == false) {
                revert ChainNotWhitelisted();
            }
            for (uint256 j = 0; j < proposal.protocolIds[i].length; j++) {
                if (whitelistedProtocols[proposal.protocolIds[i][j]] == false) {
                    revert ProtocolNotWhitelisted();
                }
            }
        }
        uint256 totalAssets = HUB.totalAssets();
        if (
            !AllocationMaths.validateSingleMove(
                proposal.proposedAllocations,
                totalAssets
            )
        ) {
            revert MaxSingleMoveExceeded();
        }

        lastRebalanceTimestamp = block.timestamp;
        for (uint256 i = 0; i < proposal.protocolIds.length; i++) {
            CCIPHelpers.AdapterInstructions[]
                memory _instructions = new CCIPHelpers.AdapterInstructions[](
                    proposal.protocolIds.length
                );
            for (uint256 j = 0; i < proposal.protocolIds[i].length; j++) {
                _instructions[i] = CCIPHelpers.AdapterInstructions({
                    adapter: proposal.protocolIds[i][j],
                    amount: proposal.proposedAllocations[i][j]
                });
            }
            HUB.sendToSpoke(proposal.chainSelectors[i], _instructions);
        }
    }

    function addChainToWhitelist(
        uint64 _chainSelector
    ) external onlyAuthorized {
        whitelistedChains[_chainSelector] = true;
    }

    function removeChainFromWhitelist(
        uint64 _chainSelector
    ) external onlyAuthorized {
        whitelistedChains[_chainSelector] = false;
    }

    function addProtocolToWhitelist(
        bytes32 _protocolId
    ) external onlyAuthorized {
        whitelistedProtocols[_protocolId] = true;
    }

    function removeProtocolFromWhitelist(
        bytes32 _protocolId
    ) external onlyAuthorized {
        whitelistedProtocols[_protocolId] = false;
    }

    function _flatten(
        uint256[][] memory arr
    ) internal pure returns (uint256[] memory) {
        uint256 total;
        for (uint256 i = 0; i < arr.length; i++) {
            total += arr[i].length;
        }
        uint256[] memory flat = new uint256[](total);
        uint256 idx;
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = 0; j < arr[i].length; j++) {
                flat[idx++] = arr[i][j];
            }
        }
        return flat;
    }
}
