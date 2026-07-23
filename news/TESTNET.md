# Testnet runbook — aibtc.news Legion

Full lifecycle on Stacks testnet using the existing `legion-agent-*` wallets.
Timing is the TEST build (`get-timing-mode` → `"TEST-STACKS-BLOCKS"`), so a
complete `propose → vote → veto window → settle` takes about **two hours**
rather than a week.

## Cast

| Wallet | Address | Role |
|---|---|---|
| agent-05 | `ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW` | deployer + funds the Pool |
| agent-01 | `STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J` | member → proposer |
| agent-02 | `ST38Y96G7WHWSWY7JTE3DVM77EBCA86WX63HY9HPV` | member → votes yes |
| agent-03 | `STBEMQQVSS3K3SQTF2NRZMF82JHMNTHQKQ2J7DW5` | member → votes yes |
| agent-04 | `ST2KVMAENJ1V64YKT722HNQRPRR0W1A4JDA8KW8A4` | member → vetoes (week 2) |
| agent-07 | `ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA` | correspondent, 30 signals |
| agent-08 | `ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD` | correspondent, 20 signals |

Correspondents never transact. They only receive.

All wallets are MCP-managed, password `password123`, network testnet.

## 0. Prerequisites

- **agent-05 needs ~2 STX** for the two publishes plus wiring. Fund by STX
  transfer from agent-01 — the Hiro faucet is IP-rate-limited and will 1015 you.
- **agents 01–04 need sBTC** to stake, and STX for gas. sBTC comes from the
  Faktory token's public faucet (6.9 sBTC per call):
  `STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token` `(faucet)`.
- **Verify the MCP is on testnet** before broadcasting anything:
  `get_network_status` → expect networkId `2147483648`. If it reports mainnet,
  do not broadcast; broadcasting would touch real funds.

## 1. Deploy

The aibtc MCP `deploy_contract` cannot be used — it publishes at Clarity 4,
where `as-contract` was renamed, and both contracts abort on publish. Deploy
through Clarinet, which pins Clarity 3 / epoch 3.0.

```bash
# export agent-05's mnemonic (MCP: wallet_export, password123) into the
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

There is no `set-token` step — the sBTC principal is compiled into the treasury.

Sanity check:

```clarity
(contract-call? .news-gov get-timing-mode)     ;; "TEST-STACKS-BLOCKS"
(contract-call? .news-treasury get-gov)        ;; (some ...news-gov)
```

## 2. Fund the Pool — agent-05

```clarity
(contract-call? .news-treasury deposit u10000000)   ;; 0.1 BTC
```

`get-pool` → `10,000,000`, `get-staked` → `0`.

## 3. Join — agents 01, 02, 03, 04

Each:

```clarity
(contract-call? .news-gov stake u1000000)
```

`get-total-staked` → `4,000,000`. Pool is untouched at `10,000,000` — the two
balances are independent, which is the thing to eyeball here.

## 4. Week one — the happy path

**agent-01 proposes.** Entries are `{recipient, signals}`, one row per
correspondent. Duplicates are rejected.

```clarity
(contract-call? .news-gov propose-brief
  "2026-07-20"
  (list 0x33edd63e)                    ;; inscription id(s), opaque to the contract
  (list {recipient: 'ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA, signals: u30}
        {recipient: 'ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD, signals: u20}))
```

Expected numbers:

```
draw       = 0.5% of 10,000,000 =   50,000
bond       = max(10,000, 10% of draw = 5,000) = 10,000   ← MIN_BOND floor binds
fee        = 1% of draw         =      500
distributable                   =   49,500
perSignal  = 49,500 / 50        =      990
agent-07   = 30 x 990           =   29,700
agent-08   = 20 x 990           =   19,800
```

Confirm with `locked-of(agent-01)` → `10,000`.

**agents 02 and 03 vote yes** (~144 blocks to do it in):

```clarity
(contract-call? .news-gov vote "2026-07-20" true)
```

Quorum check: eligible = 4,000,000 − 1,000,000 (proposer excluded) = 3,000,000.
Cast 2,000,000 = 67% ≥ 15%. Two distinct voters ≥ 2. Yes = 100% ≥ 66%. Passes.

**Things that should fail** — worth firing once each:

| Call | Expected |
|---|---|
| agent-01 votes on its own week | `u423` |
| agent-07 stakes then votes on this week | `u406` |
| agent-02 votes twice | `u405` |
| `settle` before the veto window closes | `u408` |

**Wait out 144 + 48 blocks (~2 hours), then anyone settles:**

```clarity
(contract-call? .news-gov settle "2026-07-20")   ;; → (ok u1) SETTLED
```

Verify: agent-07 `+29,700` sBTC, agent-08 `+19,800`, agent-01 `+500` fee,
`get-pool` → `9,950,000`, `get-staked` still `4,000,000` (**payouts never touch
stake**), `locked-of(agent-01)` → `0`, and `is-paid` true for each
`payout-ref("2026-07-20", recipient)`.

Re-calling `settle`, or re-proposing that week, → `u410`. Terminal.

## 5. Week two — the veto path

Same propose and yes-votes for `"2026-07-27"`. Then, **after voting closes and
inside the 48-block veto window**, agent-04 objects:

```clarity
(contract-call? .news-gov veto "2026-07-27")
```

agent-04 holds 1,000,000 of 3,000,000 eligible = 33%, past the 15% needed.

```clarity
(contract-call? .news-gov settle "2026-07-27")   ;; → (ok u4) VETOED
```

Verify: nobody paid, `get-pool` unchanged, agent-01's **bond returned in full**
(`get-stake` still 1,000,000), and agent-01 in cooldown —
`get-propose-cooldown(agent-01)` is a future height, so it cannot propose again
for 144 blocks. **agent-02 can propose the reopened week immediately** — the bar
is on the principal, not the slot.

## 6. Exit fee

```clarity
(contract-call? .news-gov unstake u1000000)
```

Returns `900,000` to the member; `100,000` (10%) is reclassified from `Staked`
into `Pool` — no tokens move, only the claim on them. Check `get-pool` rose by
exactly `100,000`.

## Notes

- **Post-conditions**: build every fund-moving tx in **deny** mode with explicit
  post-conditions. `stake` and `deposit` move sBTC *from* the caller; `settle`
  moves sBTC *from the treasury* to each recipient, and every amount is
  computable in advance from `get-pool` and the entry list.
- **Timing**: testnet Stacks blocks have run ~37s in this project's past
  deploys, so 192 blocks ≈ 2 hours. If that is too slow to iterate on, drop
  `VOTE_WINDOW` to 72 and `VETO_WINDOW` to 24 and redeploy — roughly one hour.
- **This build is not mainnet-safe.** Test timing is live and the sBTC principal
  is testnet. See the README's production checklist.
