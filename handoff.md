# Agent-News → Legion Payout — Handoff

Continue the build here. Full design history + Monte-Carlo reasoning lives in the gist:
**https://gist.github.com/biwasxyz/28ee28a35f82cbb6d870d0b94c2db72e** (`legion-news-3.0.md` is the current/frozen design; v1/v2 files are the worked-through dead-ends, kept for the *why*).

## Scope lock
Paid **agent intelligence signals on Bitcoin beats** — NOT general journalism. Don't let scope creep back toward "verified news truth machine"; that path was modeled and it doesn't close. Demand prices *value*, not *truth*.

## The one decision that gates everything
**Who refills the treasury?**
- **Patron/sponsor/protocol funds it → grants program.** Ship the simple version (below), skip all v2/v3 machinery (soulbound, demand-gating, sub-DAOs). It's a funded bounty pot + stake-gated voting + a rulebook.
- **Readers/sponsors pay → business.** Then revenue (§11 of the gist) is a *separate track* proven independently — do NOT bolt it onto the voting contract.

Until this is answered, build only the parts common to both (Rail A + fee collector). Everything else waits.

## What already exists (don't rebuild)
`contracts/legion-gov.clar` + `contracts/legion-treasury.clar` already give:
- `propose(desc, recipient, amount)` / `vote(id, support)` / `conclude-proposal(id, ft)`
- stake-weighted voting, 15% quorum, 66% approval, veto window, ≥2 voters, treasury release on pass.

This is ~80% of the original ask. The product is mostly *adding guards*, not new infrastructure.

## Build order (smallest shippable first)

### Phase 1 — MVP (the only thing to build this week)
Common to grants AND business. Target: testnet deploy + first sponsor by Week 1.

1. **PreCheckEnforcer** — computable Rail-A gates revert at `propose()`:
   - `is-fresh(inscription-height)` (A1/A2 freshness window)
   - `PaidHash` map: reject duplicate content hash (B1, on-chain paid registry)
   - `>= 2` disjoint-domain sources (C1 count-only)
2. **BondLock** — per-proposal bond earmarked from proposer stake:
   - `ProposalBond` map `{ proposer, locked, released }`
   - `locked-of(proposer)` MUST sum **all open bonds** (or "one stake → infinite proposals" reopens)
   - `StakeLockedUntil` = `burn-height + vote + exec + challenge` window (no unstake-and-run)
3. **ProposerExclusion** — proposer can't `vote` own proposal; quorum denominator = **eligible (non-proposer) stake**, not total (else a ≥85% proposer bricks every honest vote).
4. **Fee collector** — 8% skim of routed x402/agent tx volume → treasury (§11 stub in gist). This is the inflow that makes the demand-gate non-hypothetical.

### Phase 2 — only if Phase 1 gets a buyer
- Demand-gated bounty: payout = `min(CAP, SHARE × story's own realized reader revenue)`. Kill fixed flat-pay (it's the one sink demand-gating doesn't cover — see gist §2/§3).
- ChallengeMarket (Rail B) — fraud-deterrence only, self-funded from loser bonds. NOT load-bearing for solvency.

### Phase 3 — only at real scale / cartel risk
- Soulbound rep (gist §4: `Rep` map + decay + guardian recovery), quadratic weight, per-beat sub-DAOs. Premature before this.

## MVP KPIs / Kill criteria
- Week 1: Rail A auto + fee collector on testnet + first sponsor locked.
- KPIs: 10 stories filed; treasury net ≥ 0 after 30d; ≥ 1 external buyer committed.
- **KILL/pivot if no buyer by day 14.** No buyer → demand-gate has no demand → collapses to v1 faucet.

## Open questions for next session
1. Grants vs business decision (above) — blocks Phase 2 scope.
2. Sponsor target: Stacks Foundation / grants / protocol — who gets the §11 NFT template first?
3. Soulbound recovery: bind rep to aibtc **identity** (not raw wallet) + M-of-N guardian re-bind — confirm the identity contract supports the rebind path before relying on it.
4. `legion-gov.clar` quorum currently uses total-staked snapshot as denominator — Phase 1 item 3 needs it changed to eligible stake; check that doesn't break existing tests.

## Known structural limits (accepted, not bugs)
- Balance/slant/hype = unenforceable on-chain; editorial aspiration only.
- Demand-gating pays for *reads* = engagement, not accuracy; popular-but-wrong is the residual failure mode Rail B + rep must keep unprofitable.
- A pot that only pays out drains; solvency requires inflow, full stop.
