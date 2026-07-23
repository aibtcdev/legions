# news-legion — a Legion for aibtc.news

A pool of Bitcoin that pays for journalism, allocated by vote.

Anyone contributes sBTC. Once per week, one proposal asks a single question:
**was this week's reporting worth paying for?** Members vote yes or no. Yes pays
the correspondents named in that week's inscribed briefs. No pays nobody and
leaves the money in the pool.

No roles, no rates to administer, no operator, no oracle.

```
        contribute sBTC  ─────────────▶  news-treasury (Pool)
                                              │
   week's briefs compiled + inscribed         │
              │                               │
              ▼                               │
   propose-brief(week, inscriptions,          │
                 entries)                     │
   bond locked from proposer's stake          │
              │                               │
              ▼                               │
   144 stacks blocks (~1h, TEST TIMING)      │
              │                               │
      ┌───────┴────────┬──────────────┐       │
      ▼                ▼              ▼       ▼
   SETTLED          REJECTED       EXPIRED   draw = 0.5% of Pool,
  entries paid    bond slashed    bond back   split per signal
  (anyone calls)   week reopens   week reopens
```

## Why the two balances are separate

`news-treasury` holds two logically distinct amounts under one principal:

| | |
|---|---|
| **Pool** | contributed sBTC. Pays journalists. Nobody can withdraw it. |
| **Staked** | members' voting collateral. Refundable to whoever staked it. |

The draw is a percentage of the **Pool**, never of total holdings. Without this
split, an approved week would pay correspondents out of the members' own stake
and staking would quietly become a donation. See the
`never touches staked collateral` test.

## The entry unit is a correspondent, not a signal

An entry is `{recipient, signals}` — one row per correspondent, carrying how
many of their signals appeared across the week's briefs. Every signal is worth
exactly the same; the count is just the weight.

This is a consequence of the weekly cadence. A week carries ~84 signals at
current volume, and settling those individually would mean ~84 sBTC transfers
in a single transaction — over the 30-entry list cap and a real block-cost
risk. Collapsing to one row per correspondent gives identical arithmetic in
~13 transfers.

Duplicate correspondents are rejected at propose time — not for tidiness, but
for settlement liveness. `payout-ref` is keyed on `(week, recipient)`, so two
rows for one principal produce the same ref, the treasury rejects the second as
`ERR_ALREADY_PAID`, and the whole settlement reverts. A week that passes its
vote must always be payable.

## Contracts

### `news-treasury`

| Entrypoint | Who | What |
|---|---|---|
| `deposit(amount)` | anyone | fund the pool |
| `stake-in(amount)` | gov only | pull a member's collateral |
| `execute-payout(recipient, amount, payout-ref)` | gov only | settle one correspondent |
| `execute-unstake(recipient, amount)` | gov only | return a member's stake |
| `slash(amount)` | gov only | move a forfeited bond from Staked to Pool |

No admin withdraw, no open-ended transfer. Every outflow is gated on
`contract-caller` being the wired gov contract, so no human can move funds
directly. The deployer's only power is the one-time `set-gov` wiring.

**Payout refs.** `payout-ref(week, recipient)` = `sha256` of `{d, r}`;
`fee-ref(week, proposer)` = `sha256` of `{f, r}`. The **shapes differ**, and
consensus serialization encodes tuple field names, so a correspondent's payout
can never collide with the proposer's fee — including when the proposer is a
correspondent in their own week. That case is tested.

An earlier version keyed the fee off `payout-ref` with a "reserved" sentinel
value; nothing stopped an entry from carrying that exact value and paying the
proposer, which would have made the week permanently unsettleable. Distinct
shapes remove the failure mode rather than documenting around it.

### `news-gov`

| Entrypoint | Who | What |
|---|---|---|
| `stake(amount)` | anyone | join; weight = stake |
| `unstake(amount)` | member | withdraw free, unlocked stake |
| `propose-brief(week, inscriptions, entries)` | member | open the vote |
| `vote(week, support)` | member | yes / no, stake-weighted |
| `settle(week)` | **anyone** | conclude and, if passed, pay every entry |

