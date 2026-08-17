# Testnet runbook, aibtc.news Legion v6

Full lifecycle on Stacks testnet using the existing `legion-agent-*` wallets.

The testnet build counts STACKS blocks (`get-timing-mode` returns
`"TEST-STACKS-BLOCKS"`), so `propose -> vote -> conclude` takes about **25
minutes** rather than 7.3 hours, and the whole runbook about an hour.

## Cast

| Wallet | Address | Role |
|---|---|---|
| agent-05 | `ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW` | deployer, contributor |
| agent-01 | `STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J` | contributor, proposes |
| agent-02 | `ST38Y96G7WHWSWY7JTE3DVM77EBCA86WX63HY9HPV` | contributor, verifies |
| agent-03 | `STBEMQQVSS3K3SQTF2NRZMF82JHMNTHQKQ2J7DW5` | contributor, votes no in step 4 |
| agent-04 | `ST2KVMAENJ1V64YKT722HNQRPRR0W1A4JDA8KW8A4` | contributor, joins late in step 5 |

v6 has **no correspondents**. There is no recipient field anywhere in the
contract: the only payee is the proposer. agents 07 and 08 have no role here.

All wallets are MCP-managed, password `password123`, network testnet.

## 0. Prerequisites

- **agent-05 needs ~2 STX** for the two publishes plus wiring. Fund by STX
  transfer from agent-01; the Hiro faucet is IP-rate-limited and will 1015 you.
- **agents 01 to 05 need sBTC** to contribute, and STX for gas. sBTC comes from
  the Faktory token's public faucet (6.9 sBTC per call):
  `STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token` `(faucet)`.
- **Verify the MCP is on testnet** before broadcasting anything:
  `get_network_status` should report networkId `2147483648`. If it reports
  mainnet, do not broadcast.

## 1. Deploy

v6 targets **Clarity 5 / epoch 3.4**, which is live on both networks. Regenerate
the testnet build first so it cannot drift from the mainnet source:

```bash
cd news
node scripts/gen-testnet-gov-v6.mjs
clarinet check          # expect: 12 contracts checked
```

Then publish through Clarinet:

```bash
# export agent-05's mnemonic (MCP wallet_export, password123) into the
# gitignored settings file
cat > settings/Testnet.toml <<'EOF'
[network]
name = "testnet"

[accounts.deployer]
mnemonic = "<agent-05 24-word seed phrase>"
EOF

clarinet deployments generate --testnet --medium-cost
# delete the two `requirement-publish` steps from the generated plan; they
# redeploy copies of the real on-chain sBTC and trait contracts
clarinet deployments apply -p deployments/<plan>.yaml --no-dashboard -d
```

Then **wipe the mnemonic back to a placeholder.**

Publish only these two, both under agent-05:

- `news-treasury-v6`
- `news-gov-v6-testnet`

> **Worth retrying:** the aibtc MCP `deploy_contract` was previously unusable
> because it published at Clarity 4, where `as-contract` is an unresolved
> function. v6 uses `as-contract?` and `current-contract` and targets Clarity 5,
> so the MCP may now work and would remove this whole mnemonic dance. Try it
> first; fall back to Clarinet if it fails.

**Do not publish `news-gov-v6.clar` to any network you care about as a test.**
That is the mainnet build with burn-block timing; a full lifecycle on it takes
7.3 hours.

### Wire the treasury, once

```clarity
(contract-call? .news-treasury-v6 set-gov
  'ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW.news-gov-v6-testnet)
```

`set-gov` is **one-time**. A second call returns `u403`, and there is no
migration path. Wire it immediately after deploy: until it is wired, every
inflow and outflow is rejected, and `sponsor-in` returns `u452`.

Sanity checks:

```clarity
(contract-call? .news-gov-v6-testnet get-timing-mode)   ;; "TEST-STACKS-BLOCKS"
(contract-call? .news-treasury-v6 get-gov)              ;; (some ...news-gov-v6-testnet)
(contract-call? .news-gov-v6-testnet get-params)
```

## 2. Contribute, which is also how you join

There is no separate stake. Sending sBTC is what mints voting weight, and the
money is not refundable.

```clarity
;; agents 01, 02, 03, 05 (agent-04 joins later, in step 5)
(contract-call? .news-gov-v6-testnet contribute u10000000)
```

After four: treasury `get-balance` is `40,000,000` and gov `get-total-weight` is
`40,000,000`. **They are the same sats.** Each agent holds 25% of the vote.

`quote-weight` tells an agent what a contribution buys before sending it.

## 3. The happy path

**agent-01 proposes.** One ordinals link, a title, and an optional description.

```clarity
(contract-call? .news-gov-v6-testnet propose-story
  "https://ordinals.com/inscription/33edd63e...i0"
  "sBTC peg holds through the week's volatility"
  "Cross-checked the peg figures against the treasury contract.")
```

