// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Thrown when two arrays that must be equal in length are not
/// @dev Used in weightedApy(): allocations and netApys must be parallel arrays
error arrayOutOfBound();

/// @title AllocationMaths
/// @notice Pure math library for computing and validating yield allocation proposals
/// @dev All functions are internal pure: no state reads or writes, no CCIP dependency.
///      Used exclusively by the Rebalancer contract to evaluate agent proposals before
///      forwarding capital movement instructions to the HubVault.
///
///      Units convention:
///      - APY values are in basis points (bps): 100 = 1%, 500 = 5%, 10000 = 100%
///      - Allocation values are in basis points: 3000 = 30% of total capital
///      - totalAssets is in absolute USDC (6 decimal units)
///      - All bps values divide by 10_000 to get percentages
library AllocationMaths {
    // =========================================================================
    // APY Calculations
    // =========================================================================

    /// @notice Computes net APY by subtracting protocol costs from gross APY
    /// @dev Both inputs and output are in basis points.
    ///      Reverts with arithmetic underflow if costs exceed gross. That is intentional:
    ///      a negative net APY is not a valid input to the allocation system.
    /// @param _grossApy Gross APY of the protocol in basis points (e.g. 500 = 5%)
    /// @param _costs Total costs of the protocol in basis points (e.g. 50 = 0.5%)
    /// @return _netApy Net APY after costs in basis points
    function netApy(
        uint256 _grossApy,
        uint256 _costs
    ) internal pure returns (uint256 _netApy) {
        _netApy = _grossApy - _costs;
        return _netApy;
    }

    /// @notice Computes the weighted average APY across a set of allocations and their net APYs
    /// @dev Weighted average formula: sum(allocation[i] * netApy[i]) / 10_000
    ///      Both arrays must be the same length and represent parallel data, allocation[i]
    ///      corresponds to netApy[i]. Reverts with arrayOutOfBound if lengths differ.
    ///      Used to compare current vs proposed allocations in shouldRebalance().
    /// @param _allocations Array of allocation weights in basis points (must sum to 10_000)
    /// @param _netApYs Array of net APY values in basis points, one per allocation
    /// @return _weightedApy Weighted average APY in basis points
    function weightedApy(
        uint256[] memory _allocations,
        uint256[] memory _netApYs
    ) internal pure returns (uint256 _weightedApy) {
        if (_allocations.length != _netApYs.length) {
            revert arrayOutOfBound();
        }
        uint256 result;
        for (uint256 i = 0; i < _allocations.length; i++) {
            result += _allocations[i] * _netApYs[i];
        }
        _weightedApy = result / 10_000;
        return _weightedApy;
    }

    // =========================================================================
    // Allocation Validation
    // =========================================================================

    /// @notice Validates a 2D allocation array against protocol safety constraints
    /// @dev _allocations[i][j] represents the allocation for protocol j on chain i in basis points.
    ///      Four constraints enforced; a violation returns false rather than reverting:
    ///      1. Dust floor: each non-zero allocation must be >= 500 bps (5%)
    ///         Prevents economically meaningless positions with high relative gas cost.
    ///      2. Per-market cap: no single allocation may exceed 6000 bps (60%)
    ///         Limits concentration risk in a single protocol.
    ///      3. Per-chain cap: sum of all allocations on one chain must not exceed 8000 bps (80%)
    ///         Limits concentration risk on a single L2.
    ///      4. Grand total: sum of all allocations across all chains must equal exactly 10000 bps
    ///         Ensures 100% of capital is accounted for.
    ///      Zero allocations are valid: they represent a protocol not currently used.
    /// @param _allocations 2D array where _allocations[chain][protocol] is a bps value
    /// @return True if all constraints pass, false if any constraint is violated
    function validateAllocation(
        uint256[][] memory _allocations
    ) internal pure returns (bool) {
        uint256 grandTotal;
        for (uint256 i = 0; i < _allocations.length; i++) {
            uint256 chainTotal;
            for (uint256 j = 0; j < _allocations[i].length; j++) {
                uint256 allocation = _allocations[i][j];
                if (allocation != 0 && allocation < 500) return false; // dust floor
                if (allocation > 6000) return false; // per-market cap
                chainTotal += allocation;
            }
            if (chainTotal > 8000) return false; // per-chain cap
            grandTotal += chainTotal;
        }
        if (grandTotal != 10000) {
            return false; // must be fully allocated
        } else {
            return true;
        }
    }

    /// @notice Determines whether the gain from rebalancing justifies the operation
    /// @dev Returns true only if optimalWeightedApy strictly exceeds currentWeightedApy
    ///      by at least 50 bps (0.5%). This threshold prevents unnecessary rebalances
    ///      that would incur CCIP fees for marginal APY improvement.
    ///      Returns false if optimal <= current: never rebalance to a worse or equal position.
    /// @param currentWeightedApy Weighted average APY of current allocation in basis points
    /// @param optimalWeightedApy Weighted average APY of proposed allocation in basis points
    /// @return True if the gain is >= 50 bps and rebalancing is worthwhile
    function shouldRebalance(
        uint256 currentWeightedApy,
        uint256 optimalWeightedApy
    ) internal pure returns (bool) {
        if (optimalWeightedApy <= currentWeightedApy) return false;
        uint256 result = optimalWeightedApy - currentWeightedApy;
        if (result >= 50) {
            return true;
        } else {
            return false;
        }
    }

    /// @notice Validates that no single allocation in a proposal exceeds 30% of totalAssets
    /// @dev Converts each bps allocation to an absolute USDC amount and compares against
    ///      maxMove = 30% of totalAssets. Returns false (not revert) if any allocation exceeds the cap.
    ///      Guards against the agent moving too much capital in a single operation,
    ///      limits potential loss if the agent submits a bad proposal.
    ///      Zero totalAssets: all amounts are 0, maxMove is 0, all pass trivially.
    ///      Exactly 30% passes (strict greater than, not greater than or equal).
    /// @param allocations 2D array of bps allocations, same structure as validateAllocation input
    /// @param totalAssets Total USDC managed by the hub in 6-decimal absolute units
    /// @return True if every individual allocation converts to <= 30% of totalAssets
    function validateSingleMove(
        uint256[][] memory allocations,
        uint256 totalAssets
    ) internal pure returns (bool) {
        uint256 maxMove = (totalAssets * 3_000) / 10_000;
        for (uint256 i = 0; i < allocations.length; i++) {
            for (uint256 j = 0; j < allocations[i].length; j++) {
                uint256 amount = (allocations[i][j] * totalAssets) / 10_000;
                if (amount > maxMove) return false;
            }
        }
        return true;
    }
}
