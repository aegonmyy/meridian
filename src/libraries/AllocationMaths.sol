// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice error for when two arrays needed are not the same in length which will impeded calculations
error arrayOutOfBound();

library AllocationMaths {
    function netAPY(
        uint256 _grossAPY,
        uint256 _costs
    ) internal pure returns (uint256 _netAPY) {
        _netAPY = _grossAPY - _costs;
        return _netAPY;
    }

    function weightedAPY(
        uint256[] memory _allocations,
        uint256[] memory _netAPYs
    ) internal pure returns (uint256 _weightedAPY) {
        if (_allocations.length != _netAPYs.length) {
            revert arrayOutOfBound();
        }
        uint256 result;
        for (uint256 i = 0; i < _allocations.length; i++) {
            result += _allocations[i] * _netAPYs[i];
        }
        _weightedAPY = result / 10_000;
        return _weightedAPY;
    }

    function validateAllocation(
        uint256[][] memory _allocations
    ) internal pure returns (bool) {
        uint256 grandTotal;
        for (uint256 i = 0; i < _allocations.length; i++) {
            uint256 chainTotal;
            for (uint256 j = 0; j < _allocations[i].length; i++) {
                uint256 allocation = _allocations[i][j];
                if (allocation != 0 && allocation < 500) return false;
                if (allocation > 6000) return false;
                chainTotal += allocation;
            }
            if (chainTotal > 8000) return false;
            grandTotal += chainTotal;
        }
        if (grandTotal > 10000) {
            return false;
        } else {
            return true;
        }
    }

    function shouldRebalance(
        uint256 currentWeightedApy,
        uint256 optimialWeightedApy
    ) internal pure returns (bool) {
        uint256 result = optimialWeightedApy - currentWeightedApy;
        if (result >= 50) {
            return true;
        } else {
            return false;
        }
    }
}
