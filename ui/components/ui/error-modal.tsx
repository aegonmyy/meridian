"use client";

import { useEffect } from "react";
import type { HubErrorInfo } from "@/lib/hub-errors";

interface ErrorModalProps {
  error: HubErrorInfo | null;
  onClose: () => void;
}

export function ErrorModal({ error, onClose }: ErrorModalProps) {
  useEffect(() => {
    if (!error) return;
    const handler = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [error, onClose]);

  if (!error) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      style={{ background: "rgba(0,0,0,0.35)" }}
      onClick={onClose}
    >
      <div
        className="w-full max-w-sm rounded-3xl p-6 flex flex-col gap-4"
        style={{ background: "var(--color-card)", border: "1px solid var(--color-border)" }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Icon + title */}
        <div className="flex items-start gap-3">
          <div
            className="h-9 w-9 shrink-0 rounded-xl flex items-center justify-center text-white text-base font-bold"
            style={{ background: "var(--color-danger)" }}
          >
            !
          </div>
          <div>
            <p className="font-semibold text-sm" style={{ color: "var(--color-text)" }}>
              {error.title}
            </p>
            <p className="text-xs mt-0.5" style={{ color: "var(--color-muted)" }}>
              Transaction reverted
            </p>
          </div>
        </div>

        {/* Cause */}
        <div className="rounded-xl px-4 py-3" style={{ background: "var(--color-bg)" }}>
          <p className="text-xs font-medium mb-1" style={{ color: "var(--color-muted)" }}>Cause</p>
          <p className="text-sm" style={{ color: "var(--color-text)" }}>{error.cause}</p>
        </div>

        {/* Fix */}
        <div
          className="rounded-xl px-4 py-3"
          style={{ background: "#d1fae5" }}
        >
          <p className="text-xs font-medium mb-1" style={{ color: "#065f46" }}>How to fix</p>
          <p className="text-sm" style={{ color: "#065f46" }}>{error.fix}</p>
        </div>

        <button
          onClick={onClose}
          className="btn-primary w-full justify-center"
          style={{ borderRadius: "0.75rem" }}
        >
          Dismiss
        </button>
      </div>
    </div>
  );
}
