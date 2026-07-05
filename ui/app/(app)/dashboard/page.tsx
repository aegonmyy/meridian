"use client";

import { useAccount, useReadContract } from "wagmi";
import { sepolia } from "wagmi/chains";
import Link from "next/link";

import { Topbar } from "@/components/layout/topbar";
import { StatCard } from "@/components/meridian/stat-card";
import { AllocationBar } from "@/components/meridian/allocation-bar";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { EventToast } from "@/components/ui/event-toast";

import { CONTRACTS, HUB_ABI, SELECTOR_LABELS } from "@/lib/contracts";
import { formatUSD } from "@/lib/utils";
import { useLiveSpokeBalances, useToastQueue, useWatchSpokeAdded, useWatchSpokeRemoved } from "@/hooks/use-hub-events";

const SELECTOR_COLORS: Record<string, string> = {
  "3478487238524512106":  "#1814f3",
  "10344971235874465080": "#16dbcc",
  "5224473277236331295":  "#f97316",
};

function DepositIcon({ color }: { color: string }) {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-label="Deposit">
      <path d="M8 2v9M4 7.5l4 4 4-4" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M2 13h12" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
    </svg>
  );
}

function WithdrawIcon({ color }: { color: string }) {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-label="Withdraw">
      <path d="M8 14V5M4 8.5l4-4 4 4" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M2 3h12" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
    </svg>
  );
}

function RebalanceIcon({ color }: { color: string }) {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-label="Rebalance">
      <path d="M2 5h8M7 2l3 3-3 3" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M14 11H6m3 3l-3-3 3-3" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}

function TxIcon({ type, bgColor, iconColor }: { type: string; bgColor: string; iconColor: string }) {
  return (
    <div
      className="h-8 w-8 rounded-xl flex items-center justify-center"
      style={{ background: bgColor }}
    >
      {type === "Deposit"   && <DepositIcon   color={iconColor} />}
      {type === "Withdraw"  && <WithdrawIcon  color={iconColor} />}
      {type === "Rebalance" && <RebalanceIcon color={iconColor} />}
    </div>
  );
}

export default function DashboardPage() {
  const { address, isConnected } = useAccount();
  const { toasts, push, dismiss } = useToastQueue();

  const liveSpokeBalances = useLiveSpokeBalances();

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

  const sharePrice =
    totalAssets && totalSupply && totalSupply > 0n
      ? Number((totalAssets * 10n ** 6n) / totalSupply) / 1_000_000
      : null;

  const reservedFormatted = reservedAssets ? formatUSD(reservedAssets) : "—";
  const inTransitFormatted = inTransitAssets ? formatUSD(inTransitAssets) : "$0.00";

  // Real allocation segments from live spoke balances
  const totalLiveSpoke = Object.values(liveSpokeBalances).reduce((a, b) => a + b, 0n);
  const hubIdleRaw = totalAssets
    ? totalAssets - totalLiveSpoke - (inTransitAssets ?? 0n)
    : 0n;
  const hubIdle = hubIdleRaw > 0n ? hubIdleRaw : 0n;
  const tvlDenominator = totalAssets ?? 1n;

  function pct(val: bigint) {
    if (tvlDenominator === 1n) return 0;
    return Math.round(Number((val * 10000n) / tvlDenominator)) / 100;
  }

  const allocationSegments = [
    ...Object.entries(liveSpokeBalances).map(([sel, bal]) => ({
      label: SELECTOR_LABELS[sel] ?? sel.slice(0, 8) + "…",
      pct: pct(bal),
      color: SELECTOR_COLORS[sel] ?? "#6366f1",
    })),
    ...(inTransitAssets && inTransitAssets > 0n
      ? [{ label: "In Transit", pct: pct(inTransitAssets), color: "#f59e0b" }]
      : []),
    ...(hubIdle > 0n ? [{ label: "Hub Reserve", pct: pct(hubIdle), color: "#e8edf5" }] : []),
  ].filter((s) => s.pct > 0);

  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="Dashboard" />

      <main className="flex-1 p-8 flex flex-col gap-8 max-w-6xl w-full mx-auto">

        {/* Hero stats */}
        <div className="grid grid-cols-2 lg:grid-cols-3 gap-4">
          <StatCard
            label="Total Value Locked"
            value={totalAssets ? formatUSD(totalAssets) : "—"}
            sub="Across all spokes"
          />
          <StatCard
            label="Share Price"
            value={sharePrice !== null ? `$${sharePrice.toFixed(6)}` : "—"}
            sub="mUSDC / USDC"
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
        </div>

        {/* Protocol accounting */}
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
          {Object.keys(liveSpokeBalances).length > 0 && (
            <Card padding="sm" className="col-span-2">
              <p className="text-xs uppercase tracking-wider font-medium mb-2" style={{ color: "var(--color-subtle)" }}>
                Live Spoke Balances
              </p>
              <div className="flex flex-col gap-1">
                {Object.entries(liveSpokeBalances).map(([sel, bal]) => (
                  <div key={sel} className="flex justify-between text-xs">
                    <span style={{ color: "var(--color-muted)" }}>
                      {SELECTOR_LABELS[sel] ?? sel.slice(0, 8) + "…"}
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
          {allocationSegments.length > 0
            ? <AllocationBar segments={allocationSegments} />
            : (
              <p className="text-xs py-2" style={{ color: "var(--color-muted)" }}>
                No spoke balances reported yet — allocation data will appear after CCIP confirmations.
              </p>
            )
          }
        </Card>

        {/* User position */}
        <Card className="lg:max-w-sm">
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
                  {userShares
                    ? Number(userShares) / 1e18 < 0.000001
                      ? "< 0.000001"
                      : (Number(userShares) / 1e18).toFixed(6)
                    : "0.000000"}
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

      </main>

      <EventToast toasts={toasts} onDismiss={dismiss} />
    </div>
  );
}
