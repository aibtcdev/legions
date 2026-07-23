# Testnet runbook, aibtc.news Legion (optimistic settlement)

Full lifecycle on Stacks testnet using the existing `legion-agent-*` wallets.
Timing is the TEST build (`get-timing-mode` returns `"TEST-STACKS-BLOCKS"`), so
an unchallenged week takes about **90 minutes** rather than a week, and a
challenged one about three hours.

## Cast

| Wallet | Address | Role |
|---|---|---|
| agent-05 | `ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW` | deployer, and largest contributor |
| agent-01 | `STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J` | contributor, proposes |
| agent-02 | `ST38Y96G7WHWSWY7JTE3DVM77EBCA86WX63HY9HPV` | contributor, votes in disputes |
| agent-03 | `STBEMQQVSS3K3SQTF2NRZMF82JHMNTHQKQ2J7DW5` | contributor, votes in disputes |
| agent-04 | `ST2KVMAENJ1V64YKT722HNQRPRR0W1A4JDA8KW8A4` | contributor, challenges in week two |
| agent-07 | `ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA` | correspondent, 30 signals |
| agent-08 | `ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD` | correspondent, 20 signals |

Correspondents never transact. They only receive.

All wallets are MCP-managed, password `password123`, network testnet.

## 0. Prerequisites

- **agent-05 needs ~2 STX** for the two publishes plus wiring. Fund by STX
  transfer from agent-01; the Hiro faucet is IP-rate-limited and will 1015 you.
- **agents 01 to 04 need sBTC** to contribute, and STX for gas. sBTC comes from
  the Faktory token's public faucet (6.9 sBTC per call):
  `STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token` `(faucet)`.
- **Verify the MCP is on testnet** before broadcasting anything:
  `get_network_status` should report networkId `2147483648`. If it reports
  mainnet, do not broadcast.

## 1. Deploy

The aibtc MCP `deploy_contract` cannot be used: it publishes at Clarity 4, where
`as-contract` was renamed, and both contracts abort on publish. Deploy through
Clarinet, which pins Clarity 3 / epoch 3.0.

```bash
# export agent-05's mnemonic (MCP wallet_export, password123) into the
# gitignored settings file
cd news
cat > settings/Testnet.toml <<'EOF'
[network]
name = "testnet"

[accounts.deployer]
mnemonic = "<agent-05 24-word seed phrase>"
EOF

clarinet check
clarinet deployments apply -p deployments/news.testnet-plan.yaml --no-dashboard -d
```

Then **wipe the mnemonic back to a placeholder.**

Produces, all under `ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW`:

- `.news-treasury`
- `.news-gov`
- treasury wired to gov (`set-gov`, one-shot)

There is no `set-token` step; the sBTC principal is compiled into the treasury.

Sanity check:

```clarity
(contract-call? .news-gov get-timing-mode)     ;; "TEST-STACKS-BLOCKS"
(contract-call? .news-treasury get-gov)        ;; (some ...news-gov)
```

## 2. Contribute, which is also how you join

There is no separate stake. Sending sBTC to the pool is what mints voting
weight, and the money is not refundable.

```clarity
;; agent-05
(contract-call? .news-gov contribute u10000000)
;; agents 01, 02, 03, 04
(contract-call? .news-gov contribute u10000000)
```

After all five: `get-balance` on the treasury is `50,000,000`, and
`get-total-weight` on gov is `50,000,000`. **They are the same sats.** Each
agent holds 20% of the vote.

`quote-weight` tells an agent what a contribution would buy before sending it.

## 3. Week one, the happy path: nobody votes

**agent-01 submits the week.** Entries are `{recipient, signals}`, one row per
correspondent; duplicates are rejected.

```clarity
(contract-call? .news-gov propose-brief
  "2026-07-20"
  (list 0x33edd63e)
  (list {recipient: 'ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA, signals: u30}
        {recipient: 'ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD, signals: u20}))
```

At a 50,000,000 pool:

```
draw        = 0.5% of 50,000,000    = 250,000
bond        = 5bps of total weight  =  25,000  (weight, locked from agent-01)
fee         = 1% of draw            =   2,500
distributable                       = 247,500
per signal  = 247,500 / 50          =   4,950
agent-07    = 30 x 4,950            = 148,500
agent-08    = 20 x 4,950            =  99,000
```

**Then do nothing.** No votes, no confirmations. Wait out 144 blocks (~90 min)
and check:

```clarity
(contract-call? .news-gov can-settle "2026-07-20")   ;; true
(contract-call? .news-gov settle "2026-07-20")        ;; (ok u1) SETTLED
```

Verify: agent-07 `+148,500`, agent-08 `+99,000`, agent-01 `+2,500` fee, pool
down by exactly the draw, `get-total-weight` unchanged, `locked-of(agent-01)`
back to `0`.

**This is the whole point.** Zero governance transactions between propose and
settle.

Failures worth firing once:

| Call | Expected |
|---|---|
| `settle` before the window closes | `u408` |
| `vote` with no challenge open | `u429` |
| agent-01 challenges its own week | `u430` |
| `challenge` after the window closes | `u428` |

## 4. Week two: a challenge that succeeds

Propose `"2026-07-27"` from agent-01, then **inside the challenge window**
agent-04 objects, posting a matching bond:

```clarity
(contract-call? .news-gov challenge "2026-07-27")
```

Settlement is now frozen past the original deadline. agents 02 and 03 vote to
overturn:

```clarity
(contract-call? .news-gov vote "2026-07-27" true)
```

After the dispute window:

```clarity
(contract-call? .news-gov settle "2026-07-27")   ;; (ok u2) OVERTURNED
```

Verify: nobody paid, pool unchanged, **agent-01's bond weight moved to
agent-04** (`get-weight` on both), `get-total-weight` unchanged since it is a
transfer not a burn, and agent-01 in cooldown. agent-02 can propose the reopened
week immediately.

## 5. Week three: a challenge that fails

Same setup, but let the dispute window pass with **nobody voting**.

```clarity
(contract-call? .news-gov settle "2026-08-03")   ;; (ok u1) SETTLED
```

Verify: correspondents paid as normal, and **agent-04's bond weight moved to
agent-01**. The proposal stands by default, so a cheap objection cannot freeze a
week nobody actually disputes, and the challenger pays for trying.

## 6. Share-of-balance, worth seeing once

After a settlement has drawn the pool down, have a fresh wallet contribute an
amount equal to the remaining balance. It should receive weight equal to the
entire existing total, i.e. 50% of the new total, because it funded half of what
is now in the pool. `quote-weight` predicts this before sending.

## Notes

- **Post-conditions**: build every fund-moving tx in **deny** mode with explicit
  post-conditions. `contribute` moves sBTC from the caller; `settle` moves sBTC
  from the treasury to each recipient, and every amount is computable in advance
  from `get-balance` and the entry list.
- **Timing**: testnet Stacks blocks have run ~37s in this project's past
  deploys, so 144 blocks is roughly 90 minutes. Halve both windows if that is
  still too slow to iterate.
- **This build is not mainnet-safe.** Test timing is live and the sBTC principal
  is testnet. See the README's production checklist.
