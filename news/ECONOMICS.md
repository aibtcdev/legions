# news Legion v6: weight, sponsorship, and attack cost

Analysis of `news-gov-v6.clar` + `news-treasury-v6.clar`, Clarity 5 / epoch 3.4.

**Method.** Every formula below is derived from the contract's own comparisons, then
checked against simnet at the boundary: one unit below the predicted threshold and one
unit at it. The v6 attack-cost runs live in `tests/news-v6-economics.test.ts` and fail if
a formula is off by a single sat. Where a number is derived rather than executed, it says
so. Nothing here is estimated from intuition.

**Frame.** Unless stated otherwise, figures describe a pool that has not yet paid out,
where weight equals sats 1:1. Section 3 covers what changes after payouts. This frame is
stated, not assumed away: it is the most attacker-hostile state, and section 9 shows the
attack gets cheaper in sats as the pool ages.

---

## 0. What changed from v5, and what it did to the numbers

Three changes, each with a measured consequence.

| Change | Effect on attack cost | Effect on extraction |
|---|---|---|
| Veto removed | **cheaper**: 5.68A → 1.94A to take control | none |
| `VOTING_QUORUM` 15 → 10, `MIN_PARTICIPANTS` 2 → 1 | **cheaper** when undefended: 0.186A → 0.121A | none |
| `PROPOSE_INTERVAL` 1 → 18 | none | **18x slower**: 144/day → 8/day |

Net: taking control got cheaper, draining what you took got much slower. At the
sponsorship ratio that mattered most in v5 (r=48), break-even moved from **1.5 days to
9.7 days**. The rate limit more than paid for the weaker gate.

The honest reading is that v6 traded a defence that required constant attention (the veto,
worth 19x when used and 0x when nobody was watching) for one that requires none at all
(a hard cap in the contract). Section 11 covers why the veto had to go regardless.

---

## 1. Constants

Read from source, not from memory.

| Constant | v5 | v6 | Meaning |
|---|---|---|---|
| `MIN_CONTRIBUTION` | 10,000 | 10,000 | floor to join, on sats sent |
| `MIN_WEIGHT` | 10,000 | 10,000 | floor to propose or vote |
| `MIN_SPONSOR` | 100,000 | 100,000 | floor to sponsor |
| `DRAW_BPS` | 5 (0.05%) | 5 (0.05%) | paid to proposer per approved story |
| `VOTING_QUORUM` | 15% | **10%** | of eligible weight that must vote |
| `VOTING_THRESHOLD` | 66% | 66% | of cast weight that must be yes |
| `VETO_QUORUM` | 15% | **removed** | — |
| `MIN_PARTICIPANTS` | 2 | **1** | distinct voters required |
| `VOTING_DELAY` | 2 blocks | 2 blocks | proposal visible, not yet votable |
| `VOTE_WINDOW` | 30 blocks | 30 blocks | voting open |
| `VETO_WINDOW` | 6 blocks | **removed** | — |
| `CONCLUDE_WINDOW` | 12 blocks | 12 blocks | window to settle before expiry |
| `PROPOSE_INTERVAL` | 1 block | **18 blocks** | global rate limit on proposals |
| lifecycle | 50 blocks | **44 blocks** | propose to expiry |

**Every figure in this document is the MAINNET build.** The analysis targets
`news-gov-v6.clar`, which returns `get-timing-mode` = `"PROD-BURN"` and counts Bitcoin
blocks at ~10 min each; the tests advance time with `mineEmptyBurnBlocks`. So "44 blocks"
means 7.3 hours and "8/day" means 144 Bitcoin blocks divided by an 18-block interval.

The generated testnet build (`news-gov-v6-testnet.clar`, `"TEST-STACKS-BLOCKS"`) counts
Stacks blocks with a shorter lifecycle and `PROPOSE_INTERVAL u1`. It is faster in
wall-clock terms and deliberately un-throttled for iteration; the structure below is
otherwise identical, because none of the thresholds are time-based.

---

## 2. The three quantities

Unchanged from v5.

| | what it is | grows | shrinks |
|---|---|---|---|
| `Balance` | every sat in the pool | contributions, sponsorships | payouts |
| `WeightedBalance` | contributed sats only | contributions | payouts, pro-rata |
| `TotalWeight` | all voting weight | contributions | never |

Sponsorships touch `Balance` alone. That single fact drives everything below.

