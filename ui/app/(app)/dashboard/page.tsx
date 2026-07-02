"use client";

import { useAccount, useReadContract } from "wagmi";
import { sepolia } from "wagmi/chains";
import Link from "next/link";

import { Topbar } from "@/components/layout/topbar";
import { StatCard } from "@/components/meridian/stat-card";
import { AllocationBar } from "@/components/meridian/allocation-bar";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { EventToast } from "@/components/ui/event-toast";

import { CONTRACTS, HUB_ABI } from "@/lib/contracts";
import { formatUSD } from "@/lib/utils";
import { useLiveSpokeBalances, useToastQueue, useWatchSpokeAdded, useWatchSpokeRemoved } from "@/hooks/use-hub-events";

const MOCK_CHAIN_ALLOCATION = [
  { label: "Arb Sepolia / Aave V3",  pct: 60, color: "#1814f3" },
  { label: "Base Sepolia / Compound", pct: 25, color: "#16dbcc" },
  { label: "Hub Reserve",             pct: 15, color: "#e8edf5" },
];

const MOCK_HISTORY = [
  { id: "0xabc…001", type: "Deposit",   amount: "$5,000.00", chain: "Sepolia",       time: "2h ago",    status: "Confirmed" },
  { id: "0xabc…002", type: "Rebalance", amount: "$3,000.00", chain: "Arb Sepolia",   time: "4h ago",    status: "Confirmed" },
  { id: "0xabc…003", type: "Withdraw",  amount: "$500.00",   chain: "Sepolia",       time: "Yesterday", status: "Confirmed" },
];

