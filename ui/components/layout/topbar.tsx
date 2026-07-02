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
      className="flex items-center justify-between h-16 px-8 border-b shrink-0"
      style={{ background: "var(--color-card)", borderColor: "var(--color-border)" }}
    >
      <h1 className="text-lg font-semibold" style={{ color: "var(--color-text)" }}>
        {title}
      </h1>

      <div className="flex items-center gap-3">
        {isConnected && onWrongChain && (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => switchChain({ chainId: sepolia.id })}
            className="text-orange-600 border-orange-200"
          >
            Switch to Sepolia
          </Button>
        )}
        {isConnected ? (
          <>
            <Badge variant="green">
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 inline-block" />
              {shortenAddress(address!)}
            </Badge>
            <Button variant="ghost" size="sm" onClick={() => disconnect()}>
              Disconnect
            </Button>
          </>
        ) : (
          <Button
            size="sm"
            onClick={() => connect({ connector: injected() })}
          >
            Connect Wallet
          </Button>
        )}
      </div>
    </header>
  );
}
