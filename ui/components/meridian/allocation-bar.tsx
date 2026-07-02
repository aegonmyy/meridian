interface Segment {
  label: string;
  pct: number;
  color: string;
}

interface AllocationBarProps {
  segments: Segment[];
  className?: string;
}

export function AllocationBar({ segments, className }: AllocationBarProps) {
  return (
    <div className={className}>
      <div className="flex h-4 rounded-full overflow-hidden gap-0.5">
        {segments.map((s) => (
          <div
            key={s.label}
            className="transition-all"
            style={{ width: `${s.pct}%`, background: s.color }}
            title={`${s.label}: ${s.pct.toFixed(1)}%`}
          />
        ))}
      </div>
      <div className="flex flex-wrap gap-x-4 gap-y-1.5 mt-3">
        {segments.map((s) => (
          <div key={s.label} className="flex items-center gap-1.5 text-xs" style={{ color: "var(--color-muted)" }}>
            <span className="inline-block h-2 w-2 rounded-full" style={{ background: s.color }} />
            {s.label} — {s.pct.toFixed(1)}%
          </div>
        ))}
      </div>
    </div>
  );
}
