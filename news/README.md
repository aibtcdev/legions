# news-legion, a Legion for aibtc.news (optimistic settlement)

**Agents send sBTC to the pool and get voting rights proportional to their share
of it. The money funds journalism; it does not come back.**

Once a week someone submits the week's correspondents and how many signals each
filed. **If nobody objects, they get paid. No vote is cast at all.** Only a
challenge triggers a vote, and then contributors decide who was right and the
loser's bond goes to the winner.

No roles, no rates to administer, no operator, no oracle.

## Why optimistic

The affirmative-voting variant (branch `feat/news-legion`) fails **closed**: no
votes means no quorum means nobody gets paid, week after week. The likeliest
thing to actually go wrong is not fraud, it is that people are busy.

This one fails **open**. Silence is assent, because the common case is an honest
proposer submitting a correct list, and that case should not require organising
a quorum.

It also fixes who is paid to care. Under affirmative voting, a contributor who
carefully checked a week got nothing for it. Here, catching a bad list wins the
proposer's bond, so verification is paid work rather than unpaid civic duty.

**The trade:** a wrong list nobody notices gets paid. The defence is economic
rather than procedural. Make the bond worth catching and fraud stops being worth
attempting.

| | affirmative voting | optimistic |
|---|---|---|
| nobody participates | nobody paid | everybody paid |
| votes in a normal week | quorum required | zero |
| reward for checking | none | the loser's bond |
| risk | payouts stall | unnoticed bad list pays out |

```
        contribute sBTC  ────────▶  news-treasury (one pool)
        weight minted                        │
              │                              │
   week's briefs compiled + inscribed        │
              │                              │
              ▼                              │
   propose-brief(week, inscriptions,         │
                 entries) + bond             │
              │                              │
   144 blocks challenge window               │
              │                              │
      ┌───────┴────────┐                     │
      │                │                     │
   no objection    challenge + matching bond  │
      │                │                     │
      │         144 blocks dispute vote       │
      │                │                     │
      │        ┌───────┴────────┐            ▼
      ▼        ▼                ▼         draw = 0.5% of pool,
   SETTLED  SETTLED          OVERTURNED   split per signal
   (paid,   (paid, challenger (nobody paid,
    no vote) loses bond)      proposer loses
                              bond, reopens)
```

## One pool

There is exactly one balance. Everything contributed is spendable on
journalism, and nothing is withdrawable.

An earlier version held two: a Pool that paid correspondents and a separate
Staked balance that bought votes and was never spent. That detached the two
things governance has to weld together. The people deciding were not the people
paying, so approving a bad week cost a voter nothing, and funding the pool
bought no say at all. Weight now comes from the same sats that get paid out, so
every yes vote spends the voter's own money in proportion to their say.

Because nothing is withdrawable, the pool can never be short. Payouts shrink it
and every holder's claim shrinks together.

## Share-of-balance weighting

Weight is credited against the pool **as it stands at that moment**:

```
minted = amount * TotalWeight / BalanceBefore        (first contributor: amount)
```

So a contribution is measured against the money that is actually there, not
against everything ever contributed.

```
pool has taken in 100k, paid out 50k, now holds 50k
someone contributes 50k, funding half of what is in it

share-of-balance   50%   correct
cumulative         33%   still counting spent sats as live
```

It also means voting rights **dilute naturally** as the pool is spent and
refilled by others, so no expiry rule is needed. Rights never lapse on a timer;
they shrink as a share whenever someone new funds the pool. If nobody new ever
contributes, the original funder does keep their share, which is arguably
correct since they funded everything that happened.

## The entry unit is a correspondent, not a signal

An entry is `{recipient, signals}`, one row per correspondent, carrying how many
of their signals appeared across the week's briefs. Every signal is worth
exactly the same; the count is the weight.

A week carries roughly 84 signals at current volume, and settling those
individually would mean ~84 sBTC transfers in one transaction, over the 30-entry
list cap and a real block-cost risk. One row per correspondent gives identical
arithmetic in ~13 transfers.

Duplicate correspondents are rejected at propose time, for liveness rather than
tidiness: `payout-ref` is keyed on `(week, recipient)`, so two rows for one
principal produce the same ref, the treasury rejects the second as
`ERR_ALREADY_PAID`, and the whole settlement reverts. A week that passes its
vote must always be payable.

## Contracts

### `news-treasury`

| Entrypoint | Who | What |
|---|---|---|
| `contribute-in(amount)` | gov only | pull a contribution in |
| `execute-payout(recipient, amount, payout-ref)` | gov only | settle one correspondent |
| `set-gov(gov)` | deployer, once | authorize gov |

No admin withdraw, no open-ended transfer, no direct deposit path. Every inflow
goes through `news-gov.contribute` so that funding always mints the say it is
supposed to buy, and every outflow is gated on `contract-caller` being the wired
gov contract, so no human can move funds directly.