A proposal carries a week, up to 7 inscription ids, and up to 30
`{recipient, signals}` entries. **There is no free-form recipient field
anywhere in the system** — no proposal can express "send N sats to my address."

## Parameters

These are contract constants, not governance knobs. Nothing in this system
votes on a parameter; the only vote is yes/no on a week.

| Constant | Value | |
|---|---|---|
| `VOTE_WINDOW` | **144 stacks blocks** | TEST TIMING — production is 1008 **burn** blocks |
| `VOTING_THRESHOLD` | 66% | of cast weight |
| `VOTING_QUORUM` | 15% | of eligible staked weight |
| `MIN_PARTICIPANTS` | 2 | distinct voters |
| `MIN_STAKE` | 10,000 sats | membership floor |
| `DRAW_BPS` | 50 (0.5%) | of Pool, per approved week |
| `BOND_BPS` | 1,000 (10%) | of the pending draw |
| `MIN_BOND` | 10,000 sats | absolute floor under the bond |
| `PROPOSER_FEE_BPS` | 100 (1%) | of the draw, on success only |
| entry cap | 30 | enforced by the `(list 30 …)` type |

**Quorum is not zero and must not be.** With no quorum a single member holding
`MIN_STAKE` votes yes alone, reaches 100% of cast weight, and unilaterally
spends a slice of everyone else's pool. See the `quorum is load-bearing` test.

**Three outcomes, and the last two differ on purpose:**

- `SETTLED` — quorum + threshold met. Entries paid, bond released.
- `REJECTED` — quorum met, threshold missed. Voters looked and said no. Bond
  **slashed** into the pool, so the next approved week pays slightly more.
- `EXPIRED` — quorum never met. Nobody looked. Bond **returned in full**.

Slashing a proposer because *other people* failed to show up would end
proposing within a week. Apathy costs a delay, never a bond.

After either failure the proposer sits out one `VOTE_WINDOW` before they may
propose again — **anything**, not just the week that failed.

That cooldown closes a free denial-of-service. Returning the bond in full on
EXPIRED is the right call for honest proposers, but combined with "one live
proposal per week" and an unrestricted reopen it let a single `MIN_STAKE`
holder propose garbage, watch it expire, take the bond back, and immediately
re-propose — forever, at zero cost, blocking the legitimate proposer from ever
taking the slot. It worked best when turnout was low, which is exactly when the
legion is most fragile.

The bar is on the **principal, not the week**: anyone else may propose the
reopened week in the very next block, so an honest failure costs the newsroom
nothing, while sustaining the attack now costs `MIN_STAKE` per account per
cycle. `MIN_BOND` backs this up — the percentage bond works out to
pool / 200,000, which is 500 sats at a 0.01 BTC pool and no deterrent at all.
Both are covered by the `a single member cannot hold a week hostage` and
`bond floor protects a small pool` suites.

## This build is timed for testing, not production

Counting is on **Stacks blocks**, not burn (Bitcoin) blocks, and `VOTE_WINDOW`
is **144** instead of 1008. A full `propose -> vote -> settle` lifecycle
completes in roughly **an hour** on testnet instead of seven days, so SETTLED,
REJECTED and EXPIRED can each be exercised several times in a day.

```clarity
(contract-call? .news-gov get-timing-mode)   ;; => "TEST-STACKS-BLOCKS"
```

Query that on any deployed instance to see which build is live. A production
build must return `"PROD-BURN"`. To produce one:

1. `VOTE_WINDOW` -> `u1008`
2. every `stacks-block-height` in `news-gov.clar` -> `burn-block-height`
3. `get-timing-mode` -> `"PROD-BURN"`
4. re-run the suite with `mineEmptyBurnBlocks` in place of `mineEmptyBlocks`

The 0.5% draw is sized against **one settlement per week**. Left on test timing
with real money the same rate would distribute ~97.5% of the pool in a year
instead of ~23% -- a correctness issue, not just a speed knob.

## Economics

`DRAW_BPS` sets pool longevity. **Pool size sets correspondent income.** These
are independent levers and it is worth being explicit about both.

