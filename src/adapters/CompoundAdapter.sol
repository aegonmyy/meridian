// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.33;

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {IComet} from "../interfaces/compound/IComet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CompoundAdapter
/// @notice Yield adapter that routes assets into Compound V3 Comet.
contract compoundAdapter is IYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    IComet public immutable compound;

    /// @notice Raised when a required constructor address is zero.
    error ZeroAddress();

    /// @param _asset Underlying ERC20 asset.
    /// @param _compound Compound V3 Comet address.
    constructor(address _asset, address _compound) {
        if (_asset == address(0) || _compound == address(0)) {
            revert ZeroAddress();
        }
        asset = IERC20(_asset);
        compound = IComet(_compound);
        asset.forceApprove(_compound, type(uint256).max);
    }

    /// @inheritdoc IYieldSource
    function deposit(uint256 _amount) external {
        asset.safeTransferFrom(msg.sender, address(this), _amount);
        compound.supply(address(asset), _amount);
    }

    /// @inheritdoc IYieldSource
    function withdraw(uint256 _amount) external {
        compound.withdraw(address(asset), _amount);
        asset.safeTransfer(msg.sender, _amount);
    }

    /// @inheritdoc IYieldSource
    function totalAssets() external view returns (uint256) {
        return compound.balanceOf(address(this));
    }
}