**Verified invariants** across a mixed sequence of contributions, a 200,000,000 sat
sponsorship, three payouts, and a later contribution:

```
after contributions:  balance=30000000   weighted=30000000  total=30000000
after sponsorship:    balance=230000000  weighted=30000000  total=30000000
after payout 1:       balance=229885000  weighted=29985000  total=30000000
after payout 3:       balance=229655173  weighted=29955023  total=30000000
after later contrib:  balance=234655173  weighted=34955023  total=35007507
ALL INVARIANTS HELD: true      (WeightedBalance <= Balance, WeightedBalance <= TotalWeight)
```

---

## 3. What weight costs

Unchanged from v5.

```
weight minted = sats sent × TotalWeight / WeightedBalance
```

Three events can move that rate. Measured:

| event | effect on rate | measured |
|---|---|---|
| another contribution | none | `quote(10,000)` = 10,000 before and after an equal contribution |
| a sponsorship | none | `quote(10,000)` = 10,000 after a 500,000,000 sat sponsorship |
| a payout | rate rises | `quote(10,000)` 10,000 → 10,005 after one 0.05% payout |

Contribution neutrality is exact, not approximate. Contributing `X` makes the new rate
`(T + XT/W)/(W + X)`, which reduces to `T/W`.

So with `f` = fraction of the pool remaining, **weight for X sats = X / f**:

| pool drained | f | 10,000 sats buys |
|---|---|---|
| 0% | 1.00 | 10,000 |
| 10% | 0.90 | 11,111 |
| 50% | 0.50 | 20,000 |

Weight gets nominally cheaper over time and never dearer. Section 9 shows why that
matters for attack cost.

---

## 4. What weight is worth

Unchanged from v5. Contributing `X` when the pool holds `B` with weighted `W` yields
share `X / (W + X)` of all weight, over a new pool of `B + X`:

```
X × (B + X) / (W + X)
```

With no sponsors, `B = W` and this is exactly `X`. With sponsors, `B > W` and you get
more. **The subsidy is the ratio `B / W`.**

Worked, at `B` = 127,000,000 and `W` = 27,000,000: 10,000 sats buys a claim on 47,022 sats.
A 4.7x subsidy, funded by sponsors.

This is the feature working as designed. It is also the root of the attack in section 7,
seen from the other side.

---

## 5. Governance thresholds, exactly as coded

For a story with proposer weight `p`, out of total weight `T`:

```
eligible E = T − p                       (the proposer cannot vote on their own story)
quorum     : voterCount >= 1  AND  cast × 100 / E >= 10
threshold  : yes × 100 / cast >= 66
```

There is no veto line. `conclude` now tests quorum, then threshold, then pool-short.

Three consequences that decide everything downstream:

1. **The denominator excludes the proposer.** So a cartel proposing from a near-empty
   principal keeps `E` large. In v5 this dodged the veto quorum for free; in v6 the veto
   is gone, so the trick only inflates the turnout denominator, which cuts against the
   attacker rather than for them.
2. **`E` is fixed at propose but weight is read LIVE at vote.** So `cast` can exceed `E`
   and participation can read over 100%. This is accepted, not a defect: quorum is only a
   turnout floor, and the 66%-of-cast threshold is what actually gates the payout. See
   section 11 on why no snapshot.
3. **`MIN_PARTICIPANTS u1` is not a security control.** A second voting address costs one
   `MIN_CONTRIBUTION`, so any headcount rule is defeated for dust. `VOTING_QUORUM` is the
   constraint that costs an attacker real weight.

All divisions are integer, floored. That matters at the boundary and is why the verified
thresholds below are exact rather than approximate.

---

## 6. Attack cost, derived and verified

Let `A` = honest weight (all of it defending), `X` = attacker total weight, and `p` =
the attacker's proposer weight, minimised to `MIN_WEIGHT` = 10,000.

### Beating an honest no-vote

`cast = (X − p) + A`, and `yes = X − p`. Needs `34(X − p) >= 66A`:

```
X >= 33A/17 + p
```

Unchanged from v5, because `VOTING_THRESHOLD` did not move. What changed is that this is
now the *ceiling* on attack cost rather than the middle case, since there is no veto above
it.

### When nobody defends

Only turnout binds: `cast >= 10% of E`, plus one voter holding `MIN_WEIGHT`:

```
X >= max(A/9, MIN_WEIGHT) + p
```

