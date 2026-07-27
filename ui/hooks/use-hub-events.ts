"use client";

import { useWatchContractEvent } from "wagmi";
import { sepolia } from "wagmi/chains";
import { useCallback, useState } from "react";
import { CONTRACTS, HUB_ABI } from "@/lib/contracts";
import { formatUSD } from "@/lib/utils";
import type { ToastData } from "@/components/ui/event-toast";

function makeId() {
  return Math.random().toString(36).slice(2);
}

// ── Shared toast queue helper ─────────────────────────────────────────────
export function useToastQueue() {
  const [toasts, setToasts] = useState<ToastData[]>([]);
  const push = useCallback((t: Omit<ToastData, "id">) => {
    setToasts((prev) => [...prev, { ...t, id: makeId() }]);
  }, []);
  const dismiss = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);
  return { toasts, push, dismiss };
}

// ── WithdrawalQueued ──────────────────────────────────────────────────────
// Triggered: _withdraw() Path 2 (stale spokes) or Path 3 (insufficient idle)
// Indexed: owner
export function useWatchWithdrawalQueued(
  onQueued: (owner: `0x${string}`, assets: bigint, reserved: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    eventName: "WithdrawalQueued",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { owner, assets, _reservedAssets } = log.args as {
          owner: `0x${string}`;
          shares: bigint;
          assets: bigint;
          _reservedAssets: bigint;
        };
        onQueued(owner, assets, _reservedAssets);
      }
    },
  });
}

// ── WithdrawalProcessed ───────────────────────────────────────────────────
// Triggered: _processWithdrawal(). Path 1 (sync) or CCIP callbacks (Path 2/3)
// Indexed: owner, receiver
export function useWatchWithdrawalProcessed(
  onProcessed: (owner: `0x${string}`, receiver: `0x${string}`, assets: bigint, messageId: `0x${string}`) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    eventName: "WithdrawalProcessed",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { owner, receiver, assets, messageId } = log.args as {
          owner: `0x${string}`;
          receiver: `0x${string}`;
          assets: bigint;
          messageId: `0x${string}`;
        };
        onProcessed(owner, receiver, assets, messageId);
      }
    },
  });
}

// ── SpokeBalanceUpdated ───────────────────────────────────────────────────
// Triggered: every CCIP callback (CONFIRM_RECEIPT, CONFIRM_REBALANCE,
//            REPORT_BALANCE, CONFIRM_WITHDRAWAL) from any spoke
// Indexed: chainSelector
export function useWatchSpokeBalanceUpdated(
  onUpdate: (chainSelector: bigint, balance: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    eventName: "SpokeBalanceUpdated",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { chainSelector, balance } = log.args as {
          chainSelector: bigint;
          balance: bigint;
        };
        onUpdate(chainSelector, balance);
      }
    },
  });
}

// ── SpokeAdded ────────────────────────────────────────────────────────────
// Triggered: addSpoke() when owner registers or updates a spoke
// Indexed: spokeSelector, spokeAddress
export function useWatchSpokeAdded(
  onAdded: (selector: bigint, address: `0x${string}`) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    eventName: "SpokeAdded",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { spokeSelector, spokeAddress } = log.args as {
          spokeSelector: bigint;
          spokeAddress: `0x${string}`;
        };
        onAdded(spokeSelector, spokeAddress);
      }
    },
  });
}

// ── SpokeRemoved ──────────────────────────────────────────────────────────
// Triggered: removeSpoke() when owner disables a spoke
// Indexed: spokeSelector
export function useWatchSpokeRemoved(
  onRemoved: (selector: bigint) => void
) {
  useWatchContractEvent({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    eventName: "SpokeRemoved",
    chainId: sepolia.id,
    onLogs(logs) {
      for (const log of logs) {
        const { spokeSelector } = log.args as { spokeSelector: bigint };
        onRemoved(spokeSelector);
      }
    },
  });
}

// ── Composite hook for deposit page ──────────────────────────────────────
// Wires WithdrawalQueued + WithdrawalProcessed into a toast queue and
// returns a hasPending flag for the connected address.
export function useDepositPageEvents(connectedAddress?: `0x${string}`) {
  const { toasts, push, dismiss } = useToastQueue();
  const [hasPending, setHasPending] = useState(false);

  useWatchWithdrawalQueued((owner, assets, reserved) => {
    if (connectedAddress && owner.toLowerCase() !== connectedAddress.toLowerCase()) return;
    setHasPending(true);
    const isPath3 = reserved < assets;
    push({
      variant: "warning",
      title: "Withdrawal queued",
      body: isPath3
        ? `${formatUSD(assets)} will arrive after CCIP recall from spoke (~5 min).`
        : `${formatUSD(assets)} queued, awaiting a fresh spoke balance report.`,
    });
  });

  useWatchWithdrawalProcessed((owner, _receiver, assets) => {
    if (connectedAddress && owner.toLowerCase() !== connectedAddress.toLowerCase()) return;
    setHasPending(false);
    push({
      variant: "success",
      title: "Withdrawal complete",
      body: `${formatUSD(assets)} USDC sent to your wallet.`,
    });
  });

  return { toasts, dismiss, hasPending };
}

// ── Composite hook for allocations / dashboard ────────────────────────────
// Returns a live map of chainSelector → balance updated by events.
export function useLiveSpokeBalances(
  initial: Record<string, bigint> = {}
) {
  const [balances, setBalances] = useState<Record<string, bigint>>(initial);

  useWatchSpokeBalanceUpdated((chainSelector, balance) => {
    setBalances((prev) => ({ ...prev, [chainSelector.toString()]: balance }));
  });

  return balances;
}
