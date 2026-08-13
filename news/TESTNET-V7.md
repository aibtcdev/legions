# Testnet runbook, aibtc.news Legion v7

v7 is v6 plus two rules. **No story may be proposed until 21 agents hold voting
weight**, and once they do, **one other agent voting yes is enough to pay**, at
any roster size, because `VOTING_QUORUM` drops 10 to 0 and `MIN_PARTICIPANTS`
carries the rule instead.

The v6 runbook (`TESTNET.md`) still describes the v6 legion, which stays on
chain untouched. Everything below is a **separate deployment** under new contract
names; nothing migrates.

## What changed against v6

| | v6 | v7 |
|---|---|---|
| Members required to propose | none | **21** (`MIN_MEMBERS`), once, then never again |
| `VOTING_QUORUM` | 10% of eligible | **0**, no turnout floor by weight |
| Backing | none | **yes weight must be at least the draw**, else `under-backed` |
| What a payout needs | one reader holding 10% of eligible | one reader holding at least the draw |
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
#   sBTC to contribute   -> ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW.sbtc-token (faucet)
```

Each of the 21 needs sBTC for its contribution and STX for gas. Our own mock
sBTC has a public `faucet` giving 6.9 sBTC per call, so sBTC is free; STX is the
constraint, and the Hiro faucet is IP-rate-limited and will 1015 you. Fund from
agent-01 instead.

> **The token is ours, and that matters for what a testnet run proves.** v7
> points at `ST2VN1G6….sbtc-token` (source of record in
> `contracts/sbtc-token.clar`), deployed after the 2026-07-30 testnet reset wiped
> the third-party Faktory token that v3 to v6 reference. That old contract is now
> a 404, so those versions can no longer be published at all. Because our faucet
> mints without limit, **every economic property of the legion is unenforced on
> testnet**: voting weight is free, so the Sybil and drain findings in the audit
> are not merely cheap there, they are costless. Testnet proves mechanics, never
> economics.

Until all 21 have contributed, `propose-story` returns `u441` and
`propose-status` reports `membersOk: false` with a live `memberCount`.

## 1. Deploy

v7 targets **Clarity 6 / epoch 4.0**, live on mainnet since Bitcoin block 960,230
(about 30 July 2026). v6 targeted Clarity 5; v7 moves up because these contracts
are immutable, so the version chosen at publish is the version this legion runs
on for its whole life. Verified: the sources compile and the full suite passes
at Clarity 6 with no changes.

> **Check what actually got published.** The MCP `deploy_contract` pinned
> Clarity 4 when it published v6. Nothing in v7 uses Clarity 5 or 6 syntax, so a
> Clarity 4 publish would still work, and you would silently get a contract that
> cannot ever call `get-bitcoin-tx-output?` or `verify-merkle-proof`. After
> deploying, read the published version back with `get_contract_info` and
> confirm it is 6. If the MCP pins something older, deploy through Clarinet
> instead.

Regenerate the testnet build first so it
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
(contract-call? .news-gov-v7-testnet get-params)        ;; minMembers u21, votingQuorum u0
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

That single vote is all it takes: there is no turnout floor by weight, one
distinct voter meets `MIN_PARTICIPANTS`, and yes is 100% of cast, past the 66%
threshold. Wait out the 24-block vote window and conclude:

```clarity
(contract-call? .news-gov-v7-testnet conclude u1)   ;; (ok u1) PASSED
```

Verify the proposer is `+105,000` sBTC, the treasury is down by exactly the draw,
and `get-total-weight` is unchanged.

## 4. Silence still pays nobody

Propose again, let nobody vote, conclude: `FAILED`, reason `no-quorum`. This is
the rule the legion exists to express, and v7 does not soften it. With quorum at
0 it is `MIN_PARTICIPANTS` that fails an unread story, not the turnout maths: no
voters, no payout.

## 5. Growth does not raise the bar

Worth proving once on chain, because it is the reason quorum is 0. Seat a 22nd
member, ideally one holding far more weight than the rest, and have it stay
silent. Propose, have one ordinary member vote yes, conclude. It **pays**.

Under the 10% quorum v6 used, and under the 5% this PR originally carried, that
same vote would have failed as `no-quorum`: turnout was measured against all
seated weight, so a dormant member kept dragging the percentage down and the
number of active readers needed grew with the roster. That is now gone. What a
payout requires does not change as the legion grows or as members go quiet.

## Notes

- **Backing prices the drain, it does not prevent it.** `conclude` requires the
  yes weight to be at least the draw, which is what stops a floor-stake wallet
  authorising a payout from a pool of any size. The bar is the draw itself, so it
  tracks the money at stake and never the roster, and an ordinary member of a
  21-way legion holds about 95x it. But backing weight is bought once while the
  draw recurs, so an attacker holding just over one draw breaks even after about
  two stories and profits after that. Measured, not assumed: a 175,000-sat stake
  extracted 629,734 over six stories. Raising the multiple raises the payback
  period in proportion, and costs liveness in the same proportion. This is the
  open trade-off; see the audit.
- **`VOTING_QUORUM` is 0, and the dial is kept rather than deleted.** There is
  no turnout floor by weight; `MIN_PARTICIPANTS` (1) is the whole participation
  rule. The constant stays in the source and in `get-params` so a later version
  can raise it by changing one number rather than reshaping `conclude`, and so a
  UI reads an explicit `votingQuorum: u0` instead of inferring it from an absent
  field. Turnout is still fully recorded per story: `get-story` carries
  `voterCount`, `yesWeight`, `noWeight`, and `eligibleSnapshot`.
- **The trade this makes.** Quorum was what made a colluding pair expensive. At 0
  two agents can approve each other's stories, bounded only by `PROPOSE_INTERVAL`
  (8 stories a day on mainnet) and the 5 bp draw. Still holding them back: a
  proposer can never vote on its own story, and a single no vote blocks a single
  yes at the 66% threshold. If collusion ever shows up in practice, raising
  `VOTING_QUORUM` or `MIN_PARTICIPANTS` is the lever, and it means a new
  deployment.
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
