# news Legion v5: weight, sponsorship, and attack cost

Analysis of `news-gov-v5.clar` + `news-treasury-v5.clar` at commit `bb4071a`.

**Method.** Every formula below is derived from the contract's own comparisons, then
checked against simnet at the boundary: one unit below the predicted threshold and one
unit at it. Where a number is derived rather than executed, it says so. Nothing here is
estimated from intuition.

**Frame.** Unless stated otherwise, figures describe a pool that has not yet paid out,
where weight equals sats 1:1. Section 5 covers what changes after payouts. This frame is
stated, not assumed away: it is the most attacker-hostile state, and section 9 shows the
attack gets cheaper in sats as the pool ages.

---

## 1. Constants

Read from source, not from memory.

| Constant | Value | Meaning |
|---|---|---|
| `MIN_CONTRIBUTION` | 10,000 sats | floor to join, on sats sent |
| `MIN_WEIGHT` | 10,000 weight | floor to propose, vote, or veto |
| `MIN_SPONSOR` | 100,000 sats | floor to sponsor |
| `DRAW_BPS` | 5 (0.05%) | paid to proposer per approved story |
| `VOTING_QUORUM` | 15% | of eligible weight that must vote |
| `VOTING_THRESHOLD` | 66% | of cast weight that must be yes |
| `VETO_QUORUM` | 15% | of eligible weight that blocks |
| `MIN_PARTICIPANTS` | 2 | distinct voters required |
| `VOTING_DELAY` | 2 blocks | proposal visible, not yet votable |
| `VOTE_WINDOW` | 30 blocks | voting open |
| `VETO_WINDOW` | 6 blocks | objection period |
| `CONCLUDE_WINDOW` | 12 blocks | window to settle before expiry |
| `PROPOSE_INTERVAL` | 1 block | global rate limit on proposals |

**Every figure in this document is the MAINNET build.** The analysis targets
`news-gov-v5.clar`, which returns `get-timing-mode` = `"PROD-BURN"` and counts Bitcoin
blocks at ~10 min each; the tests advance time with `mineEmptyBurnBlocks`. So "38 blocks"
means 6.3 hours and "144/day" means one per Bitcoin block, not per Stacks block.

The generated testnet build (`news-gov-v5-testnet.clar`, `"TEST-STACKS-BLOCKS"`) counts
Stacks blocks with a shorter lifecycle. It is faster in wall-clock terms but the structure
below is identical, because none of the thresholds are time-based.

---

## 2. The three quantities

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

A payout shrinks `Balance` and `WeightedBalance` by an identical factor while
`TotalWeight` holds. Measured on a 30,000,000 pool paying a 15,000 draw:

```
balance factor  = 0.99950000
weighted factor = 0.99950000
totalWeight changed: false
```

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

Contributing `X` when the pool holds `B` with weighted `W` yields share `X / (W + X)` of
all weight, over a new pool of `B + X`. The money behind it is:

```
X × (B + X) / (W + X)
```

With no sponsors, `B = W` and this is exactly `X`. You get your money's worth, nothing more.

With sponsors, `B > W` and you get more. **The subsidy is the ratio `B / W`.**

Worked, at `B` = 127,000,000 and `W` = 27,000,000: 10,000 sats buys a claim on 47,022 sats.
A 4.7x subsidy, funded by sponsors.

This is the feature working as designed. It is also the root of the attack in section 7,
seen from the other side.

---

## 5. Governance thresholds, exactly as coded

For a story with proposer weight `p`, out of total weight `T`:

```
eligible E = T − p                       (the proposer cannot vote on their own story)
quorum     : voterCount >= 2  AND  cast × 100 / E >= 15
threshold  : yes × 100 / cast >= 66
vetoed     : vetoWeight × 100 / E >= 15
```

Two consequences that decide everything downstream:

1. **The denominator excludes the proposer.** So a cartel proposing from a near-empty
   principal keeps `E` large and pushes honest holders below the veto threshold. This
   costs the attacker nothing: the draw does not depend on proposer weight.
2. **Veto is checked first** in `conclude`, before quorum and before threshold. A
   successful veto beats a passed vote.

All divisions are integer, floored. That matters at the boundary and is why the verified
thresholds below are exact rather than approximate.

---

## 6. Attack cost, derived and verified

Let `A` = honest weight (all of it defending), `X` = attacker total weight, and `p` =
the attacker's proposer weight, minimised to `MIN_WEIGHT` = 10,000.

### Beating the veto

Attacker needs `A × 100 / E < 15`, with `E = A + X − p`:

```
X > 17A/3 + p
```

