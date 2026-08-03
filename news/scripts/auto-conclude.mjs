// Watches a proposal and calls `conclude` the moment its window opens.
//
// `conclude` is permissionless and only valid inside [voteEnd + VETO_WINDOW,
// voteEnd + VETO_WINDOW + CONCLUDE_WINDOW). Miss it and the piece EXPIRES paying
// nobody. On a chain with variable block times that window can be minutes wide,
// which is far too tight to hit by hand -- both testnet attempts were lost that
// way. Something automated has to hold the trigger, in testing and in production.
//
// Usage:
//   MNEMONIC="..." node scripts/auto-conclude.mjs <gov-contract-id> <proposal-id>
//
// The mnemonic is read from the environment and never written to disk here.

import { generateWallet } from "@stacks/wallet-sdk";
import {
  makeContractCall,
  broadcastTransaction,
  AnchorMode,
  PostConditionMode,
  uintCV,
  cvToHex,
  hexToCV,
  cvToJSON,
} from "@stacks/transactions";

const API = "https://api.testnet.hiro.so";
const [contractId, proposalIdArg] = process.argv.slice(2);
const proposalId = Number(proposalIdArg);

if (!contractId || !Number.isFinite(proposalId)) {
  console.error("usage: MNEMONIC=... node scripts/auto-conclude.mjs <address.contract> <proposalId>");
  process.exit(1);
}
if (!process.env.MNEMONIC) {
  console.error("MNEMONIC env var is required");
  process.exit(1);
}

const [address, name] = contractId.split(".");

async function readPhase() {
  const res = await fetch(`${API}/v2/contracts/call-read/${address}/${name}/get-phase`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sender: address, arguments: [cvToHex(uintCV(proposalId))] }),
  });
  if (!res.ok) return null; // rate limited or transient: treat as unknown, keep polling
  const j = await res.json();
  if (!j.okay || !j.result) return null;
  return cvToJSON(hexToCV(j.result)).value;
}

async function height() {
  const res = await fetch(`${API}/extended/v1/block?limit=1`);
  if (!res.ok) return null;
  return (await res.json()).results[0].height;
}

const wallet = await generateWallet({ secretKey: process.env.MNEMONIC, password: "" });
const senderKey = wallet.accounts[0].stxPrivateKey;

const stamp = () => new Date().toISOString().slice(11, 19);
console.log(`${stamp()} watching ${contractId} proposal ${proposalId}`);

let lastSeen = null;
for (let i = 0; i < 2000; i++) {
  const phase = await readPhase();
  const h = await height();

  if (phase && phase !== lastSeen) {
    console.log(`${stamp()} height=${h} phase=${phase}`);
    lastSeen = phase;
  }

  if (phase === "concludable") {
    console.log(`${stamp()} WINDOW OPEN at height ${h}, broadcasting conclude`);
    try {
      const tx = await makeContractCall({
        contractAddress: address,
        contractName: name,
        functionName: "conclude",
        functionArgs: [uintCV(proposalId)],
        senderKey,
        network: "testnet",
        anchorMode: AnchorMode.Any,
        // conclude moves sBTC out of the treasury to the proposer, not to us.
        // We cannot post-condition someone else's receipt, so allow is required
        // here; the contract itself constrains the amount and the recipient.
        postConditionMode: PostConditionMode.Allow,
        fee: 10000,
      });
      const r = await broadcastTransaction({ transaction: tx, network: "testnet" });
      console.log(`${stamp()} broadcast: ${JSON.stringify(r)}`);
      if (r.txid) {
        console.log(`${stamp()} txid ${r.txid}`);
        console.log(`${stamp()} https://explorer.hiro.so/txid/${r.txid}?chain=testnet`);
        process.exit(0);
      }
      // reason present means it was rejected; keep trying while the window lasts
      console.log(`${stamp()} rejected, retrying`);
    } catch (e) {
      console.log(`${stamp()} error: ${e.message}, retrying`);
    }
  }

  if (phase === "expired" || phase === "passed" || phase === "failed") {
    console.log(`${stamp()} terminal phase ${phase}, nothing to do`);
    process.exit(phase === "expired" ? 1 : 0);
  }

  await new Promise((r) => setTimeout(r, 15000));
}
console.log(`${stamp()} gave up after 2000 polls`);
process.exit(1);
