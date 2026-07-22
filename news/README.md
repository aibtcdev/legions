# news-legion — a Legion for aibtc.news

A pool of Bitcoin that pays for journalism, allocated by vote.

Anyone contributes sBTC. Once per brief, one proposal asks a single question:
**was this brief worth paying for?** Members vote yes or no. Yes pays the
correspondents named in that brief. No pays nobody and leaves the money in the
pool.

No roles, no rates to administer, no operator, no oracle.

```
        contribute sBTC  ─────────────▶  news-treasury (Pool)
                                              │
   brief compiled + inscribed                 │
              │                               │
              ▼                               │
   propose-brief(date, inscription-id,        │
                 entries)                     │
   bond locked from proposer's stake          │
              │                               │
              ▼                               │
   144 burn blocks (~24h), stake-weighted     │
              │                               │
      ┌───────┴────────┬──────────────┐       │
      ▼                ▼              ▼       ▼
   SETTLED          REJECTED       EXPIRED   draw = 1% of Pool,
  entries paid    bond slashed    bond back   split equally per entry
  (anyone calls)   date reopens   date reopens
```

## Why the two balances are separate

`news-treasury` holds two logically distinct amounts under one principal:

| | |
|---|---|
| **Pool** | contributed sBTC. Pays journalists. Nobody can withdraw it. |
| **Staked** | members' voting collateral. Refundable to the member who staked it. |

The draw is a percentage of the **Pool**, never of total holdings. Without this
split, an approved brief would pay correspondents out of the members' own
stake and staking would quietly become a donation.

## Contracts

### `news-treasury`

| Entrypoint | Who | What |
|---|---|---|
| `deposit(amount)` | anyone | fund the pool |
| `stake-in(amount)` | gov only | pull a member's collateral |
| `execute-payout(recipient, amount, payout-ref)` | gov only | settle one entry |
| `execute-unstake(recipient, amount)` | gov only | return a member's stake |
| `slash(amount)` | gov only | move a forfeited bond from Staked to Pool |

No admin withdraw, no open-ended transfer. Every outflow is gated on
`contract-caller` being the wired gov contract, so no human can move funds
directly. The deployer's only power is the one-time `set-gov` wiring.

`payout-ref` = `sha256` of `{d: brief-date, s: signal-id, r: recipient}` in
consensus serialization. A ref can never be settled twice, so anyone holding the
brief inscription can recompute a ref and ask the treasury whether that signal
was paid, and for how much.

