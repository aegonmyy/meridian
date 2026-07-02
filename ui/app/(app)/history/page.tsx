"use client";

import { useState } from "react";
import { Topbar } from "@/components/layout/topbar";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

type TxType = "All" | "Deposit" | "Withdraw" | "Rebalance";

const ALL_TXS = [
  { id: "0x1a2b…3c4d", type: "Deposit",   amount: "+$5,000.00", chain: "Sepolia",       time: "Jun 29, 14:21", ccipMsgId: null,          status: "Confirmed" },
  { id: "0x5e6f…7a8b", type: "Rebalance", amount: "$3,000.00",  chain: "→ Arb Sepolia", time: "Jun 29, 10:05", ccipMsgId: "0xcc…aa01",   status: "Confirmed" },
  { id: "0x9c0d…1e2f", type: "Withdraw",  amount: "−$500.00",   chain: "Sepolia",       time: "Jun 28, 19:33", ccipMsgId: null,          status: "Confirmed" },
  { id: "0x3a4b…5c6d", type: "Rebalance", amount: "$1,500.00",  chain: "→ Base Sepolia",time: "Jun 28, 08:11", ccipMsgId: "0xcc…bb02",   status: "Confirmed" },
  { id: "0x7e8f…9a0b", type: "Deposit",   amount: "+$2,000.00", chain: "Sepolia",       time: "Jun 27, 16:44", ccipMsgId: null,          status: "Confirmed" },
  { id: "0xb1c2…d3e4", type: "Withdraw",  amount: "−$200.00",   chain: "Sepolia",       time: "Jun 27, 09:02", ccipMsgId: "0xcc…cc03",   status: "Pending" },
];

const TYPE_COLORS: Record<string, { bg: string; color: string }> = {
  Deposit:   { bg: "#ede9fe", color: "#4c1d95" },
  Withdraw:  { bg: "#fef3c7", color: "#92400e" },
  Rebalance: { bg: "#d1fae5", color: "#065f46" },
};

export default function HistoryPage() {
  const [filter, setFilter] = useState<TxType>("All");

  const shown = filter === "All" ? ALL_TXS : ALL_TXS.filter((t) => t.type === filter);

  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="History" />

      <main className="flex-1 p-8 flex flex-col gap-6 max-w-4xl w-full mx-auto">
        {/* Filter row */}
        <div className="flex gap-2 flex-wrap">
          {(["All", "Deposit", "Withdraw", "Rebalance"] as TxType[]).map((f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className="px-4 py-1.5 rounded-xl text-sm font-medium transition-colors"
              style={
                filter === f
                  ? { background: "var(--color-primary)", color: "#fff" }
                  : { background: "var(--color-card)", color: "var(--color-muted)", border: "1px solid var(--color-border)" }
              }
            >
              {f}
            </button>
          ))}
        </div>

        <Card padding="sm">
          {shown.length === 0 ? (
            <p className="text-sm text-center py-8" style={{ color: "var(--color-muted)" }}>
              No transactions found
            </p>
          ) : (
            <div className="flex flex-col">
              {/* Header */}
              <div
                className="grid text-xs font-medium px-3 py-2 rounded-xl mb-1"
                style={{
                  gridTemplateColumns: "2fr 1fr 1fr 1fr 1fr",
                  color: "var(--color-muted)",
                  background: "var(--color-bg)",
                }}
              >
                <span>Transaction</span>
                <span>Type</span>
                <span>Amount</span>
                <span>Chain</span>
                <span>Status</span>
              </div>

              {shown.map((tx, i) => (
                <div
                  key={tx.id}
                  className="grid items-center px-3 py-3.5 rounded-xl text-sm transition-colors hover:bg-[var(--color-bg)]"
                  style={{ gridTemplateColumns: "2fr 1fr 1fr 1fr 1fr" }}
                >
                  <div>
                    <p className="font-mono text-xs font-medium" style={{ color: "var(--color-text)" }}>
                      {tx.id}
                    </p>
                    <p className="text-xs mt-0.5" style={{ color: "var(--color-subtle)" }}>
                      {tx.time}
                      {tx.ccipMsgId && (
                        <span className="ml-2" title={`CCIP: ${tx.ccipMsgId}`}>
                          ⛓ CCIP
                        </span>
                      )}
                    </p>
                  </div>
                  <span>
                    <span
                      className="badge"
                      style={{
                        background: TYPE_COLORS[tx.type]?.bg,
                        color: TYPE_COLORS[tx.type]?.color,
                        borderRadius: "99px",
                        padding: "0.2rem 0.6rem",
                        fontSize: "0.75rem",
                        fontWeight: 600,
                      }}
                    >
                      {tx.type}
                    </span>
                  </span>
                  <span
                    className="font-semibold tabular-nums text-sm"
                    style={{
                      color: tx.amount.startsWith("+")
                        ? "var(--color-success)"
                        : tx.amount.startsWith("−")
                        ? "var(--color-danger)"
                        : "var(--color-text)",
                    }}
                  >
                    {tx.amount}
                  </span>
                  <span className="text-xs" style={{ color: "var(--color-muted)" }}>
                    {tx.chain}
                  </span>
                  <Badge variant={tx.status === "Confirmed" ? "green" : "orange"}>
                    {tx.status}
                  </Badge>
                </div>
              ))}
            </div>
          )}
        </Card>
      </main>
    </div>
  );
}
