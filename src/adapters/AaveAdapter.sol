// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.33;

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {IPool, IAtoken} from "../interfaces/aave/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveAdapter
/// @notice Yield adapter that routes assets into Aave.
contract AaveAdapter is IYieldSource {
    using SafeERC20 for IERC20;

    IPool public immutable AAVE;
    IAtoken public immutable A_TOKEN;
    IERC20 public immutable ASSET;

    /// @notice Raised when a required constructor address is zero.
    error ZeroAddress();

    /// @param _aave Aave pool contract.
    /// @param _aToken Interest-bearing token for `_asset`.
    /// @param _asset Underlying ERC20 asset.
    constructor(address _aave, address _aToken, address _asset) {
        if (_aave == address(0) || _aToken == address(0) || _asset == address(0)) {
            revert ZeroAddress();
        }
        AAVE = IPool(_aave);
        A_TOKEN = IAtoken(_aToken);
        ASSET = IERC20(_asset);
        ASSET.forceApprove(_aave, type(uint256).max);
    }

    /// @inheritdoc IYieldSource
    function deposit(uint256 _amount) external {
        ASSET.safeTransferFrom(msg.sender, address(this), _amount);
        AAVE.supply(address(ASSET), _amount, address(this), 0);
    }

    /// @inheritdoc IYieldSource
    function withdraw(uint256 _amount) external {
        uint256 withdrawn = AAVE.withdraw(address(ASSET), _amount, address(this));
        ASSET.safeTransfer(msg.sender, withdrawn);
    }

    /// @inheritdoc IYieldSource
    function totalAssets() external view returns (uint256) {
        return A_TOKEN.balanceOf(address(this));
    }
}
