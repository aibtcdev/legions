#!/usr/bin/env node
// Register a Legion in legion-registry (reusable across legions for "multi").
//   KIND=provider MODEL=qwen2.5-7b TREASURY=ADDR.legion-treasury \
//   FEES=ADDR.legion-fees URI="..." STACKS_MNEMONIC="..." node spark/register-legion.mjs
import {
  makeContractCall, broadcastTransaction, AnchorMode, PostConditionMode,
  stringAsciiCV, contractPrincipalCV, someCV, noneCV, cvToValue,
} from '@stacks/transactions';
import { StacksTestnet } from '@stacks/network';
import { resolveKey } from './pay.mjs';

const API = 'https://api.testnet.hiro.so';
const [REG_ADDR, REG_NAME] = (process.env.REGISTRY || 'STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J.legion-registry').split('.');
const KIND = process.env.KIND || 'provider';
const MODEL = process.env.MODEL || 'qwen2.5-7b';
const URI = process.env.URI || '';
const TREASURY = process.env.TREASURY;          // "ADDR.legion-treasury" (required)
const FEES = process.env.FEES;                  // "ADDR.legion-fees" (optional)
const GOV = process.env.GOV;                    // "ADDR.legion-gov" (optional)

const cp = (s) => { const [a, n] = s.split('.'); return contractPrincipalCV(a, n); };
const optCp = (s) => (s ? someCV(cp(s)) : noneCV());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const main = async () => {
  const key = await resolveKey();
  if (!key) throw new Error('set STACKS_MNEMONIC / STACKS_PRIVATE_KEY (the registering owner)');
  if (!TREASURY) throw new Error('set TREASURY=ADDR.legion-treasury');
  const network = new StacksTestnet({ url: API });

  console.log(`registering ${KIND} legion "${MODEL}" -> ${REG_ADDR}.${REG_NAME}`);
  const tx = await makeContractCall({
    contractAddress: REG_ADDR, contractName: REG_NAME, functionName: 'register',
    functionArgs: [stringAsciiCV(KIND), cp(TREASURY), optCp(GOV), optCp(FEES), stringAsciiCV(MODEL), stringAsciiCV(URI)],
    senderKey: key, network, anchorMode: AnchorMode.Any, postConditionMode: PostConditionMode.Deny, fee: 12000n,
  });
  const res = await broadcastTransaction(tx, network);
  if (res.error) throw new Error(`broadcast failed: ${res.error} ${res.reason ?? ''}`);
  console.log('tx', res.txid, '… waiting');
  for (let i = 0; i < 40; i++) {
    const r = await fetch(`${API}/extended/v1/tx/${res.txid}`);
    if (r.ok) { const t = await r.json(); if (t.tx_status && t.tx_status !== 'pending') {
      if (t.tx_status !== 'success') throw new Error(`tx ${res.txid} -> ${t.tx_status}`);
      const id = t.tx_result?.repr;
      console.log(`✅ registered. result ${id}  (tx ${res.txid})`);
      return;
    } }
    await sleep(6000);
  }
  throw new Error('did not confirm in time');
};
main().catch((e) => { console.error('✗', e.message); process.exit(1); });