The proposer's success fee uses `fee-ref` = `sha256` of `{f: brief-date,
r: proposer}` — a **different tuple shape**. Consensus serialization encodes
field names, so `{f,r}` and `{d,s,r}` can never produce identical bytes. This is
not cosmetic: an earlier version keyed the fee off `payout-ref` with a
"reserved" all-zero signal id, and nothing prevents a brief from containing an
entry with that exact signal id paying the proposer. The refs would collide, the
treasury would reject the second payout as `ERR_ALREADY_PAID`, and that brief
could never settle. Distinct shapes remove the failure mode rather than
documenting around it. See the `fee ref cannot collide` tests.

### `news-gov`

| Entrypoint | Who | What |
|---|---|---|
| `stake(amount)` | anyone | join; weight = stake |
| `unstake(amount)` | member | withdraw free, unlocked stake |
| `propose-brief(date, inscription-id, entries)` | member | open the vote |
| `vote(date, support)` | member | yes / no, stake-weighted |
| `settle(date)` | **anyone** | conclude and, if passed, pay every entry |

A proposal carries a date, an inscription id, and up to 30
`{signalId, recipient}` entries. **There is no free-form recipient field
anywhere in the system** — no proposal can express "send N sats to my address."

## Parameters

These are contract constants, not governance knobs. Nothing in this system
votes on a parameter; the only vote is yes/no on a brief.

| Constant | Value | |
|---|---|---|
| `VOTE_WINDOW` | 144 burn blocks | ~24h, closes before the next brief |
| `VOTING_THRESHOLD` | 66% | of cast weight |
| `VOTING_QUORUM` | 15% | of eligible staked weight |
| `MIN_PARTICIPANTS` | 2 | distinct voters |
| `MIN_STAKE` | 10,000 sats | membership floor |
| `DRAW_BPS` | 100 (1%) | of Pool, per approved brief |
| `BOND_BPS` | 1,000 (10%) | of the pending draw |
| `PROPOSER_FEE_BPS` | 100 (1%) | of the draw, on success only |
| `MAX_ENTRIES` | 30 | matches the brief roster cap |

**Quorum is not zero and must not be.** With no quorum a single member holding
`MIN_STAKE` votes yes alone, reaches 100% of cast weight, and unilaterally
spends a slice of everyone else's pool. Quorum is the only thing standing
between the treasury and one 10k-sat principal — see the
`quorum is load-bearing` test.

**Three outcomes, and the last two are different on purpose:**

- `SETTLED` — quorum met, threshold met. Entries paid, bond released.
- `REJECTED` — quorum met, threshold missed. Voters looked and said no. Bond
  slashed into the pool, so the next approved brief pays slightly more.
- `EXPIRED` — quorum never met. Nobody looked. **Bond returned in full.**

Slashing a proposer because *other people* failed to show up would end
proposing within a week. Apathy costs a delay, never a bond.

## No oracle

Clarity cannot read a Bitcoin inscription, so these contracts do not try. The
proposer submits the entries; the contract stores a canonical digest of them
(`get-entry-digest`); verifiers recompute that digest from the named inscription
off-chain. A tampered list fails the comparison, gets voted down, and costs the
proposer their bond — so the attack costs the attacker and yields nothing.

Entries must ascend strictly by `signalId`. That canonical ordering is what
makes the digest reproducible: two people building the same brief produce
byte-identical lists, so verification is one hash comparison rather than a diff
of an arbitrarily ordered list.

## Develop

```bash
cd news
clarinet check     # static analysis, pulls the sBTC requirement
npx vitest run     # 33 tests against the real testnet sBTC contract in simnet
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

The sBTC token principal is compiled in
(`STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token`, testnet). Retarget it
in both contracts for mainnet.

> `contract-call?` requires a literal contract identifier — a `define-constant`
> bound to a contract principal passes `clarinet check` but fails at runtime with
> `ContractCallExpectName`. The token is therefore written out at each call site.

## Conventions the contracts do not enforce

**`inscriptionId` is an opaque `(buff 64)`.** The contract stores it and never
interprets it, so off-chain tooling must agree on one encoding. Use the ordinal
inscription id as ASCII bytes — `<txid>i<index>`, e.g.
`33edd63e…3b195ei0` — since that is what the brief API returns and what a
verifier will paste into an explorer. Two tools using different encodings will
produce briefs that look wrong to each other's verifiers.

**`briefDate` is validated for shape, not for being a real date.** Length 10
with separators at positions 4 and 7. `2026-13-45` passes; `21-07-2026` does
not. The separator check exists because the date is the map key that gates
settlement — length alone would let the same brief occupy two independently
settleable slots.

## Deliberate omissions

**No pause, no upgrade path, no admin key.** Consistent with "immutable
parameters, vote only on work" — but worth stating plainly for a contract that
will hold real sBTC: if a parameter turns out wrong, the remedy is deploying a
new pair and letting the old pool drain, not patching in place. Every parameter
in the table above is therefore a decision you are making once.

**Mainnet is not wired.** The sBTC principal compiled into both contracts is the
**testnet** token. Swap it at all four `contract-call?` sites in `news-treasury`
plus the `SBTC` view constant, and re-run the suite, before any mainnet deploy.

## Not in scope

This Legion never votes on people, roles, appointments, or succession. The only
question it can be asked is whether a specific brief gets paid for.