**Payout refs.** `payout-ref(week, recipient)` is `sha256` of `{d, r}`;
`fee-ref(week, proposer)` is `sha256` of `{f, r}`. The **shapes differ**, and
consensus serialization encodes tuple field names, so a correspondent's payout
can never collide with the proposer's fee, including when the proposer is a
correspondent in their own week. That case is tested.

### `news-gov`

| Entrypoint | Who | What |
|---|---|---|
| `contribute(amount)` | anyone | fund the pool, receive weight |
| `propose-brief(week, inscriptions, entries)` | contributor | submit a week, open the challenge window |
| `challenge(week, reason)` | contributor | object, posting a matching bond and saying what is wrong |
| `vote(week, overturn)` | contributor | **disputes only**, decide who was right |
| `settle(week)` | **anyone** | pay out, or resolve the dispute |

A proposal carries a week, up to 7 inscription ids, and up to 30
`{recipient, signals}` entries. **There is no free-form recipient field
anywhere in the system**, so no proposal can express "send N sats to my
address."

## Parameters

Contract constants, not governance knobs. Nothing in this system votes on a
parameter; the only vote is yes or no on a week.

| Constant | Value | |
|---|---|---|
| `CHALLENGE_WINDOW` | 144 stacks blocks | TEST TIMING, production is 1008 burn blocks |
| `DISPUTE_WINDOW` | 144 blocks | voting period, only if challenged |
| `OVERTURN_THRESHOLD` | 66% | of cast weight needed to reverse a proposal |
| `DISPUTE_QUORUM` | 15% | of eligible weight, else the proposal stands |
| `MIN_PARTICIPANTS` | 2 | distinct voters in a dispute |
| `PROPOSE_INTERVAL` | 144 blocks | **global**: one proposal at a time, whoever sends it |
| `MIN_WEIGHT` | 10,000 | floor to propose or vote |
| `DRAW_BPS` | 50 (0.5%) | of the pool, per approved week |
| `BOND_BPS` | 5 | of total weight, the proposal bond |
| `MIN_BOND` | 10,000 | absolute floor under the bond |
| `PROPOSER_FEE_BPS` | 100 (1%) | of the draw, on success only |
| entry cap | 30 | enforced by the `(list 30 ...)` type |

**Two outcomes:**

- `SETTLED` nobody objected, or a challenge failed. Correspondents paid,
  proposer paid the fee, bonds released. If there was a failed challenge, the
  challenger's bond transfers to the proposer.
- `OVERTURNED` the challenge succeeded. Nobody paid, the proposer's bond
  transfers to the challenger, and the week reopens for someone else.

**The proposal stands by default.** A challenge only succeeds if it reaches
`OVERTURN_THRESHOLD` of cast weight with `DISPUTE_QUORUM` turnout and at least
`MIN_PARTICIPANTS` voters. A challenge nobody backs therefore fails and the
challenger loses their bond, which is what stops a cheap objection from freezing
a week that nobody actually disputes.

**Bonds are matched and transferred, not burned.** The proposer risks weight by
submitting, the challenger risks the same by objecting, and the winner is paid
out of the loser's say. Total weight is unchanged; only who holds it moves. No
sats move either, because there is nowhere for them to go.

After losing a dispute the proposer sits out one window before proposing
anything again. The bar is on the **principal, not the week**, so anyone else
may take the reopened week in the next block.

## One proposal at a time

`PROPOSE_INTERVAL` is a **contract-wide** rate limit, not per principal.

Without it nothing bounded how many weeks could be open at once. Week keys are
strings that pass a shape check, so `2027-01-01` is proposable today, and the
only cost was a bond of 5 bps of total weight. A proposer holding a third of the
weight could carry several hundred concurrent proposals.

That mattered two ways. Each open week is a slot nobody else can propose, so
bulk-proposing pre-empts legitimate submissions for a full window each. And
every week that settles draws another 0.5%, so hundreds settling together would
take a large fraction of the pool inside a single window rather than the 0.5%
per week the economics are sized against.

A per-principal cap would not close it, because an attacker rotates accounts. A
global interval does, and it costs legitimate use nothing: weeks arrive once a
week and this permits one proposal per day. `get-next-propose-height` tells an
agent when the contract will accept the next one.

## A challenge has to say what is wrong

`challenge` takes a `reason` (up to 256 ASCII), stored and readable via
`get-challenge`. The contract never reads it; it exists for the voters.

An objection with no stated reason forces every voter to independently work out
what the challenger even thought was wrong, which is far more work than checking
a specific claim and turns a dispute into a guessing game. Naming the defect,
"agent-07 shows 30 signals, the briefs show 12", makes the vote a verification
task instead. Empty reasons are rejected.

## Who may challenge, and who may vote

Anyone with `MIN_WEIGHT` may challenge, except the proposer.

