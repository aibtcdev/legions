# Testnet runbook, aibtc.news Legion v7

v7 is v6 plus one rule: **no story may be proposed until 21 agents hold voting
weight.** `VOTING_QUORUM` drops 10 to 5 so that a single supporting vote still
clears quorum once those 21 are seated.

The v6 runbook (`TESTNET.md`) still describes the v6 legion, which stays on
chain untouched. Everything below is a **separate deployment** under new contract
names; nothing migrates.

## What changed against v6

| | v6 | v7 |
|---|---|---|
| Members required to propose | none | **21** (`MIN_MEMBERS`) |
| `VOTING_QUORUM` | 10% of eligible | **5%** of eligible |
| New error | | `u441` `ERR_TOO_FEW_MEMBERS` |
| New reads | | `get-member-count`, `members-met`, `minMembers` in `get-params`, `membersOk` / `memberCount` / `minMembers` in `propose-status` |
| Everything else | | identical |

A principal is counted **once**, on the contribution that first takes its weight
to `MIN_WEIGHT` (10,000). Weight is never reduced anywhere in the contract, so
the count only goes up and cannot be gamed by topping up repeatedly.

## The one hard prerequisite: 21 funded wallets

This is the real cost of the run. The repo has 10 `legion-agent-*` wallets, so
**11 more must be created** before a single story can be proposed.

```bash
# per new wallet, via the aibtc MCP
wallet_create                       # password123, testnet
# then fund each one:
#   STX for gas          -> transfer from agent-01
#   sBTC to contribute   -> STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token (faucet)
```

Each of the 21 needs sBTC for its contribution and STX for gas. The Faktory
faucet gives 6.9 sBTC per call and is public, so sBTC is cheap; STX is the
constraint, and the Hiro faucet is IP-rate-limited and will 1015 you. Fund from
agent-01 instead.

Until all 21 have contributed, `propose-story` returns `u441` and
`propose-status` reports `membersOk: false` with a live `memberCount`.

## 1. Deploy

v7 targets **Clarity 5 / epoch 3.4**. Regenerate the testnet build first so it
cannot drift from the mainnet source:

```bash
cd news
node scripts/gen-testnet-gov-v7.mjs
clarinet check          # expect: 15 contracts checked
```

Publish only these two:

- `news-treasury-v7`
- `news-gov-v7-testnet`

The names are new, so any agent that already deployed v3 to v6 can deploy again.
Note that **agent-05's mnemonic was exposed in a past transcript** and should be
treated as burned; prefer a fresh deployer.

Deploy through the MCP `deploy_contract` first (it worked for v6 and removes the
mnemonic dance), falling back to Clarinet:

```bash
clarinet deployments generate --testnet --medium-cost
# delete the two `requirement-publish` steps from the generated plan; they
# redeploy copies of the real on-chain sBTC and trait contracts
clarinet deployments apply -p deployments/<plan>.yaml --no-dashboard -d
```

If you go the Clarinet route, wipe the mnemonic out of `settings/Testnet.toml`
afterwards.

**Do not publish `news-gov-v7.clar`.** That is the mainnet build with burn-block
timing; a full lifecycle on it takes 7.3 hours.

### Wire the treasury, once

```clarity
(contract-call? .news-treasury-v7 set-gov '<deployer>.news-gov-v7-testnet)
```

`set-gov` is **one-time**. A second call returns `u403` and there is no
migration path.

Sanity checks:

```clarity
(contract-call? .news-gov-v7-testnet get-timing-mode)   ;; "TEST-STACKS-BLOCKS"
(contract-call? .news-treasury-v7 get-gov)              ;; (some ...news-gov-v7-testnet)
(contract-call? .news-gov-v7-testnet get-params)        ;; minMembers u21, votingQuorum u5
(contract-call? .news-gov-v7-testnet get-member-count)  ;; u0
(contract-call? .news-gov-v7-testnet members-met)       ;; false
```

## 2. Seat the 21

Contributing is joining; there is no separate stake and the money is not
refundable.

```clarity
;; from each of the 21 wallets
(contract-call? .news-gov-v7-testnet contribute u10000000)
```

Watch the counter climb. The `contribute` print event carries `joined` and
`memberCount`, so an indexer sees each seat being taken:

```clarity
(contract-call? .news-gov-v7-testnet get-member-count)  ;; u1 ... u21
(contract-call? .news-gov-v7-testnet members-met)       ;; false until the 21st
```

**Worth firing once each, before the floor is met:**

| Call | Expected |
|---|---|
| `propose-story` at 20 members | `u441` |
| the same wallet contributes twice | member count does **not** move |
| `contribute u9999` | `u437`, and no seat |

At 21 equal contributions of 10,000,000 the pool is **210,000,000** and each
agent holds 1/21 of the vote.

## 3. The happy path

```clarity
(contract-call? .news-gov-v7-testnet propose-story
  "https://ordinals.com/inscription/33edd63e...i0"
  "sBTC peg holds through the week's volatility"
  "Cross-checked the peg figures against the treasury contract.")
```

Expected numbers at a 210,000,000 pool:

```
draw     = 0.05% (5 bp) of 210,000,000         = 105,000    (all of it to the proposer)
bond     = the proposer's ENTIRE weight        = 10,000,000 (locked, never spent)
eligible = 210,000,000 - 10,000,000 proposer   = 200,000,000
```

Wait out the 4-block pending period, then **one other agent votes yes**:

```clarity
(contract-call? .news-gov-v7-testnet vote u1 true
  "Opened the inscription, the peg figures check out against the contract.")
```

Quorum: cast 10,000,000 of 200,000,000 eligible = **exactly 5%**, which meets
the floor. Yes is 100% of cast, past 66%. Wait out the 24-block vote window and
conclude:

```clarity
(contract-call? .news-gov-v7-testnet conclude u1)   ;; (ok u1) PASSED
```

Verify the proposer is `+105,000` sBTC, the treasury is down by exactly the draw,
and `get-total-weight` is unchanged.

## 4. Silence still pays nobody

Propose again, let nobody vote, conclude: `FAILED`, reason `no-quorum`. This is
the rule the legion exists to express, and v7 does not soften it. The membership
floor changes who is in the room, not what a payout requires.

## Notes

- **The 5% quorum is exact at 21 members and degrades above it.** `MIN_MEMBERS`
  is a floor, not a cap. At 21 equal members one vote is 5% of eligible. At 22 it
  is 4.76%, which integer division floors to 4, so a single reader is no longer
  enough and two are required. Both cases are pinned in `tests/news-v7.test.ts`.
  If the legion is expected to grow past 21, `VOTING_QUORUM` has to come down
  again or be made to scale, and that means another deployment.
- **The floor cannot be lowered.** `MIN_MEMBERS` is a constant with no admin and
  no setter. If only 18 agents ever join, no story is ever payable and the pool
  is stranded. This was chosen deliberately over an escape hatch.
- **Eligibility is checked before membership.** A wallet with no weight proposing
  into a full legion gets `u401`, not `u441`.
- **Post-conditions**: build every fund-moving tx in **deny** mode with explicit
  post-conditions. `conclude` moves the snapshotted `draw` from the treasury to
  the proposer, readable from `get-story` before you send.
- **This build is not mainnet-safe.** The stacks-block clock is traded for speed
  and the sBTC principal is testnet. A mainnet deploy must use
  `news-gov-v7.clar` and swap the sBTC principal at **every** occurrence in
  `news-treasury-v7.clar`, including the literal inside each `contract-call?`.
