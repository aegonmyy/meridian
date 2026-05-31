// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.33;

interface IYieldSource {
    /// @notice Deposits underlying assets into the strategy.
    /// @dev Caller must have approved the adapter for `amount`.
    /// @param amount Amount of underlying asset to deposit.
    function deposit(uint256 amount) external;

    /// @notice Withdraws underlying assets from the strategy.
    /// @param amount Amount of underlying asset to withdraw.
    function withdraw(uint256 amount) external;

    /// @notice Returns total underlying assets currently managed by the strategy.
    /// @dev The returned value must represent assets attributable to the adapter itself.
    /// @return Total managed underlying assets.
    function totalAssets() external view returns (uint256);
}
