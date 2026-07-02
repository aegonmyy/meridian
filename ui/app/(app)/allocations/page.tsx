"use client";

import { useReadContract } from "wagmi";
import { sepolia, arbitrumSepolia } from "wagmi/chains";

import { Topbar } from "@/components/layout/topbar";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { AllocationBar } from "@/components/meridian/allocation-bar";
import { EventToast } from "@/components/ui/event-toast";

import { CONTRACTS, HUB_ABI, SPOKE_ABI, PROTOCOL_LABELS, CHAIN_SELECTORS } from "@/lib/contracts";
import { formatUSD } from "@/lib/utils";
import { useLiveSpokeBalances, useToastQueue } from "@/hooks/use-hub-events";
import { useSpokeAdapterEvents } from "@/hooks/use-spoke-events";

const ARB_SELECTOR = CHAIN_SELECTORS.arbitrumSepolia.toString();

export default function AllocationsPage() {
  const { toasts, push, dismiss } = useToastQueue();

  // ── Live spoke balances from SpokeBalanceUpdated events ─────────────────
  const liveSpokeBalances = useLiveSpokeBalances();

  // Toast when adapters change on Arb spoke
  useSpokeAdapterEvents(push);

  // ── Hub reads ─────────────────────────────────────────────────────────────
  const { data: totalAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "totalAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  const { data: reservedAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "reservedAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  const { data: inTransitAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "inTransitAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  // Arb spoke total via Hub's spokeBalances mapping (includes all adapters aggregated)
  const { data: arbSpokeBalance } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "spokeBalances",
    args: [CHAIN_SELECTORS.arbitrumSepolia],
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  // Arb spoke freshness
  const { data: arbLastReport } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "lastReportTimestamp",
    args: [CHAIN_SELECTORS.arbitrumSepolia],
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  // ── Spoke reads (Arbitrum Sepolia) ────────────────────────────────────────
  // getAllocations() — per-adapter balance breakdown from the spoke itself
  const { data: allocations, refetch: refetchAllocations } = useReadContract({
    address: CONTRACTS.arbSpoke.address,
    abi: SPOKE_ABI,
    functionName: "getAllocations",
    chainId: arbitrumSepolia.id,
    query: { refetchInterval: 30_000 },
  });

  // ── Derived values ─────────────────────────────────────────────────────────
  // Prefer live event balance for arb spoke, fall back to last chain read
  const arbBalance =
    liveSpokeBalances[ARB_SELECTOR] !== undefined
      ? liveSpokeBalances[ARB_SELECTOR]
      : (arbSpokeBalance ?? 0n);

  const hubIdle = totalAssets && arbBalance
    ? totalAssets - arbBalance - (inTransitAssets ?? 0n)
    : (totalAssets ?? 0n);

  const total = totalAssets ?? 1n; // avoid div-by-zero

  function pct(val: bigint): number {
    if (total === 0n) return 0;
    return Math.round(Number((val * 10000n) / total)) / 100;
  }

  const barSegments = [
    { label: "Arb Sepolia", pct: pct(arbBalance),         color: "#1814f3" },
    { label: "In Transit",  pct: pct(inTransitAssets ?? 0n), color: "#16dbcc" },
    { label: "Hub Idle",    pct: pct(hubIdle > 0n ? hubIdle : 0n), color: "#e8edf5" },
  ].filter((s) => s.pct > 0);

  // Staleness check (MAX_STALENESS = 1 hour)
  const nowSec = Math.floor(Date.now() / 1000);
  const isArbFresh = arbLastReport
    ? nowSec - Number(arbLastReport) < 3600
    : false;
  const arbAge = arbLastReport
    ? Math.floor((nowSec - Number(arbLastReport)) / 60)
    : null;

  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="Allocations" />

      <main className="flex-1 p-8 flex flex-col gap-8 max-w-6xl w-full mx-auto">

        {/* Summary bar */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Capital Distribution
            </CardTitle>
            <span className="text-sm font-semibold tabular-nums" style={{ color: "var(--color-primary)" }}>
              TVL: {totalAssets ? formatUSD(totalAssets) : "—"}
            </span>
          </CardHeader>
          {barSegments.length > 0
            ? <AllocationBar segments={barSegments} />
            : <p className="text-xs" style={{ color: "var(--color-muted)" }}>No allocation data yet.</p>
          }
        </Card>

        {/* Chain cards */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">

          {/* Arbitrum Sepolia */}
          <Card className="flex flex-col gap-5">
            <div className="flex items-start justify-between">
              <div className="flex items-center gap-2">
                <div className="h-8 w-8 rounded-xl flex items-center justify-center text-white text-xs font-bold"
                  style={{ background: "#1814f3" }}>A</div>
                <div>
                  <p className="text-sm font-semibold" style={{ color: "var(--color-text)" }}>Arbitrum Sepolia</p>
                  <p className="text-xs" style={{ color: "var(--color-muted)" }}>L2 Spoke</p>
                </div>
              </div>
              <div className="flex flex-col items-end gap-1">
                <Badge variant={arbBalance > 0n ? "blue" : "gray"}>
                  {arbBalance > 0n ? "Active" : "Idle"}
                </Badge>
                {arbAge !== null && (
                  <span className="text-xs" style={{ color: isArbFresh ? "var(--color-success)" : "var(--color-warning)" }}>
                    {isArbFresh ? `Fresh (${arbAge}m ago)` : `Stale (${arbAge}m ago)`}
                  </span>
                )}
              </div>
            </div>

            {/* Allocation bar for this spoke */}
            <div>
              <div className="flex justify-between text-xs mb-1" style={{ color: "var(--color-muted)" }}>
                <span>Deployed</span>
                <span className="font-medium tabular-nums" style={{ color: "var(--color-text)" }}>
                  {pct(arbBalance).toFixed(1)}% of TVL
                </span>
              </div>
              <div className="h-2 rounded-full overflow-hidden" style={{ background: "var(--color-border)" }}>
                <div className="h-full rounded-full transition-all"
                  style={{ width: `${pct(arbBalance)}%`, background: "#1814f3" }} />
              </div>
              <p className="text-xs mt-1 tabular-nums" style={{ color: "var(--color-muted)" }}>
                {formatUSD(arbBalance)} total
              </p>
            </div>

            {/* Per-adapter breakdown from getAllocations() */}
            <div className="flex flex-col gap-2">
              {allocations && allocations.length > 0
                ? allocations
                    .filter((a) => a.protocolId !== "0x0000000000000000000000000000000000000000000000000000000000000000")
                    .map((a) => {
                      const label = PROTOCOL_LABELS[a.protocolId] ?? a.protocolId.slice(0, 10) + "…";
                      return (
                        <div key={a.protocolId}
                          className="flex items-center justify-between text-xs rounded-xl px-3 py-2"
                          style={{ background: "var(--color-bg)" }}>
                          <span className="font-medium" style={{ color: "var(--color-text)" }}>{label}</span>
                          <span className="font-semibold tabular-nums" style={{ color: "var(--color-muted)" }}>
                            {formatUSD(a.balance)}
                          </span>
                        </div>
                      );
                    })
                : (
                  <p className="text-xs" style={{ color: "var(--color-muted)" }}>
                    {allocations ? "No adapters registered." : "Loading adapter data…"}
                  </p>
                )
              }
            </div>
          </Card>

          {/* Base Sepolia — not yet deployed */}
          <Card className="flex flex-col gap-5" style={{ opacity: 0.6 }}>
            <div className="flex items-start justify-between">
              <div className="flex items-center gap-2">
                <div className="h-8 w-8 rounded-xl flex items-center justify-center text-white text-xs font-bold"
                  style={{ background: "#16dbcc" }}>B</div>
                <div>
                  <p className="text-sm font-semibold" style={{ color: "var(--color-text)" }}>Base Sepolia</p>
                  <p className="text-xs" style={{ color: "var(--color-muted)" }}>L2 Spoke</p>
                </div>
              </div>
              <Badge variant="gray">Not deployed</Badge>
            </div>
            <p className="text-xs" style={{ color: "var(--color-muted)" }}>
              Register a spoke on Base Sepolia via the Operator panel to deploy capital here.
            </p>
          </Card>

          {/* Hub reserve */}
          <Card className="flex flex-col gap-5">
            <div className="flex items-start justify-between">
              <div className="flex items-center gap-2">
                <div className="h-8 w-8 rounded-xl flex items-center justify-center text-white text-xs font-bold"
                  style={{ background: "#10b981" }}>E</div>
                <div>
                  <p className="text-sm font-semibold" style={{ color: "var(--color-text)" }}>Ethereum Sepolia</p>
                  <p className="text-xs" style={{ color: "var(--color-muted)" }}>Hub Reserve</p>
                </div>
              </div>
            </div>
            <div>
              <div className="flex justify-between text-xs mb-1" style={{ color: "var(--color-muted)" }}>
                <span>Idle</span>
                <span className="font-medium tabular-nums" style={{ color: "var(--color-text)" }}>
                  {pct(hubIdle > 0n ? hubIdle : 0n).toFixed(1)}% of TVL
                </span>
              </div>
              <div className="h-2 rounded-full overflow-hidden" style={{ background: "var(--color-border)" }}>
                <div className="h-full rounded-full" style={{ width: `${pct(hubIdle > 0n ? hubIdle : 0n)}%`, background: "#10b981" }} />
              </div>
              <p className="text-xs mt-1 tabular-nums" style={{ color: "var(--color-muted)" }}>
                {formatUSD(hubIdle > 0n ? hubIdle : 0n)} idle
              </p>
            </div>
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center justify-between rounded-xl px-3 py-2 text-xs"
                style={{ background: "var(--color-bg)" }}>
                <span style={{ color: "var(--color-text)" }}>Reserved (pending withdrawals)</span>
                <span className="font-semibold tabular-nums" style={{ color: "var(--color-warning)" }}>
                  {reservedAssets ? formatUSD(reservedAssets) : "$0.00"}
                </span>
              </div>
              <div className="flex items-center justify-between rounded-xl px-3 py-2 text-xs"
                style={{ background: "var(--color-bg)" }}>
                <span style={{ color: "var(--color-text)" }}>In Transit (CCIP)</span>
                <span className="font-semibold tabular-nums" style={{ color: "var(--color-primary)" }}>
                  {inTransitAssets ? formatUSD(inTransitAssets) : "$0.00"}
                </span>
              </div>
            </div>
          </Card>
        </div>

        {/* CCIP info */}
        <Card padding="sm">
          <p className="text-xs leading-relaxed" style={{ color: "var(--color-muted)" }}>
            <strong style={{ color: "var(--color-text)" }}>Staleness: </strong>
            Spoke balances are reported after each CCIP callback (CONFIRM_RECEIPT, CONFIRM_REBALANCE,
            REPORT_BALANCE, CONFIRM_WITHDRAWAL). A spoke is considered stale after 1 hour without
            a report — stale spokes trigger Path 2 withdrawals. Live event updates arrive via
            <strong style={{ color: "var(--color-text)" }}> SpokeBalanceUpdated</strong>.
          </p>
        </Card>

      </main>

      {/* Event toasts — AdapterSet, AdapterRemoved */}
      <EventToast toasts={toasts} onDismiss={dismiss} />
    </div>
  );
}
