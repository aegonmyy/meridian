// CCIP deposit tracer. Given the Sepolia send tx hash (the proposeAllocation tx that fanned
// out DEPOSIT messages), it traces every leg across 4 layers and prints a verdict per leg.
//
//   node agent-testing/trace.mjs <sepoliaTxHash>
//
// Layers (source of truth is the protocol/chain state, not the CCIP Explorer UI):
//   L1 SOURCE   — did the send even enter CCIP? (receipt revert OR SentToSpoke messageIds)
//   L2 IN-FLIGHT— hub in-transit accounting for the internal messageId + CCIP Explorer URL
//                 + best-effort dest OffRamp ExecutionStateChanged(ccipMessageId)
//   L3 DEST     — did funds land, and where? spoke idle USDC vs adapter aUSDC
//                 (distinguishes "delivered but adapter deposit skipped" from "in Aave")
//   L4 CONFIRM  — did CONFIRM_RECEIPT return? hub inTransitToSpoke / spokeBalances updated;
//                 DepositInstructionFailed / ConfirmSendFailed on the spoke
import { ethers } from "ethers";
import {
  HUB_CHAIN, SPOKE_CHAINS, ART, ERC20_ABI, AAVE_ID,
  provider, erc20, loadDeployment, fmtUsdc,
} from "./lib/infra.mjs";

const SENT_TOPIC = ethers.id("SentToSpoke(uint64,bytes32,bytes32,uint256)");
const EXEC_STATE = ["UNTOUCHED", "IN_PROGRESS", "SUCCESS", "FAILURE"];
const OFFRAMP_ABI = ["function getOffRamps() view returns (tuple(uint64 sourceChainSelector, address offRamp)[])"];

const spokeBySelector = (sel) => SPOKE_CHAINS.find((s) => s.ccipSelector === sel.toString());

async function destExecState(spokeChain, ccipMessageId) {
  // Scan every Sepolia-lane OffRamp on the dest chain for an ExecutionStateChanged carrying
  // this messageId in any indexed topic (layout differs across OffRamp versions, so match
  // client-side by topic value rather than a fixed position).
  const p = provider(spokeChain);
  const router = new ethers.Contract(spokeChain.ccipRouter, OFFRAMP_ABI, p);
  let ramps = [];
  try {
    ramps = (await router.getOffRamps())
      .filter((r) => r.sourceChainSelector.toString() === HUB_CHAIN.ccipSelector)
      .map((r) => r.offRamp);
  } catch { /* fall through */ }
  const latest = await p.getBlockNumber();
  const from = Math.max(0, latest - 45000); // ~ a few hours of L2 blocks
  for (const ramp of ramps) {
    try {
      const logs = await p.getLogs({ address: ramp, fromBlock: from, toBlock: latest });
      const hit = logs.find((l) => l.topics.includes(ccipMessageId));
      if (hit) {
        // state is the first non-indexed word (uint8) in data for v1.5 layout; best-effort.
        let state = "seen";
        try { state = EXEC_STATE[Number(BigInt(hit.data.slice(0, 66)))] ?? "seen"; } catch {}
        return { ramp, state, block: hit.blockNumber };
      }
    } catch { /* ramp not scannable, continue */ }
  }
  return null;
}

async function main() {
  const txHash = process.argv[2];
  if (!txHash) { console.log("usage: node trace.mjs <sepoliaTxHash>"); process.exit(1); }
  const d = loadDeployment();
  const hp = provider(HUB_CHAIN);
  const hub = new ethers.Contract(d.hub.hub, ART.HUB.abi, hp);

  // ── L1: source receipt ──
  const rc = await hp.getTransactionReceipt(txHash);
  if (!rc) { console.log("tx not found / not mined yet"); process.exit(1); }
  if (rc.status === 0) {
    console.log(`L1 SOURCE: send REVERTED on Sepolia (block ${rc.blockNumber}). Never entered CCIP.`);
    console.log("  → trace = decode the revert: cast run", txHash, "--rpc-url", HUB_CHAIN.rpc);
    return;
  }
  const legs = rc.logs
    .filter((l) => l.address.toLowerCase() === d.hub.hub.toLowerCase() && l.topics[0] === SENT_TOPIC)
    .map((l) => {
      const chainSelector = BigInt(l.topics[1]);
      const ccipMessageId = l.topics[2];
      const [internalMessageId, amount] = ethers.AbiCoder.defaultAbiCoder().decode(["bytes32", "uint256"], l.data);
      return { chainSelector, ccipMessageId, internalMessageId, amount };
    });
  if (legs.length === 0) { console.log("L1: tx mined but emitted no SentToSpoke — not a deposit send?"); return; }
  console.log(`L1 SOURCE: ${legs.length} DEPOSIT leg(s) entered CCIP (block ${rc.blockNumber}).\n`);

  for (const leg of legs) {
    const sc = spokeBySelector(leg.chainSelector);
    console.log(`── leg → ${sc?.name ?? leg.chainSelector} | ${fmtUsdc(leg.amount)} USDC`);
    console.log(`   ccipMessageId=${leg.ccipMessageId}`);
    console.log(`   CCIP Explorer: https://ccip.chain.link/msg/${leg.ccipMessageId}`);

    // ── L2: hub in-transit accounting + dest exec state ──
    const inTransit = await hub.inTransitAmount(leg.internalMessageId);
    const leg2 = await hub.transitLegs(leg.internalMessageId);
    const sentAt = Number(leg2.sentAt ?? leg2[1] ?? 0n);
    const ageMin = sentAt ? ((Date.now() / 1000 - sentAt) / 60).toFixed(1) : "?";
    console.log(`   L2 hub inTransitAmount=${fmtUsdc(inTransit)} USDC (age ${ageMin} min)`);
    const exec = await destExecState(sc, leg.ccipMessageId);
    console.log(`   L2 dest OffRamp: ${exec ? `${exec.state} @ ${exec.ramp} (block ${exec.block})` : "not yet executed (in flight / awaiting finality)"}`);

    // ── L3/L4: dest spoke state ──
    const s = d.spokes[sc.name];
    const sp = provider(sc);
    const usdc = erc20(sc, sc.usdc, sp);
    const ausdc = erc20(sc, sc.aUsdc, sp);
    const spokeIdle = await usdc.balanceOf(s.spoke);
    const inAave = await ausdc.balanceOf(s.aaveAdapter);
    const hubSpokeBal = await hub.spokeBalances(leg.chainSelector);
    console.log(`   L3 dest spoke idle USDC=${fmtUsdc(spokeIdle)} | adapter aUSDC(in Aave)=${fmtUsdc(inAave)}`);
    console.log(`   L4 hub.spokeBalances=${fmtUsdc(hubSpokeBal)} | inTransitToSpoke=${await hub.inTransitToSpoke(leg.chainSelector)}`);

    // verdict
    let verdict;
    if (inAave > 0n && exec?.state === "SUCCESS") verdict = "DELIVERED & DEPLOYED to Aave ✓";
    else if (exec?.state === "SUCCESS" && spokeIdle > 0n && inAave === 0n) verdict = "DELIVERED but adapter deposit SKIPPED (funds idle on spoke — check DepositInstructionFailed / adapter)";
    else if (exec?.state === "FAILURE") verdict = "CCIP execution FAILED on dest — inspect OffRamp returnData / re-execute";
    else if (inTransit > 0n) verdict = `IN FLIGHT — ${ageMin} min elapsed (Sepolia→L2 is finality-bound, ~15-20 min typical). Not a failure yet.`;
    else verdict = "indeterminate — check CCIP Explorer";
    console.log(`   VERDICT: ${verdict}\n`);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
