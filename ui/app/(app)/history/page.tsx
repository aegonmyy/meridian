"use client";

import { Topbar } from "@/components/layout/topbar";
import { Card } from "@/components/ui/card";

function EmptyClockIcon() {
  return (
    <svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="20" cy="20" r="14" stroke="currentColor" strokeWidth="1.5"/>
      <path d="M20 13v7l4 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}

export default function HistoryPage() {
  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="History" />

      <main className="flex-1 p-8 flex flex-col gap-6 max-w-4xl w-full mx-auto">
        <Card padding="sm">
          <div
            className="flex flex-col items-center justify-center py-16 gap-4"
            style={{ color: "var(--color-muted)" }}
          >
            <EmptyClockIcon />
            <p className="text-sm font-medium" style={{ color: "var(--color-text)" }}>
              No transaction history yet
            </p>
            <p className="text-xs text-center max-w-xs">
              On-chain event indexing is not yet connected. Transactions will appear here once the indexer is wired up.
            </p>
          </div>
        </Card>
      </main>
    </div>
  );
}
