#!/usr/bin/env node
// Onboard an inference provider into a Provider Legion's guild: post a refundable
// sBTC bond + advertise a model/endpoint. Reusable across guilds.
//   PROVIDERS=ADDR.legion-providers MODEL=qwen2.5-7b ENDPOINT=https://... BOND=1000000 \
//   STACKS_MNEMONIC="..." node spark/provider-register.mjs
import {
  makeContractCall, broadcastTransaction, AnchorMode, PostConditionMode,
  FungibleConditionCode, createAssetInfo, makeStandardFungiblePostCondition,
  uintCV, stringAsciiCV, contractPrincipalCV, getAddressFromPrivateKey, TransactionVersion,
} from '@stacks/transactions';
import { StacksTestnet } from '@stacks/network';
import { resolveKey, SBTC } from './pay.mjs';

const API = 'https://api.testnet.hiro.so';
const [ADDR, NAME] = (process.env.PROVIDERS || 'STGX5YP51NKM69ZMP6DVB6GAJAANCG5WB3718KD9.legion-providers').split('.');
const MODEL = process.env.MODEL || 'qwen2.5-7b';
const ENDPOINT = process.env.ENDPOINT || 'https://local-dev/v1';
const BOND = BigInt(process.env.BOND || '1000000');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const main = async () => {
  const key = await resolveKey();
  if (!key) throw new Error('set STACKS_MNEMONIC / STACKS_PRIVATE_KEY (the provider)');
  const network = new StacksTestnet({ url: API });
  const me = getAddressFromPrivateKey(key, TransactionVersion.Testnet);

  console.log(`onboarding provider ${me} -> ${ADDR}.${NAME} (model ${MODEL}, bond ${BOND})`);
  const tx = await makeContractCall({
    contractAddress: ADDR, contractName: NAME, functionName: 'register',
    functionArgs: [contractPrincipalCV(SBTC.address, SBTC.name), stringAsciiCV(MODEL), stringAsciiCV(ENDPOINT), uintCV(BOND)],
    senderKey: key, network, anchorMode: AnchorMode.Any,
    postConditionMode: PostConditionMode.Deny,
    postConditions: [makeStandardFungiblePostCondition(
      me, FungibleConditionCode.Equal, BOND, createAssetInfo(SBTC.address, SBTC.name, SBTC.asset))],
    fee: 12000n,
  });
  const res = await broadcastTransaction(tx, network);
  if (res.error) throw new Error(`broadcast failed: ${res.error} ${res.reason ?? ''}`);
  console.log('tx', res.txid, '… waiting');
  for (let i = 0; i < 40; i++) {
    const r = await fetch(`${API}/extended/v1/tx/${res.txid}`);
    if (r.ok) { const t = await r.json(); if (t.tx_status && t.tx_status !== 'pending') {
      if (t.tx_status !== 'success') throw new Error(`tx ${res.txid} -> ${t.tx_status}`);
      console.log(`✅ provider bonded (${BOND}). tx ${res.txid}`);
      return;
    } }
    await sleep(6000);
  }
  throw new Error('did not confirm in time');
};
main().catch((e) => { console.error('✗', e.message); process.exit(1); });
