import type { HubErrorInfo } from "./hub-errors";

// Re-uses the same shape as hub errors so both feed into the same ErrorModal.
export const SPOKE_ERROR_MAP: Record<string, HubErrorInfo> = {
  ZeroAddress: {
    title: "Invalid adapter address",
    cause: "A zero address (0x000…) was provided for the adapter.",
    fix: "Enter the deployed IYieldSource adapter contract address.",
  },
  AdapterNotFound: {
    title: "Adapter not found",
    cause: "The protocol ID is not registered or has already been removed.",
    fix: "Check the protocol ID and make sure the adapter was added first.",
  },
  NotHub: {
    title: "Unauthorised sender",
    cause: "A CCIP message arrived from an address other than the registered Hub.",
    fix: "Internal error — contact the protocol team.",
  },
  InvalidMessageType: {
    title: "Invalid CCIP message",
    cause: "Spoke received a message with an unrecognised type or empty instructions.",
    fix: "Internal error — contact the protocol team.",
  },
  AmountCannotBeZero: {
    title: "Zero amount",
    cause: "A deposit or withdrawal instruction carried a zero amount.",
    fix: "Internal error — the Rebalancer should never send zero amounts.",
  },
  InvalidConstructorArguments: {
    title: "Invalid deployment arguments",
    cause: "A constructor argument was the zero address or zero selector.",
    fix: "Deployment error — re-deploy with valid arguments.",
  },
};

// Unified parser that checks both Hub and Spoke error maps.
export function parseSpokeError(err: unknown): HubErrorInfo | null {
  if (!err || typeof err !== "object") return null;
  let node: unknown = err;
  while (node && typeof node === "object") {
    const o = node as Record<string, unknown>;
    const errorName =
      (o.data as Record<string, unknown> | undefined)?.errorName as string | undefined
      ?? o.errorName as string | undefined;
    if (errorName && SPOKE_ERROR_MAP[errorName]) return SPOKE_ERROR_MAP[errorName];

    for (const text of [o.shortMessage, o.message]) {
      if (typeof text === "string") {
        for (const key of Object.keys(SPOKE_ERROR_MAP)) {
          if (text.includes(key)) return SPOKE_ERROR_MAP[key];
        }
      }
    }
    node = o.cause;
  }
  return null;
}
