"use client";

import { useState } from "react";
import { useWatchContractEvent } from "wagmi";
import { sepolia } from "wagmi/chains";
import { CONTRACTS, AGENT_CONSUMER_ABI } from "@/lib/contracts";

export interface ProposalRecord {
  caller: `0x${string}`;
  timestamp: number; // unix seconds
}

// ── AllocationProposed ────────────────────────────────────────────────────
// Triggered: proposeAllocation() succeeds and Rebalancer accepts the proposal.
// This is the only on-chain signal that a rebalance happened via the agent flow.
export function useWatchAllocationProposed(
  onProposed: (caller: `0x${string}`, timestamp: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.agentConsumer.address,
    abi: AGENT_CONSUMER_ABI,
    eventName: "AllocationProposed",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { caller, timestamp } = log.args as { caller: `0x${string}`; timestamp: bigint };
        onProposed(caller, timestamp);
      }
    },
  });
}

// ── Composite: track the last proposal ───────────────────────────────────
// Returns the most recent AllocationProposed event seen in this session.
export function useLastProposal(): {
  lastProposal: ProposalRecord | null;
} {
  const [lastProposal, setLastProposal] = useState<ProposalRecord | null>(null);

  useWatchAllocationProposed((caller, timestamp) => {
    setLastProposal({ caller, timestamp: Number(timestamp) });
  });

  return { lastProposal };
}
