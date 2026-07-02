export type HubErrorInfo = {
  title: string;
  cause: string;
  fix: string;
};

export const HUB_ERROR_MAP: Record<string, HubErrorInfo> = {
  ZeroWithdrawal: {
    title: "Withdrawal too small",
    cause: "Your shares are worth less than 1 unit of USDC at the current share price.",
    fix: "Deposit more USDC or wait for yield to accrue before withdrawing.",
  },
  NotRebalancer: {
    title: "Not authorised",
    cause: "This function can only be called by the Rebalancer contract.",
    fix: "You cannot call this function directly.",
  },
  ZeroAddress: {
    title: "Invalid address",
    cause: "A zero address (0x000…) was provided where a real address is required.",
    fix: "Enter a valid contract or wallet address.",
  },
  SpokeNotFound: {
    title: "Spoke not found",
    cause: "The chain selector is not registered as an active spoke.",
    fix: "Check the chain selector and make sure the spoke was added first.",
  },
  SpokeAlreadyRegistered: {
    title: "Spoke already registered",
    cause: "This spoke address is already mapped to a different chain selector.",
    fix: "Remove the existing registration first, or use a different spoke address.",
  },
  NotSpoke: {
    title: "Unknown spoke",
    cause: "A CCIP message arrived from an unregistered address.",
    fix: "Internal error — contact the protocol team.",
  },
  InvalidMessageType: {
    title: "Invalid CCIP message",
    cause: "An unrecognised message type was received over CCIP.",
    fix: "Internal error — contact the protocol team.",
  },
  InvalidConstructorArguments: {
    title: "Invalid deployment arguments",
    cause: "A constructor argument was the zero address.",
    fix: "Deployment error — re-deploy with valid addresses.",
  },
};

// Walk viem/wagmi error chain to find a Hub custom error name.
export function parseHubError(err: unknown): HubErrorInfo | null {
  if (!err || typeof err !== "object") return null;
  let node: unknown = err;
  while (node && typeof node === "object") {
    const o = node as Record<string, unknown>;
    const errorName =
      (o.data as Record<string, unknown> | undefined)?.errorName as string | undefined
      ?? o.errorName as string | undefined;
    if (errorName && HUB_ERROR_MAP[errorName]) return HUB_ERROR_MAP[errorName];

    // Fallback: scan shortMessage / message strings
    for (const text of [o.shortMessage, o.message]) {
      if (typeof text === "string") {
        for (const key of Object.keys(HUB_ERROR_MAP)) {
          if (text.includes(key)) return HUB_ERROR_MAP[key];
        }
      }
    }
    node = o.cause;
  }
  return null;
}
