"use client";

import { useWatchContractEvent } from "wagmi";
import { arbitrumSepolia } from "wagmi/chains";
import { CONTRACTS, SPOKE_ABI, PROTOCOL_LABELS } from "@/lib/contracts";

// ── AdapterSet ────────────────────────────────────────────────────────────
// Triggered: setAdapter(protocolId, adapterAddress) — onlyOwner on SpokeVault (Arb Sepolia)
// Indexed: protocolId, adapter
export function useWatchAdapterSet(
  onSet: (protocolId: `0x${string}`, adapter: `0x${string}`) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.arbSpoke.address,
    abi: SPOKE_ABI,
    eventName: "AdapterSet",
    chainId: arbitrumSepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { protocolId, adapter } = log.args as {
          protocolId: `0x${string}`;
          adapter: `0x${string}`;
        };
        onSet(protocolId, adapter);
      }
    },
  });
}

// ── AdapterRemoved ────────────────────────────────────────────────────────
// Triggered: removeAdapter(protocolId) — onlyOwner on SpokeVault (Arb Sepolia)
// Indexed: protocolId
// NOTE: capital already deployed to this adapter is NOT recalled automatically.
// A WITHDRAW_AMOUNT instruction from Hub is needed to reclaim funds.
export function useWatchAdapterRemoved(
  onRemoved: (protocolId: `0x${string}`) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.arbSpoke.address,
    abi: SPOKE_ABI,
    eventName: "AdapterRemoved",
    chainId: arbitrumSepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { protocolId } = log.args as { protocolId: `0x${string}` };
        onRemoved(protocolId);
      }
    },
  });
}

// ── Composite hook for operator page ─────────────────────────────────────
// Wires both spoke events into the shared toast queue.
export function useSpokeAdapterEvents(
  push: (t: { variant: "success" | "info" | "warning"; title: string; body: string }) => void
) {
  useWatchAdapterSet((protocolId, adapter) => {
    const label = PROTOCOL_LABELS[protocolId] ?? protocolId.slice(0, 10) + "…";
    push({
      variant: "success",
      title: "Adapter registered",
      body: `${label} → ${adapter.slice(0, 10)}…`,
    });
  });

  useWatchAdapterRemoved((protocolId) => {
    const label = PROTOCOL_LABELS[protocolId] ?? protocolId.slice(0, 10) + "…";
    push({
      variant: "warning",
      title: "Adapter disabled",
      body: `${label} was removed. Deployed funds NOT recalled automatically.`,
    });
  });
}