export default function DashboardPage() {
  const { address, isConnected } = useAccount();
  const { toasts, push, dismiss } = useToastQueue();

  // ── Live spoke balances — updated by SpokeBalanceUpdated events ──────────
  const liveSpokeBalances = useLiveSpokeBalances();

  // Notify on spoke admin changes
  useWatchSpokeAdded((selector, addr) => {
    push({
      variant: "info",
      title: "Spoke added",
      body: `Selector ${selector.toString().slice(0, 8)}… → ${addr.slice(0, 10)}…`,
    });
  });
  useWatchSpokeRemoved((selector) => {
    push({
      variant: "warning",
      title: "Spoke removed",
      body: `Chain selector ${selector.toString().slice(0, 8)}… was disabled.`,
    });
  });

  // ── Contract reads ────────────────────────────────────────────────────────
  const { data: totalAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "totalAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  const { data: totalSupply } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "totalSupply",
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

  const { data: userShares } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!address, refetchInterval: 15_000 },
  });

  const { data: userAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "convertToAssets",
    args: userShares !== undefined ? [userShares] : undefined,
    chainId: sepolia.id,
    query: { enabled: userShares !== undefined },
  });

  // ── Derived values ─────────────────────────────────────────────────────────
  const sharePrice =
    totalAssets && totalSupply && totalSupply > 0n
      ? Number((totalAssets * 10n ** 6n) / totalSupply) / 1_000_000
      : 1.0;

  const reservedFormatted = reservedAssets ? formatUSD(reservedAssets) : "—";
  const inTransitFormatted = inTransitAssets ? formatUSD(inTransitAssets) : "$0.00";

  // Show live balances if we have them, otherwise fall back to mock
  const liveBalanceCount = Object.keys(liveSpokeBalances).length;

  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="Dashboard" />

      <main className="flex-1 p-8 flex flex-col gap-8 max-w-6xl w-full mx-auto">

        {/* Hero stats */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            label="Total Value Locked"
            value={totalAssets ? formatUSD(totalAssets) : "—"}
            sub="Across all spokes"
            delta="2.4%"
            deltaPositive
          />
          <StatCard
            label="Share Price"
            value={`$${sharePrice.toFixed(6)}`}
            sub="mUSDC / USDC"
            delta="0.03%"
            deltaPositive
            accent
          />
          <StatCard
            label="Your Position"
            value={
              isConnected && userAssets !== undefined
                ? formatUSD(userAssets)
                : isConnected
                ? "$0.00"
                : "—"
            }
            sub={isConnected ? "USDC equivalent" : "Connect wallet"}
          />
          <StatCard
            label="Est. Net APY"
            value="4.82%"
            sub="Weighted avg across spokes"
            delta="0.12%"
            deltaPositive
          />
        </div>

        {/* Protocol accounting — reservedAssets and inTransitAssets from Hub */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <Card padding="sm">
            <p className="text-xs uppercase tracking-wider font-medium mb-2" style={{ color: "var(--color-subtle)" }}>
              Reserved
            </p>
            <p className="text-lg font-bold tabular-nums" style={{ color: "var(--color-warning)" }}>
              {reservedFormatted}
            </p>
            <p className="text-xs mt-1" style={{ color: "var(--color-muted)" }}>
              Locked for pending withdrawals
            </p>
          </Card>
          <Card padding="sm">
            <p className="text-xs uppercase tracking-wider font-medium mb-2" style={{ color: "var(--color-subtle)" }}>
              In Transit
            </p>
            <p className="text-lg font-bold tabular-nums" style={{ color: "var(--color-primary)" }}>
              {inTransitFormatted}
            </p>
            <p className="text-xs mt-1" style={{ color: "var(--color-muted)" }}>
              CCIP in-flight to spokes
            </p>
          </Card>
          {liveBalanceCount > 0 && (
            <Card padding="sm" className="col-span-2">
              <p className="text-xs uppercase tracking-wider font-medium mb-2" style={{ color: "var(--color-subtle)" }}>
                Live Spoke Balances
              </p>
              <div className="flex flex-col gap-1">
                {Object.entries(liveSpokeBalances).map(([sel, bal]) => (
                  <div key={sel} className="flex justify-between text-xs">
                    <span style={{ color: "var(--color-muted)" }}>
                      {sel.slice(0, 8)}…
                    </span>
                    <span className="font-semibold tabular-nums" style={{ color: "var(--color-text)" }}>
                      {formatUSD(bal)}
                    </span>
                  </div>
                ))}
              </div>
            </Card>
          )}
        </div>

        {/* Capital allocation */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontSize: "0.875rem", fontWeight: 600 }}>
              Capital Allocation
            </CardTitle>
            <Link href="/allocations">
              <Button variant="ghost" size="sm">View details →</Button>
            </Link>
          </CardHeader>
          <AllocationBar segments={MOCK_CHAIN_ALLOCATION} />
        </Card>

        {/* User position + recent activity */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <Card className="lg:col-span-1">
            <CardHeader>
              <CardTitle style={{ color: "var(--color-text)", fontSize: "0.875rem", fontWeight: 600 }}>
                Your Position
              </CardTitle>
            </CardHeader>
            {isConnected ? (
              <div className="flex flex-col gap-4">
                <div className="rounded-xl p-4" style={{ background: "var(--color-bg)" }}>
                  <p className="text-xs" style={{ color: "var(--color-muted)" }}>mUSDC Shares</p>
                  <p className="text-xl font-bold tabular-nums mt-1" style={{ color: "var(--color-text)" }}>
                    {userShares ? Number(userShares) / 1e18 < 0.000001 ? "< 0.000001" : (Number(userShares) / 1e18).toFixed(6) : "0.000000"}
                  </p>
                </div>
                <div className="rounded-xl p-4" style={{ background: "var(--color-bg)" }}>
                  <p className="text-xs" style={{ color: "var(--color-muted)" }}>USDC Value</p>
                  <p className="text-xl font-bold tabular-nums mt-1" style={{ color: "var(--color-primary)" }}>
                    {userAssets !== undefined ? formatUSD(userAssets) : "$0.00"}
                  </p>
                </div>
                <div className="flex gap-2">
                  <Link href="/deposit" className="flex-1">
                    <Button className="w-full justify-center">Deposit</Button>
                  </Link>
                  <Link href="/deposit?tab=withdraw" className="flex-1">
                    <Button variant="ghost" className="w-full justify-center">Withdraw</Button>
                  </Link>
                </div>
              </div>
            ) : (
              <div className="flex flex-col items-center justify-center gap-4 py-8">
                <p className="text-sm text-center" style={{ color: "var(--color-muted)" }}>
                  Connect your wallet to see your position
                </p>
                <Link href="/deposit">
                  <Button>Get Started</Button>
                </Link>
              </div>
            )}
          </Card>

          <Card className="lg:col-span-2">
            <CardHeader>
              <CardTitle style={{ color: "var(--color-text)", fontSize: "0.875rem", fontWeight: 600 }}>
                Recent Activity
              </CardTitle>
              <Link href="/history">
                <Button variant="ghost" size="sm">View all</Button>
              </Link>
            </CardHeader>
            <div className="flex flex-col gap-2">
              {MOCK_HISTORY.map((tx) => (
                <div
                  key={tx.id}
                  className="flex items-center justify-between text-sm py-3 border-b last:border-0"
                  style={{ borderColor: "var(--color-border)" }}
                >
                  <div className="flex items-center gap-3">
                    <div
                      className="h-8 w-8 rounded-xl flex items-center justify-center text-xs font-bold"
                      style={{
                        background: tx.type === "Deposit" ? "#ede9fe" : tx.type === "Rebalance" ? "#d1fae5" : "#fef3c7",
                        color:      tx.type === "Deposit" ? "#4c1d95" : tx.type === "Rebalance" ? "#065f46" : "#92400e",
                      }}
                    >
                      {tx.type.slice(0, 1)}
                    </div>
                    <div>
                      <p className="font-medium" style={{ color: "var(--color-text)" }}>{tx.type}</p>
                      <p className="text-xs" style={{ color: "var(--color-muted)" }}>{tx.chain} · {tx.time}</p>
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className="font-semibold tabular-nums" style={{ color: "var(--color-text)" }}>
                      {tx.amount}
                    </span>
                    <Badge variant="green">{tx.status}</Badge>
                  </div>
                </div>
              ))}
            </div>
          </Card>
        </div>
      </main>

      {/* Toasts: SpokeAdded / SpokeRemoved events */}
      <EventToast toasts={toasts} onDismiss={dismiss} />
    </div>
  );
}
