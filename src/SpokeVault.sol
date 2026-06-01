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

contract SpokeVault is CCIPReceiver, Ownable {
    address public immutable HUB;
    IERC20 public immutable asset;
    mapping(bytes32 => adapterInfo) public adapters;
    bytes32[] public activeAdapters;
    error ZeroAddress();
    error AdapterNotFound();
    error NotHub();
    struct adapterInfo {
        IYieldSource adapter;
        bool exists;
    }

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

    function setAdapter(
        bytes32 _protocolId,
        address _adapter
    ) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        if (adapters[_protocolId].exists) {
            adapters[_protocolId].adapter = IYieldSource(_adapter);
            return;
        }
        activeAdapters.push(_protocolId);
        adapters[_protocolId].adapter = IYieldSource(_adapter);
        adapters[_protocolId].exists = true;
    }

    function removeAdapter(bytes32 _protocolId) external onlyOwner {
        if (adapters[_protocolId].exists == false) revert AdapterNotFound();
        adapters[_protocolId].adapter = IYieldSource(address(0));
        adapters[_protocolId].exists = false;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        if (abi.decode(message.sender, (address)) != HUB) revert NotHub();
        CCIPHelpers.CCIPMessage memory _message = CCIPHelpers.decode(
            message.data
        );
    }
}
