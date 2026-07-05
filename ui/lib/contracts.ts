import { sepolia, arbitrumSepolia, baseSepolia, optimismSepolia } from "wagmi/chains";

/* ── Deployed addresses ─────────────────────────────────────────────────── */
export const CONTRACTS = {
  hub: {
    chainId: sepolia.id,
    address: (process.env.NEXT_PUBLIC_HUB_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
  },
  rebalancer: {
    chainId: sepolia.id,
    address: (process.env.NEXT_PUBLIC_REBALANCER_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
  },
  agentConsumer: {
    chainId: sepolia.id,
    address: (process.env.NEXT_PUBLIC_AGENT_CONSUMER_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
  },
  arbSpoke: {
    chainId: arbitrumSepolia.id,
    address: (process.env.NEXT_PUBLIC_ARB_SPOKE_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
  },
  baseSpoke: {
    chainId: baseSepolia.id,
    address: (process.env.NEXT_PUBLIC_BASE_SPOKE_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
  },
  opSpoke: {
    chainId: optimismSepolia.id,
    address: (process.env.NEXT_PUBLIC_OP_SPOKE_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
  },
  usdc: {
    sepolia: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as `0x${string}`,
    arbitrumSepolia: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" as `0x${string}`,
  },
} as const;

/* ── Hub ABI ─────────────────────────────────────────────────────────────── */
export const HUB_ABI = [
  // ── ERC4626 user functions ──────────────────────────────────────────────
  {
    name: "deposit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  // withdraw: user inputs USDC amount (preferred over redeem for UX)
  {
    name: "withdraw",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  // redeem: user inputs share amount
  {
    name: "redeem",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ name: "assets", type: "uint256" }],
  },

  // ── Admin functions (onlyOwner) ─────────────────────────────────────────
  // setRebalancer: ZeroAddress() if _rebalancer == address(0)
  {
    name: "setRebalancer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_rebalancer", type: "address" }],
    outputs: [],
  },
  // addSpoke: ZeroAddress() if _spokeAddress == 0; SpokeAlreadyRegistered() if address on wrong selector
  {
    name: "addSpoke",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_chainSelector", type: "uint64" },
      { name: "_spokeAddress", type: "address" },
    ],
    outputs: [],
  },
  // removeSpoke: SpokeNotFound() if selector not active
  {
    name: "removeSpoke",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_chainSelector", type: "uint64" }],
    outputs: [],
  },

  // ── View functions ───────────────────────────────────────────────────────
  { name: "totalAssets",  type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "totalSupply",  type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "reservedAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "inTransitAssets",  type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "outboundGasLimit", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint32" }] },

  // ── Recovery / tuning (onlyOwner) ───────────────────────────────────────
  // setOutboundGasLimit: set CCIP gas limit for outbound messages (default 1_500_000)
  {
    name: "setOutboundGasLimit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_gasLimit", type: "uint32" }],
    outputs: [],
  },
  // adjustInTransitAssets: emergency correction when CCIP messages fail — zeroes or
  // reduces inTransitAssets so share prices are not inflated by stuck transit amounts.
  {
    name: "adjustInTransitAssets",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_newAmount", type: "uint256" }],
    outputs: [],
  },
  { name: "spokeChainSelectorsLength", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "convertToAssets",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "shares", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "convertToShares",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "assets", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "previewWithdraw",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "assets", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "maxWithdraw",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "isValidSpoke",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "_spoke", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "spokeBalances",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "chainSelector", type: "uint64" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "lastReportTimestamp",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "chainSelector", type: "uint64" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "spokes",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "chainSelector", type: "uint64" }],
    outputs: [
      { name: "spoke",          type: "address" },
      { name: "exists",         type: "bool" },
      { name: "everRegistered", type: "bool" },
    ],
  },
  {
    name: "pendingWithdrawals",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "messageId", type: "bytes32" }],
    outputs: [
      { name: "shares",           type: "uint256" },
      { name: "assets",           type: "uint256" },
      { name: "requestedAt",      type: "uint256" },
      { name: "receiver",         type: "address" },
      { name: "owner",            type: "address" },
      { name: "_reservedAssets",  type: "uint256" },
    ],
  },
  {
    name: "REBALANCER",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },

  // ── Events ───────────────────────────────────────────────────────────────
  // WithdrawalQueued: Path 2 (stale spokes) or Path 3 (insufficient idle)
  // Triggered by: redeem() / withdraw() when idle < assets OR any spoke stale
  {
    name: "WithdrawalQueued",
    type: "event",
    inputs: [
      { name: "owner",            type: "address", indexed: true },
      { name: "shares",           type: "uint256", indexed: false },
      { name: "assets",           type: "uint256", indexed: false },
      { name: "_reservedAssets",  type: "uint256", indexed: false },
    ],
  },
  // WithdrawalProcessed: Path 1 (sync) or async settlement via CCIP callback
  // Triggered by: _processWithdrawal → from _withdraw (Path 1) or CCIP handlers
  {
    name: "WithdrawalProcessed",
    type: "event",
    inputs: [
      { name: "owner",     type: "address",  indexed: true },
      { name: "receiver",  type: "address",  indexed: true },
      { name: "assets",    type: "uint256",  indexed: false },
      { name: "messageId", type: "bytes32",  indexed: false },
    ],
  },
  // SpokeAdded: addSpoke() succeeds — admin registered or updated a spoke
  {
    name: "SpokeAdded",
    type: "event",
    inputs: [
      { name: "spokeSelector", type: "uint64",  indexed: true },
      { name: "spokeAddress",  type: "address", indexed: true },
    ],
  },
  // SpokeRemoved: removeSpoke() succeeds — admin disabled a spoke
  {
    name: "SpokeRemoved",
    type: "event",
    inputs: [
      { name: "spokeSelector", type: "uint64", indexed: true },
    ],
  },
  // SpokeBalanceUpdated: every CCIP callback from a spoke updates accounting
  // Triggered by: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL
  {
    name: "SpokeBalanceUpdated",
    type: "event",
    inputs: [
      { name: "chainSelector", type: "uint64",  indexed: true },
      { name: "balance",       type: "uint256", indexed: false },
    ],
  },
  // SentToSpoke: emitted on every hub→spoke CCIP send — track ccipMessageId on ccip.chain.link
  {
    name: "SentToSpoke",
    type: "event",
    inputs: [
      { name: "chainSelector",    type: "uint64",  indexed: true  },
      { name: "ccipMessageId",    type: "bytes32", indexed: true  },
      { name: "internalMessageId",type: "bytes32", indexed: false },
      { name: "amount",           type: "uint256", indexed: false },
    ],
  },

  // ── Custom errors (decoded by viem for precise user feedback) ───────────
  // ZeroWithdrawal: redeem/withdraw when previewRedeem(shares) == 0 (dust shares)
  { name: "ZeroWithdrawal",         type: "error", inputs: [] },
  // NotRebalancer: caller is not REBALANCER or hub address
  { name: "NotRebalancer",          type: "error", inputs: [] },
  // ZeroAddress: setRebalancer(0) or addSpoke(sel, 0)
  { name: "ZeroAddress",            type: "error", inputs: [] },
  // SpokeNotFound: removeSpoke / sendToSpoke with inactive selector
  { name: "SpokeNotFound",          type: "error", inputs: [] },
  // SpokeAlreadyRegistered: addSpoke with address already on a different selector
  { name: "SpokeAlreadyRegistered", type: "error", inputs: [] },
  // NotSpoke: CCIP message from unregistered address — not user-triggerable
  { name: "NotSpoke",               type: "error", inputs: [] },
  // InvalidMessageType: unknown CCIP message type — not user-triggerable
  { name: "InvalidMessageType",     type: "error", inputs: [] },
  // InvalidConstructorArguments: constructor zero-address — not user-triggerable
  { name: "InvalidConstructorArguments", type: "error", inputs: [] },
] as const;

