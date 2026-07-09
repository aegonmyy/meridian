// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {Asset} from "./Asset.sol";

contract MockYieldSource is IYieldSource {
    Asset public asset;
    uint256 private _totalAssets;
    // FX-6b: lets tests simulate a protocol-level withdraw failure (paused pool, frozen
    // Comet market, etc.) that min-capping cannot prevent — distinct from an insufficient-
    // balance revert, which the real recall pull loop's capping already avoids.
    bool public withdrawShouldRevert;

    constructor(address _asset) {
        asset = Asset(_asset);
    }

    function deposit(uint256 amount) external override {
        bool success = asset.transferFrom(msg.sender, address(this), amount);
        require(success, "deposit in mock yield failed");
        _totalAssets += amount;
    }

    function withdraw(uint256 amount) external override {
        require(!withdrawShouldRevert, "mock: withdraw disabled (simulated protocol pause)");
        _totalAssets -= amount;
        bool success = asset.transfer(msg.sender, amount);
        require(success, "withdraw in mock yield failed");
    }

    // Helper for tests — simulate a protocol-level condition that reverts every withdraw
    // (e.g. a paused Aave pool or frozen Comet market), independent of balance sufficiency.
    function setWithdrawShouldRevert(bool shouldRevert) external {
        withdrawShouldRevert = shouldRevert;
    }

    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    // Helper for tests — simulate yield accrual
    function simulateYield(uint256 amount) external {
        _totalAssets += amount;
    }

    // Helper for tests — seed totalAssets directly (use with vm.deal for ERC20 balance)
    function setTotalAssets(uint256 amount) external {
        _totalAssets = amount;
    }
}
