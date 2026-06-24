#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  Legion ⇄ Inference — "First Light" bridge
//
//  The Legion's whole thesis is agents filing *paid Bitcoin intelligence
//  signals*. The one thing the contracts can't do is the thinking. This bridge
//  is the missing organ: it lets a Legion agent rent cognition from the AIBTC
//  inference marketplace (../inference) to turn live on-chain data into a real
//  signal — and it settles that spend through `legion-fees.route`, so 8% of
//  every thought flows back into the Legion's own treasury.
//
//      live BTC/Stacks data ──▶ inference gateway (open model) ──▶ signal
//                                        │
//                          legion-fees.route(amount) ──▶ 8% ──▶ treasury
//                                        └──────────── 92% ──▶ provider
//
//  This step does the COGNITION (data → paid signal + content-hash). The
//  on-chain settlement (the 8% skim) is fired separately against the live
//  testnet contracts — see spark/SPARK.md.
//
//  Usage:  node spark/bridge.mjs
//  Env:    GATEWAY (default http://localhost:8787)  MODEL (default qwen2.5-7b)
// ─────────────────────────────────────────────────────────────────────────────
import { createHash } from 'node:crypto';
import { routePayment, resolveKey } from './pay.mjs';

const GATEWAY = process.env.GATEWAY || 'http://localhost:8787';
const MODEL = process.env.MODEL || 'qwen2.5-7b';
const BEAT = process.env.BEAT || 'bitcoin-macro';

const j = (u, o) => fetch(u, o).then(async (r) => {
  const t = await r.text();
  try { return JSON.parse(t); } catch { throw new Error(`${u} → ${r.status} ${t.slice(0, 200)}`); }
});

// 1) RAW MATERIAL — pull a live, public on-chain snapshot (no key needed).
async function snapshot() {
  const [fees, mp, tipHeight, price] = await Promise.all([
    j('https://mempool.space/api/v1/fees/recommended'),
    j('https://mempool.space/api/mempool'),
    j('https://mempool.space/api/blocks/tip/height').catch(() => null),
    j('https://mempool.space/api/v1/prices').catch(() => ({})),
  ]);
  return {
    capturedAt: new Date().toISOString(),
    btcUsd: price?.USD ?? null,
    tipHeight,
    fees, // fastestFee / halfHourFee / hourFee / economyFee / minimumFee (sat/vB)
    mempool: { txCount: mp?.count, vsizeBytes: mp?.vsize, totalFeeBtc: (mp?.total_fee ?? 0) / 1e8 },
  };
}

// 2) COGNITION — the Legion agent rents the open model to read the tape.
//    Option B paid flow: POST → if 402, settle via legion-fees.route on-chain
//    (the treasury skims 8%), then retry with the settled txid in the header.
async function think(snap) {
  const system =
    'You are a Legion intelligence agent. From the live Bitcoin/Stacks snapshot, ' +
    'produce ONE high-signal, non-obvious read for the bitcoin-macro beat. Be ' +
    'specific and quantitative, cite the data points it rests on, and avoid ' +
    'hype. Respond as STRICT JSON only, no prose, with keys: ' +
    'headline (<=120 chars), body (<=600 chars), confidence (0-1 number), ' +
    'data_points (array of short strings), tags (array of lowercase slugs).';
  const user = `Live snapshot:\n${JSON.stringify(snap, null, 2)}`;
  const body = JSON.stringify({
    model: MODEL,
    messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
    temperature: 0.4,
    max_tokens: 600,
    response_format: { type: 'json_object' },
  });
  const url = `${GATEWAY}/v1/chat/completions`;
  const post = (headers = {}) =>
    fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body });

  // First attempt — no payment.
  let res = await post();
  let payment = null;

  if (res.status === 402) {
    // Parse the fee-rail challenge. Field names follow the Option B wire protocol
    // in the gist (legion-inference-1.0.md §2); adjust here if the gateway differs.
    const ch = await res.json();
    const c = ch.accepts?.[0] ?? ch; // tolerate both wrapped + flat challenge shapes
    const amount = c.price ?? c.amount ?? c.maxAmountRequired;
    const provider = c.provider ?? c.payTo;
    const feeContract = c.feeContract;
    const agentKey = await resolveKey();
    if (!agentKey) throw new Error('gateway requires payment (402) but no STACKS_PRIVATE_KEY / STACKS_MNEMONIC set');

    console.log(`   402 → settling ${amount} sBTC via legion-fees.route → treasury skims 8%…`);
    payment = await routePayment({ privateKey: agentKey, amount, provider, feeContract });
    console.log(`   paid: tx ${payment.txid} confirmed · treasury +${payment.fee} · provider +${payment.amount - payment.fee}`);

    // Retry with the settled txid the gateway will verify on-chain.
    res = await post({ 'X-PAYMENT-ROUTE-TXID': payment.txid, 'X-PAYMENT-TOKEN-TYPE': 'sBTC' });
  }

  const t = await res.text();
  let data;
  try { data = JSON.parse(t); } catch { throw new Error(`${url} → ${res.status} ${t.slice(0, 200)}`); }
  if (!res.ok) throw new Error(`gateway ${res.status}: ${t.slice(0, 200)}`);

  const raw = data?.choices?.[0]?.message?.content ?? '';
  let signal;
  try { signal = JSON.parse(raw); }
  catch { signal = JSON.parse(raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1)); }
  return { signal, receipt: data?._marketplace, usage: data?.usage, payment };
}

