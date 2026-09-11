// auto-conclude.mjs
//
// Watches one legion proposal and calls `conclude` the moment it can.
//
// `conclude` is permissionless but only accepted on the 12 burn blocks after
// voting closes. Miss them and the proposal settles `not-concluded` and pays
// nothing, however the vote went. That is exactly how the first mainnet
// proposal died: the watcher was a task tied to an interactive session, the
// session ended, and nobody fired. So this is a plain Node process meant to be
// run under nohup, outliving whatever started it.
//
// Usage:
//   MNEMONIC="..." nohup node scripts/auto-conclude.mjs <address.contract> <id> \
//     > conclude-<id>.log 2>&1 &
//
// Sign with a throwaway wallet. The caller gains nothing from concluding and
// needs only enough STX for one fee. The mnemonic is read from the environment
// and never written to disk here.
//
// Post-condition mode is DENY with no conditions, and that is exact rather than
// permissive: a passing conclude moves market shares, which are rows in the
// market's positions map, not a fungible token, and a credited conclude moves
// nothing at all. So no FT or STX may leave the caller, and none does.

import { generateWallet } from "@stacks/wallet-sdk";
import {
  makeContractCall,
  broadcastTransaction,
  PostConditionMode,
  uintCV,
  cvToHex,
  hexToCV,
  cvToJSON,
} from "@stacks/transactions";

const API = "https://api.hiro.so";
const NETWORK = "mainnet";
const POLL_MS = 60_000;
const FEE = 10_000;
// The tx indexer has been seen to never index a confirmed transaction. Past this
// age an in-flight conclude is treated as lost and the phase decides instead.
const INFLIGHT_MAX_MS = 10 * 60_000;

const [contractId, idArg] = process.argv.slice(2);
const proposalId = Number(idArg);

if (!contractId || !contractId.includes(".") || !Number.isInteger(proposalId)) {
  console.error("usage: MNEMONIC=... node scripts/auto-conclude.mjs <address.contract> <proposalId>");
  process.exit(1);
}
if (!process.env.MNEMONIC) {
  console.error("MNEMONIC env var is required");
  process.exit(1);
}

const [address, name] = contractId.split(".");
const stamp = () => new Date().toISOString().replace("T", " ").slice(0, 19);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Transient API failures return null and the loop keeps polling.
async function readOnly(fn) {
  try {
    const res = await fetch(`${API}/v2/contracts/call-read/${address}/${name}/${fn}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sender: address, arguments: [cvToHex(uintCV(proposalId))] }),
    });
    if (!res.ok) return null;
    const j = await res.json();
    if (!j.okay || !j.result) return null;
    return cvToJSON(hexToCV(j.result)).value;
  } catch {
    return null;
  }
}

async function burnHeight() {
  try {
    const res = await fetch(`${API}/v2/pox`);
    if (!res.ok) return null;
    return (await res.json()).current_burnchain_block_height;
  } catch {
    return null;
  }
}

async function txStatus(txid) {
  try {
    const res = await fetch(`${API}/extended/v1/tx/${txid}`);
    if (!res.ok) return "pending";
    return (await res.json()).tx_status;
  } catch {
    return "pending";
  }
}

const wallet = await generateWallet({ secretKey: process.env.MNEMONIC, password: "" });
const senderKey = wallet.accounts[0].stxPrivateKey;

console.log(`${stamp()} watching ${contractId} proposal ${proposalId}`);

let lastPhase = null;
let pendingTx = null;
let pendingSince = 0;

// No poll cap. The loop ends when the proposal reaches a terminal phase, which
// it always does: at worst it lapses to "expired" once the window closes.
for (;;) {
  const [phase, h] = await Promise.all([readOnly("get-phase"), burnHeight()]);

  if (phase && phase !== lastPhase) {
    console.log(`${stamp()} burn=${h} phase=${phase}`);
    lastPhase = phase;
  }

  if (phase === "passed" || phase === "failed") {
    const p = await readOnly("get-proposal");
    const reason = p?.value?.reason?.value ?? "?";
    console.log(`${stamp()} settled: ${phase} (${reason})`);
    process.exit(0);
  }
  if (phase === "expired") {
    console.log(`${stamp()} EXPIRED without being concluded`);
    process.exit(1);
  }

  // A broadcast conclude takes a block or two to land. Don't fire again while
  // one is in flight, or the second just burns a fee on an already-settled id.
  //
  // The read-only phase is the source of truth, not the indexer: a landed
  // conclude flips it to passed or failed above. If the indexer still says
  // pending after INFLIGHT_MAX_MS and the phase is still concludable, assume the
  // tx was dropped and fire again. A duplicate only fails with u410 and a fee.
  if (pendingTx) {
    const s = await txStatus(pendingTx);
    const stale = Date.now() - pendingSince > INFLIGHT_MAX_MS;
    if (s === "pending" && !stale) {
      await sleep(POLL_MS);
      continue;
    }
    console.log(`${stamp()} ${pendingTx} -> ${stale && s === "pending" ? "unconfirmed after 10m, retrying" : s}`);
    pendingTx = null;
  }

  if (phase === "concludable") {
    console.log(`${stamp()} WINDOW OPEN at burn ${h}, broadcasting conclude`);
    try {
      const tx = await makeContractCall({
        contractAddress: address,
        contractName: name,
        functionName: "conclude",
        functionArgs: [uintCV(proposalId)],
        senderKey,
        network: NETWORK,
        postConditionMode: PostConditionMode.Deny,
        postConditions: [],
        fee: FEE,
      });
      const r = await broadcastTransaction({ transaction: tx, network: NETWORK });
      if (r.txid) {
        pendingTx = r.txid;
        pendingSince = Date.now();
        console.log(`${stamp()} broadcast ${r.txid}`);
        console.log(`${stamp()} https://explorer.hiro.so/txid/${r.txid}?chain=mainnet`);
      } else {
        console.log(`${stamp()} rejected: ${JSON.stringify(r)}; retrying`);
      }
    } catch (e) {
      console.log(`${stamp()} error: ${e.message}; retrying`);
    }
  }

  await sleep(POLL_MS);
}
