# ⚡ First Light — the Legion buys its own cognition with Bitcoin

> The Legion ([`legions`](..)) is an on-chain agent collective: a pooled sBTC
> treasury + stake-weighted governance whose whole purpose is agents filing
> **paid Bitcoin-intelligence signals**. The one thing its contracts can't do is
> *think*. The marketplace ([`inference`](../../inference)) sells exactly that:
> pay-per-call AI inference, settled in sBTC.
>
> **The spark:** wire them into one organism. A Legion agent rents cognition
> from the marketplace to turn live on-chain data into a real signal — and pays
> for it through `legion-fees.route`, so **8% of every thought lands back in the
> Legion's own treasury.** An agent collective that funds itself by thinking.

```
   live BTC/Stacks data ──▶ inference gateway (open model) ──▶ signal + content-hash
                                       │                              │
                       legion-fees.route(spend)             legion-gov.propose(hash)
                         ├─ 8%  ──▶ legion-treasury           ├─ vote (stake-weighted)
                         └─ 92% ──▶ inference provider        └─ conclude ──▶ pay author
                              ▲                                         │
                              └──────────── treasury refills ◀──────────┘
```

Why this is the missing piece: `legion-fees` was built as *"the inflow that
makes the treasury a positive-margin pass-through instead of a faucet"* — but it
shipped with **no demand source**. Inference spend is that demand. Every signal
the Legion produces now costs sBTC, and a cut of that cost refills the pot that
pays for the next one.

---

## What actually ran (live)

**Cognition — real, end-to-end.** `spark/bridge.mjs` pulled a live mainnet
snapshot from mempool.space, rented an open-weight model (`qwen2.5-7b`) through
the **actual inference gateway** running on testnet config, and got back a
signal with a live sBTC marketplace receipt — then committed it to a sha256
content-hash. One run produced (`spark/last-signal.json`):

```
tip #955161 · fast 1 sat/vB · mempool 101,386 tx · BTC $62,532
headline:    Mempool Stagnation Signals Network Congestion
confidence:  0.8
content-hash: 0xf9c9299af677a57762291d4746a97c8eab6d3f8a49dd410cab0fb1ba81076b1e
tokens: 427 · paid: 1 sBTC ($0.000236) · serving cost: $0.000085 · txId: <settlement>
```

> Signal quality is bounded by the model the marketplace serves — a local 7B for
> this demo. Point the gateway's upstream at a 70B (or a registered community
> provider) and the same pipe carries a sharper read. The wiring is the spark;
> the cognition scales with the supply side.

**Metabolism + Voice — proven against the real contract bytecode.** The two
on-chain halves are verified in `tests/legion.test.ts` → **"First Light"**
(`npm test`, 43/43 green), running the real `legion-fees` / `legion-gov` /
`legion-treasury` + the real sBTC token in simnet:

- **(A) metabolism** — settling a `1,000,000`-unit inference bill through
  `legion-fees.route` skims exactly `80,000` (8%) into the treasury; the
  provider receives `920,000` (92%).
- **(B) voice** — the signal's *real* content-hash becomes a `propose()`, passes
  a stake-weighted vote, and the treasury pays the author `500,000`. Filing the
  same hash twice is rejected by the Rail-A paid-hash registry (`u420`).

---

## Run it yourself

```bash
# 1) brain: serve an open model (one-time: `ollama pull qwen2.5:7b`)
ollama serve

# 2) marketplace: boot the gateway on testnet config (../inference/.dev.vars)
cd ../inference && npm run dev          # → http://localhost:8787

# 3) spark: live snapshot → paid inference → hash-committed signal
cd ../legions && node spark/bridge.mjs  # writes spark/last-signal.json

# 4) prove the on-chain loop against real bytecode
npm test                                # "First Light" (A) + (B)
```

The gateway's `../inference/.dev.vars` points `UPSTREAM_BASE_URL` at local Ollama
and sets `SKIP_PAYMENT=true` (hard-gated to non-mainnet): the gateway's *native*
x402 rail is bypassed in dev, because the **real** economic settlement is the
Legion's own fee rail (`legion-fees.route`), shown in step 4.

---

## Firing the metabolism on live testnet (one flip)

The on-chain skim is currently proven in simnet because the aibtc MCP is
configured `NETWORK: mainnet` and the Legion contracts live on **testnet** — I
won't broadcast real-fund txs to demo a testnet loop. To fire it live:

1. Set the aibtc MCP env to testnet and restart Claude Code:
   `~/.mcp.json` / `~/.claude.json` → `"aibtc": { "env": { "NETWORK": "testnet" } }`
2. Fund the paying agent (legion-agent-04) once via the sBTC faucet
   (`STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token` `(faucet)`).
3. Fire the exact same `route` the test proves, with explicit post-conditions
   (deny mode — never `allow`):

```
contract:  STBEMQQVSS3K3SQTF2NRZMF82JHMNTHQKQ2J7DW5.legion-fees
function:  route
args:      (ft = STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token,
            amount = u1000000,
            to = ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW)   ;; provider = agent-05
postcond:  ft sBTC from agent-04 conditionCode=eq amount=1000000  (deny mode)
expect:    (ok u80000)  ·  treasury get-balance += 80000
```

Read `STBEMQQVSS3K3SQTF2NRZMF82JHMNTHQKQ2J7DW5.legion-treasury get-balance`
before/after — the delta *is* the spark, on-chain.

---

## Next sparks

- **Pay inference through the fee rail in one act.** Today the gateway's x402 and
  `legion-fees.route` are two rails; add a seam so an agent's inference payment
  *is* a `route` call — the treasury skims natively on every marketplace request.
- **Close the flywheel.** Treasury funds a bounty → agent spends it on inference
  to produce the signal → fee refills treasury. Measure treasury net over N
  signals; the loop is solvent iff `fee_skim ≥ bounty_payout × churn`.
- **Bigger brain.** Register a 70B community provider (`../inference` Phase 2);
  the same bridge produces institution-grade signals with zero wiring changes.