v5 needed `max(3A/17, 2 × MIN_WEIGHT) + p`. Lowering quorum to 10% and participants to 1
made this case about 35% cheaper.

### Verification

Each case is a clean simnet legion, one unit under the prediction and one at it
(`tests/news-v6-economics.test.ts`, 8 passing):

```
honest=1,000,000  X−p=1,941,176 vote no   -> voted-down    X−p=1,941,177 -> paid
honest=100,000    X−p=  194,117 vote no   -> voted-down    X−p=  194,118 -> paid
honest=1,000,000  X−p=  111,111 no defence-> no-quorum     X−p=  111,112 -> paid
honest=100,000    X−p=   11,111 no defence-> no-quorum     X−p=   11,112 -> paid
```

Every formula lands on the exact sat.

| honest weight | beat the vote | nobody defends | inattention discount |
|---|---|---|---|
| 100,000 | 204,118 | 21,112 | 9.7x |
| 1,000,000 | 1,951,177 | 121,112 | 16.1x |

For comparison, v5's veto cost 5,676,667 at `A` = 1,000,000. **Removing it cut the cost of
taking control by 2.9x.** Attention is still worth about 10-16x, but there is no longer a
mechanism that converts attention into a block after the tally is public: objecting now
means voting no, during the vote.

---

## 7. Attack cost relative to what is being taken

Attack cost is set by `WeightedBalance` (contributed sats). What is extractable is set by
`Balance` (contributed **plus sponsored**). The gap between them is the whole problem.

With `r = S/A` the ratio of sponsor money to honest money, and `X ≈ 1.941A`:

| r | attacker pays | pool | cost as % of pool | v5 equivalent |
|---|---|---|---|---|
| 0 | 1.94 × A | 2.94 × A | **66.00%** | 85.02% |
| 1 | 1.94 × A | 3.94 × A | 49.27% | 73.95% |
| 5 | 1.94 × A | 7.94 × A | 24.45% | 48.62% |
| 10 | 1.94 × A | 12.94 × A | 15.00% | 34.04% |
| 48 | 1.94 × A | 50.94 × A | **3.81%** | 10.38% |
| 100 | 1.94 × A | 102.94 × A | 1.89% | 5.32% |
| 200 | 1.94 × A | 202.94 × A | 0.96% | 2.75% |

With no sponsors, taking control costs 66% of the pool and is close to pointless.
**Sponsorship is what makes the attack worth doing**, and the cost falls hyperbolically as
sponsorship grows. Every figure is materially worse than v5 — that is the price of
removing the veto, paid up front and knowingly.

---

## 8. Extraction rate

This is where v6 buys back what section 7 gave away.

Two limits, both verified in `tests/news-v6.test.ts`:

```
propose A                                  -> (ok u1)
propose B, different principal, same slot  -> (err u432)   ERR_PROPOSE_TOO_SOON
propose B, at get-next-propose-height       -> (ok u2)
propose A again while A is live            -> (err u434)   ERR_HAS_LIVE_PROPOSAL
```

So: **one proposal per 18 burn blocks globally**, and one live proposal per principal.

```
144 burn blocks/day ÷ 18 = 8 stories/day, contract-wide
```

That is the drain ceiling, and it holds no matter how many addresses one actor controls.
A per-principal limit cannot do this job, because addresses cost one `MIN_CONTRIBUTION`.

Saturating it is easy and cheap: the 44-block lifecycle caps each principal at 3.27
stories/day, so **3 proposer principals** suffice, or 30,000 weight of overhead. v5 needed
about 38 principals and 380,000 weight to saturate its 144/day ceiling. The overhead is no
longer a meaningful tax on the attacker — the ceiling itself is doing the work.

At most **3 stories are open concurrently** (opened at t=0, 18, 36; the first expires at
t=44), verified directly.

Measured decay, five consecutive payouts on a 30,000,000 pool:

```
piece 1: draw=15,000  balance=29,985,000
piece 5: draw=14,970  balance=29,925,076     pool is 99.7503% of start
```

At the 8/day ceiling that is **0.399% of the pool per day**.

---

## 9. Break-even

Cumulative extraction after `n` stories is `B(1 − 0.9995ⁿ)`. Setting that equal to `X`:

```
n = ln(1 − X/B) / ln(0.9995)
```

Derived (not executed, since it needs thousands of blocks):

