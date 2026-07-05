import { NextRequest, NextResponse } from "next/server";

// CCIP v1.0 CCIPSendRequested (OP Sepolia OnRamp)
const TOPIC_V1 =
  "0xd0c3c799bf9e2639de44391e7f524d229b2b55f5b1ea94b2bf7da42f7243dddd";

// CCIP v1.5 CCIPSendRequested (Arb + Base Sepolia OnRamp)
const TOPIC_V15 =
  "0x192442a2b2adb6a7948f097023cb6b57d29d3a7a5dd33e6666d33c39cc456f32";

// Sepolia OnRamp addresses (from Router.getOnRamp())
const ONRAMP_OP = "0xacdfd7a98d853fa3914047cd46e7f5d53bbc9fbb";
const ONRAMP_ARB_BASE = "0x23a5084fa78104f3df11c63ae59fcac4f6ad9dee";

const ETHERSCAN_KEY =
  process.env.ETHERSCAN_API_KEY ?? "58YU6RJHFMH8S28RDSNRYCGVETIJITWTR6";
const SEPOLIA_CHAIN_ID = "11155111";

type LogEntry = { topics: string[]; data: string; transactionHash: string };

// messageId is word[13] in v1.0 struct (word[0] is the outer ABI offset)
function extractMsgIdV1(data: string): string | null {
  const words = (data.startsWith("0x") ? data.slice(2) : data).match(/.{64}/g);
  return words && words.length >= 14 ? "0x" + words[13] : null;
}

// In v1.5, RampMessageHeader is the first field; messageId is its first member → word[1]
function extractMsgIdV15(data: string): string | null {
  const words = (data.startsWith("0x") ? data.slice(2) : data).match(/.{64}/g);
  return words && words.length >= 2 ? "0x" + words[1] : null;
}

// sender is word[2] in v1.0 struct (after offset + sourceChainSelector)
function senderV1(data: string): string {
  const words = (data.startsWith("0x") ? data.slice(2) : data).match(/.{64}/g);
  return words && words.length >= 3 ? words[2].slice(-40).toLowerCase() : "";
}

// In v1.5, header is 5 words (msgId, srcSel, dstSel, seqNum, nonce), sender at word[6]
function senderV15(data: string): string {
  const words = (data.startsWith("0x") ? data.slice(2) : data).match(/.{64}/g);
  return words && words.length >= 7 ? words[6].slice(-40).toLowerCase() : "";
}

async function etherscanGetLogs(
  address: string,
  topic0: string,
  fromBlock: number
): Promise<LogEntry[]> {
  const qs = new URLSearchParams({
    chainid: SEPOLIA_CHAIN_ID,
    module: "logs",
    action: "getLogs",
    address,
    topic0,
    fromBlock: String(fromBlock),
    page: "1",
    offset: "100",
    apikey: ETHERSCAN_KEY,
  });
  const res = await fetch(`https://api.etherscan.io/v2/api?${qs}`, {
    next: { revalidate: 0 },
  });
  const d = await res.json();
  return Array.isArray(d.result) ? d.result : [];
}

async function getHubCreationBlock(hub: string): Promise<number> {
  const qs = new URLSearchParams({
    chainid: SEPOLIA_CHAIN_ID,
    module: "contract",
    action: "getcontractcreation",
    contractaddresses: hub,
    apikey: ETHERSCAN_KEY,
  });
  const res = await fetch(`https://api.etherscan.io/v2/api?${qs}`, {
    next: { revalidate: 3600 },
  });
  const d = await res.json();
  const block = d?.result?.[0]?.blockNumber;
  return block ? parseInt(block, 10) : 0;
}

async function fetchCcipStatus(messageId: string) {
  const res = await fetch(
    `https://ccip.chain.link/api/h/atlas/message/${messageId}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "Mozilla/5.0 Meridian/1.0",
      },
      next: { revalidate: 0 },
    }
  );
  if (!res.ok) return null;
  return res.json();
}

export async function GET(request: NextRequest) {
  const hub = request.nextUrl.searchParams.get("hub");
  if (!hub) {
    return NextResponse.json({ error: "hub param required" }, { status: 400 });
  }

  const hubLower = hub.toLowerCase().replace("0x", "");

  try {
    // Get Hub creation block so we only scan relevant history
    const fromBlock = await getHubCreationBlock(hub);

    const [logsV1, logsV15] = await Promise.all([
      etherscanGetLogs(ONRAMP_OP, TOPIC_V1, fromBlock),
      etherscanGetLogs(ONRAMP_ARB_BASE, TOPIC_V15, fromBlock),
    ]);

    const found: Array<{ messageId: string; txHash: string }> = [];

    for (const log of logsV1) {
      if (senderV1(log.data) !== hubLower) continue;
      const mid = extractMsgIdV1(log.data);
      if (mid) found.push({ messageId: mid, txHash: log.transactionHash });
    }

    for (const log of logsV15) {
      if (senderV15(log.data) !== hubLower) continue;
      const mid = extractMsgIdV15(log.data);
      if (mid) found.push({ messageId: mid, txHash: log.transactionHash });
    }

    if (found.length === 0) {
      return NextResponse.json({ data: [] });
    }

    // Deduplicate and fetch status for each unique messageId
    const seen = new Set<string>();
    const unique = found.filter(({ messageId }) => {
      if (seen.has(messageId)) return false;
      seen.add(messageId);
      return true;
    });

    const messages = await Promise.all(
      unique.map(async ({ messageId, txHash }) => {
        const msg = await fetchCcipStatus(messageId);
        if (!msg) return null;
        return { ...msg, sourceTransactionHash: txHash };
      })
    );

    return NextResponse.json({ data: messages.filter(Boolean) });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "fetch failed" },
      { status: 502 }
    );
  }
}
