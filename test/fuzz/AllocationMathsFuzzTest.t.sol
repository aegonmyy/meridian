// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AllocationMaths, arrayOutOfBound} from "../../src/libraries/AllocationMaths.sol";

contract AllocationMathsFuzzTest is Test {
    // =========================================================================
    // netApy fuzz tests
    // Property: result + costs always equals gross
    // Property: result always <= gross
    // Property: result always >= 0 (enforced by Solidity underflow protection)
    // =========================================================================

    function testFuzz_netApy_sumEqualsGross(
        uint256 gross,
        uint256 costs
    ) public pure {
        // skip inputs where costs exceed gross — would underflow
        vm.assume(costs <= gross);

        uint256 result = AllocationMaths.netApy(gross, costs);

        // result + costs must always equal gross — no value created or lost
        assertEq(result + costs, gross);
    }

    function testFuzz_netApy_resultNeverExceedsGross(
        uint256 gross,
        uint256 costs
    ) public pure {
        vm.assume(costs <= gross);
        assertLe(AllocationMaths.netApy(gross, costs), gross);
    }

    function testFuzz_netApy_zeroCostsReturnsGross(uint256 gross) public pure {
        // zero costs — net always equals gross
        assertEq(AllocationMaths.netApy(gross, 0), gross);
    }

    function testFuzz_netApy_fullCostsReturnsZero(uint256 gross) public pure {
        // costs equal gross — net always zero
        assertEq(AllocationMaths.netApy(gross, gross), 0);
    }

    // =========================================================================
    // weightedApy fuzz tests
    // Property: result always between min and max apy in array
    // Property: if all apys equal X — result equals X
    // Property: result scales linearly with allocations
    // =========================================================================

    function testFuzz_weightedApy_boundedByMinMaxApy(
        uint256 alloc1,
        uint256 alloc2,
        uint256 apy1,
        uint256 apy2
    ) public pure {
        // allocations must sum to 10000 and be reasonable
        vm.assume(alloc1 <= 10_000);
        alloc2 = 10_000 - alloc1;
        vm.assume(apy1 <= 10_000 && apy2 <= 10_000);

        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](2);
        allocations[0] = alloc1;
        allocations[1] = alloc2;
        apys[0] = apy1;
        apys[1] = apy2;

        uint256 result = AllocationMaths.weightedApy(allocations, apys);
        uint256 maxApy = apy1 > apy2 ? apy1 : apy2;
        uint256 minApy = apy1 < apy2 ? apy1 : apy2;

        // weighted average must always sit between min and max
        assertLe(result, maxApy);
        assertGe(result, minApy);
    }

    function testFuzz_weightedApy_uniformApyReturnsItself(
        uint256 alloc1,
        uint256 uniformApy
    ) public pure {
        // if all markets have same apy — weighted result equals that apy
        vm.assume(alloc1 <= 10_000);
        vm.assume(uniformApy <= 10_000);
        uint256 alloc2 = 10_000 - alloc1;

        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](2);
        allocations[0] = alloc1;
        allocations[1] = alloc2;
        apys[0] = uniformApy;
        apys[1] = uniformApy;

        assertEq(AllocationMaths.weightedApy(allocations, apys), uniformApy);
    }

    function testFuzz_weightedApy_zeroAllocationIgnored(
        uint256 apy1,
        uint256 apy2
    ) public pure {
        // zero allocation market contributes nothing to weighted apy
        vm.assume(apy1 <= 10_000 && apy2 <= 10_000);

        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](2);
        allocations[0] = 10_000; // full allocation
        allocations[1] = 0; // zero — ignored
        apys[0] = apy1;
        apys[1] = apy2;

        // result should only reflect apy1 since alloc2 is zero
        assertEq(AllocationMaths.weightedApy(allocations, apys), apy1);
    }

    function testFuzz_weightedApy_revert_lengthMismatch(
        uint8 len1,
        uint8 len2
    ) public {
        vm.assume(len1 != len2);
        vm.assume(len1 <= 10 && len2 <= 10); // keep arrays small

        uint256[] memory allocations = new uint256[](len1);
        uint256[] memory apys = new uint256[](len2);

        vm.expectRevert(arrayOutOfBound.selector);
        AllocationMaths.weightedApy(allocations, apys);
    }

    // =========================================================================
    // shouldRebalance fuzz tests
    // Property: never returns true when optimal <= current
    // Property: always returns true when gain >= 50 and optimal > current
    // Property: never returns true when gain < 50
    // =========================================================================

    function testFuzz_shouldRebalance_neverTrueWhenOptimalWorse(
        uint256 current,
        uint256 optimal
    ) public pure {
        // optimal worse than or equal to current — never rebalance
        vm.assume(optimal <= current);
        assertFalse(AllocationMaths.shouldRebalance(current, optimal));
    }

    function testFuzz_shouldRebalance_alwaysTrueWhenGainAboveThreshold(
        uint256 current,
        uint256 gain
    ) public pure {
        // gain >= 50 bps — always rebalance
        vm.assume(gain >= 50);
        vm.assume(current <= type(uint256).max - gain); // prevent overflow
        uint256 optimal = current + gain;
        assertTrue(AllocationMaths.shouldRebalance(current, optimal));
    }

    function testFuzz_shouldRebalance_neverTrueWhenGainBelowThreshold(
        uint256 current,
        uint256 gain
    ) public pure {
        // gain < 50 bps — never rebalance
        vm.assume(gain < 50);
        vm.assume(current <= type(uint256).max - gain);
        uint256 optimal = current + gain;
        assertFalse(AllocationMaths.shouldRebalance(current, optimal));
    }

    // =========================================================================
    // validateAllocation fuzz tests
    // Property: valid allocation always sums to exactly 10000
    // Property: invalid sum always returns false
    // Property: any allocation > 6000 always returns false
    // Property: any chain total > 8000 always returns false
    // Property: any allocation between 1 and 499 always returns false
    // =========================================================================

    function testFuzz_validateAllocation_validInputAlwaysTrue(
        uint256 a,
        uint256 b
    ) public pure {
        // construct valid three-market allocation summing to 10000
        vm.assume(a >= 500 && a <= 6_000);
        vm.assume(b >= 500 && b <= 6_000);
        vm.assume(a + b <= 8_000); // chain 1 concentration
        uint256 c = 10_000 - a - b;
        vm.assume(c >= 500 && c <= 6_000);

        uint256[][] memory allocations = new uint256[][](2);
        allocations[0] = new uint256[](2);
        allocations[1] = new uint256[](1);
        allocations[0][0] = a;
        allocations[0][1] = b;
        allocations[1][0] = c;

        assertTrue(AllocationMaths.validateAllocation(allocations));
    }

    function testFuzz_validateAllocation_wrongSumAlwaysFalse(
        uint256 a,
        uint256 b
    ) public pure {
        // deliberately construct sum != 10000
        vm.assume(a <= 5_000 && b <= 4_000);
        vm.assume(a + b != 10_000);
        vm.assume(a >= 500 && b >= 500);

        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = a;
        allocations[0][1] = b;

        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function testFuzz_validateAllocation_overMaxMarketAlwaysFalse(
        uint256 excess
    ) public pure {
        // any allocation strictly above 6000 always fails
        vm.assume(excess > 0);
        vm.assume(excess <= 4_000); // keep total reasonable
        uint256 bad = 6_000 + excess;
        uint256 rest = 10_000 - bad;
        vm.assume(rest >= 500 && rest <= 6_000);

        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = bad;
        allocations[0][1] = rest;

        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function testFuzz_validateAllocation_dustAllocationAlwaysFalse(
        uint256 dust
    ) public pure {
        // allocation between 1 and 499 always fails
        vm.assume(dust >= 1 && dust <= 499);
        uint256 rest = 10_000 - dust;
        vm.assume(rest <= 6_000);

        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = dust;
        allocations[0][1] = rest;

        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function testFuzz_validateAllocation_chainConcentrationAlwaysFalse(
        uint256 excess
    ) public pure {
        // chain total above 8000 always fails
        vm.assume(excess > 0 && excess <= 2_000);
        uint256 chainTotal = 8_000 + excess;
        uint256 a = 6_000;
        uint256 b = chainTotal - a;
        vm.assume(b >= 500 && b <= 6_000);
        uint256 rest = 10_000 - chainTotal;
        vm.assume(rest >= 500 && rest <= 6_000);

        uint256[][] memory allocations = new uint256[][](2);
        allocations[0] = new uint256[](2);
        allocations[1] = new uint256[](1);
        allocations[0][0] = a;
        allocations[0][1] = b;
        allocations[1][0] = rest;

        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    // =========================================================================
    // validateSingleMove fuzz tests
    // Property: allocation <= 3000 bps always passes
    // Property: allocation > 3000 bps always fails
    // Property: zero allocation always passes
    // =========================================================================

    function testFuzz_validateSingleMove_belowMaxAlwaysTrue(
        uint256 allocation,
        uint256 totalAssets
    ) public pure {
        // allocation at or below 30% always passes
        vm.assume(allocation <= 3_000);
        vm.assume(totalAssets <= type(uint128).max); // prevent overflow

        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = allocation;

        assertTrue(
            AllocationMaths.validateSingleMove(allocations, totalAssets)
        );
    }

    function testFuzz_validateSingleMove_aboveMaxAlwaysFalse(
        uint256 excess,
        uint256 totalAssets
    ) public pure {
        // allocation strictly above 30% always fails
        vm.assume(excess > 0 && excess <= 7_000);
        vm.assume(totalAssets >= 1_000e6); // need meaningful totalAssets
        vm.assume(totalAssets <= type(uint128).max);
        uint256 allocation = 3_000 + excess;

        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = allocation;

        assertFalse(
            AllocationMaths.validateSingleMove(allocations, totalAssets)
        );
    }

    function testFuzz_validateSingleMove_zeroAllocationAlwaysTrue(
        uint256 totalAssets
    ) public pure {
        vm.assume(totalAssets <= type(uint128).max);

        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = 0;

        assertTrue(
            AllocationMaths.validateSingleMove(allocations, totalAssets)
        );
    }
}
