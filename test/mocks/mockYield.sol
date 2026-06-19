// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {Asset} from "./Asset.sol";

contract MockYieldSource is IYieldSource {
    Asset public asset;
    uint256 private _totalAssets;

    constructor(address _asset) {
        asset = Asset(_asset);
    }

    function deposit(uint256 amount) external override {
        asset.transferFrom(msg.sender, address(this), amount);
        _totalAssets += amount;
    }

    function withdraw(uint256 amount) external override {
        _totalAssets -= amount;
        asset.transfer(msg.sender, amount);
    }

    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    // Helper for tests — simulate yield accrual without external token movement
    function simulateYield(uint256 amount) external {
        _totalAssets += amount;
    }
}
