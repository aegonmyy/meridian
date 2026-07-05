"use client";

import { useState, useEffect } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { sepolia, arbitrumSepolia } from "wagmi/chains";

import { Topbar } from "@/components/layout/topbar";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { ErrorModal } from "@/components/ui/error-modal";
import { EventToast } from "@/components/ui/event-toast";

import {
  CONTRACTS, HUB_ABI, SPOKE_ABI, REBALANCER_ABI, AGENT_CONSUMER_ABI,
  CHAIN_SELECTORS, SELECTOR_LABELS, PROTOCOL_IDS, PROTOCOL_LABELS,
} from "@/lib/contracts";
import { parseHubError } from "@/lib/hub-errors";
import { parseSpokeError } from "@/lib/spoke-errors";
import { parseRebalancerError } from "@/lib/rebalancer-errors";
import {
  useToastQueue,
  useWatchSpokeAdded,
  useWatchSpokeRemoved,
} from "@/hooks/use-hub-events";
import { useSpokeAdapterEvents } from "@/hooks/use-spoke-events";
import { useRebalancerEvents } from "@/hooks/use-rebalancer-events";
import { useLastProposal, useWatchAllocationProposed } from "@/hooks/use-agent-consumer-events";
import {
  useCcipMessages,
  CCIP_STATE_LABELS,
  CCIP_STATE_VARIANTS,
  type CcipMessage,
} from "@/hooks/use-ccip-messages";

/* ── CCIP chain name helper ──────────────────────────────────────────────── */
function chainName(networkName?: string): string {
  if (!networkName) return "Unknown";
  if (networkName.includes("arbitrum")) return "Arb Sepolia";
  if (networkName.includes("base")) return "Base Sepolia";
  if (networkName.includes("optimism")) return "OP Sepolia";
  if (networkName.includes("sepolia")) return "Sepolia";
  return networkName.split("-").slice(-1)[0];
}

/* ── Shared field wrapper ────────────────────────────────────────────────── */
function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <label className="text-xs font-medium" style={{ color: "var(--color-text)" }}>{label}</label>
      {children}
      {hint && <p className="text-xs" style={{ color: "var(--color-subtle)" }}>{hint}</p>}
    </div>
  );
}

/* ── Text input ──────────────────────────────────────────────────────────── */
function TextInput(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      className="w-full text-sm px-3 py-2.5 rounded-xl outline-none font-mono"
      style={{
        background: "var(--color-bg)",
        border: "1px solid var(--color-border)",
        color: "var(--color-text)",
      }}
    />
  );
}

/* ── Chain selector dropdown ─────────────────────────────────────────────── */
function ChainSelect({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="w-full text-sm px-3 py-2.5 rounded-xl outline-none"
      style={{
        background: "var(--color-bg)",
        border: "1px solid var(--color-border)",
        color: "var(--color-text)",
      }}
    >
      <option value="">Select chain…</option>
      {Object.entries(CHAIN_SELECTORS).map(([name, sel]) => (
        <option key={name} value={sel.toString()}>
          {SELECTOR_LABELS[sel.toString()] ?? name} ({sel.toString().slice(0, 6)}…)
        </option>
      ))}
    </select>
  );
}

/* ── Protocol ID selector (Spoke adapters) ───────────────────────────────── */
function ProtocolSelect({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="w-full text-sm px-3 py-2.5 rounded-xl outline-none"
      style={{
        background: "var(--color-bg)",
        border: "1px solid var(--color-border)",
        color: "var(--color-text)",
      }}
    >
      <option value="">Select protocol…</option>
      {Object.entries(PROTOCOL_IDS).map(([name, id]) => (
        <option key={name} value={id}>
          {PROTOCOL_LABELS[id] ?? name}
        </option>
      ))}
    </select>
  );
}