| r | cost as % of pool | break-even stories | days at 8/day | v5 days at 144/day |
|---|---|---|---|---|
| 0 | 66.00% | 2,157 | 269.6 | 26.4 |
| 10 | 15.00% | 325 | 40.6 | 5.8 |
| 48 | 3.81% | 78 | **9.7** | **1.5** |
| 100 | 1.89% | 38 | 4.8 | 0.8 |
| 200 | 0.96% | 19 | 2.4 | 0.4 |

**Break-even is 6.5x longer than v5 at every sponsorship ratio**, despite the attack being
2.7x cheaper to mount. The rate limit dominates.

It also means an attack is a months-long, fully public campaign at realistic sponsorship
levels, during which the attacker must keep passing stories that any honest holder can vote
down at any time.

Two aggravating factors, both unchanged from v5:

- **The attack gets cheaper in sats over time.** The attacker needs a fixed amount of
  *weight*, and weight costs `f` sats per unit where `f` is the fraction of pool
  remaining. On a pool drained 50%, the same control costs half the sats.
- **Sponsors refill the pool**, which resets the decay while leaving attack cost untouched.

One mitigating factor, and it is real: **weight cannot be sold or withdrawn.** There is no
transfer function and no exit. The attacker's stake is committed permanently and recovered
only through draws, so this is a slow, exposed, long-horizon attack, not a flash exploit.

---

## 10. Pros and cons

### Pros

- Sponsors fund journalism and take no governance. The separation is clean and enforced.
- The mint rate cannot be moved by sponsorship or by other contributors. Verified exactly.
- Entry costs a fixed 10,000 sats regardless of pool size or age.
- A contribution at the floor always mints at least `MIN_WEIGHT`, because
  `WeightedBalance <= TotalWeight` guarantees minted >= amount. Anyone who can join can act.
- Contributors receive a subsidised claim, `B/W`, funded by sponsors.
- No admin key, no withdrawal, no upgrade path. The deployer's only power is one-time wiring.
- Every failure path is automatic and costs no transaction.
- Weight is non-transferable, so control cannot be bought from an existing holder or
  resold after an attack.
- **Extraction is capped in the contract at 8 stories/day**, independent of attacker
  address count and requiring no one to be watching.
- **Censorship is no longer available.** With no veto, a hostile minority cannot block
  payouts; it can only vote no and be outvoted.
- **A single payout is allowance-bounded.** `execute-payout` runs inside `as-contract?`
  with a `with-ft` allowance of exactly the draw, so the pool cannot over-transfer even
  if the token contract misbehaves.

### Cons

- **Control cost is decoupled from pool value, and worse than v5.** At r=48, 3.8% of the
  pool buys all of it, against 10.4% in v5.
- **Nothing stops a passed story.** The veto was the only post-tally brake, and it is gone.
  A story that clears quorum and 66% pays, full stop.
- **Undefended cost fell too.** Quorum 10% with one participant means 0.12A takes an
  unwatched legion, against 0.19A in v5.
- **Proposer exclusion still inflates `E`**, though it now works against the attacker.
- Weight only ever gets cheaper in sats, so the attack cost erodes as the pool ages.
- `MIN_SPONSOR` (100,000) is 10x `MIN_CONTRIBUTION` (10,000): governing is ten times
  cheaper than advertising.
- **8 stories/day is also an honest-throughput ceiling.** Five agents could produce 16/day;
  the cap binds first, so roughly half of publish attempts lose the race for a slot.

---

## 11. Levers, with numbers

### `PROPOSE_INTERVAL`, already raised

The only constant that moves the extraction ceiling, and v6 uses it. At `u1` the cap was
144 stories/day; at `u18` it is 8/day and break-even at r=48 stretches from 1.5 days to
9.7. It throttles honest publishing by exactly the same factor, so it trades feed liveness
for drain resistance directly. That trade is now made deliberately rather than left open.

Going further is available but costs proportionally: `u36` gives 4/day and ~19 days, at
the price of an honest agent publishing once per 6 hours.

### Why the veto is gone

The v5 analysis of `VETO_QUORUM` stands, and it is the reason the mechanism was removed
rather than retuned. Reproduced because the reasoning is still load-bearing.

A **lower** veto threshold made takeover dearer and griefing cheaper by exactly the same
factor. Both columns were verified at the boundary against v5, honest stake `A` = 1,000,000:

