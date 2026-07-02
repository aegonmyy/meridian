import type { HubErrorInfo } from "./hub-errors";

export const REBALANCER_ERROR_MAP: Record<string, HubErrorInfo> = {
  NotAuthorized: {
    title: "Not authorised",
    cause: "Your wallet is neither the Rebalancer owner nor the AgentConsumer contract.",
    fix: "Connect with the owner wallet or the AgentConsumer address.",
  },
  CooldownNotElapsed: {
    title: "Cooldown not elapsed",
    cause: "Less than 24 hours have passed since the last rebalance. The Rebalancer enforces a 24-hour cooldown between operations.",
    fix: "Wait for the cooldown timer to reach 00:00:00 before executing.",
  },
  SourceEqualsTarget: {
    title: "Source equals target",
    cause: "The source and target protocol IDs are identical — moving capital from a protocol to itself is a no-op.",
    fix: "Select two different protocols for the rebalance.",
  },
  ZeroAmount: {
    title: "Zero amount",
    cause: "The rebalance amount is 0 USDC.",
    fix: "Enter a non-zero USDC amount.",
  },
  BelowThreshold: {
    title: "APY gain below threshold",
    cause: "The proposed allocation's weighted APY does not beat the current allocation by at least 50 bps (0.5%). The Rebalancer requires a meaningful improvement to justify CCIP fees.",
    fix: "Wait for a larger APY spread, or adjust the proposed allocations so the improvement exceeds 50 bps.",
  },
  MaxSingleMoveExceeded: {
    title: "Single move cap exceeded",
    cause: "One or more allocations would move more than 30% of total TVL in a single operation.",
    fix: "Reduce the per-protocol allocation so no single entry exceeds 3,000 bps (30%) of TVL.",
  },
  ChainNotWhitelisted: {
    title: "Chain not whitelisted",
    cause: "The target chain selector has not been approved on the Rebalancer.",
    fix: "Call addChainToWhitelist() with the correct CCIP chain selector before deploying capital to this chain.",
  },
  ProtocolNotWhitelisted: {
    title: "Protocol not whitelisted",
    cause: "One of the protocol IDs in the proposal or rebalance has not been approved on the Rebalancer.",
    fix: "Call addProtocolToWhitelist() with the correct keccak256 protocol ID.",
  },
  InvalidAllocation: {
    title: "Invalid allocation",
    cause: "The proposed allocations failed one or more on-chain checks: allocations must sum to exactly 10,000 bps, each non-zero entry must be ≥ 500 bps, no single market may exceed 6,000 bps, and no chain may exceed 8,000 bps.",
    fix: "Adjust the allocation percentages so they sum to 100%, every entry is at least 5%, no protocol gets more than 60%, and no chain gets more than 80%.",
  },
  InvalidConstructorArguments: {
    title: "Invalid deployment arguments",
    cause: "A constructor argument was the zero address.",
    fix: "Deployment error — re-deploy with valid hub, agentConsumer, and owner addresses.",
  },
};

export function parseRebalancerError(err: unknown): HubErrorInfo | null {
  if (!err || typeof err !== "object") return null;
  let node: unknown = err;
  while (node && typeof node === "object") {
    const o = node as Record<string, unknown>;
    const errorName =
      (o.data as Record<string, unknown> | undefined)?.errorName as string | undefined
      ?? o.errorName as string | undefined;
    if (errorName && REBALANCER_ERROR_MAP[errorName]) return REBALANCER_ERROR_MAP[errorName];

    for (const text of [o.shortMessage, o.message]) {
      if (typeof text === "string") {
        for (const key of Object.keys(REBALANCER_ERROR_MAP)) {
          if (text.includes(key)) return REBALANCER_ERROR_MAP[key];
        }
      }
    }
    node = o.cause;
  }
  return null;
}