const main = async () => {
  console.log('⚡  Legion ⇄ Inference — First Light\n');
  console.log('① Pulling live on-chain snapshot…');
  const snap = await snapshot();
  console.log(`   tip #${snap.tipHeight} · fast ${snap.fees?.fastestFee} sat/vB · ` +
    `mempool ${snap.mempool.txCount?.toLocaleString()} tx · BTC $${snap.btcUsd?.toLocaleString?.() ?? '—'}\n`);

  console.log(`② Renting cognition from the marketplace (${MODEL})…`);
  const { signal, receipt, usage, payment } = await think(snap);

  // 3) MINT THE SIGNAL — canonical bytes + content-hash for the on-chain proposal.
  const canonical = JSON.stringify({ beat: BEAT, ...signal, snapshotAt: snap.capturedAt });
  const contentHash = createHash('sha256').update(canonical).digest('hex');

  console.log('\n──────────────────────────  SIGNAL  ──────────────────────────');
  console.log(`beat:        ${BEAT}`);
  console.log(`headline:    ${signal.headline}`);
  console.log(`body:        ${signal.body}`);
  console.log(`confidence:  ${signal.confidence}`);
  console.log(`data_points: ${(signal.data_points || []).map((d) => `\n   • ${d}`).join('')}`);
  console.log(`tags:        ${(signal.tags || []).join(', ')}`);
  console.log('───────────────────────────────────────────────────────────────');
  console.log(`content-hash (sha256): 0x${contentHash}`);
  console.log(`tokens: ${usage?.total_tokens}  ·  serving cost: $${receipt?.servingCostUsd}`);
  if (payment) {
    console.log(`settlement: legion-fees.route tx ${payment.txid}  ·  ` +
      `treasury skim +${payment.fee} sBTC  ·  provider +${payment.amount - payment.fee} sBTC`);
  } else {
    console.log('settlement: dev mode (gateway SKIP_PAYMENT) — no on-chain skim');
  }

  // Machine-readable handoff for the on-chain settlement step.
  const out = {
    beat: BEAT, signal, contentHash: `0x${contentHash}`, snapshot: snap, receipt, usage,
    payment: payment && { txid: payment.txid, amount: payment.amount.toString(), fee: payment.fee.toString() },
  };
  await import('node:fs/promises').then((fs) =>
    fs.writeFile(new URL('./last-signal.json', import.meta.url), JSON.stringify(out, null, 2)));
  console.log('\n→ wrote spark/last-signal.json (handoff to on-chain settlement)');
};

main().catch((e) => { console.error('✗', e.message); process.exit(1); });
