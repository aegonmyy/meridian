"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";

const NAV_ITEMS = [
  { href: "/dashboard",   label: "Dashboard",    icon: GridIcon },
  { href: "/deposit",     label: "Deposit",      icon: ArrowDownIcon },
  { href: "/allocations", label: "Allocations",  icon: PieIcon },
  { href: "/history",     label: "History",      icon: ClockIcon },
  { href: "/operator",    label: "Operator",     icon: ToolIcon },
];

export function Sidebar() {
  const path = usePathname();

  return (
    <aside
      className="hidden md:flex flex-col w-60 shrink-0 h-screen sticky top-0 border-r py-6 px-4"
      style={{ background: "var(--color-card)", borderColor: "var(--color-border)" }}
    >
      {/* Logo */}
      <div className="flex items-center gap-2.5 px-2 mb-8">
        <div
          className="h-8 w-8 rounded-xl flex items-center justify-center text-white text-sm font-bold"
          style={{ background: "var(--color-primary)" }}
        >
          M
        </div>
        <span className="font-semibold text-base" style={{ color: "var(--color-text)" }}>
          Meridian
        </span>
      </div>

      {/* Nav */}
      <nav className="flex flex-col gap-1 flex-1">
        {NAV_ITEMS.map(({ href, label, icon: Icon }) => {
          const active = path === href;
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                "flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-colors",
                active
                  ? "text-white"
                  : "hover:bg-[var(--color-border)]"
              )}
              style={
                active
                  ? { background: "var(--color-primary)", color: "#fff" }
                  : { color: "var(--color-muted)" }
              }
            >
              <Icon size={16} />
              {label}
            </Link>
          );
        })}
      </nav>

      {/* Footer */}
      <div
        className="text-xs px-3 py-2 rounded-xl"
        style={{ color: "var(--color-subtle)", background: "var(--color-bg)" }}
      >
        Sepolia Testnet
      </div>
    </aside>
  );
}

/* ── Inline icons ────────────────────────────────────────────────────────── */
function GridIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <rect x="1" y="1" width="6" height="6" rx="1.5" fill="currentColor" opacity=".9" />
      <rect x="9" y="1" width="6" height="6" rx="1.5" fill="currentColor" opacity=".9" />
      <rect x="1" y="9" width="6" height="6" rx="1.5" fill="currentColor" opacity=".9" />
      <rect x="9" y="9" width="6" height="6" rx="1.5" fill="currentColor" opacity=".9" />
    </svg>
  );
}

function ArrowDownIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <path d="M8 2v10M3 8l5 5 5-5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function PieIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <path d="M8 8L8 1.5A6.5 6.5 0 0 1 14.5 8H8z" fill="currentColor" opacity=".8" />
      <circle cx="8" cy="8" r="6.5" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

function ClockIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <circle cx="8" cy="8" r="6.5" stroke="currentColor" strokeWidth="1.5" />
      <path d="M8 5v3.5l2.5 1.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}

function ToolIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none">
      <path d="M10.5 2.5a3 3 0 0 1 0 4.24l-5.5 5.5a1.5 1.5 0 0 1-2.12-2.12l5.5-5.5A3 3 0 0 1 10.5 2.5z" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}