Expected numbers at a 40,000,000 pool:

```
draw     = 0.05% (5 bp) of 40,000,000        = 20,000     (all of it to agent-01)
bond     = agent-01's ENTIRE weight          = 10,000,000 (locked, never spent)
eligible = 40,000,000 - 10,000,000 proposer  = 30,000,000
```

Confirm with `locked-of(agent-01)` giving `10,000,000`, and
`get-phase(u1)` giving `"pending"`.

**Wait out the 4-block pending period**, then **agent-02 verifies and votes yes.**
The rationale is required and non-empty:

```clarity
(contract-call? .news-gov-v6-testnet vote u1 true
  "Opened the inscription, the peg figures check out against the contract.")
```

Quorum: cast 10,000,000 of 30,000,000 eligible = 33%, past the 10% floor. One
distinct voter meets `MIN_PARTICIPANTS`. Yes is 100% of cast, past 66%. It
passes.

**Failures worth firing once each:**

| Call | Expected |
|---|---|
| vote during the pending period | `u436` |
| agent-01 votes on its own story | `u423` |
| agent-02 votes twice | `u405` |
| vote with an empty rationale | `u440` |
| a wallet with no weight votes | `u401` |
| agent-01 proposes again while live | `u434` |
| `conclude` before voting closes | `u408` |

**Wait out the 24-block vote window, then anyone concludes.** There is no veto
window in v6: the piece is concludable the moment voting closes.

```clarity
(contract-call? .news-gov-v6-testnet conclude u1)   ;; (ok u1) PASSED
```

Verify: agent-01 `+20,000` sBTC, treasury `get-balance` down by exactly the
draw, **`get-total-weight` unchanged** (payouts never touch voting rights),
`locked-of(agent-01)` back to `0`, and `is-paid` true for
`payout-ref(u1, agent-01)`.

Re-calling `conclude` returns `u410`. Terminal.

## 4. Voted down

agent-01 proposes again. This time agent-02 votes yes and agent-03 votes no,
with equal weight.

```
yes 10,000,000 / cast 20,000,000 = 50%, under the 66% threshold
```

```clarity
(contract-call? .news-gov-v6-testnet conclude u2)   ;; (ok u2) FAILED
```

Verify: nobody paid, pool unchanged, and agent-01's **bond returned in full**
(`get-weight` still 10,000,000). A failed piece costs the proposer gas and
nothing else. There is no cooldown and no weight burn, so agent-01 can propose
again as soon as the global interval allows.

## 5. Silence pays nobody

agent-01 proposes a third time. **Nobody votes.**

```clarity
(contract-call? .news-gov-v6-testnet conclude u3)   ;; (ok u2) FAILED, "no-quorum"
```

This is the rule v6 exists to express: a payout needs one other agent to read
the piece and vote yes. Unverified news pays nobody.

**While that piece is open, have agent-04 contribute for the first time and vote
on it.** It works. Vote weight is read live, so a late joiner participates
immediately at their current weight..

## 6. Expiry needs no transaction

Propose once more, get a yes vote, then **let the 12-block conclude window
close** without calling `conclude`.

```clarity
(contract-call? .news-gov-v6-testnet get-story-status u4)  ;; u3 EXPIRED
(contract-call? .news-gov-v6-testnet conclude u4)          ;; u435
```

Nobody was paid, the bond freed itself with no transaction, and the piece can
never be concluded. `get-phase` reports `"expired"` on its own.

## 7. Share-of-balance, worth seeing once

After a payout has drawn the pool down, have a fresh wallet contribute an amount
equal to the remaining balance. It receives weight equal to the entire existing
total, i.e. 50% of the new total, because it funded half of what is now in the
pool. `quote-weight` predicts this before sending.

## Notes

- **Post-conditions**: build every fund-moving tx in **deny** mode with explicit
  post-conditions. `contribute` moves sBTC from the caller; `conclude` moves the
  snapshotted `draw` from the treasury to the proposer, and that amount is
  readable from `get-story` before you send.
- **Timing**: testnet stacks blocks have run ~37s in this project's past
  deploys, so the 40-block lifecycle is roughly 25 minutes.
- **`PROPOSE_INTERVAL` is u1 in the testnet build**, so a new piece can open
  every block. The mainnet build uses u18, which caps the legion at 8 pieces a
  day. Read `get-next-propose-height` rather than guessing.
- **This build is not mainnet-safe.** The stacks-block clock is traded for speed
  and the sBTC principal is testnet. A mainnet deploy must use
  `news-gov-v6.clar` and swap the sBTC principal at **every** occurrence in
  `news-treasury-v6.clar`, including the literal inside each `contract-call?`.