### Beating only the vote (honest vote no, never veto)

`cast = (X − p) + A`, and `yes = X − p`. Needs `34(X − p) >= 66A`:

```
X >= 33A/17 + p
```

### When nobody defends

Only turnout binds: `cast >= 15% of E`, plus two voters each holding `MIN_WEIGHT`:

```
X >= max(3A/17, 2 × MIN_WEIGHT) + p
```

### Verification

Each run below is a clean simnet scenario, one unit under the prediction and one at it:

```
honest=100,000    X=576,666  veto      -> vetoed        X=576,667  -> paid
honest=1,000,000  X=5,676,666 veto     -> vetoed        X=5,676,667 -> paid
honest=100,000    X=204,117  vote no   -> voted-down    X=204,118  -> paid
honest=100,000    X=29,999   no defence-> no-quorum     X=30,000   -> paid
honest=1,000,000  X=186,470  no defence-> no-quorum     X=186,471  -> paid
```

Every formula lands on the exact sat.

| honest weight | beat veto | beat vote only | nobody defends |
|---|---|---|---|
| 100,000 | 576,667 | 204,118 | 30,000 |
| 1,000,000 | 5,676,667 | 1,951,177 | 186,471 |

**The veto roughly triples the cost** (5.68A vs 1.94A). **Inattention divides it by 19**
(576,667 → 30,000). Attention is worth more than money here.

---

## 7. Attack cost relative to what is being taken

Attack cost is set by `WeightedBalance` (contributed sats). What is extractable is set by
`Balance` (contributed **plus sponsored**). The gap between them is the whole problem.

With `r = S/A` the ratio of sponsor money to honest money:

| r | attacker pays | pool | cost as % of pool |
|---|---|---|---|
| 0 | 5.68 × A | 6.68 × A | **85.02%** |
| 1 | 5.68 × A | 7.68 × A | 73.95% |
| 5 | 5.68 × A | 11.68 × A | 48.62% |
| 10 | 5.68 × A | 16.68 × A | 34.04% |
| 48 | 5.68 × A | 54.68 × A | **10.38%** |
| 100 | 5.68 × A | 106.68 × A | 5.32% |
| 200 | 5.68 × A | 206.68 × A | 2.75% |

With no sponsors, taking control costs 85% of the pool and is pointless. **Sponsorship is
what makes the attack worth doing**, and the cost falls hyperbolically as sponsorship grows.

---

## 8. Extraction rate

Two limits, both verified:

```
propose A                                  -> (ok u1)
propose B, same block, different principal -> (err u432)   ERR_PROPOSE_TOO_SOON
propose C, next block                      -> (ok u2)
propose A again while A is live            -> (err u434)   ERR_HAS_LIVE_PROPOSAL
```

So: **one proposal per block globally**, and one live proposal per principal. Measured
cycle for a single principal, propose to concludable and immediately re-proposable:

```
conclude at +38 blocks -> (ok u1)
re-propose immediately -> (ok u2) at +38
```

The ceiling is therefore **144 stories/day** (one per Bitcoin block), and saturating it
needs about 38 proposer principals staggered across the cycle. Each needs only
`MIN_WEIGHT` = 10,000, so 380,000 weight of overhead. Voters can be reused across every
story, since voting does not consume weight.

At `A` = 100,000 this just fits: 576,667 total, 380,000 in proposers, 196,667 in voters
against a 194,118 threshold requirement. At larger `A` the fixed overhead matters less.

Measured decay, five consecutive payouts on a 30,000,000 pool:

```
piece 1: draw=15,000  balance=29,985,000
piece 5: draw=14,970  balance=29,925,076     pool is 99.7503% of start
```

---

## 9. Break-even

Cumulative extraction after `n` stories is `B(1 − 0.9995ⁿ)`. Setting that equal to `X`:

```
n = ln(1 − X/B) / ln(0.9995)
```

Derived (not executed, since it needs thousands of blocks):

| r | cost as % of pool | break-even stories | days at 144/day |
|---|---|---|---|
| 0 | 85.02% | 3,796 | 26.4 |
| 10 | 34.04% | 832 | 5.8 |
| 48 | 10.38% | 219 | **1.5** |
| 100 | 5.32% | 109 | 0.8 |
| 200 | 2.75% | 56 | 0.4 |

Two aggravating factors:

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

### Cons

- **Control cost is decoupled from pool value.** At r=48, 10.4% of the pool buys all of it.
- **The veto is the only real defence, and it needs attention** inside 6 blocks. Unwatched,
  the attack cost falls 19x.
