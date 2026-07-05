"use client";

import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { injected } from "wagmi/connectors";
import { sepolia } from "wagmi/chains";
import { shortenAddress } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";

export function Topbar({ title }: { title: string }) {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  const onWrongChain = isConnected && chainId !== sepolia.id;

  return (
    <header
      className="flex items-center justify-between h-16 px-4 sm:px-8 border-b shrink-0"
      style={{ background: "var(--color-card)", borderColor: "var(--color-border)" }}
    >
      {/* Logo — only visible on mobile where sidebar is hidden */}
      <div className="flex items-center gap-2 md:hidden">
        <div
          className="h-7 w-7 rounded-lg flex items-center justify-center text-white text-xs font-bold"
          style={{ background: "var(--color-primary)" }}
        >
          M
        </div>
        <span className="font-semibold text-sm" style={{ color: "var(--color-text)" }}>
          Meridian
        </span>
      </div>

      {/* Page title — only on desktop where sidebar provides the brand */}
      <h1 className="hidden md:block text-lg font-semibold" style={{ color: "var(--color-text)" }}>
        {title}
      </h1>

      <div className="flex items-center gap-2 sm:gap-3">
        {isConnected && onWrongChain && (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => switchChain({ chainId: sepolia.id })}
            className="text-orange-600 border-orange-200 text-xs"
          >
            Wrong network
          </Button>
        )}
        {isConnected ? (
          <>
            <Badge variant="green" className="hidden sm:flex">
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 inline-block" />
              {shortenAddress(address!)}
            </Badge>
            {/* Compact address on mobile */}
            <span className="flex sm:hidden text-xs font-mono font-medium px-2 py-1 rounded-lg"
              style={{ background: "var(--color-bg)", color: "var(--color-text)" }}>
              {shortenAddress(address!)}
            </span>
            <Button variant="ghost" size="sm" onClick={() => disconnect()} className="hidden sm:flex">
              Disconnect
            </Button>
          </>
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
