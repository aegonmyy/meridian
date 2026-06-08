// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {FunctionsClient} from "@chainlink/functions/v1_3_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/functions/dev/v1_X/libraries/FunctionsRequest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AllocationProposal, IRebalancer} from "./interfaces/IRebalancer.sol";

contract AgentConsumer is FunctionsClient, Ownable {
    IRebalancer public immutable REBALANCER;
    bytes32 public donId;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    string public sourceCodeCid;
    bytes32 public lastRequestId;

    event Error(bytes error);
    error NotValidRequestId(bytes32 requestId);

    constructor(
        address _owner,
        address _rebalancer,
        address _router,
        uint32 _gasLimit,
        uint64 _subscriptionId,
        bytes32 _donId,
        string memory _sourceCodeUrl
    ) Ownable(_owner) FunctionsClient(_router) {
        REBALANCER = IRebalancer(_rebalancer);
        callbackGasLimit = _gasLimit;
        subscriptionId = _subscriptionId;
        donId = _donId;
        sourceCodeCid = _sourceCodeUrl;
    }

    function requestRebalance() external {
        FunctionsRequest.Request memory req;
        FunctionsRequest._initializeRequest(
            req, FunctionsRequest.Location.Remote, FunctionsRequest.CodeLanguage.JavaScript, sourceCodeCid
        );
        lastRequestId = _sendRequest(FunctionsRequest._encodeCBOR(req), subscriptionId, callbackGasLimit, donId);
    }

    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (requestId != lastRequestId) revert NotValidRequestId(requestId);
        if (err.length > 0) {
            emit Error(err);
        }
        AllocationProposal memory proposal = abi.decode(response, (AllocationProposal));
        REBALANCER.proposeAllocation(proposal);
    }

    function updateSourceCode(string memory _newSource) external onlyOwner {
        sourceCodeCid = _newSource;
    }
}
