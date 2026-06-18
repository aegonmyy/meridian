// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AllocationMaths, arrayOutOfBound} from "../../src/libraries/AllocationMaths.sol";

contract AllocationMathsTest is Test {
    // =========================================================================
    // netApy
    // =========================================================================

    function test_netApy_correctSubtraction() public pure {
        // 500 bps gross - 50 bps costs = 450 bps net
        uint256 result = AllocationMaths.netApy(500, 50);
        assertEq(result, 450);
    }

    function test_netApy_zeroCosts() public pure {
        // no costs — net equals gross
        uint256 result = AllocationMaths.netApy(300, 0);
        assertEq(result, 300);
    }

    function test_netApy_zeroGross() public pure {
        uint256 result = AllocationMaths.netApy(0, 0);
        assertEq(result, 0);
    }

    function test_netApy_revert_underflow() public {
        // costs exceed gross — should underflow
        vm.expectRevert();
        AllocationMaths.netApy(100, 200);
    }

    // =========================================================================
    // weightedApy
    // =========================================================================

    function test_weightedApy_singleMarket() public pure {
        // 10000 bps allocation at 500 bps apy = 500 weighted
        uint256[] memory allocations = new uint256[](1);
        uint256[] memory apys = new uint256[](1);
        allocations[0] = 10_000;
        apys[0] = 500;
        uint256 result = AllocationMaths.weightedApy(allocations, apys);
        assertEq(result, 500);
    }

    function test_weightedApy_twoMarkets_equalSplit() public pure {
        // 5000 bps each — one at 400 bps, one at 600 bps
        // weighted = (5000 * 400 + 5000 * 600) / 10000 = 500
        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](2);
        allocations[0] = 5_000;
        allocations[1] = 5_000;
        apys[0] = 400;
        apys[1] = 600;
        uint256 result = AllocationMaths.weightedApy(allocations, apys);
        assertEq(result, 500);
    }

    function test_weightedApy_twoMarkets_unequalSplit() public pure {
        // 8000 bps at 200 bps apy, 2000 bps at 800 bps apy
        // weighted = (8000 * 200 + 2000 * 800) / 10000 = 320
        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](2);
        allocations[0] = 8_000;
        allocations[1] = 2_000;
        apys[0] = 200;
        apys[1] = 800;
        uint256 result = AllocationMaths.weightedApy(allocations, apys);
        assertEq(result, 320);
    }

    function test_weightedApy_zeroAllocation() public pure {
        // zero allocation contributes nothing to weighted apy
        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](2);
        allocations[0] = 10_000;
        allocations[1] = 0;
        apys[0] = 500;
        apys[1] = 1000;
        uint256 result = AllocationMaths.weightedApy(allocations, apys);
        assertEq(result, 500);
    }

    function test_weightedApy_revert_arrayLengthMismatch() public {
        uint256[] memory allocations = new uint256[](2);
        uint256[] memory apys = new uint256[](3);
        vm.expectRevert(arrayOutOfBound.selector);
        AllocationMaths.weightedApy(allocations, apys);
    }

    // =========================================================================
    // validateAllocation
    // =========================================================================

    function test_validateAllocation_validSingleChain() public pure {
        // single chain, two markets summing to 10000
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 5_000; // 50%
        allocations[0][1] = 5_000; // 50%
        assertTrue(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_validMultiChain() public pure {
        // three chains summing to 10000 total
        uint256[][] memory allocations = new uint256[][](3);
        allocations[0] = new uint256[](2);
        allocations[1] = new uint256[](2);
        allocations[2] = new uint256[](1);
        allocations[0][0] = 2_000;
        allocations[0][1] = 2_000; // chain 1 = 4000
        allocations[1][0] = 2_000;
        allocations[1][1] = 2_000; // chain 2 = 4000
        allocations[2][0] = 2_000; // chain 3 = 2000
        assertTrue(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_revert_sumNot10000() public pure {
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 5_000;
        allocations[0][1] = 4_000; // sum = 9000 not 10000
        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_revert_belowMinimum() public pure {
        // 499 bps — below 500 minimum (but not zero)
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 499;
        allocations[0][1] = 9_501;
        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_zeroAllowedAsMinimum() public pure {
        // zero is allowed — means market not used
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 0;
        allocations[0][1] = 10_000;
        assertTrue(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_revert_exceedsMaxPerMarket() public pure {
        // 6001 bps — exceeds 6000 max per market
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 6_001;
        allocations[0][1] = 3_999;
        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_exactlyMaxPerMarket() public pure {
        // exactly 6000 bps — should pass
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 6_000;
        allocations[0][1] = 4_000;
        assertTrue(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_revert_chainConcentrationExceeds8000()
        public
        pure
    {
        // single chain with 8001 bps — exceeds 8000 max chain concentration
        uint256[][] memory allocations = new uint256[][](2);
        allocations[0] = new uint256[](2);
        allocations[1] = new uint256[](1);
        allocations[0][0] = 6_000;
        allocations[0][1] = 2_001; // chain 1 = 8001
        allocations[1][0] = 1_999; // chain 2 = 1999
        assertFalse(AllocationMaths.validateAllocation(allocations));
    }

    function test_validateAllocation_exactlyMaxChainConcentration()
        public
        pure
    {
        // exactly 8000 bps on one chain — should pass
        uint256[][] memory allocations = new uint256[][](2);
        allocations[0] = new uint256[](2);
        allocations[1] = new uint256[](1);
        allocations[0][0] = 6_000;
        allocations[0][1] = 2_000; // chain 1 = 8000
        allocations[1][0] = 2_000; // chain 2 = 2000
        assertTrue(AllocationMaths.validateAllocation(allocations));
    }

    // =========================================================================
    // shouldRebalance
    // =========================================================================

    function test_shouldRebalance_returnsTrueWhenGainAboveThreshold()
        public
        pure
    {
        // optimal 550 bps, current 500 bps — gain of 50 bps exactly
        assertTrue(AllocationMaths.shouldRebalance(500, 550));
    }

    function test_shouldRebalance_returnsTrueWhenGainWellAboveThreshold()
        public
        pure
    {
        // optimal 700 bps, current 500 bps — gain of 200 bps
        assertTrue(AllocationMaths.shouldRebalance(500, 700));
    }

    function test_shouldRebalance_returnsFalseWhenGainBelowThreshold()
        public
        pure
    {
        // optimal 549 bps, current 500 bps — gain of 49 bps — below 50 threshold
        assertFalse(AllocationMaths.shouldRebalance(500, 549));
    }

    function test_shouldRebalance_returnsFalseWhenEqual() public pure {
        // same apy — no reason to rebalance
        assertFalse(AllocationMaths.shouldRebalance(500, 500));
    }

    function test_shouldRebalance_returnsFalseWhenOptimalWorse() public pure {
        // optimal lower than current — definitely don't rebalance
        assertFalse(AllocationMaths.shouldRebalance(600, 500));
    }

    function test_shouldRebalance_exactlyThreshold() public pure {
        // exactly 50 bps gain — should return true (>= 50)
        assertTrue(AllocationMaths.shouldRebalance(500, 550));
    }

    // =========================================================================
    // validateSingleMove
    // =========================================================================

    function test_validateSingleMove_validAllocation() public pure {
        // max single allocation 3000 bps = 30% — should pass
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = 3_000; // exactly 30%
        assertTrue(
            AllocationMaths.validateSingleMove(allocations, 1_000_000e6)
        );
    }

    function test_validateSingleMove_revert_exceedsMaxMove() public pure {
        // 3001 bps = 30.01% — exceeds 30% max
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = 3_001;
        assertFalse(
            AllocationMaths.validateSingleMove(allocations, 1_000_000e6)
        );
    }

    function test_validateSingleMove_multipleMarketsAllValid() public pure {
        // two markets both under 30%
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](2);
        allocations[0][0] = 2_000; // 20%
        allocations[0][1] = 2_000; // 20%
        assertTrue(
            AllocationMaths.validateSingleMove(allocations, 1_000_000e6)
        );
    }

    function test_validateSingleMove_multipleMarketsOneInvalid() public pure {
        // one market exceeds 30%
        uint256[][] memory allocations = new uint256[][](2);
        allocations[0] = new uint256[](1);
        allocations[1] = new uint256[](1);
        allocations[0][0] = 2_000; // 20% — valid
        allocations[1][0] = 3_500; // 35% — invalid
        assertFalse(
            AllocationMaths.validateSingleMove(allocations, 1_000_000e6)
        );
    }

    function test_validateSingleMove_zeroAllocation() public pure {
        // zero allocation — always passes
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = 0;
        assertTrue(
            AllocationMaths.validateSingleMove(allocations, 1_000_000e6)
        );
    }

    function test_validateSingleMove_zeroTotalAssets() public pure {
        // zero totalAssets — all amounts are 0 — passes
        uint256[][] memory allocations = new uint256[][](1);
        allocations[0] = new uint256[](1);
        allocations[0][0] = 5_000;
        assertTrue(AllocationMaths.validateSingleMove(allocations, 0));
    }
}
