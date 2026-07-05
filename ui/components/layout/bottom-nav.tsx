"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";

const NAV_ITEMS = [
  { href: "/dashboard",   label: "Dashboard",   icon: GridIcon },
  { href: "/deposit",     label: "Deposit",     icon: ArrowDownIcon },
  { href: "/allocations", label: "Allocations", icon: PieIcon },
  { href: "/history",     label: "History",     icon: ClockIcon },
  { href: "/operator",    label: "Operator",    icon: ToolIcon },
];

export function BottomNav() {
  const path = usePathname();

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-40 grid md:hidden border-t"
      style={{
        gridTemplateColumns: `repeat(${NAV_ITEMS.length}, 1fr)`,
        height: "64px",
        background: "var(--color-card)",
        borderColor: "var(--color-border)",
      }}
    >
      {NAV_ITEMS.map(({ href, label, icon: Icon }) => {
        const active = path === href;
        return (
          <Link
            key={href}
            href={href}
            className="flex flex-col items-center justify-center gap-1 transition-colors"
            style={{ color: active ? "var(--color-primary)" : "var(--color-muted)" }}
          >
            <Icon size={20} />
            <span className="text-[10px] font-medium">{label}</span>
          </Link>
        );
      })}
    </nav>
  );
}

function GridIcon({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="none">
      <rect x="2" y="2" width="7" height="7" rx="1.5" fill="currentColor" opacity=".9" />
      <rect x="11" y="2" width="7" height="7" rx="1.5" fill="currentColor" opacity=".9" />
      <rect x="2" y="11" width="7" height="7" rx="1.5" fill="currentColor" opacity=".9" />
      <rect x="11" y="11" width="7" height="7" rx="1.5" fill="currentColor" opacity=".9" />
    </svg>
  );
}

function ArrowDownIcon({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="none">
      <path d="M10 3v12M4 10l6 6 6-6" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function PieIcon({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="none">
      <path d="M10 10L10 2.5A7.5 7.5 0 0 1 17.5 10H10z" fill="currentColor" opacity=".8" />
      <circle cx="10" cy="10" r="7.5" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}

function ClockIcon({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="none">
      <circle cx="10" cy="10" r="7.5" stroke="currentColor" strokeWidth="1.6" />
      <path d="M10 6v4.5l3 1.8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  );
}

function ToolIcon({ size = 20 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="none">
      <path d="M13 3.5a3.5 3.5 0 0 1 0 5L6.5 15A1.75 1.75 0 0 1 4 12.5L10.5 6a3.5 3.5 0 0 1 2.5-2.5z" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}
