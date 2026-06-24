#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  On-chain inference credits — "pay once, use many" (Direction A unlock)
//
//  Proves the credits rail: the agent makes ONE on-chain legion-fees.route
//  top-up (treasury skims 8% once), then draws N inference calls against that
//  credit with ZERO further Stacks transactions. This is what makes the rail
//  usable by external agents — per-call gas/signing would otherwise kill it.
//
//  Usage:  STACKS_MNEMONIC="…" CALLS=5 node spark/credit-demo.mjs
// ─────────────────────────────────────────────────────────────────────────────
import { routePayment, resolveKey } from './pay.mjs';

const GATEWAY = process.env.GATEWAY || 'http://localhost:8787';
const MODEL = process.env.MODEL || 'qwen2.5-7b';
const CALLS = Number(process.env.CALLS || 5);
const url = `${GATEWAY}/v1/chat/completions`;

const ask = (headers, content) => fetch(url, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', ...headers },
  body: JSON.stringify({ model: MODEL, messages: [{ role: 'user', content }], max_tokens: 8 }),
});

async function challenge() {
  const r = await ask({}, 'ping');
  if (r.status !== 402) throw new Error(`expected 402 challenge, got ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const ch = await r.json();
  const c = ch.accepts?.[0] ?? ch;
  return { price: BigInt(c.price ?? c.amount), provider: c.provider ?? c.payTo, feeContract: c.feeContract };
}

const main = async () => {
  const key = await resolveKey();
  if (!key) throw new Error('set STACKS_MNEMONIC or STACKS_PRIVATE_KEY');

  console.log('⚡ On-chain inference credits — pay once, use many\n');
  const { price, provider, feeContract } = await challenge();
  const topup = price * BigInt(CALLS);
  console.log(`per-call price ${price} sBTC · topping up ${topup} for ~${CALLS} calls → ONE route tx…`);

  const pay = await routePayment({ privateKey: key, amount: topup, provider, feeContract });
  console.log(`✓ top-up tx ${pay.txid} confirmed · treasury +${pay.fee} (8%) · provider +${pay.amount - pay.fee}\n`);

  let served = 0;
  for (let i = 1; i <= CALLS + 1; i++) {
    const r = await ask({ 'X-PAYMENT-ROUTE-TXID': pay.txid }, `ping ${i}`);
    const remaining = r.headers.get('X-LEGION-CREDIT-REMAINING');
    const body = await r.json().catch(() => ({}));
    if (r.status === 200) {
      served++;
      console.log(`call ${i}: ✓ "${(body?.choices?.[0]?.message?.content || '').trim()}" · credit left ${remaining} · 0 new tx`);
    } else {
      console.log(`call ${i}: ${r.status} ${body?.code || body?.error} → credit drained, would top up again`);
      break;
    }
  }
  console.log(`\n${served} inference calls served from 1 on-chain transaction. Treasury skimmed once.`);
};

main().catch((e) => { console.error('✗', e.message); process.exit(1); });
