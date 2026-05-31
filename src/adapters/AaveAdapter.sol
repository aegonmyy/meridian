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

    IPool public immutable aave;
    IAtoken public immutable aToken;
    IERC20 public immutable asset;

    /// @notice Raised when a required constructor address is zero.
    error ZeroAddress();

    /// @param _aave Aave pool contract.
    /// @param _aToken Interest-bearing token for `_asset`.
    /// @param _asset Underlying ERC20 asset.
    constructor(address _aave, address _aToken, address _asset) {
        if (
            _aave == address(0) || _aToken == address(0) || _asset == address(0)
        ) {
            revert ZeroAddress();
        }
        aave = IPool(_aave);
        aToken = IAtoken(_aToken);
        asset = IERC20(_asset);
        asset.forceApprove(_aave, type(uint256).max);
    }

    /// @inheritdoc IYieldSource
    function deposit(uint256 _amount) external {
        asset.safeTransferFrom(msg.sender, address(this), _amount);
        aave.supply(address(asset), _amount, address(this), 0);
    }

    /// @inheritdoc IYieldSource
    function withdraw(uint256 _amount) external {
        uint256 withdrawn = aave.withdraw(
            address(asset),
            _amount,
            address(this)
        );
        asset.safeTransfer(msg.sender, withdrawn);
    }

    /// @inheritdoc IYieldSource
    function totalAssets() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }
}
