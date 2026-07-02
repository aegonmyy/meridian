"use client";

import { useEffect } from "react";

export type ToastVariant = "success" | "info" | "warning";

export type ToastData = {
  id: string;
  variant: ToastVariant;
  title: string;
  body: string;
};

const STYLE: Record<ToastVariant, { border: string; icon: string; iconBg: string }> = {
  success: { border: "#10b981", icon: "✓", iconBg: "#10b981" },
  info:    { border: "#1814f3", icon: "i", iconBg: "#1814f3" },
  warning: { border: "#f59e0b", icon: "!", iconBg: "#f59e0b" },
};

interface EventToastProps {
  toasts: ToastData[];
  onDismiss: (id: string) => void;
}

export function EventToast({ toasts, onDismiss }: EventToastProps) {
  useEffect(() => {
    if (toasts.length === 0) return;
    const latest = toasts[toasts.length - 1];
    const t = setTimeout(() => onDismiss(latest.id), 6000);
    return () => clearTimeout(t);
  }, [toasts, onDismiss]);

  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-6 right-6 z-40 flex flex-col gap-2 max-w-xs w-full">
      {toasts.map((toast) => {
        const s = STYLE[toast.variant];
        return (
          <div
            key={toast.id}
            className="flex items-start gap-3 px-4 py-3 rounded-2xl"
            style={{
              background: "var(--color-card)",
              border: `1px solid ${s.border}`,
              boxShadow: "0 4px 12px 0 rgb(0 0 0 / 0.1)",
            }}
          >
            <div
              className="h-6 w-6 shrink-0 rounded-lg flex items-center justify-center text-white text-xs font-bold"
              style={{ background: s.iconBg }}
            >
              {s.icon}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold truncate" style={{ color: "var(--color-text)" }}>
                {toast.title}
              </p>
              <p className="text-xs mt-0.5" style={{ color: "var(--color-muted)" }}>
                {toast.body}
              </p>
            </div>
            <button
              onClick={() => onDismiss(toast.id)}
              className="text-xs shrink-0"
              style={{ color: "var(--color-subtle)" }}
            >
              ✕
            </button>
          </div>
        );
      })}
    </div>
  );
}