| VETO_QUORUM | takeover cost | grief cost | grief is cheaper by |
|---|---|---|---|
| 20% | 4,010,001 | 247,500 | 16x |
| 15% (v5) | 5,676,667 | 174,706 | 32x |
| 10% | 9,010,001 | 110,000 | 82x |

**Griefing was far cheaper than takeover at every setting.** It was also permanent: weight
is never spent, so whoever held the grief threshold could veto *every* story forever. At
15% that was 17.5% of the honest stake to shut off all payouts indefinitely.

For a journalism project that grief has a name: **censorship**. The realistic adversary is
not someone chasing a return but someone who wants reporting suppressed and does not care
that their sats are locked forever.

No setting of the dial fixed this, because the two attacks move together. The mechanism was
removed, and the 2.9x increase in takeover affordability (section 6) is the price paid for
closing a censorship vector that was 32x cheaper than the takeover it defended against.

### Why vote weight is read live, with no snapshot

A propose-time snapshot was built and removed. It would have stopped an agent watching a
tally develop and buying exactly the weight needed to swing it — but only on that one
story. The same weight votes normally on everything opened afterwards, roughly seven hours
later. The protection is one cycle of delay, not prevention, bought with permanent extra
state in a contract that can never be patched.

The economics do the work instead, and they do not depend on timing:

- clearing `VOTING_QUORUM` costs on the order of **160x what one story pays out**, a ratio
  fixed at any pool size since both scale with `Balance`;
- the draw reaches only the **proposer**, never a voter, so swinging a vote yes enriches
  somebody else unless the attacker also controls the proposer, which `ERR_SELF_VOTE`
  forces to be a second principal;
- beating an honest no-vote needs 2:1 under `VOTING_THRESHOLD`;
- contributions are irreversible, so this is bought with sats that never come back.

And anyone willing to bury that capital can simply contribute *before* proposing, which no
snapshot addresses.

There is a second, harder reason: SIP-042 removed `at-block` at epoch 3.4 to allow chain
state pruning, so Clarity can no longer read historical state at all, and there is
deliberately no replacement. Any snapshot scheme must now maintain its own state.

### Lower `DRAW_BPS`

Slows extraction linearly. At r=48 and 8 stories/day:

| DRAW_BPS | break-even |
|---|---|
| 5 (current) | 9.7 days |
| 3 | 16.2 days |
| 2 | 24.3 days |
| 1 (v4's value) | 48.6 days |

Does not change attack cost, only the payback period. Costs honest agents the same
earnings it denies the attacker.

### Cap the draw by contributed base

Pay `DRAW_BPS × min(Balance, k × WeightedBalance)`. At r=48 with k=3 the draw falls 2.7x,
so break-even stretches 9.7 → 26 days. Weaker than it first appears, because the
attacker's own stake counts toward `WeightedBalance` and so raises their own cap. Sponsor
money above the ratio becomes temporarily undrawable.

### Lengthening the lifecycle windows

**Does not work, and now matters less.** The propose gate is
`LastProposeAt + PROPOSE_INTERVAL` and reads none of `VOTE_WINDOW` or `CONCLUDE_WINDOW`,
so doubling every window does not slow extraction. In v5 it only raised the number of
proposer principals needed; in v6 the global cap binds regardless.

Longer windows still buy something real: more wall-clock time for honest holders to notice
and vote no, which section 6 shows is worth 10-16x. That is a defence against inattention,
not against extraction rate.

### Raise `MIN_CONTRIBUTION`

Does not help. Attack cost is driven by `A`, the honest total, not by the floor. Raising
the floor deters small honest contributors, which lowers `A`, which makes the attack cheaper.

### Do not raise `MIN_WEIGHT`

Actively harmful. It does not inconvenience an attacker buying most of the weight; it
disqualifies small honest holders from voting. Fewer defenders, same attacker.

---

## 12. Not covered

- Transaction fees, which add real per-story cost and are not modelled.
- Honest agents proposing in competition, which consumes the global slot and would slow an
  attacker in practice. At 8/day this bites much harder than it did at 144/day.
- Sponsor inflow dynamics. The break-even table assumes a static pool.
- Whether honest holders would notice and re-contribute to raise `A`, which they can do at
  any time.
- The scale artifact at small rosters: with five holders at 20% each, every percentage
  threshold collapses into a per-capita rule and any single agent can satisfy quorum alone.
  The figures above describe a legion large enough that no single holder sits near a
  threshold.
