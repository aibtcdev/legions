#!/usr/bin/env node
// Provision a genuinely EXTERNAL agent for the marketplace test: a brand-new
// principal (no Legion governance role), funded only with a little testnet STX
// (gas) + sBTC from the public faucet. Prints its mnemonic so it can then act as
// an ordinary x402 client against the gateway (see credit-demo.mjs).
//
//   FUNDER_MNEMONIC="…agent-01…" node spark/fund-external.mjs
import {
  makeSTXTokenTransfer, makeContractCall, broadcastTransaction, AnchorMode,
  PostConditionMode, getAddressFromPrivateKey, TransactionVersion,
} from '@stacks/transactions';
import { StacksTestnet } from '@stacks/network';
import { generateWallet, generateSecretKey } from '@stacks/wallet-sdk';
import { resolveKey, SBTC } from './pay.mjs';

const API = 'https://api.testnet.hiro.so';
const network = new StacksTestnet({ url: API });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function wait(txid, label) {
  for (let i = 0; i < 40; i++) {
    const r = await fetch(`${API}/extended/v1/tx/${txid}`);
    if (r.ok) { const t = await r.json(); if (t.tx_status && t.tx_status !== 'pending') {
      if (t.tx_status !== 'success') throw new Error(`${label} ${txid} -> ${t.tx_status}`);
      return t;
    } }
    await sleep(6000);
  }
  throw new Error(`${label} ${txid} did not confirm`);
}

const main = async () => {
  const funder = await resolveKey({ mnemonic: process.env.FUNDER_MNEMONIC });
  if (!funder) throw new Error('set FUNDER_MNEMONIC (an agent with testnet STX)');

  // 1) fresh external identity — never part of the Legion
  const mnemonic = generateSecretKey();
  const w = await generateWallet({ secretKey: mnemonic, password: '' });
  const extKey = w.accounts[0].stxPrivateKey;
  const extAddr = getAddressFromPrivateKey(extKey, TransactionVersion.Testnet);
  console.log('🆕 external agent:', extAddr);

  // 2) gas: 3 STX from the funder
  const stxTx = await makeSTXTokenTransfer({
    recipient: extAddr, amount: 3_000_000n, senderKey: funder, network,
    anchorMode: AnchorMode.Any, fee: 3000n,
  });
  const stx = await broadcastTransaction(stxTx, network);
  if (stx.error) throw new Error(`STX fund failed: ${stx.error} ${stx.reason ?? ''}`);
  console.log('   funding 3 STX gas, tx', stx.txid, '… waiting');
  await wait(stx.txid, 'stx-fund');

  // 3) sBTC from the public faucet (mints 6.9 sBTC to tx-sender)
  const fTx = await makeContractCall({
    contractAddress: SBTC.address, contractName: SBTC.name, functionName: 'faucet',
    functionArgs: [], senderKey: extKey, network, anchorMode: AnchorMode.Any,
    postConditionMode: PostConditionMode.Deny, fee: 3000n,
  });
  const f = await broadcastTransaction(fTx, network);
  if (f.error) throw new Error(`faucet failed: ${f.error} ${f.reason ?? ''}`);
  console.log('   sBTC faucet, tx', f.txid, '… waiting');
  await wait(f.txid, 'faucet');

  const bal = await (await fetch(`${API}/extended/v1/address/${extAddr}/balances`)).json();
  const sb = Object.entries(bal.fungible_tokens || {}).find(([k]) => k.includes('sbtc-token'));
  console.log(`✅ external agent funded: ${Number(bal.stx.balance)/1e6} STX · sBTC ${sb?.[1]?.balance}`);
  console.log('\nEXTERNAL_MNEMONIC:');
  console.log(mnemonic);
};
main().catch((e) => { console.error('✗', e.message); process.exit(1); });
