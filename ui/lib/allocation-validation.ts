// Client-side mirror of AllocationMaths.sol: pre-flight validation before sending tx.
// All constraints match the on-chain library exactly.

export interface AllocationIssue {
  type: "dust" | "marketCap" | "chainCap" | "grandTotal" | "threshold" | "singleMove";
  message: string;
}

// Mirrors AllocationMaths.validateAllocation()
// _allocations[chain][protocol] in bps
export function validateAllocation(allocations: number[][]): AllocationIssue | null {
  let grandTotal = 0;
  for (const chainAllocs of allocations) {
    let chainTotal = 0;
    for (const alloc of chainAllocs) {
      if (alloc !== 0 && alloc < 500)
        return { type: "dust", message: `Each non-zero allocation must be at least 500 bps (5%). Got ${alloc} bps.` };
      if (alloc > 6000)
        return { type: "marketCap", message: `No single market may exceed 6,000 bps (60%). Got ${alloc} bps.` };
      chainTotal += alloc;
    }
    if (chainTotal > 8000)
      return { type: "chainCap", message: `No chain may exceed 8,000 bps (80%). Chain total: ${chainTotal} bps.` };
    grandTotal += chainTotal;
  }
  if (grandTotal !== 10000)
    return { type: "grandTotal", message: `Allocations must sum to exactly 10,000 bps (100%). Current total: ${grandTotal} bps.` };
  return null;
}

// Mirrors AllocationMaths.shouldRebalance()
// Returns true if optimalWeightedApy > currentWeightedApy by >= 50 bps
export function shouldRebalance(currentBps: number, optimalBps: number): boolean {
  if (optimalBps <= currentBps) return false;
  return optimalBps - currentBps >= 50;
}

// Mirrors AllocationMaths.validateSingleMove()
// totalAssets in USDC 6-decimal units (bigint); allocations in bps
export function validateSingleMove(allocations: number[][], totalAssets: bigint): AllocationIssue | null {
  const maxMove = (totalAssets * 3000n) / 10000n;
  for (const chainAllocs of allocations) {
    for (const alloc of chainAllocs) {
      const amount = (BigInt(alloc) * totalAssets) / 10000n;
      if (amount > maxMove)
        return {
          type: "singleMove",
          message: `Single allocation of ${alloc} bps exceeds the 30% per-move cap (${Number(maxMove) / 1e6} USDC).`,
        };
    }
  }
  return null;
}

// Run all pre-flight checks and return the first failure found.
export function preflightProposal(
  allocations: number[][],
  currentWeightedApyBps: number,
  optimalWeightedApyBps: number,
  totalAssets: bigint
): AllocationIssue | null {
  const allocIssue = validateAllocation(allocations);
  if (allocIssue) return allocIssue;

  if (!shouldRebalance(currentWeightedApyBps, optimalWeightedApyBps))
    return {
      type: "threshold",
      message: `Optimal APY gain of ${optimalWeightedApyBps - currentWeightedApyBps} bps is below the 50 bps minimum threshold.`,
    };

  return validateSingleMove(allocations, totalAssets);
}
