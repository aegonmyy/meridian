"use client";

import { useState, useEffect, useCallback } from "react";

export type CcipMessageState = 0 | 1 | 2 | 3;
export const CCIP_STATE_LABELS: Record<CcipMessageState, string> = {
  0: "Untouched",
  1: "In Progress",
  2: "Success",
  3: "Failure",
};
export const CCIP_STATE_VARIANTS: Record<CcipMessageState, "gray" | "blue" | "green" | "red"> = {
  0: "gray",
  1: "blue",
  2: "green",
  3: "red",
};

export interface CcipMessage {
  messageId: string;
  state: CcipMessageState;
  sourceTransactionHash: string;
  sendTimestamp?: string;
  sourceNetworkName?: string;
  destNetworkName?: string;
  receiver?: string;
  sender?: string;
  // token amounts come as nested array in CCIP API
  tokenAmounts?: Array<{ token: string; amount: string }>;
}

interface CcipApiResponse {
  data: CcipMessage[];
}

export function useCcipMessages(hubAddress: string | undefined, pollMs = 30_000) {
  const [messages, setMessages] = useState<CcipMessage[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchMessages = useCallback(async () => {
    if (!hubAddress || hubAddress === "0x0000000000000000000000000000000000000000") return;
    setLoading(true);
    try {
      const res = await fetch(
        `/api/ccip-messages?hub=${hubAddress}`,
        { headers: { Accept: "application/json" } }
      );
      if (!res.ok) throw new Error(`API returned ${res.status}`);
      const json: CcipApiResponse = await res.json();
      setMessages(json.data ?? []);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to fetch CCIP messages");
    } finally {
      setLoading(false);
    }
  }, [hubAddress]);

  useEffect(() => {
    fetchMessages();
    const id = setInterval(fetchMessages, pollMs);
    return () => clearInterval(id);
  }, [fetchMessages, pollMs]);

  return { messages, loading, error, refetch: fetchMessages };
}