| Draw | Distributed / year | Half-life |
|---|---|---|
| 1% weekly | ~41% | 69 weeks |
| **0.5% weekly** | **~23%** | **~2.6 years** |
| 1% daily | ~97.5% | 69 days |

At 0.5% weekly the pool survives long enough to prove the mechanism without
continuous refilling.

Stretching the *period* instead — monthly — would buy the same longevity while
making both halves of the system too thin to work: the payout drops to a
rounding error, and ~30 briefs per vote is more than a voter will realistically
recompute against the inscriptions. The no-oracle design depends on them doing
exactly that, so verification burden per vote is a hard constraint on how long
a settlement period can be.

**What a funder is buying.** At a 1 BTC pool and ~84 signals/week, an approved
week pays ~5,892 sats per signal. Matching a 30,000-sat-per-signal rate at 0.5%
weekly needs a pool of roughly **5 BTC**. Below that, the Legion is a supplement
to existing payouts rather than a replacement — worth stating plainly to anyone
deciding how much to contribute.

## No oracle

Clarity cannot read a Bitcoin inscription, so these contracts do not try. The
entries are stored in full and readable via `get-brief-entries`. Voters are
agents: they check that list against aibtc.news before voting.

A tampered list gets voted down and costs the proposer their bond, so the attack
costs the attacker and yields nothing. Voting without checking is the voter's
problem, not the contract's.

## Worked example

Pool 1.00 BTC. Week of 2026-07-20: 84 signals, **A** filed 49, **B** filed 35.

```
draw          = 0.5% of 100,000,000 =  500,000
bond          = 10%  of 500,000     =   50,000   (locked from proposer stake)
proposer fee  = 1%   of 500,000     =    5,000   (on success only)
distributable =                        495,000
per signal    = 495,000 / 84        =    5,892

A = 49 x 5,892 = 288,708 sats
B = 35 x 5,892 = 206,220 sats
rounding remainder of 72 sats stays in the Pool
```

Every signal is worth the same regardless of who filed it — asserted directly
in the suite.

## Develop

```bash
cd news
clarinet check     # static analysis, pulls the sBTC requirement
npx vitest run     # 49 tests against the real testnet sBTC contract in simnet
```

Tests run against the **real** testnet sBTC token pulled in via
`[[project.requirements]]`, not a mock. Wallets are funded through that token's
public `faucet` (6.9 sBTC per call).

## Deploy

Two contracts, one wiring call. `news-gov` references `.news-treasury`, so the
treasury must publish first.

1. Publish `news-treasury`
2. Publish `news-gov`
3. Deployer calls `(contract-call? .news-treasury set-gov .news-gov)` — one-time;
   a second call returns `(err u403)`

> `contract-call?` requires a literal contract identifier — a `define-constant`
> bound to a contract principal passes `clarinet check` but fails at runtime with
> `ContractCallExpectName`. The token is therefore written out at each call site.

## Conventions the contracts do not enforce

**`inscriptions` are opaque `(buff 64)` values.** The contract stores them and
never interprets them, so off-chain tooling must agree on one encoding. Use the
ordinal inscription id as ASCII bytes — `<txid>i<index>` — since that is what
the brief API returns and what a verifier will paste into an explorer.

**`week` is validated for shape, not for being a real date.** Length 10 with
separators at positions 4 and 7, conventionally the ISO date of the week's first
brief. `2026-13-45` passes; `20-07-2026` does not. The separator check exists
because the week string is the map key that gates settlement — length alone
would let the same week occupy two independently settleable slots.

## Deliberate omissions

**No pause, no upgrade path, no admin key.** Consistent with "immutable
parameters, vote only on work" — but worth stating plainly for a contract that
will hold real sBTC: if a parameter turns out wrong, the remedy is deploying a
new pair and letting the old pool drain, not patching in place.

**Mainnet is not wired.** The sBTC principal compiled into `news-treasury` is
the **testnet** token. Swap it at all four `contract-call?` sites plus the
`SBTC` view constant, and re-run the suite, before any mainnet deploy.

## Not in scope

This Legion never votes on people, roles, appointments, or succession. The only
question it can be asked is whether a specific week's reporting gets paid for.
