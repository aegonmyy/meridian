import { clsx, type ClassValue } from "clsx";

export function cn(...inputs: ClassValue[]) {
  return clsx(inputs);
}

export function formatUSD(value: bigint | number, decimals = 6): string {
  const n = typeof value === "bigint" ? Number(value) / 10 ** decimals : value;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(n);
}

export function formatPct(bps: number): string {
  return (bps / 100).toFixed(2) + "%";
}

export function shortenAddress(addr: string): string {
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}
