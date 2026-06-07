// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IComet {
    function supply(address asset, uint256 amount) external;

    function withdraw(address asset, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);
}
