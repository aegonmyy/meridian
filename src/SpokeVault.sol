// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;
import {CCIPReceiver} from "@chainlink/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouter} from "@chainlink/ccip/interfaces/IRouter.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SpokeVault is CCIPReceiver, Ownable {
    address public immutable HUB;
    IERC20 public asset;
    mapping(bytes32 => address) public adapters;
    error ZeroAddress();

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
        adapters[_protocolId] = _adapter;
    }

    function removeAdapter(
        bytes32 _protocolId,
        address _adapter
    ) external onlyOwner {
        adapters[_protocolId] = _adapter;
    }
}
