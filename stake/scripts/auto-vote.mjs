// auto-vote.mjs
//
// Waits for one legion proposal to open for voting, casts one vote, and exits.
//
// Voting is rejected with u436 for the 2 burn blocks after a proposal is made,
// then open for 30. Casting by hand means someone has to be watching when the
// window opens, which is the same failure that killed the first mainnet
// proposal at the conclude step. This is a plain Node process meant to be run
// under nohup, like auto-conclude.mjs, so it outlives whatever started it.
//
// Usage:
//   MNEMONIC="..." nohup node scripts/auto-vote.mjs \
//     <address.contract> <proposalId> <yes|no> "<rationale>" > vote-<id>.log 2>&1 &
//
// The rationale is required by the contract and goes on chain verbatim, at most
// 256 ASCII characters. The mnemonic is read from the environment and never
// written to disk here.
//
// Post-condition mode is DENY with no conditions, which is exact: a vote moves
// nothing, so no asset may leave the voter and none does.
//
// Everything is decided by read-only calls, never by the tx indexer, which has
// been seen never to index a confirmed transaction. Before firing it asks the
// legion itself whether this wallet may vote and whether it already has.

import { generateWallet } from "@stacks/wallet-sdk";
import {
  makeContractCall,
  broadcastTransaction,
  PostConditionMode,
  uintCV,
  boolCV,
  stringAsciiCV,
  principalCV,
  privateKeyToAddress,
  cvToHex,
  hexToCV,
  cvToJSON,
} from "@stacks/transactions";

const API = "https://api.hiro.so";
const NETWORK = "mainnet";
const POLL_MS = 60_000;
const FEE = 10_000;
const INFLIGHT_MAX_MS = 10 * 60_000;

const [contractId, idArg, sideArg, rationale] = process.argv.slice(2);
const proposalId = Number(idArg);
const support = sideArg === "yes" ? true : sideArg === "no" ? false : null;

const usage =
  'usage: MNEMONIC=... node scripts/auto-vote.mjs <address.contract> <proposalId> <yes|no> "<rationale>"';
if (!contractId || !contractId.includes(".") || !Number.isInteger(proposalId) || support === null) {
  console.error(usage);
  process.exit(1);
}
if (!rationale || rationale.length > 256 || !/^[\x20-\x7e]*$/.test(rationale)) {
  console.error("rationale is required, printable ASCII, at most 256 characters");
  process.exit(1);
}
if (!process.env.MNEMONIC) {
  console.error("MNEMONIC env var is required");
  process.exit(1);
}

const [address, name] = contractId.split(".");
const stamp = () => new Date().toISOString().replace("T", " ").slice(0, 19);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const wallet = await generateWallet({ secretKey: process.env.MNEMONIC, password: "" });
const senderKey = wallet.accounts[0].stxPrivateKey;
const voter = privateKeyToAddress(senderKey, NETWORK);

// Transient API failures return null and the loop keeps polling.
async function readOnly(fn, args) {
  try {
    const res = await fetch(`${API}/v2/contracts/call-read/${address}/${name}/${fn}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sender: voter, arguments: args.map(cvToHex) }),
    });
    if (!res.ok) return null;
    const j = await res.json();
    if (!j.okay || !j.result) return null;
    return cvToJSON(hexToCV(j.result));
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

const id = uintCV(proposalId);
const phaseOf = async () => (await readOnly("get-phase", [id]))?.value ?? null;
// get-vote-record returns (optional {...}); cvToJSON gives value null for none.
const hasVoted = async () => {
  const r = await readOnly("get-vote-record", [id, principalCV(voter)]);
  return r === null ? null : r.value !== null;
};
const power = async () => (await readOnly("vote-power", [id, principalCV(voter)]))?.value?.value ?? null;

console.log(`${stamp()} ${voter} will vote ${sideArg} on ${contractId} proposal ${proposalId}`);

let lastPhase = null;
let pendingTx = null;
let pendingSince = 0;

for (;;) {
  const [phase, h] = await Promise.all([phaseOf(), burnHeight()]);

  if (phase && phase !== lastPhase) {
    console.log(`${stamp()} burn=${h} phase=${phase}`);
    lastPhase = phase;
  }

  // The contract refuses a second vote with u405, but asking first saves a fee
  // and makes re-running this script on the same proposal harmless.
  const voted = await hasVoted();
  if (voted === true) {
    const r = await readOnly("get-vote-record", [id, principalCV(voter)]);
    const rec = r?.value?.value;
    console.log(
      `${stamp()} vote recorded: support=${rec?.support?.value} weight=${rec?.weight?.value}`,
    );
    process.exit(0);
  }

  // Voting closes for good once the proposal leaves the voting phase.
  if (phase === "concludable" || phase === "expired" || phase === "passed" || phase === "failed") {
    console.log(`${stamp()} voting closed (${phase}) without a vote from ${voter}`);
    process.exit(1);
  }

  if (pendingTx) {
    if (Date.now() - pendingSince <= INFLIGHT_MAX_MS) {
      await sleep(POLL_MS);
      continue;
    }
    console.log(`${stamp()} ${pendingTx} unconfirmed after 10m and no vote recorded, retrying`);
    pendingTx = null;
  }

  if (phase === "voting") {
    // Check eligibility at the moment of firing: weight is a live position and
    // may have moved since the script started.
    const p = await power();
    if (p) {
      if (p.isProposer?.value === true) {
        console.log(`${stamp()} ${voter} is the proposer and cannot vote on its own proposal`);
        process.exit(1);
      }
      if (p.meetsFloor?.value === false) {
        console.log(`${stamp()} weight ${p.weight?.value} is below the floor; waiting in case it is topped up`);
        await sleep(POLL_MS);
        continue;
      }
    }

    console.log(`${stamp()} VOTING OPEN at burn ${h}, broadcasting ${sideArg}`);
    try {
      const tx = await makeContractCall({
        contractAddress: address,
        contractName: name,
        functionName: "vote",
        functionArgs: [id, boolCV(support), stringAsciiCV(rationale)],
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
