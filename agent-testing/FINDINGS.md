# Meridian live testnet validation: findings

Fresh deployment (2026-07-19), Aave x3, real Chainlink CCIP. Addresses in `deployment.json`.
All results from real on-chain txns on Sepolia + Arb/Base/OP Sepolia.

## Validated OK

| Flow | Result | Evidence |
|---|---|---|
| Deposit (ERC4626) | works | 6 USDC in, 6 shares minted at 1.0 |
| Cross-chain allocate (hub→3 spokes→Aave) | works end-to-end | `proposeAllocation` tx 0xaa5284…; funds landed in Aave on all 3 chains (2.4/2.4/1.2) |
| CCIP confirm return legs + hub reconciliation | works | after both hops, hub `spokeBalances`=2.4/2.4/1.2, `inTransit`=0, `inTransitToSpoke`=0 |
| Multi-user share math | correct | depositor #1: 2 USDC → exactly 2 shares at price 1.0 |
| Path 1 synchronous withdrawal | works | depositor #1 redeemed 2 shares, got 2 USDC immediately, no queue (tx 0xcb56b8…) |
| Guard / access-control battery | 25/25 pass | `probe.mjs`: auth, whitelists, allocation validation, zero-address/amount, ERC4626 limits all revert correctly |

## Timings (real testnet)

- Sepolia → L2 deposit leg (into Aave): ~20–25 min (Ethereum finality bound).
- L2 → Sepolia confirm return leg: another ~10–15 min.
- Full deposit round trip (allocate → funds in Aave → hub books reconciled): ~35 min.

## Observations (not bugs, but worth knowing)

