"use client";

import { useWatchContractEvent } from "wagmi";
import { sepolia } from "wagmi/chains";
import { CONTRACTS, REBALANCER_ABI, PROTOCOL_LABELS, SELECTOR_LABELS } from "@/lib/contracts";

// ── RebalanceExecuted ─────────────────────────────────────────────────────
// Triggered: rebalance() or proposeAllocation() success
// weightedApy == 0 for rebalance(); non-zero for proposeAllocation()
export function useWatchRebalanceExecuted(
  onExecuted: (timestamp: bigint, weightedApy: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    eventName: "RebalanceExecuted",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { timestamp, weightedApy } = log.args as { timestamp: bigint; weightedApy: bigint };
        onExecuted(timestamp, weightedApy);
      }
    },
  });
}

// ── ChainWhitelisted ──────────────────────────────────────────────────────
// Triggered: addChainToWhitelist(chainSelector)
export function useWatchChainWhitelisted(
  onWhitelisted: (chainSelector: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    eventName: "ChainWhitelisted",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { chainSelector } = log.args as { chainSelector: bigint };
        onWhitelisted(chainSelector);
      }
    },
  });
}

// ── ChainRemovedFromWhitelist ─────────────────────────────────────────────
// Triggered: removeChainFromWhitelist(chainSelector)
export function useWatchChainRemovedFromWhitelist(
  onRemoved: (chainSelector: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    eventName: "ChainRemovedFromWhitelist",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { chainSelector } = log.args as { chainSelector: bigint };
        onRemoved(chainSelector);
      }
    },
  });
}

// ── ProtocolWhitelisted ───────────────────────────────────────────────────
// Triggered: addProtocolToWhitelist(protocolId)
export function useWatchProtocolWhitelisted(
  onWhitelisted: (protocolId: `0x${string}`) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    eventName: "ProtocolWhitelisted",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { protocolId } = log.args as { protocolId: `0x${string}` };
        onWhitelisted(protocolId);
      }
    },
  });
}

// ── ProtocolRemovedFromWhitelist ──────────────────────────────────────────
// Triggered: removeProtocolFromWhitelist(protocolId)
export function useWatchProtocolRemovedFromWhitelist(
  onRemoved: (protocolId: `0x${string}`) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    eventName: "ProtocolRemovedFromWhitelist",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { protocolId } = log.args as { protocolId: `0x${string}` };
        onRemoved(protocolId);
      }
    },
  });
}

// ── Composite hook for operator page ─────────────────────────────────────
// Wires all Rebalancer events into the shared toast queue + optional refetch callbacks.
export function useRebalancerEvents(
  push: (t: { variant: "success" | "info" | "warning"; title: string; body: string }) => void,
  refetchWhitelist?: () => void,
  refetchCooldown?: () => void,
) {
  useWatchRebalanceExecuted((timestamp, weightedApy) => {
    const apyText = weightedApy > 0n ? ` · Weighted APY: ${Number(weightedApy) / 100}%` : "";
    push({
      variant: "success",
      title: "Rebalance executed",
      body: `Capital moved at ${new Date(Number(timestamp) * 1000).toLocaleTimeString()}${apyText}`,
    });
    refetchCooldown?.();
  });

  useWatchChainWhitelisted((chainSelector) => {
    const label = SELECTOR_LABELS[chainSelector.toString()] ?? chainSelector.toString().slice(0, 10) + "…";
    push({ variant: "success", title: "Chain whitelisted", body: label });
    refetchWhitelist?.();
  });

  useWatchChainRemovedFromWhitelist((chainSelector) => {
    const label = SELECTOR_LABELS[chainSelector.toString()] ?? chainSelector.toString().slice(0, 10) + "…";
    push({ variant: "warning", title: "Chain removed from whitelist", body: label });
    refetchWhitelist?.();
  });

  useWatchProtocolWhitelisted((protocolId) => {
    const label = PROTOCOL_LABELS[protocolId] ?? protocolId.slice(0, 10) + "…";
    push({ variant: "success", title: "Protocol whitelisted", body: label });
    refetchWhitelist?.();
  });

  useWatchProtocolRemovedFromWhitelist((protocolId) => {
    const label = PROTOCOL_LABELS[protocolId] ?? protocolId.slice(0, 10) + "…";
    push({ variant: "warning", title: "Protocol removed from whitelist", body: label });
    refetchWhitelist?.();
  });
}