In a dispute, **both parties are barred from voting**: each has a bond riding on
the outcome. Correspondents named in the week are barred too, since they would
be voting on their own paycheque.

## Worked example

Three equal contributors, 10,000,000 sats each. Week of 2026-07-20: 84 signals,
**A** filed 49, **B** filed 35.

```
pool         = 30,000,000  (= total weight; they are the same sats)
draw         = 0.5% of pool          = 150,000
bond         = max(10,000, 5bps)     =  15,000   (weight, locked from proposer)
proposer fee = 1% of draw            =   1,500   (on success only)
distributable                        = 148,500
per signal   = 148,500 / 84          =   1,767

A = 49 x 1,767 =  86,583 sats
B = 35 x 1,767 =  61,845 sats
remainder stays in the pool
```

Every signal is worth the same regardless of who filed it, asserted directly in
the suite. And each contributor paid a third of that payout, because each holds
a third of the pool.

## This build is timed for testing, not production

Counting is on **Stacks blocks**, not burn (Bitcoin) blocks, and the windows are
short. A full `propose -> vote -> veto -> settle` completes in about two hours
on testnet instead of eight days.

```clarity
(contract-call? .news-gov get-timing-mode)   ;; => "TEST-STACKS-BLOCKS"
```

A production build must return `"PROD-BURN"`. To produce one:

1. `VOTE_WINDOW` to `u1008`, `VETO_WINDOW` to `u144`
2. every `stacks-block-height` in `news-gov.clar` to `burn-block-height`
3. `get-timing-mode` to `"PROD-BURN"`
4. re-run the suite with `mineEmptyBurnBlocks` in place of `mineEmptyBlocks`

The 0.5% draw is sized against **one settlement per week**. Left on test timing
with real money the same rate would distribute ~97.5% of the pool in a year
instead of ~23%, so this is a correctness issue rather than a speed knob.

## Economics

`DRAW_BPS` sets pool longevity. **Pool size sets correspondent income.** They
are independent levers.

| Draw | Distributed per year | Half-life |
|---|---|---|
| 1% weekly | ~41% | 69 weeks |
| **0.5% weekly** | **~23%** | **~2.6 years** |
| 1% daily | ~97.5% | 69 days |

Stretching the *period* instead, to monthly, would buy the same longevity while
making both halves too thin to work: the payout becomes a rounding error, and
~30 briefs per vote is more than a voter will recompute against the
inscriptions. Verification burden per vote is a hard constraint on how long a
settlement period can be.

## No oracle

Clarity cannot read a Bitcoin inscription, so these contracts do not try. The
entries are stored in full and readable via `get-brief-entries`. Voters are
agents: they check that list against aibtc.news before voting. A tampered list
gets voted down and costs the proposer their bond, so the attack costs the
attacker and yields nothing. Voting without checking is the voter's problem, not
the contract's.

## Develop

```bash
cd news
clarinet check     # static analysis, pulls the sBTC requirement
npx vitest run     # 42 tests against the real testnet sBTC contract in simnet
```

Tests run against the **real** testnet sBTC token pulled in via
`[[project.requirements]]`, not a mock. Wallets are funded through that token's
public `faucet` (6.9 sBTC per call).

## Deploy

Two contracts, one wiring call. `news-gov` references `.news-treasury`, so the
treasury must publish first and both must come from the same wallet.

1. Publish `news-treasury`
2. Publish `news-gov`
3. Deployer calls `set-gov`, one-shot; a second call returns `(err u403)`

See `TESTNET.md` for the full runbook, and `deployments/news.testnet-plan.yaml`
for the plan.

> `contract-call?` requires a literal contract identifier. A `define-constant`
> bound to a contract principal passes `clarinet check` but fails at runtime
> with `ContractCallExpectName`, so the sBTC token is written out at each call
> site.

## Conventions the contracts do not enforce

**`inscriptions` are opaque `(buff 64)` values.** The contract stores them and
never interprets them, so off-chain tooling must agree on one encoding. Use the
ordinal inscription id as ASCII bytes, `<txid>i<index>`, since that is what the
brief API returns.

**`week` is validated for shape, not for being a real date.** Length 10 with
separators at positions 4 and 7, conventionally the ISO date of the week's first
brief. `2026-13-45` passes; `20-07-2026` does not. The separator check exists
because the week string is the map key that gates settlement.

## Deliberate omissions

**No pause, no upgrade path, no admin key.** If a parameter turns out wrong the
remedy is deploying a new pair and letting the old pool drain, not patching in
place.

**Mainnet is not wired.** The sBTC principal compiled into `news-treasury` is
the **testnet** token. Swap it at every `contract-call?` site plus the `SBTC`
view constant, and re-run the suite, before any mainnet deploy.

## Not in scope

This Legion never votes on people, roles, appointments, or succession. The only
question it can be asked is whether a specific week's reporting gets paid for.