- **Share price lags accrued yield.** `totalAssets` = idle + sum of *reported* `spokeBalances`
  + inTransit. It does not query live Aave balances (can't, cross-chain). So yield accruing on
  spokes is invisible to share price until a fresh `REPORT_BALANCE` (bounded by `MAX_STALENESS`
  = 1 hour). Example: reported total 6.000000 while real Aave holdings were 6.000013. A depositor
  right before a report gets very slightly more shares than "live-fair"; a withdrawer right
  before a report leaves a sliver of yield behind. Small at these sizes; scales with yield rate
  and report cadence.
- **Alchemy OP-Sepolia `eth_estimateGas` false-reverts** on valid txs (proven by a raw eth_call
  succeeding). Any tx that touches OP must pass an explicit gas limit. Not a contract issue.
- **Intra-spoke rebalance not functionally testable here**: only one adapter (Aave) per spoke,
  and `rebalance` requires source != target. Its guards were verified (revert paths); the
  happy path needs a 2nd adapter, which no L2 testnet provides.

## Finding: stranded dust permanently blocks re-allocation (real bug)

Severity: medium (yield drag + operational lockup, not loss of funds).

Repro (live): after depositing 6 USDC, allocating to 3 spokes, and recalling all of it back,
a re-allocation reverts `InsufficientIdleForProposal(6000015, 6000000)`.

Mechanism:
1. `recallFromSpoke` pulls the exact amount quoted. Yield accrues on the spoke's Aave position
   between quote and execution, so a sliver (here ~0.000016 USDC total) stays in Aave on the spokes.
2. That sliver counts in `totalAssets` (6.000016) but is not in hub `idle` (6.000000).
3. `Rebalancer.proposeAllocation` requires the proposal to sum to exactly 10000 bps, and sizes
   each send as `bps * totalAssets / 10000`, i.e. a full proposal requests 100% of totalAssets.
   But `sendToSpoke` pays only from idle. Request 6.000016 > available idle 6.000000 -> revert.

Why it is a trap, not a transient:
- Depositing more does not help: idle and totalAssets rise together, the gap == spokeBalances stays.
- The validator forbids proposing < 10000 bps, so you cannot "leave the dust out".
- A balance report does not clear it either: the dust is real capital sitting in the spoke's
  Aave position, so a report sets spokeBalances to the real ~0.00001, not 0.
- So `proposeAllocation` only ever succeeds when the hub holds 100% of assets as idle. That is
  true on the very first deploy, but after any deploy+recall cycle the stranded dust makes a full
  re-allocation revert. The only escape is recalling every last wei off every spoke, which
  continuous yield accrual keeps defeating and which costs orders of magnitude more in CCIP fees
  than the dust is worth.

Root causes (two, compounding):
- (a) recall-by-exact-amount strands yield accrued after quoting (the earlier "dust left behind"
  observation), and
- (b) proposeAllocation sizes against totalAssets but funds from idle, with a hard 10000-bps sum.

Possible fixes (design discussion, not implemented): a "recall max / sweep" that withdraws the
spoke's full live balance rather than a fixed number; and/or letting proposeAllocation size
against available idle (deploy a % of idle) instead of requiring 100% of totalAssets; and/or a
small tolerance band on the idle check.

## Withdrawal paths (all validated live)

- **Path 1 (sync):** idle covers + all spokes fresh. Paid immediately, no queue. (validated earlier)
- **Path 3 (async recall):** redeemed 3 shares with idle ~0. Hub planned a MULTI-LEG recall
  (Arb ~2.39 + Base ~0.61 = the 3.0 shortfall), each spoke pulled from Aave and shipped USDC
  back. `attemptSettlement` first emitted `SettlementDeferred` (see finding below), then settled
  after idle was added. `WithdrawalRepriced(3.000008 -> 3.000155)`, user got more than quoted
  because Aave yield accrued during flight (claim-time pricing, working correctly).
- **Path 2 (refresh-then-settle):** redeemed 1 share with idle 2.0 (covers it) while a spoke was
  stale. Queued, sent REPORT_BALANCE pings to all 3 spokes (no tokens), settled once all fresh
  via `attemptSettlement`. `WithdrawalRepriced(1.000051 -> 1.000064)`. The `_allSpokesFresh`
  gate is enforced on-chain at settlement (a pre-settle RPC read showed one spoke momentarily
  stale, but the settle tx executed against a block where all were fresh. Read race, not a bug).

## Finding: Path 3 settlement can stall on the yield delta without an idle buffer

Severity: low/medium (temporary stall, funds safe, recoverable).

A Path 3 recall is sized on the request-time quote. Settlement pays at CLAIM-TIME price, which
is higher if yield accrued during the ~35 min flight. The difference (here ~0.00015 USDC on a
3 USDC withdrawal) must come from free hub idle, per design ("yield during flight settles from
free idle"). In a FULLY-DEPLOYED vault with no idle buffer, that idle does not exist, so
`attemptSettlement` emits `SettlementDeferred(payout, available)` with payout > available and the
withdrawal stays pending until idle appears (a deposit, a recall, or cancellation after 24h).
Reproduced live: had to deposit 0.5 USDC to let the 3 USDC Path 3 withdrawal settle. Another
argument for keeping a hub idle buffer (which also enables instant Path 1 withdrawals).

## Dust-lock fix: deployed and validated live

The Rebalancer dust-lock fix (size sends against deployable idle, not totalAssets) was deployed
by hot-swapping the Rebalancer (`hub.setRebalancer`, hub + spokes untouched). Live proof: in a
state with idle 0.5 and totalAssets 3.5 (where the old contract reverted
`InsufficientIdleForProposal`), the new contract deployed exactly the 0.5 idle
(0.199941 + 0.199941 + 0.099970) and drove idle to ~0. Full test suite green (297/297) with the
change; the obsolete WI-3 test was rewritten to assert the new behavior.

## Not runnable live (mechanism/time-gated, covered by unit tests)

- **retryConfirm**: needs a spoke to exhaust LINK mid-confirm; no function drains a spoke's
  LINK, so forcing it takes many round trips. Covered by WI-2 unit tests.
- **cancelWithdrawal**: gated on the 24h WITHDRAWAL_TIMEOUT. Covered by WithdrawPath unit tests.
- **Intra-chain rebalance**: needs a 2nd adapter per spoke; only Aave exists on these testnets.
- **Quarantine (WI-7)** and **reconcileTransit (7d)**: cannot be triggered with honest spokes /
  practical time.
