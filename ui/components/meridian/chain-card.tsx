import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatUSD, formatPct } from "@/lib/utils";

interface Protocol {
  name: string;
  allocated: bigint;
  apy?: number;
}

interface ChainCardProps {
  chain: string;
  chainId: number;
  totalAllocated: bigint;
  totalCapital: bigint;
  protocols: Protocol[];
  live?: boolean;
}

const CHAIN_COLORS: Record<string, string> = {
  "Arbitrum Sepolia": "#1814f3",
  "Base Sepolia":     "#16dbcc",
  "Ethereum Sepolia": "#10b981",
};

export function ChainCard({ chain, totalAllocated, totalCapital, protocols, live }: ChainCardProps) {
  const pct = totalCapital > 0n
    ? Number((totalAllocated * 10000n) / totalCapital) / 100
    : 0;
  const accentColor = CHAIN_COLORS[chain] ?? "var(--color-muted)";

  return (
    <Card className="flex flex-col gap-5">
      <div className="flex items-start justify-between">
        <div className="flex items-center gap-2">
          <div
            className="h-8 w-8 rounded-xl flex items-center justify-center text-white text-xs font-bold"
            style={{ background: accentColor }}
          >
            {chain.slice(0, 1)}
          </div>
          <div>
            <p className="text-sm font-semibold" style={{ color: "var(--color-text)" }}>{chain}</p>
            <p className="text-xs" style={{ color: "var(--color-muted)" }}>L2 Spoke</p>
          </div>
        </div>
        <Badge variant={live ? "green" : "gray"}>{live ? "Live" : "Idle"}</Badge>
      </div>

      <div>
        <div className="flex justify-between text-xs mb-1" style={{ color: "var(--color-muted)" }}>
          <span>Allocated</span>
          <span className="font-medium tabular-nums" style={{ color: "var(--color-text)" }}>
            {pct.toFixed(1)}%
          </span>
        </div>
        <div className="h-2 rounded-full overflow-hidden" style={{ background: "var(--color-border)" }}>
          <div
            className="h-full rounded-full transition-all"
            style={{ width: `${pct}%`, background: accentColor }}
          />
        </div>
        <p className="text-xs mt-1 tabular-nums" style={{ color: "var(--color-muted)" }}>
          {formatUSD(totalAllocated)} deployed
        </p>
      </div>

      {protocols.length > 0 && (
        <div className="flex flex-col gap-2">
          {protocols.map((p) => (
            <div
              key={p.name}
              className="flex items-center justify-between text-xs rounded-xl px-3 py-2"
              style={{ background: "var(--color-bg)" }}
            >
              <span className="font-medium" style={{ color: "var(--color-text)" }}>{p.name}</span>
              <div className="flex items-center gap-3 tabular-nums" style={{ color: "var(--color-muted)" }}>
                <span>{formatUSD(p.allocated)}</span>
                {p.apy !== undefined && (
                  <span className="font-semibold" style={{ color: "var(--color-success)" }}>
                    {formatPct(p.apy * 100)}
                  </span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
