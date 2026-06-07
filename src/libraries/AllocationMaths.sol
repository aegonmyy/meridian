// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice error for when two arrays needed are not the same in length which will impeded calculations
error arrayOutOfBound();

library AllocationMaths {
    function netApy(
        uint256 _grossApy,
        uint256 _costs
    ) internal pure returns (uint256 _netApy) {
        _netApy = _grossApy - _costs;
        return _netApy;
    }

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

    function validateAllocation(
        uint256[][] memory _allocations
    ) internal pure returns (bool) {
        uint256 grandTotal;
        for (uint256 i = 0; i < _allocations.length; i++) {
            uint256 chainTotal;
            for (uint256 j = 0; j < _allocations[i].length; j++) {
                uint256 allocation = _allocations[i][j];
                if (allocation != 0 && allocation < 500) return false;
                if (allocation > 6000) return false;
                chainTotal += allocation;
            }
            if (chainTotal > 8000) return false;
            grandTotal += chainTotal;
        }
        if (grandTotal != 10000) {
            return false;
        } else {
            return true;
        }
    }

    function shouldRebalance(
        uint256 currentWeightedApy,
        uint256 optimalWeightedApy
    ) internal pure returns (bool) {
        if (currentWeightedApy <= optimalWeightedApy) return false;
        uint256 result = optimalWeightedApy - currentWeightedApy;
        if (result >= 50) {
            return true;
        } else {
            return false;
        }
    }

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
