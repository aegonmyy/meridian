"use client";

import { useState } from "react";
import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { injected } from "wagmi/connectors";
import { sepolia } from "wagmi/chains";
import { shortenAddress } from "@/lib/utils";
import { Button } from "@/components/ui/button";

export function Topbar({ title }: { title: string }) {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const [copied, setCopied] = useState(false);

  const onWrongChain = isConnected && chainId !== sepolia.id;

  function copyAddress() {
    if (!address) return;
    navigator.clipboard.writeText(address).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }

  return (
    <header
      className="flex items-center justify-between h-16 px-4 sm:px-8 border-b shrink-0"
      style={{ background: "var(--color-card)", borderColor: "var(--color-border)" }}
    >
      {/* Logo icon only on mobile — no wordmark */}
      <div className="flex items-center md:hidden">
        <div
          className="h-7 w-7 rounded-lg flex items-center justify-center text-white text-xs font-bold"
          style={{ background: "var(--color-primary)" }}
        >
          M
        </div>
      </div>

      {/* Page title — only on desktop where sidebar provides the brand */}
      <h1 className="hidden md:block text-lg font-semibold" style={{ color: "var(--color-text)" }}>
        {title}
      </h1>

      <div className="flex items-center gap-2">
        {isConnected && onWrongChain && (
          <button
            onClick={() => switchChain({ chainId: sepolia.id })}
            className="text-xs px-2 py-1 rounded-lg font-medium"
            style={{ background: "#fef3c7", color: "#92400e", border: "1px solid #f59e0b" }}
          >
            Wrong network
          </button>
        )}
        {isConnected ? (
          <div className="flex items-center gap-1 rounded-xl border overflow-hidden text-xs"
            style={{ background: "var(--color-bg)", borderColor: "var(--color-border)" }}>
            {/* Green dot + address — click to copy */}
            <button
              onClick={copyAddress}
              title={copied ? "Copied!" : "Click to copy address"}
              className="flex items-center gap-1.5 px-2.5 py-1.5 font-mono transition-opacity hover:opacity-70"
              style={{ color: "var(--color-text)" }}
            >
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 shrink-0" />
              {copied ? "Copied!" : shortenAddress(address!)}
            </button>
            {/* Divider */}
            <span className="w-px self-stretch" style={{ background: "var(--color-border)" }} />
            {/* Disconnect */}
            <button
              onClick={() => disconnect()}
              className="px-2.5 py-1.5 transition-opacity hover:opacity-70"
              style={{ color: "var(--color-muted)" }}
              title="Disconnect wallet"
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path d="M4.5 6h6M8 3.5L10.5 6 8 8.5M7.5 2H2.5A.5.5 0 002 2.5v7a.5.5 0 00.5.5H7.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </button>
          </div>
        ) : (
          <Button
            size="sm"
            onClick={() => connect({ connector: injected() })}
          >
            <span className="hidden sm:inline">Connect Wallet</span>
            <span className="sm:hidden">Connect</span>
          </Button>
        )}
      </div>
    </header>
  );
}
