import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

interface StatCardProps {
  label: string;
  value: string;
  sub?: string;
  delta?: string;
  deltaPositive?: boolean;
  accent?: boolean;
}

export function StatCard({ label, value, sub, delta, deltaPositive, accent }: StatCardProps) {
  return (
    <Card className="flex flex-col gap-3">
      <span className="text-xs font-medium uppercase tracking-wider" style={{ color: "var(--color-subtle)" }}>
        {label}
      </span>
      <div className="flex items-end justify-between gap-2">
        <span
          className={cn("text-2xl font-bold tabular-nums", accent && "text-primary")}
          style={accent ? { color: "var(--color-primary)" } : { color: "var(--color-text)" }}
        >
          {value}
        </span>
        {delta && (
          <Badge variant={deltaPositive ? "green" : "red"}>
            {deltaPositive ? "▲" : "▼"} {delta}
          </Badge>
        )}
      </div>
      {sub && (
        <span className="text-xs" style={{ color: "var(--color-muted)" }}>
          {sub}
        </span>
      )}
    </Card>
  );
}