/* ── ERC20 ABI ───────────────────────────────────────────────────────────── */
export const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

/* ── Rebalancer ABI ──────────────────────────────────────────────────────── */
export const REBALANCER_ABI = [
  // ── View / immutables ──────────────────────────────────────────────────────
  { name: "owner",                   type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "HUB",                     type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "AGENT_CONSUMER",          type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  // Whitelist mappings
  { name: "whitelistedChains",       type: "function", stateMutability: "view", inputs: [{ name: "_chainSelector", type: "uint64" }], outputs: [{ name: "", type: "bool" }] },
  { name: "whitelistedProtocols",    type: "function", stateMutability: "view", inputs: [{ name: "_protocolId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },

  // ── Core operations (onlyAuthorized: owner or AgentConsumer) ──────────────
  // rebalance — intra-spoke capital move between adapters on one chain
  // Errors: SourceEqualsTarget, ZeroAmount, ChainNotWhitelisted, ProtocolNotWhitelisted
  {
    name: "rebalance",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_source",        type: "bytes32" },
      { name: "_target",        type: "bytes32" },
      { name: "_amount",        type: "uint256" },
      { name: "_chainSelector", type: "uint64"  },
    ],
    outputs: [],
  },

  // ── Whitelist management (onlyAuthorized) ─────────────────────────────────
  { name: "addChainToWhitelist",        type: "function", stateMutability: "nonpayable", inputs: [{ name: "_chainSelector", type: "uint64"  }], outputs: [] },
  { name: "removeChainFromWhitelist",   type: "function", stateMutability: "nonpayable", inputs: [{ name: "_chainSelector", type: "uint64"  }], outputs: [] },
  { name: "addProtocolToWhitelist",     type: "function", stateMutability: "nonpayable", inputs: [{ name: "_protocolId",    type: "bytes32" }], outputs: [] },
  { name: "removeProtocolFromWhitelist",type: "function", stateMutability: "nonpayable", inputs: [{ name: "_protocolId",    type: "bytes32" }], outputs: [] },

  // ── Events ────────────────────────────────────────────────────────────────
  // RebalanceExecuted — emitted after successful rebalance() or proposeAllocation()
  // weightedApy is 0 for rebalance(), non-zero for proposeAllocation()
  {
    name: "RebalanceExecuted",
    type: "event",
    inputs: [
      { name: "timestamp",   type: "uint256", indexed: false },
      { name: "weightedApy", type: "uint256", indexed: false },
    ],
  },
  // ChainWhitelisted / ChainRemovedFromWhitelist — addChainToWhitelist / removeChainFromWhitelist
  { name: "ChainWhitelisted",          type: "event", inputs: [{ name: "chainSelector", type: "uint64",  indexed: false }] },
  { name: "ChainRemovedFromWhitelist", type: "event", inputs: [{ name: "chainSelector", type: "uint64",  indexed: false }] },
  // ProtocolWhitelisted / ProtocolRemovedFromWhitelist — addProtocolToWhitelist / removeProtocolFromWhitelist
  { name: "ProtocolWhitelisted",           type: "event", inputs: [{ name: "protocolId", type: "bytes32", indexed: false }] },
  { name: "ProtocolRemovedFromWhitelist",  type: "event", inputs: [{ name: "protocolId", type: "bytes32", indexed: false }] },

  // ── Custom errors ─────────────────────────────────────────────────────────
  // InvalidConstructorArguments — constructor, not user-triggerable
  { name: "InvalidConstructorArguments", type: "error", inputs: [] },
  // NotAuthorized — caller is not owner or AgentConsumer
  { name: "NotAuthorized",              type: "error", inputs: [] },
  // SourceEqualsTarget — rebalance() with _source == _target
  { name: "SourceEqualsTarget",         type: "error", inputs: [] },
  // ZeroAmount — rebalance() with _amount == 0
  { name: "ZeroAmount",                 type: "error", inputs: [] },
  // BelowThreshold — proposeAllocation() optimal APY doesn't beat current by >= 50 bps
  { name: "BelowThreshold",             type: "error", inputs: [] },
  // MaxSingleMoveExceeded — any allocation > 30% of totalAssets
  { name: "MaxSingleMoveExceeded",      type: "error", inputs: [] },
  // ChainNotWhitelisted — chain not in whitelistedChains mapping
  { name: "ChainNotWhitelisted",        type: "error", inputs: [] },
  // ProtocolNotWhitelisted — protocol not in whitelistedProtocols mapping
  { name: "ProtocolNotWhitelisted",     type: "error", inputs: [] },
  // InvalidAllocation — validateAllocation() failed: sum≠10000, market>6000, chain>8000, dust<500
  { name: "InvalidAllocation",          type: "error", inputs: [] },
] as const;

/* ── AgentConsumer ABI ───────────────────────────────────────────────────── */
// Thin access-control wrapper — off-chain agent calls proposeAllocation() which
// immediately forwards to Rebalancer. No on-chain approval queue.
export const AGENT_CONSUMER_ABI = [
  // View: immutable references
  { name: "REBALANCER", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "AGENT",      type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },

  // AllocationProposed — emitted after proposeAllocation() forwards to Rebalancer successfully
  // Indexed: caller (AGENT or owner). Shows when and who submitted a proposal.
  {
    name: "AllocationProposed",
    type: "event",
    inputs: [
      { name: "caller",    type: "address", indexed: true  },
      { name: "timestamp", type: "uint256", indexed: false },
    ],
  },

  // NotAgent — caller is neither AGENT nor owner (not user-triggerable from normal UI)
  { name: "NotAgent",                    type: "error", inputs: [] },
  { name: "InvalidConstructorArguments", type: "error", inputs: [] },
] as const;

/* ── Spoke ABI ───────────────────────────────────────────────────────────── */
export const SPOKE_ABI = [
  // ── Admin functions (onlyOwner) ─────────────────────────────────────────
  // setAdapter: ZeroAddress() if _adapter == address(0)
  //             AdapterNotFound() NOT thrown here — creates new if first time
  {
    name: "setAdapter",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_protocolId", type: "bytes32" },
      { name: "_adapter",    type: "address" },
    ],
    outputs: [],
  },
  // removeAdapter: AdapterNotFound() if protocolId not currently active
  {
    name: "removeAdapter",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_protocolId", type: "bytes32" }],
    outputs: [],
  },

  // ── View functions ───────────────────────────────────────────────────────
  // getAllocations: per-adapter balance snapshot — used by allocations page
  {
    name: "getAllocations",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "balances",
        type: "tuple[]",
        components: [
          { name: "protocolId", type: "bytes32" },
          { name: "balance",    type: "uint256" },
        ],
      },
    ],
  },
  { name: "activeAdaptersLength", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  {
    name: "adapters",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "protocolId", type: "bytes32" }],
    outputs: [
      { name: "adapter",         type: "address" },
      { name: "exists",          type: "bool" },
      { name: "everRegistered",  type: "bool" },
    ],
  },
  {
    name: "activeAdapters",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "index", type: "uint256" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
  { name: "HUB",               type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "HUB_CHAIN_SELECTOR",type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint64" }] },

  // setHub: update Hub address when Hub is redeployed — onlyOwner
  {
    name: "setHub",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_hub", type: "address" }],
    outputs: [],
  },

  // ── Events ───────────────────────────────────────────────────────────────
  // AdapterSet: setAdapter() success — new adapter registered or address updated
  // Triggered by: setAdapter(protocolId, adapterAddress) — onlyOwner
  {
    name: "AdapterSet",
    type: "event",
    inputs: [
      { name: "protocolId", type: "bytes32",  indexed: true },
      { name: "adapter",    type: "address",  indexed: true },
    ],
  },
  // AdapterRemoved: removeAdapter() success — adapter disabled (funds NOT recalled)
  // Triggered by: removeAdapter(protocolId) — onlyOwner
  {
    name: "AdapterRemoved",
    type: "event",
    inputs: [
      { name: "protocolId", type: "bytes32", indexed: true },
    ],
  },
  // HubUpdated: setHub() success — Hub address updated
  {
    name: "HubUpdated",
    type: "event",
    inputs: [
      { name: "oldHub", type: "address", indexed: true },
      { name: "newHub", type: "address", indexed: true },
    ],
  },

  // ── Custom errors ────────────────────────────────────────────────────────
  // ZeroAddress: setAdapter(id, address(0))
  { name: "ZeroAddress",                type: "error", inputs: [] },
  // AdapterNotFound: removeAdapter with inactive/unregistered protocolId
  //                  also: CCIP handlers when adapter missing — not user-triggered
  { name: "AdapterNotFound",            type: "error", inputs: [] },
  // NotHub: CCIP message from non-hub — not user-triggerable
  { name: "NotHub",                     type: "error", inputs: [] },
  // InvalidMessageType: CCIP with unknown type or empty instructions — not user-triggerable
  { name: "InvalidMessageType",         type: "error", inputs: [] },
  // AmountCannotBeZero: CCIP instruction with amount == 0 — not user-triggerable
  { name: "AmountCannotBeZero",         type: "error", inputs: [] },
  // InvalidConstructorArguments: constructor — not user-triggerable
  { name: "InvalidConstructorArguments",type: "error", inputs: [] },
] as const;

/* ── Known protocol IDs (keccak256 of name string, matching DeployTestnet.s.sol) ── */
export const PROTOCOL_IDS = {
  AAVE:     "0xde46fbfa339d54cd65b79d8320a7a53c78177565c2aaf4c8b13eed7865e7cfc8" as `0x${string}`,
  COMPOUND: "0x7d6bdc9fe7673eecf8fa621e8239262df5263d2fde3d056056a24536fe392d63" as `0x${string}`,
  MORPHO:   "0x2b95345152918f6eca21b9f1c7c788ee6d9a7e143f74a546048b568034c711e5" as `0x${string}`,
} as const;

export const PROTOCOL_LABELS: Record<string, string> = {
  [PROTOCOL_IDS.AAVE]:     "Aave V3",
  [PROTOCOL_IDS.COMPOUND]: "Compound V3",
  [PROTOCOL_IDS.MORPHO]:   "Morpho",
};

/* ── CCIP chain selectors ─────────────────────────────────────────────────── */
export const CHAIN_SELECTORS = {
  sepolia:          16015286601757825753n,
  arbitrumSepolia:  3478487238524512106n,
  baseSepolia:      10344971235874465080n,
  optimismSepolia:  5224473277236331295n,
} as const;

export const SELECTOR_LABELS: Record<string, string> = {
  "16015286601757825753": "Ethereum Sepolia",
  "3478487238524512106":  "Arbitrum Sepolia",
  "10344971235874465080": "Base Sepolia",
  "5224473277236331295":  "OP Sepolia",
};