- **Proposer exclusion is exploitable.** Proposing from a near-empty principal dodges the
  veto quorum for free.
- **144 stories/day is a generous extraction ceiling** for a legion publishing a handful.
- Weight only ever gets cheaper in sats, so the attack cost erodes as the pool ages.
- `MIN_SPONSOR` (100,000) is 10x `MIN_CONTRIBUTION` (10,000): governing is ten times
  cheaper than advertising.

---

## 11. Levers, with numbers

### Lower `DRAW_BPS`

Slows extraction linearly. At r=48:

| DRAW_BPS | break-even |
|---|---|
| 5 (current) | 1.5 days |
| 3 | 2.5 days |
| 2 | 3.8 days |
| 1 (v4's value) | 7.6 days |

Does not change attack cost, only the payback period. Costs honest agents the same
earnings it denies the attacker.

### `VETO_QUORUM`: one dial, two opposite attacks

A **lower** veto threshold makes takeover dearer, because honest holders need a smaller
share to block. It makes **griefing cheaper** by exactly the same factor, because a hostile
minority also needs a smaller share to block.

Both columns verified at the boundary, honest stake `A` = 1,000,000:

| VETO_QUORUM | takeover cost | grief cost | grief is cheaper by |
|---|---|---|---|
| 20% | 4,010,001 | 247,500 | 16x |
| **15% (current)** | **5,676,667** | **174,706** | **32x** |
| 10% | 9,010,001 | 110,000 | 82x |

Verified: at 10%, 9,010,000 vetoed / 9,010,001 paid, and 109,999 paid / 110,001 blocked.
At 15%, 174,705 paid / 174,706 blocked.

**Griefing is far cheaper than takeover at every setting, and lowering the quorum widens
the gap.** It is also permanent: weight is never spent, so whoever holds the grief
threshold can veto *every* story forever. At 15% that costs 17.5% of the honest stake to
shut off all payouts indefinitely.

For a journalism project this grief has a name: **censorship**. The realistic adversary is
not someone chasing a return but someone who wants reporting suppressed and does not care
that their sats are locked forever. `VETO_QUORUM` is precisely that dial.

**Recommendation: do not lower it.** Takeover is slow, public, and must keep publishing for
days to profit. Censorship is instant, silent, and 32x cheaper already. If this constant
moves at all, the argument for raising it is stronger than for lowering it.

### Cap the draw by contributed base

Pay `DRAW_BPS × min(Balance, k × WeightedBalance)`. At r=48 with k=3 the draw falls 2.7x,
so break-even stretches 1.5 → 4.1 days. Weaker than it first appears, because the
attacker's own stake counts toward `WeightedBalance` and so raises their own cap. Sponsor
money above the ratio becomes temporarily undrawable.

### Lengthening the lifecycle windows

**Does not work.** This is the obvious lever and it is the wrong one.

Extraction throughput is `min(1 per block, N principals / cycle length)`. The propose gate
is `LastProposeAt + PROPOSE_INTERVAL` (`news-gov-v5.clar:430`) and reads none of
`VOTE_WINDOW`, `VETO_WINDOW`, or `CONCLUDE_WINDOW`. So doubling every window does not slow
extraction at all: it only doubles the number of proposer principals needed to saturate the
global cap, and principals are free. An attacker adds addresses; the ceiling stays 144/day.

Longer windows do buy something real, just not this: more wall-clock time for honest
holders to notice and cast a veto, which section 6 shows is worth 19x. That is a defence
against inattention, not against extraction rate.

### Raise `PROPOSE_INTERVAL`

The only constant that moves the extraction ceiling. At `u1` the cap is 144 stories/day. At
`u6` it is 24/day, and break-even at r=48 stretches from 1.5 days to 9.1. It throttles
honest publishing by exactly the same factor, so it trades feed liveness for drain
resistance directly.

### Raise `MIN_CONTRIBUTION`

Does not help. Attack cost is driven by `A`, the honest total, not by the floor. Raising
the floor deters small honest contributors, which lowers `A`, which makes the attack cheaper.

### Do not raise `MIN_WEIGHT`

Actively harmful. It does not inconvenience an attacker buying 85% of the weight; it
disqualifies small honest holders from vetoing. Fewer defenders, same attacker.

---

## 12. Not covered

- Transaction fees, which add real per-story cost to a 144/day attack and are not modelled.
- Honest agents proposing in competition, which consumes the global 1-per-block slot and
  would slow an attacker in practice.
- Sponsor inflow dynamics. The break-even table assumes a static pool.
- Whether honest holders would notice and re-contribute to restore their veto share, which
  they can do at any time and which scales `A` back up.
