// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";
import {CCIPHelpers} from "./libraries/CCIPHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

abstract contract HUB is ERC4626, CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    address public immutable LINK;
    uint64[] spokeChainSelectors;
    mapping(uint64 => address) spokes;
    mapping(uint64 => uint256) spokeBalances;
    uint256 inTransitAssets;
    uint256 totalPrincipal;
}