export default function OperatorPage() {
  const { address, isConnected } = useAccount();
  const { toasts, push, dismiss } = useToastQueue();
  const [hubError, setHubError] = useState<ReturnType<typeof parseHubError>>(null);

  /* ── Agent: last on-chain proposal ────────────────────────────────────── */
  const { lastProposal } = useLastProposal();

  /* ── Hub admin inputs ──────────────────────────────────────────────────── */
  const [addSelector, setAddSelector] = useState("");
  const [addAddress, setAddAddress] = useState("");
  const [removeSelector, setRemoveSelector] = useState("");
  const [rebalancerAddr, setRebalancerAddr] = useState("");

  /* ── Spoke admin inputs ────────────────────────────────────────────────── */
  const [setAdapterProtocol, setSetAdapterProtocol] = useState("");
  const [setAdapterAddress, setSetAdapterAddress] = useState("");
  const [removeAdapterProtocol, setRemoveAdapterProtocol] = useState("");

  /* ── Rebalancer: intra-spoke rebalance inputs ──────────────────────────── */
  const [rebalSource, setRebalSource] = useState("");
  const [rebalTarget, setRebalTarget] = useState("");
  const [rebalAmount, setRebalAmount] = useState("");
  const [rebalChain, setRebalChain] = useState("");

  /* ── Rebalancer: whitelist management inputs ───────────────────────────── */
  const [wlAddChain, setWlAddChain] = useState("");
  const [wlRemoveChain, setWlRemoveChain] = useState("");
  const [wlAddProtocol, setWlAddProtocol] = useState("");
  const [wlRemoveProtocol, setWlRemoveProtocol] = useState("");

  /* ── Recovery inputs ───────────────────────────────────────────────────── */
  const [adjustAmount, setAdjustAmount] = useState("");
  const [newGasLimit, setNewGasLimit] = useState("");

  /* ── CCIP message tracking ─────────────────────────────────────────────── */
  const { messages: ccipMessages, loading: ccipLoading, error: ccipError, refetch: refetchCcip } =
    useCcipMessages(CONTRACTS.hub.address);

  // Hub + Spoke + Rebalancer errors all feed the same ErrorModal
  function onError(err: unknown) {
    const info = parseHubError(err) ?? parseSpokeError(err) ?? parseRebalancerError(err);
    if (info) setHubError(info);
  }

  /* ── Hub event watchers ────────────────────────────────────────────────── */
  useWatchSpokeAdded((selector, addr) => {
    push({ variant: "success", title: "Spoke registered", body: `Chain ${selector.toString().slice(0, 8)}… → ${addr.slice(0, 10)}…` });
    setAddSelector(""); setAddAddress("");
  });
  useWatchSpokeRemoved((selector) => {
    push({ variant: "warning", title: "Spoke disabled", body: `Chain selector ${selector.toString().slice(0, 8)}… was removed.` });
    setRemoveSelector("");
  });

  /* ── Spoke event watchers (Arb Sepolia) ────────────────────────────────── */
  useSpokeAdapterEvents(push);

  /* ── Rebalancer event watchers (Sepolia) ───────────────────────────────── */
  useRebalancerEvents(push, () => { refetchWlArbChain(); refetchWlBaseChain(); refetchWlAave(); refetchWlCompound(); refetchWlMorpho(); }, () => {});

  /* ── AgentConsumer event watchers (Sepolia) ────────────────────────────── */
  // AllocationProposed fires when the off-chain agent's proposal passes all Rebalancer guards.
  // useLastProposal() above handles state; here we also push a toast.
  useWatchAllocationProposed((caller, timestamp) => {
    push({
      variant: "info",
      title: "Agent proposal executed",
      body: `${caller.slice(0, 10)}… at ${new Date(Number(timestamp) * 1000).toLocaleTimeString()}`,
    });
  });

  /* ── Contract reads ────────────────────────────────────────────────────── */
  const { data: rebalancerOwner } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "owner",
    chainId: sepolia.id,
  });

  const { data: agentConsumerAddr } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "AGENT_CONSUMER",
    chainId: sepolia.id,
  });

  // AGENT — the off-chain cron job EOA that submits proposals
  const { data: agentEOA } = useReadContract({
    address: CONTRACTS.agentConsumer.address,
    abi: AGENT_CONSUMER_ABI,
    functionName: "AGENT",
    chainId: sepolia.id,
  });

  // Whitelist status — chains
  const { data: wlArbChain, refetch: refetchWlArbChain } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "whitelistedChains",
    args: [CHAIN_SELECTORS.arbitrumSepolia as unknown as bigint],
    chainId: sepolia.id,
    query: { refetchInterval: 60_000 },
  });
  const { data: wlBaseChain, refetch: refetchWlBaseChain } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "whitelistedChains",
    args: [CHAIN_SELECTORS.baseSepolia as unknown as bigint],
    chainId: sepolia.id,
    query: { refetchInterval: 60_000 },
  });

  // Whitelist status — protocols
  const { data: wlAave, refetch: refetchWlAave } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "whitelistedProtocols",
    args: [PROTOCOL_IDS.AAVE],
    chainId: sepolia.id,
    query: { refetchInterval: 60_000 },
  });
  const { data: wlCompound, refetch: refetchWlCompound } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "whitelistedProtocols",
    args: [PROTOCOL_IDS.COMPOUND],
    chainId: sepolia.id,
    query: { refetchInterval: 60_000 },
  });
  const { data: wlMorpho, refetch: refetchWlMorpho } = useReadContract({
    address: CONTRACTS.rebalancer.address,
    abi: REBALANCER_ABI,
    functionName: "whitelistedProtocols",
    args: [PROTOCOL_IDS.MORPHO],
    chainId: sepolia.id,
    query: { refetchInterval: 60_000 },
  });

  // Current rebalancer address
  const { data: currentRebalancer, refetch: refetchRebalancer } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "REBALANCER",
    chainId: sepolia.id,
  });

  // Hub accounting — inTransitAssets and configurable gas limit
  const { data: inTransitAssets, refetch: refetchInTransit } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "inTransitAssets",
    chainId: sepolia.id,
    query: { refetchInterval: 20_000 },
  });
  const { data: currentGasLimit, refetch: refetchGasLimit } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "outboundGasLimit",
    chainId: sepolia.id,
  });

  // Spoke check: isValidSpoke for arbSpoke address
  const { data: arbSpokeValid } = useReadContract({
    address: CONTRACTS.hub.address,
    abi: HUB_ABI,
    functionName: "isValidSpoke",
    args: [CONTRACTS.arbSpoke.address],
    chainId: sepolia.id,
    query: { refetchInterval: 30_000 },
  });

  /* ── Writes ────────────────────────────────────────────────────────────── */
  const { writeContract: addSpokeFn,       isPending: isAdding           } = useWriteContract();
  const { writeContract: removeSpokeFn,    isPending: isRemoving         } = useWriteContract();
  const { writeContract: setRebalancerFn,  isPending: isSettingRebalancer, data: setRebalancerTxHash } = useWriteContract();
  const { writeContract: setAdapterFn,     isPending: isSettingAdapter   } = useWriteContract();
  const { writeContract: removeAdapterFn,  isPending: isRemovingAdapter  } = useWriteContract();
  // Rebalancer writes
  const { writeContract: rebalanceFn,      isPending: isRebalancing      } = useWriteContract();
  const { writeContract: addChainWlFn,     isPending: isAddingChainWl    } = useWriteContract();
  const { writeContract: removeChainWlFn,  isPending: isRemovingChainWl  } = useWriteContract();
  const { writeContract: addProtoWlFn,     isPending: isAddingProtoWl    } = useWriteContract();
  const { writeContract: removeProtoWlFn,  isPending: isRemovingProtoWl  } = useWriteContract();
  // Recovery writes (onlyOwner Hub functions)
  const { writeContract: adjustTransitFn,  isPending: isAdjusting        } = useWriteContract();
  const { writeContract: setGasLimitFn,    isPending: isSettingGas       } = useWriteContract();

  const { isSuccess: rebalancerSet } = useWaitForTransactionReceipt({ hash: setRebalancerTxHash });
  useEffect(() => { if (rebalancerSet) { refetchRebalancer(); setRebalancerAddr(""); } }, [rebalancerSet, refetchRebalancer]);

  /* ── Spoke: read current adapter info ─────────────────────────────────── */
  const { data: arbAllocations } = useReadContract({
    address: CONTRACTS.arbSpoke.address,
    abi: SPOKE_ABI,
    functionName: "getAllocations",
    chainId: arbitrumSepolia.id,
    query: { refetchInterval: 30_000 },
  });

  // Check if a specific protocolId is currently active on spoke
  const { data: setAdapterInfo } = useReadContract({
    address: CONTRACTS.arbSpoke.address,
    abi: SPOKE_ABI,
    functionName: "adapters",
    args: setAdapterProtocol ? [setAdapterProtocol as `0x${string}`] : undefined,
    chainId: arbitrumSepolia.id,
    query: { enabled: !!setAdapterProtocol },
  });

  // setAdapter(bytes32 _protocolId, address _adapter) — onlyOwner on SpokeVault (Arb Sepolia)
  // Errors: ZeroAddress if _adapter == address(0)
  function handleSetAdapter() {
    if (!setAdapterProtocol || !setAdapterAddress) return;
    setAdapterFn(
      {
        address: CONTRACTS.arbSpoke.address,
        abi: SPOKE_ABI,
        functionName: "setAdapter",
        args: [setAdapterProtocol as `0x${string}`, setAdapterAddress as `0x${string}`],
        chainId: arbitrumSepolia.id,
      },
      {
        onError,
        onSuccess: () => { setSetAdapterProtocol(""); setSetAdapterAddress(""); },
      }
    );
  }

  // removeAdapter(bytes32 _protocolId) — onlyOwner on SpokeVault (Arb Sepolia)
  // Errors: AdapterNotFound if protocolId not currently active
  // NOTE: capital in this adapter is NOT recalled — emit warning in UI
  function handleRemoveAdapter() {
    if (!removeAdapterProtocol) return;
    removeAdapterFn(
      {
        address: CONTRACTS.arbSpoke.address,
        abi: SPOKE_ABI,
        functionName: "removeAdapter",
        args: [removeAdapterProtocol as `0x${string}`],
        chainId: arbitrumSepolia.id,
      },
      {
        onError,
        onSuccess: () => setRemoveAdapterProtocol(""),
      }
    );
  }

  // addSpoke(uint64 _chainSelector, address _spokeAddress)
  // Errors: ZeroAddress (spokeAddress == 0), SpokeAlreadyRegistered (address on different selector)
  function handleAddSpoke() {
    if (!addSelector || !addAddress) return;
    addSpokeFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        functionName: "addSpoke",
        args: [BigInt(addSelector), addAddress as `0x${string}`],
        chainId: sepolia.id,
      },
      { onError }
    );
  }

  // removeSpoke(uint64 _chainSelector)
  // Errors: SpokeNotFound (selector not active)
  function handleRemoveSpoke() {
    if (!removeSelector) return;
    removeSpokeFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        functionName: "removeSpoke",
        args: [BigInt(removeSelector)],
        chainId: sepolia.id,
      },
      { onError }
    );
  }

  // setRebalancer(address _rebalancer)
  // Errors: ZeroAddress (_rebalancer == 0)
  function handleSetRebalancer() {
    if (!rebalancerAddr) return;
    setRebalancerFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        functionName: "setRebalancer",
        args: [rebalancerAddr as `0x${string}`],
        chainId: sepolia.id,
      },
      {
        onError,
        onSuccess: () => push({ variant: "success", title: "Rebalancer updated", body: rebalancerAddr }),
      }
    );
  }

  // rebalance(source, target, amount, chainSelector) — Rebalancer, onlyAuthorized
  // Errors: CooldownNotElapsed, SourceEqualsTarget, ZeroAmount, ChainNotWhitelisted, ProtocolNotWhitelisted
  function handleRebalance() {
    if (!rebalSource || !rebalTarget || !rebalAmount || !rebalChain) return;
    const amountRaw = BigInt(Math.round(parseFloat(rebalAmount) * 1e6));
    rebalanceFn(
      {
        address: CONTRACTS.rebalancer.address,
        abi: REBALANCER_ABI,
        functionName: "rebalance",
        args: [
          rebalSource as `0x${string}`,
          rebalTarget as `0x${string}`,
          amountRaw,
          BigInt(rebalChain) as unknown as bigint,
        ],
        chainId: sepolia.id,
      },
      {
        onError,
        onSuccess: () => {
          push({ variant: "success", title: "Rebalance sent", body: `${PROTOCOL_LABELS[rebalSource] ?? rebalSource.slice(0, 8)} → ${PROTOCOL_LABELS[rebalTarget] ?? rebalTarget.slice(0, 8)}` });
          setRebalSource(""); setRebalTarget(""); setRebalAmount(""); setRebalChain("");
        },
      }
    );
  }

  function handleAddChainWl() {
    if (!wlAddChain) return;
    addChainWlFn(
      { address: CONTRACTS.rebalancer.address, abi: REBALANCER_ABI, functionName: "addChainToWhitelist", args: [BigInt(wlAddChain) as unknown as bigint], chainId: sepolia.id },
      { onError, onSuccess: () => setWlAddChain("") }
    );
  }
  function handleRemoveChainWl() {
    if (!wlRemoveChain) return;
    removeChainWlFn(
      { address: CONTRACTS.rebalancer.address, abi: REBALANCER_ABI, functionName: "removeChainFromWhitelist", args: [BigInt(wlRemoveChain) as unknown as bigint], chainId: sepolia.id },
      { onError, onSuccess: () => setWlRemoveChain("") }
    );
  }
  function handleAddProtoWl() {
    if (!wlAddProtocol) return;
    addProtoWlFn(
      { address: CONTRACTS.rebalancer.address, abi: REBALANCER_ABI, functionName: "addProtocolToWhitelist", args: [wlAddProtocol as `0x${string}`], chainId: sepolia.id },
      { onError, onSuccess: () => setWlAddProtocol("") }
    );
  }
  function handleRemoveProtoWl() {
    if (!wlRemoveProtocol) return;
    removeProtoWlFn(
      { address: CONTRACTS.rebalancer.address, abi: REBALANCER_ABI, functionName: "removeProtocolFromWhitelist", args: [wlRemoveProtocol as `0x${string}`], chainId: sepolia.id },
      { onError, onSuccess: () => setWlRemoveProtocol("") }
    );
  }

  function handleAdjustInTransit() {
    if (!adjustAmount) return;
    const rawAmount = BigInt(Math.round(parseFloat(adjustAmount) * 1e6));
    adjustTransitFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        functionName: "adjustInTransitAssets",
        args: [rawAmount],
        chainId: sepolia.id,
      },
      {
        onError,
        onSuccess: () => {
          push({ variant: "success", title: "inTransitAssets adjusted", body: `New value: ${adjustAmount} USDC` });
          setAdjustAmount("");
          setTimeout(() => refetchInTransit(), 3000);
        },
      }
    );
  }

  function handleSetGasLimit() {
    if (!newGasLimit) return;
    setGasLimitFn(
      {
        address: CONTRACTS.hub.address,
        abi: HUB_ABI,
        functionName: "setOutboundGasLimit",
        args: [Number(newGasLimit)],
        chainId: sepolia.id,
      },
      {
        onError,
        onSuccess: () => {
          push({ variant: "success", title: "Gas limit updated", body: `New limit: ${Number(newGasLimit).toLocaleString()}` });
          setNewGasLimit("");
          setTimeout(() => refetchGasLimit(), 3000);
        },
      }
    );
  }

  // Pre-flight checks for the intra-spoke rebalance form
  const rebalancePreflight = (() => {
    if (!rebalSource || !rebalTarget) return null;
    if (rebalSource === rebalTarget) return "Source and target must differ (SourceEqualsTarget)";
    if (!rebalAmount || parseFloat(rebalAmount) <= 0) return "Enter a non-zero amount (ZeroAmount)";
    if (!rebalChain) return null;
    const chainLabel = SELECTOR_LABELS[rebalChain] ?? rebalChain;
    const isChainWl = rebalChain === CHAIN_SELECTORS.arbitrumSepolia.toString() ? wlArbChain
                    : rebalChain === CHAIN_SELECTORS.baseSepolia.toString() ? wlBaseChain
                    : undefined;
    if (isChainWl === false) return `${chainLabel} is not whitelisted (ChainNotWhitelisted)`;
    const sourceWl = rebalSource === PROTOCOL_IDS.AAVE ? wlAave : rebalSource === PROTOCOL_IDS.COMPOUND ? wlCompound : rebalSource === PROTOCOL_IDS.MORPHO ? wlMorpho : undefined;
    if (sourceWl === false) return `${PROTOCOL_LABELS[rebalSource] ?? "Source protocol"} is not whitelisted (ProtocolNotWhitelisted)`;
    const targetWl = rebalTarget === PROTOCOL_IDS.AAVE ? wlAave : rebalTarget === PROTOCOL_IDS.COMPOUND ? wlCompound : rebalTarget === PROTOCOL_IDS.MORPHO ? wlMorpho : undefined;
    if (targetWl === false) return `${PROTOCOL_LABELS[rebalTarget] ?? "Target protocol"} is not whitelisted (ProtocolNotWhitelisted)`;
    return null;
  })();

  return (
    <div className="flex flex-col flex-1 overflow-auto">
      <Topbar title="Operator" />

      <main className="flex-1 p-8 flex flex-col gap-6 max-w-4xl w-full mx-auto">

        {/* Rebalancer status strip */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <Card padding="sm">
            <p className="text-xs font-medium mb-2" style={{ color: "var(--color-muted)" }}>Rebalancer Status</p>
            <Badge variant="green">No cooldown</Badge>
          </Card>
          <Card padding="sm">
            <p className="text-xs font-medium mb-2" style={{ color: "var(--color-muted)" }}>In Transit</p>
            <p className="text-lg font-bold" style={{ color: inTransitAssets && inTransitAssets > 0n ? "#f59e0b" : "var(--color-text)" }}>
              ${inTransitAssets !== undefined ? (Number(inTransitAssets) / 1e6).toFixed(2) : "—"}
            </p>
          </Card>
          <Card padding="sm">
            <p className="text-xs font-medium mb-2" style={{ color: "var(--color-muted)" }}>CCIP Gas Limit</p>
            <p className="text-lg font-bold" style={{ color: "var(--color-text)" }}>
              {currentGasLimit !== undefined ? Number(currentGasLimit).toLocaleString() : "—"}
            </p>
          </Card>
        </div>

        {/* ── CCIP Transfer Status ─────────────────────────────────────── */}
        {/* Polls the CCIP Explorer API for all messages sent from the Hub.
            State 0=Untouched, 1=In Progress, 2=Success, 3=Failure.
            FAILURE means the spoke received the message but execution reverted —
            tokens sit in the OffRamp until manually executed or abandoned. */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              CCIP Transfer Status
            </CardTitle>
            <div className="flex items-center gap-2">
              {ccipLoading && <Badge variant="gray">Syncing…</Badge>}
              {!ccipLoading && <Badge variant="gray">{ccipMessages.length} messages</Badge>}
              <button
                onClick={() => refetchCcip()}
                className="text-xs px-2 py-1 rounded-lg"
                style={{ background: "var(--color-bg)", color: "var(--color-muted)", border: "1px solid var(--color-border)" }}
              >
                Refresh
              </button>
            </div>
          </CardHeader>

          {ccipError && (
            <div className="rounded-xl px-3 py-2.5 text-xs mb-3" style={{ background: "#fef3c7", color: "#92400e" }}>
              CCIP Explorer unavailable: {ccipError} —{" "}
              <a
                href={`https://ccip.chain.link/address/${CONTRACTS.hub.address}`}
                target="_blank"
                rel="noreferrer"
                style={{ textDecoration: "underline" }}
              >
                view manually
              </a>
            </div>
          )}

          {ccipMessages.length === 0 && !ccipLoading && !ccipError ? (
            <p className="text-xs" style={{ color: "var(--color-muted)" }}>
              No messages found for Hub address. Messages appear once Hub sends to a spoke.
            </p>
          ) : (
            <div className="flex flex-col gap-2">
              {ccipMessages.map((msg: CcipMessage) => {
                const usdcAmount = msg.tokenAmounts?.[0]?.amount;
                const usdc = usdcAmount ? (Number(usdcAmount) / 1e6).toFixed(2) : null;
                const stateLabel = CCIP_STATE_LABELS[msg.state] ?? "Unknown";
                const stateVariant = CCIP_STATE_VARIANTS[msg.state] ?? "gray";
                const explorerUrl = `https://ccip.chain.link/msg/${msg.messageId}`;
                return (
                  <div
                    key={msg.messageId}
                    className="rounded-xl px-3 py-2.5 flex items-start justify-between gap-3 text-xs"
                    style={{ background: "var(--color-bg)" }}
                  >
                    <div className="flex flex-col gap-1 min-w-0">
                      <div className="flex items-center gap-2 min-w-0">
                        <span className="font-mono text-xs truncate" style={{ color: "var(--color-subtle)" }}>
                          {msg.messageId.slice(0, 10)}…{msg.messageId.slice(-6)}
                        </span>
                        <span className="shrink-0" style={{ color: "var(--color-muted)" }}>→ {chainName(msg.destNetworkName)}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        {usdc && (
                          <span className="font-semibold" style={{ color: "var(--color-text)" }}>${usdc} USDC</span>
                        )}
                        <span style={{ color: "var(--color-muted)" }}>
                          {msg.sendTimestamp ? new Date(msg.sendTimestamp).toLocaleTimeString() : ""}
                        </span>
                      </div>
                    </div>
                    <div className="flex items-center gap-2 shrink-0">
                      <Badge variant={stateVariant}>{stateLabel}</Badge>
                      <a
                        href={explorerUrl}
                        target="_blank"
                        rel="noreferrer"
                        title={msg.state === 3 ? "Open CCIP Explorer → click 'Execute manually' to retry" : "View on CCIP Explorer"}
                        className="text-xs px-2 py-1 rounded-lg"
                        style={{
                          background: msg.state === 3 ? "var(--color-error-bg, #fee)" : "var(--color-surface)",
                          color: msg.state === 3 ? "#dc2626" : "var(--color-primary)",
                          border: `1px solid ${msg.state === 3 ? "#fca5a5" : "var(--color-border)"}`,
                        }}
                      >
                        {msg.state === 3 ? "Retry ↗" : "Explorer ↗"}
                      </a>
                    </div>
                  </div>
                );
              })}
            </div>
          )}

          {ccipMessages.some((m: CcipMessage) => m.state === 3) && (
            <p className="mt-2 text-xs px-1" style={{ color: "var(--color-muted)" }}>
              <strong style={{ color: "#dc2626" }}>Failure:</strong> Click <strong>Retry ↗</strong> → CCIP Explorer will show an &ldquo;Execute manually&rdquo; button that re-submits the message to the OffRamp on the destination chain. After all messages are confirmed failed/unrecoverable, use the Recovery panel below to zero out <code>inTransitAssets</code>.
            </p>
          )}

          <div className="mt-3 text-xs" style={{ color: "var(--color-muted)" }}>
            Polls every 30s · Hub: <span className="font-mono">{CONTRACTS.hub.address.slice(0, 10)}…</span>
            {" · "}
            <a
              href={`https://ccip.chain.link/address/${CONTRACTS.hub.address}`}
              target="_blank"
              rel="noreferrer"
              style={{ color: "var(--color-primary)", textDecoration: "underline" }}
            >
              View all on CCIP Explorer
            </a>
          </div>
        </Card>

        {/* ── Rebalancer: whitelist status ──────────────────────────────── */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Rebalancer Whitelist
            </CardTitle>
            <Badge variant="gray">Sepolia</Badge>
          </CardHeader>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <p className="text-xs font-medium mb-2" style={{ color: "var(--color-muted)" }}>Chains</p>
              <div className="flex flex-col gap-1.5">
                {[
                  { label: "Arbitrum Sepolia", val: wlArbChain },
                  { label: "Base Sepolia",     val: wlBaseChain },
                ].map(({ label, val }) => (
                  <div key={label} className="flex items-center justify-between rounded-lg px-2.5 py-2 text-xs"
                    style={{ background: "var(--color-bg)" }}>
                    <span style={{ color: "var(--color-text)" }}>{label}</span>
                    <Badge variant={val === true ? "green" : val === false ? "red" : "gray"}>
                      {val === true ? "Approved" : val === false ? "Blocked" : "—"}
                    </Badge>
                  </div>
                ))}
              </div>
            </div>
            <div>
              <p className="text-xs font-medium mb-2" style={{ color: "var(--color-muted)" }}>Protocols</p>
              <div className="flex flex-col gap-1.5">
                {[
                  { label: "Aave V3",      val: wlAave     },
                  { label: "Compound V3",  val: wlCompound  },
                  { label: "Morpho",       val: wlMorpho    },
                ].map(({ label, val }) => (
                  <div key={label} className="flex items-center justify-between rounded-lg px-2.5 py-2 text-xs"
                    style={{ background: "var(--color-bg)" }}>
                    <span style={{ color: "var(--color-text)" }}>{label}</span>
                    <Badge variant={val === true ? "green" : val === false ? "red" : "gray"}>
                      {val === true ? "Approved" : val === false ? "Blocked" : "—"}
                    </Badge>
                  </div>
                ))}
              </div>
            </div>
          </div>
          <div className="mt-3 flex flex-col gap-1 text-xs" style={{ color: "var(--color-muted)" }}>
            <div className="flex items-center gap-1 min-w-0">
              <span className="shrink-0">Owner:</span>
              <span className="font-mono truncate" style={{ color: "var(--color-text)" }}>{rebalancerOwner ?? "—"}</span>
            </div>
            <div className="flex items-center gap-1 min-w-0">
              <span className="shrink-0">Agent:</span>
              <span className="font-mono truncate" style={{ color: "var(--color-text)" }}>{agentConsumerAddr ?? "—"}</span>
            </div>
          </div>
        </Card>

        {/* ── Rebalancer: intra-spoke rebalance ─────────────────────────── */}
        {/* rebalance(bytes32 source, bytes32 target, uint256 amount, uint64 chainSelector)
            Moves capital between two adapters on the same spoke without crossing chains.
            Guards: cooldown, source≠target, amount>0, chain whitelisted, both protocols whitelisted. */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Intra-Spoke Rebalance
            </CardTitle>
            <Badge variant="blue">Rebalancer · onlyAuthorized</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <div className="grid grid-cols-2 gap-3">
              <Field label="From Protocol" hint="Source adapter to withdraw from.">
                <ProtocolSelect value={rebalSource} onChange={setRebalSource} />
              </Field>
              <Field label="To Protocol" hint="Target adapter to deposit into.">
                <ProtocolSelect value={rebalTarget} onChange={setRebalTarget} />
              </Field>
            </div>
            <Field label="Amount (USDC)" hint="Absolute USDC amount to move between adapters on the same spoke.">
              <TextInput
                type="number"
                min="0"
                step="1"
                placeholder="e.g. 1000"
                value={rebalAmount}
                onChange={(e) => setRebalAmount(e.target.value)}
              />
            </Field>
            <Field label="Spoke Chain" hint="Chain where both adapters are deployed.">
              <ChainSelect value={rebalChain} onChange={setRebalChain} />
            </Field>
            {rebalancePreflight && (
              <p className="text-xs rounded-xl px-3 py-2.5" style={{ background: "#fef3c7", color: "#92400e" }}>
                {rebalancePreflight}
              </p>
            )}
            <Button
              className="w-full justify-center"
              disabled={!isConnected || !!rebalancePreflight || isRebalancing || !rebalSource || !rebalTarget || !rebalAmount || !rebalChain}
              loading={isRebalancing}
              onClick={handleRebalance}
            >
              Send Intra-Spoke Rebalance
            </Button>
          </div>
        </Card>

        {/* Agent proposal log — last AllocationProposed event from AgentConsumer */}
        {/* The agent (off-chain cron EOA) calls AgentConsumer.proposeAllocation() which
            immediately forwards to Rebalancer — there is no on-chain approval queue.
            AllocationProposed is emitted only after the Rebalancer fully accepts the proposal. */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Agent Activity
            </CardTitle>
            <Badge variant={lastProposal ? "green" : "gray"}>
              {lastProposal ? "Proposal seen" : "Watching…"}
            </Badge>
          </CardHeader>

          {lastProposal ? (
            <div className="flex flex-col gap-3">
              <div className="rounded-xl px-4 py-3 flex flex-col gap-1.5 text-xs"
                style={{ background: "var(--color-bg)" }}>
                <div className="flex justify-between">
                  <span style={{ color: "var(--color-muted)" }}>Caller</span>
                  <span className="font-mono" style={{ color: "var(--color-text)" }}>
                    {lastProposal.caller.slice(0, 10)}…{lastProposal.caller.slice(-6)}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span style={{ color: "var(--color-muted)" }}>Executed at</span>
                  <span style={{ color: "var(--color-text)" }}>
                    {new Date(lastProposal.timestamp * 1000).toLocaleString()}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span style={{ color: "var(--color-muted)" }}>Via</span>
                  <span style={{ color: "var(--color-text)" }}>AgentConsumer → Rebalancer → Hub</span>
                </div>
              </div>
              <p className="text-xs" style={{ color: "var(--color-muted)" }}>
                Full allocation details are available on Rebalancer&apos;s CCIP message to the spoke.
              </p>
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              <p className="text-xs" style={{ color: "var(--color-muted)" }}>
                No allocation proposal seen this session. The off-chain agent submits proposals
                automatically on its schedule — they execute immediately if all Rebalancer guards pass.
              </p>
              <div className="rounded-xl px-3 py-2.5 text-xs" style={{ background: "var(--color-bg)" }}>
                <span style={{ color: "var(--color-muted)" }}>Agent EOA: </span>
                <span className="font-mono break-all" style={{ color: "var(--color-text)" }}>
                  {agentEOA ?? "Loading…"}
                </span>
              </div>
            </div>
          )}
        </Card>

        {/* ── Recovery: adjust inTransitAssets ─────────────────────────── */}
        {/* Use when CCIP messages have FAILURE state and cannot be retried.
            adjustInTransitAssets corrects Hub accounting without moving USDC.
            Actual USDC stuck in OffRamp must be handled separately via CCIP Explorer
            manual execution (if the spoke can receive) or OffRamp claim. */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Recovery
            </CardTitle>
            <Badge variant="red">Emergency · onlyOwner</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <div
              className="rounded-xl px-4 py-3 text-xs"
              style={{ background: "#fef3c7", border: "1px solid #f59e0b" }}
            >
              <p className="font-semibold mb-1" style={{ color: "#92400e" }}>When to use this</p>
              <p style={{ color: "#92400e" }}>
                If CCIP Explorer shows a FAILURE state for a Hub→Spoke message, the Hub's
                {" "}<code>inTransitAssets</code> is stuck and inflates share prices. Set it to 0
                (or the correct amount) after confirming funds are unrecoverable.
                <br /><br />
                Current: <strong>${inTransitAssets !== undefined ? (Number(inTransitAssets) / 1e6).toFixed(2) : "…"} USDC</strong> in transit
              </p>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="flex flex-col gap-3">
                <Field
                  label="New inTransitAssets (USDC)"
                  hint="Set to 0 after full failure recovery. Use exact amount if only some messages failed."
                >
                  <TextInput
                    type="number"
                    min="0"
                    step="0.01"
                    placeholder="0"
                    value={adjustAmount}
                    onChange={(e) => setAdjustAmount(e.target.value)}
                  />
                </Field>
                <Button
                  variant="ghost"
                  className="w-full justify-center"
                  style={{ borderColor: "var(--color-danger)", color: "var(--color-danger)" }}
                  disabled={!isConnected || !adjustAmount || isAdjusting}
                  loading={isAdjusting}
                  onClick={handleAdjustInTransit}
                >
                  Adjust inTransitAssets
                </Button>
              </div>

              <div className="flex flex-col gap-3">
                <Field
                  label="CCIP Outbound Gas Limit"
                  hint="Increase if spoke messages fail with out-of-gas. Default: 1,500,000."
                >
                  <TextInput
                    type="number"
                    min="100000"
                    step="100000"
                    placeholder={currentGasLimit !== undefined ? Number(currentGasLimit).toString() : "1500000"}
                    value={newGasLimit}
                    onChange={(e) => setNewGasLimit(e.target.value)}
                  />
                </Field>
                <Button
                  className="w-full justify-center"
                  disabled={!isConnected || !newGasLimit || isSettingGas}
                  loading={isSettingGas}
                  onClick={handleSetGasLimit}
                >
                  Update Gas Limit
                </Button>
              </div>
            </div>
          </div>
        </Card>

        {/* ── Admin: addSpoke ──────────────────────────────────────────── */}
        {/* addSpoke(uint64 _chainSelector, address _spokeAddress) — onlyOwner
            Errors: ZeroAddress if spokeAddress is 0x0
                    SpokeAlreadyRegistered if address already on different selector */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Add / Update Spoke
            </CardTitle>
            <Badge variant="blue">onlyOwner</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <Field
              label="Chain Selector"
              hint="CCIP chain selector of the spoke chain."
            >
              <ChainSelect value={addSelector} onChange={setAddSelector} />
            </Field>
            <Field
              label="Spoke Address"
              hint="Address of the SpokeVault contract deployed on that chain."
            >
              <TextInput
                placeholder="0x…"
                value={addAddress}
                onChange={(e) => setAddAddress(e.target.value)}
              />
            </Field>
            <Button
              className="w-full justify-center"
              disabled={!isConnected || !addSelector || !addAddress || isAdding}
              loading={isAdding}
              onClick={handleAddSpoke}
            >
              Add Spoke
            </Button>
          </div>
        </Card>

        {/* ── Admin: removeSpoke ───────────────────────────────────────── */}
        {/* removeSpoke(uint64 _chainSelector) — onlyOwner
            Errors: SpokeNotFound if selector not active */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Remove Spoke
            </CardTitle>
            <Badge variant="red">Emergency</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <Field
              label="Chain Selector"
              hint="Disables this spoke. Capital already deployed is NOT recalled automatically."
            >
              <ChainSelect value={removeSelector} onChange={setRemoveSelector} />
            </Field>
            <Button
              variant="ghost"
              className="w-full justify-center"
              style={{ borderColor: "var(--color-danger)", color: "var(--color-danger)" }}
              disabled={!isConnected || !removeSelector || isRemoving}
              loading={isRemoving}
              onClick={handleRemoveSpoke}
            >
              Disable Spoke
            </Button>
          </div>
        </Card>

        {/* ── Admin: setRebalancer ─────────────────────────────────────── */}
        {/* setRebalancer(address _rebalancer) — onlyOwner
            Errors: ZeroAddress if _rebalancer == address(0) */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Set Rebalancer
            </CardTitle>
            <Badge variant="blue">onlyOwner</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <div className="rounded-xl px-3 py-2" style={{ background: "var(--color-bg)" }}>
              <p className="text-xs" style={{ color: "var(--color-muted)" }}>Current</p>
              <p className="text-xs font-mono mt-0.5 break-all" style={{ color: "var(--color-text)" }}>
                {currentRebalancer ?? "—"}
              </p>
            </div>
            <Field
              label="New Rebalancer Address"
              hint="Only the Rebalancer can move capital between hub and spokes."
            >
              <TextInput
                placeholder="0x…"
                value={rebalancerAddr}
                onChange={(e) => setRebalancerAddr(e.target.value)}
              />
            </Field>
            <Button
              className="w-full justify-center"
              disabled={!isConnected || !rebalancerAddr || isSettingRebalancer}
              loading={isSettingRebalancer}
              onClick={handleSetRebalancer}
            >
              Update Rebalancer
            </Button>
            {rebalancerSet && (
              <p className="text-xs text-center font-medium" style={{ color: "var(--color-success)" }}>
                ✓ Rebalancer updated
              </p>
            )}
          </div>
        </Card>

        {/* ═══════════════════════════════════════════════════════════════
            SPOKE ADMIN — SpokeVault on Arbitrum Sepolia
            ═══════════════════════════════════════════════════════════════ */}

        {/* ── Spoke: current adapter allocations ──────────────────────── */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Arb Spoke — Active Adapters
            </CardTitle>
            <Badge variant={arbAllocations && arbAllocations.length > 0 ? "green" : "gray"}>
              Arbitrum Sepolia
            </Badge>
          </CardHeader>
          {arbAllocations && arbAllocations.filter(a => a.protocolId !== "0x0000000000000000000000000000000000000000000000000000000000000000").length > 0
            ? (
              <div className="flex flex-col gap-2">
                {arbAllocations
                  .filter(a => a.protocolId !== "0x0000000000000000000000000000000000000000000000000000000000000000")
                  .map((a) => {
                    const label = PROTOCOL_LABELS[a.protocolId] ?? a.protocolId.slice(0, 10) + "…";
                    return (
                      <div key={a.protocolId} className="flex items-center justify-between text-xs rounded-xl px-3 py-2.5"
                        style={{ background: "var(--color-bg)" }}>
                        <div className="flex items-center gap-2">
                          <span className="font-mono text-xs" style={{ color: "var(--color-subtle)" }}>
                            {a.protocolId.slice(0, 8)}…
                          </span>
                          <span className="font-medium" style={{ color: "var(--color-text)" }}>{label}</span>
                        </div>
                        <span className="font-semibold tabular-nums" style={{ color: "var(--color-primary)" }}>
                          ${(Number(a.balance) / 1e6).toFixed(2)}
                        </span>
                      </div>
                    );
                  })}
              </div>
            ) : (
              <p className="text-xs" style={{ color: "var(--color-muted)" }}>
                {arbAllocations ? "No adapters registered on Arb Sepolia." : "Loading…"}
              </p>
            )
          }
        </Card>

        {/* ── Spoke: setAdapter ─────────────────────────────────────────── */}
        {/* setAdapter(bytes32 _protocolId, address _adapter) — onlyOwner on SpokeVault
            Errors: ZeroAddress if _adapter == address(0) */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Register / Update Adapter
            </CardTitle>
            <Badge variant="blue">Arb Spoke · onlyOwner</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <Field
              label="Protocol"
              hint="keccak256 of the protocol name — must match what the Rebalancer uses."
            >
              <ProtocolSelect value={setAdapterProtocol} onChange={setSetAdapterProtocol} />
            </Field>
            {setAdapterProtocol && setAdapterInfo && (
              <div className="rounded-xl px-3 py-2" style={{ background: "var(--color-bg)" }}>
                <p className="text-xs" style={{ color: "var(--color-muted)" }}>Current adapter</p>
                <p className="text-xs font-mono mt-0.5 break-all" style={{ color: "var(--color-text)" }}>
                  {setAdapterInfo[1]
                    ? setAdapterInfo[0]
                    : "Not registered"}
                </p>
              </div>
            )}
            <Field
              label="Adapter Address (IYieldSource)"
              hint="The deployed adapter contract on Arbitrum Sepolia."
            >
              <TextInput
                placeholder="0x…"
                value={setAdapterAddress}
                onChange={(e) => setSetAdapterAddress(e.target.value)}
              />
            </Field>
            <Button
              className="w-full justify-center"
              disabled={!isConnected || !setAdapterProtocol || !setAdapterAddress || isSettingAdapter}
              loading={isSettingAdapter}
              onClick={handleSetAdapter}
            >
              Register Adapter
            </Button>
          </div>
        </Card>

        {/* ── Spoke: removeAdapter ──────────────────────────────────────── */}
        {/* removeAdapter(bytes32 _protocolId) — onlyOwner on SpokeVault
            Errors: AdapterNotFound if protocolId not currently active
            IMPORTANT: capital in this adapter is NOT recalled automatically */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Disable Adapter
            </CardTitle>
            <Badge variant="red">Emergency · Arb Spoke</Badge>
          </CardHeader>
          <div className="flex flex-col gap-4">
            <div
              className="rounded-xl px-4 py-3 text-xs"
              style={{ background: "#fef3c7", border: "1px solid #f59e0b" }}
            >
              <p className="font-semibold mb-0.5" style={{ color: "#92400e" }}>Warning</p>
              <p style={{ color: "#92400e" }}>
                Capital deployed in this adapter is NOT recalled. A WITHDRAW_AMOUNT instruction from Hub
                must be sent separately to recover funds.
              </p>
            </div>
            <Field
              label="Protocol"
              hint="Select the adapter to disable. Must currently be active."
            >
              <ProtocolSelect value={removeAdapterProtocol} onChange={setRemoveAdapterProtocol} />
            </Field>
            <Button
              variant="ghost"
              className="w-full justify-center"
              style={{ borderColor: "var(--color-danger)", color: "var(--color-danger)" }}
              disabled={!isConnected || !removeAdapterProtocol || isRemovingAdapter}
              loading={isRemovingAdapter}
              onClick={handleRemoveAdapter}
            >
              Disable Adapter
            </Button>
          </div>
        </Card>

        {/* ═══════════════════════════════════════════════════════════════
            REBALANCER ADMIN — whitelist management
            ═══════════════════════════════════════════════════════════════ */}

        {/* ── Add / remove chain whitelist ──────────────────────────────── */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Chain Whitelist
            </CardTitle>
            <Badge variant="blue">Rebalancer · onlyAuthorized</Badge>
          </CardHeader>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div className="flex flex-col gap-3">
              <Field label="Approve chain" hint="Capital can only be deployed to whitelisted chains.">
                <ChainSelect value={wlAddChain} onChange={setWlAddChain} />
              </Field>
              <Button
                className="w-full justify-center"
                disabled={!isConnected || !wlAddChain || isAddingChainWl}
                loading={isAddingChainWl}
                onClick={handleAddChainWl}
              >
                Approve Chain
              </Button>
            </div>
            <div className="flex flex-col gap-3">
              <Field label="Remove chain" hint="Blocks new capital deployments. Existing funds are NOT recalled.">
                <ChainSelect value={wlRemoveChain} onChange={setWlRemoveChain} />
              </Field>
              <Button
                variant="ghost"
                className="w-full justify-center"
                style={{ borderColor: "var(--color-danger)", color: "var(--color-danger)" }}
                disabled={!isConnected || !wlRemoveChain || isRemovingChainWl}
                loading={isRemovingChainWl}
                onClick={handleRemoveChainWl}
              >
                Remove Chain
              </Button>
            </div>
          </div>
        </Card>

        {/* ── Add / remove protocol whitelist ──────────────────────────── */}
        <Card>
          <CardHeader>
            <CardTitle style={{ color: "var(--color-text)", fontWeight: 600, fontSize: "0.875rem" }}>
              Protocol Whitelist
            </CardTitle>
            <Badge variant="blue">Rebalancer · onlyAuthorized</Badge>
          </CardHeader>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div className="flex flex-col gap-3">
              <Field label="Approve protocol" hint="Capital can only be deployed to whitelisted protocols.">
                <ProtocolSelect value={wlAddProtocol} onChange={setWlAddProtocol} />
              </Field>
              <Button
                className="w-full justify-center"
                disabled={!isConnected || !wlAddProtocol || isAddingProtoWl}
                loading={isAddingProtoWl}
                onClick={handleAddProtoWl}
              >
                Approve Protocol
              </Button>
            </div>
            <div className="flex flex-col gap-3">
              <Field label="Remove protocol" hint="Blocks new allocations. Use Spoke removeAdapter() to fully exit.">
                <ProtocolSelect value={wlRemoveProtocol} onChange={setWlRemoveProtocol} />
              </Field>
              <Button
                variant="ghost"
                className="w-full justify-center"
                style={{ borderColor: "var(--color-danger)", color: "var(--color-danger)" }}
                disabled={!isConnected || !wlRemoveProtocol || isRemovingProtoWl}
                loading={isRemovingProtoWl}
                onClick={handleRemoveProtoWl}
              >
                Remove Protocol
              </Button>
            </div>
          </div>
        </Card>

        {/* Contract addresses */}
        <Card padding="sm">
          <p className="text-xs font-semibold mb-3" style={{ color: "var(--color-text)" }}>
            Deployed Addresses
          </p>
          <div className="flex flex-col gap-2">
            {([
              ["Hub (Sepolia)",            CONTRACTS.hub.address],
              ["Rebalancer (Sepolia)",     CONTRACTS.rebalancer.address],
              ["AgentConsumer (Sepolia)",  CONTRACTS.agentConsumer.address],
              ["Agent EOA",               agentEOA ?? "—"],
              ["Arb Spoke",               CONTRACTS.arbSpoke.address],
            ] as [string, string][]).map(([label, addr]) => (
              <div key={label} className="flex justify-between items-center text-xs">
                <span style={{ color: "var(--color-muted)" }}>{label}</span>
                <div className="flex items-center gap-2">
                  <span className="font-mono" style={{ color: "var(--color-text)" }}>
                    {addr.slice(0, 10)}…{addr.slice(-6)}
                  </span>
                  {label === "Arb Spoke" && addr !== "—" && (
                    <Badge variant={arbSpokeValid ? "green" : "gray"}>
                      {arbSpokeValid ? "Active" : "Inactive"}
                    </Badge>
                  )}
                </div>
              </div>
            ))}
          </div>
        </Card>

      </main>

      {/* Error modal — Hub + Spoke custom errors decoded and explained */}
      <ErrorModal error={hubError} onClose={() => setHubError(null)} />

      {/* Event toasts — SpokeAdded, SpokeRemoved, AdapterSet, AdapterRemoved */}
      <EventToast toasts={toasts} onDismiss={dismiss} />
    </div>
  );
}
