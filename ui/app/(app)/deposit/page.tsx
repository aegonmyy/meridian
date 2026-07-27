"use client";

import { useState, useEffect, Suspense } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { sepolia } from "wagmi/chains";
import { useSearchParams } from "next/navigation";

import { Topbar } from "@/components/layout/topbar";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { ErrorModal } from "@/components/ui/error-modal";
import { EventToast } from "@/components/ui/event-toast";

import { CONTRACTS, HUB_ABI, ERC20_ABI } from "@/lib/contracts";
import { formatUSD } from "@/lib/utils";
import { parseHubError } from "@/lib/hub-errors";
import { useDepositPageEvents } from "@/hooks/use-hub-events";

const USDC_DECIMALS = 6;

// ── Path labels so the user understands async withdrawals ─────────────────
const WITHDRAWAL_PATH_HELP = {
  path1: "Immediate. Idle USDC covers your amount and all spoke reports are fresh.",
  path2: "Queued. Idle covers your amount but spoke reports are stale. Hub is refreshing balances via CCIP (~1 min).",
  path3: "Queued. There is not enough idle USDC. Hub is recalling funds from the best spoke via CCIP (~5 min).",
};

function DepositContent() {
  const searchParams = useSearchParams();
  const defaultTab = searchParams.get("tab") === "withdraw" ? "withdraw" : "deposit";

  const [tab, setTab] = useState<"deposit" | "withdraw">(defaultTab as "deposit" | "withdraw");
  const [amount, setAmount] = useState("");
  const [hubError, setHubError] = useState<ReturnType<typeof parseHubError>>(null);

  const { address, isConnected } = useAccount();
  const { toasts, dismiss, hasPending } = useDepositPageEvents(address);

  // ── On-chain reads ───────────────────────────────────────────────────────
  const { data: usdcBalance, refetch: refetchUsdc } = useReadContract({
    address: CONTRACTS.usdc.sepolia,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: CONTRACTS.usdc.sepolia,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, CONTRACTS.hub.address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!address, refetchInterval: 8_000 },
  });

  const { data: mUSDCBalance, refetch: refetchShares } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });

  // Preview how many shares a withdrawal will cost (for display only)
  const parsedAssets =
    amount && !isNaN(Number(amount)) ? parseUnits(amount, USDC_DECIMALS) : 0n;

  const { data: previewShares } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "previewWithdraw",
    args: parsedAssets > 0n ? [parsedAssets] : undefined,
    chainId: sepolia.id,
    query: { enabled: parsedAssets > 0n },
  });

  // Max USDC the user can withdraw
  const { data: maxWithdraw } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "maxWithdraw",
    args: address ? [address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!address },
  });

  // Hub idle vs reserved: indicates which withdrawal path will trigger
  const { data: reservedAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "reservedAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  const { data: totalAssets } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "totalAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 15_000 },
  });

  // ── Writes ───────────────────────────────────────────────────────────────
  function handleError(err: unknown) {
    const info = parseHubError(err);
    if (info) setHubError(info);
  }

  const { writeContract: approve, data: approveTxHash, isPending: isApproving } =
    useWriteContract();
  const { writeContract: depositFn, data: depositTxHash, isPending: isDepositing } =
    useWriteContract();
  // withdraw() takes USDC amount, cleaner UX than redeem() which takes shares
  const { writeContract: withdrawFn, data: withdrawTxHash, isPending: isWithdrawing } =
    useWriteContract();

  const { isLoading: waitingApprove, isSuccess: approveSuccess } =
    useWaitForTransactionReceipt({ hash: approveTxHash });
  const { isLoading: waitingDeposit, isSuccess: depositSuccess } =
    useWaitForTransactionReceipt({ hash: depositTxHash });
  const { isLoading: waitingWithdraw } =
    useWaitForTransactionReceipt({ hash: withdrawTxHash });

  useEffect(() => {
    if (depositSuccess) {
      setAmount("");
      refetchUsdc();
      refetchShares();
    }
  }, [depositSuccess, refetchUsdc, refetchShares]);

  const needsApproval =
    allowance !== undefined && parsedAssets > 0n && allowance < parsedAssets;

  function handleApprove() {
    approve(
      {
        address: CONTRACTS.usdc.sepolia,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [CONTRACTS.hub.address, parsedAssets],
        chainId: sepolia.id,
      },
      { onError: handleError }
    );
  }

  function handleDeposit() {
    if (!address) return;
    depositFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        functionName: "deposit",
        // deposit(assets, receiver), ERC4626
        args: [parsedAssets, address],
        chainId: sepolia.id,
      },
      {
        onError: handleError,
        onSuccess: () => refetchAllowance(),
      }
    );
  }

  function handleWithdraw() {
    if (!address || !parsedAssets) return;
    withdrawFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        // withdraw(assets, receiver, owner), triggers _withdraw internally
        // Hub decides Path 1/2/3 based on idle balance and spoke freshness
        functionName: "withdraw",
        args: [parsedAssets, address, address],
        chainId: sepolia.id,
      },
      { onError: handleError }
    );
  }

  // ── Derived display values ────────────────────────────────────────────────
  const usdcBalanceFormatted = usdcBalance
    ? Number(formatUnits(usdcBalance, USDC_DECIMALS)).toFixed(2)
    : "0.00";
  const maxWithdrawFormatted = maxWithdraw
    ? Number(formatUnits(maxWithdraw, USDC_DECIMALS)).toFixed(2)
    : "0.00";
  const sharesFormatted = previewShares
    ? Number(formatUnits(previewShares, 18)).toFixed(6)
    : "—";

  // Predict withdrawal path for the entered amount
  function predictedPath(): "path1" | "path2" | "path3" | null {
    if (!parsedAssets || !totalAssets || !reservedAssets) return null;
    // Simplified: if parsedAssets > totalAssets - reservedAssets, it's path3
    const idle = totalAssets - reservedAssets;
    if (parsedAssets > idle) return "path3";
    return "path2"; // conservative, assume stale spokes (path2), may upgrade to path1 on-chain
  }

  const path = tab === "withdraw" ? predictedPath() : null;
  const isLoading =
    isApproving || waitingApprove || isDepositing || waitingDeposit || isWithdrawing || waitingWithdraw;

  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="Deposit / Withdraw" />

      <main className="flex-1 p-8 flex items-start justify-center">
        <div className="w-full max-w-md flex flex-col gap-6">

          {/* Pending withdrawal banner */}
          {hasPending && (
            <div
              className="rounded-2xl px-4 py-3 flex items-start gap-3"
              style={{ background: "#fef3c7", border: "1px solid #f59e0b" }}
            >
              <span className="text-base">⏳</span>
              <div>
                <p className="text-xs font-semibold" style={{ color: "#92400e" }}>
                  Withdrawal in progress
                </p>
                <p className="text-xs mt-0.5" style={{ color: "#92400e" }}>
                  Your funds are being recalled via CCIP. You will be notified when they arrive.
                </p>
              </div>
            </div>
          )}

          {/* Tab switcher */}
          <div
            className="flex rounded-2xl p-1"
            style={{ background: "var(--color-card)", border: "1px solid var(--color-border)" }}
          >
            {(["deposit", "withdraw"] as const).map((t) => (
              <button
                key={t}
                onClick={() => { setTab(t); setAmount(""); }}
                className="flex-1 py-2.5 rounded-xl text-sm font-semibold capitalize transition-colors"
                style={
                  tab === t
                    ? { background: "var(--color-primary)", color: "#fff" }
                    : { color: "var(--color-muted)" }
                }
              >
                {t}
              </button>
            ))}
          </div>

          <Card>
            <CardHeader>
              <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
                {tab === "deposit" ? "Deposit USDC" : "Withdraw USDC"}
              </CardTitle>
              <span className="text-xs" style={{ color: "var(--color-muted)" }}>
                {tab === "deposit"
                  ? `Balance: ${usdcBalanceFormatted} USDC`
                  : `Max: ${maxWithdrawFormatted} USDC`}
              </span>
            </CardHeader>

            {/* Amount input */}
            <div
              className="rounded-xl p-4 flex items-center gap-3 mb-4"
              style={{ background: "var(--color-bg)", border: "1px solid var(--color-border)" }}
            >
              <input
                type="number"
                placeholder="0.00"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                className="flex-1 bg-transparent text-2xl font-bold outline-none tabular-nums"
                style={{ color: "var(--color-text)" }}
                min="0"
                step="0.01"
              />
              <div className="flex flex-col items-end gap-1">
                <span
                  className="text-sm font-semibold px-3 py-1 rounded-lg"
                  style={{ background: "var(--color-card)", color: "var(--color-muted)" }}
                >
                  USDC
                </span>
                <button
                  onClick={() =>
                    setAmount(tab === "deposit" ? usdcBalanceFormatted : maxWithdrawFormatted)
                  }
                  className="text-xs font-medium"
                  style={{ color: "var(--color-primary)" }}
                >
                  MAX
                </button>
              </div>
            </div>

            {/* Summary rows */}
            <div className="flex flex-col gap-2 mb-5">
              {tab === "deposit" ? (
                <>
                  <SummaryRow label="You receive" value={amount ? `~${amount} mUSDC` : "—"} />
                  <SummaryRow label="Protocol" value="Meridian Hub · Sepolia" />
                  <SummaryRow label="Est. gas" value="~0.001 ETH" />
                  {needsApproval && (
                    <SummaryRow label="Approval" value="Required first" highlight />
                  )}
                </>
              ) : (
                <>
                  {/* Withdrawal-specific rows */}
                  <SummaryRow label="Shares burned" value={previewShares ? `${sharesFormatted} mUSDC` : "—"} />
                  <SummaryRow label="Est. gas" value="~0.001–0.003 ETH" />
                  {path && (
                    <div
                      className="rounded-xl px-3 py-2.5 mt-1"
                      style={{
                        background: path === "path3" ? "#fef3c7" : path === "path2" ? "#ede9fe" : "#d1fae5",
                      }}
                    >
                      <p
                        className="text-xs font-semibold mb-0.5"
                        style={{
                          color: path === "path3" ? "#92400e" : path === "path2" ? "#4c1d95" : "#065f46",
                        }}
                      >
                        {path === "path1" ? "Path 1: instant" : path === "path2" ? "Path 2: ~1 min" : "Path 3: ~5 min"}
                      </p>
                      <p
                        className="text-xs"
                        style={{
                          color: path === "path3" ? "#92400e" : path === "path2" ? "#4c1d95" : "#065f46",
                        }}
                      >
                        {WITHDRAWAL_PATH_HELP[path]}
                      </p>
                    </div>
                  )}
                </>
              )}
            </div>

            {/* Action buttons */}
            {!isConnected ? (
              <p className="text-sm text-center py-2" style={{ color: "var(--color-muted)" }}>
                Connect wallet to continue
              </p>
            ) : tab === "deposit" ? (
              <div className="flex flex-col gap-2">
                {needsApproval && (
                  <Button
                    variant="ghost"
                    className="w-full justify-center"
                    onClick={handleApprove}
                    loading={isApproving || waitingApprove}
                    disabled={!parsedAssets}
                  >
                    1. Approve USDC
                  </Button>
                )}
                <Button
                  className="w-full justify-center"
                  onClick={handleDeposit}
                  loading={isDepositing || waitingDeposit}
                  disabled={!parsedAssets || (needsApproval && !approveSuccess)}
                >
                  {needsApproval ? "2. " : ""}Deposit
                </Button>
              </div>
            ) : (
              <Button
                className="w-full justify-center"
                onClick={handleWithdraw}
                loading={isWithdrawing || waitingWithdraw}
                disabled={!parsedAssets}
              >
                Withdraw
              </Button>
            )}

            {depositSuccess && (
              <p className="text-xs text-center mt-4 font-medium" style={{ color: "var(--color-success)" }}>
                ✓ Deposit confirmed
              </p>
            )}
          </Card>

          {/* Info card */}
          <Card padding="sm">
            <p className="text-xs leading-relaxed" style={{ color: "var(--color-muted)" }}>
              <strong style={{ color: "var(--color-text)" }}>Withdrawal paths: </strong>
              Hub tries to settle immediately (Path 1). If spoke reports are stale it queues
              and refreshes via CCIP (Path 2, ~1 min). If idle USDC is insufficient it recalls
              funds from the best spoke (Path 3, ~5 min). Your shares are locked in escrow
              until settlement.
            </p>
          </Card>
        </div>
      </main>

      {/* Error modal, shown when any Hub custom error is thrown */}
      <ErrorModal error={hubError} onClose={() => setHubError(null)} />

      {/* Event toasts: WithdrawalQueued and WithdrawalProcessed */}
      <EventToast toasts={toasts} onDismiss={dismiss} />
    </div>
  );
}

function SummaryRow({
  label, value, highlight,
}: {
  label: string; value: string; highlight?: boolean;
}) {
  return (
    <div className="flex justify-between text-xs">
      <span style={{ color: "var(--color-muted)" }}>{label}</span>
      <span
        className="font-medium"
        style={{ color: highlight ? "var(--color-warning)" : "var(--color-text)" }}
      >
        {value}
      </span>
    </div>
  );
}

export default function DepositPage() {
  return (
    <Suspense>
      <DepositContent />
    </Suspense>
  );
}
