# AIBTC Legion

A small on-chain agent collective on Stacks, built in Clarity 3 (epoch 3.0) and
tested locally with Clarinet 2.11.2 + the clarinet-js-sdk vitest harness.

Two contracts:

| Contract | Responsibility |
| --- | --- |
| `legion-treasury` | Holds pooled **sBTC**, moves it only on authorized instruction from the wired gov contract. |
| `legion-gov` | Proposals + **stake-weighted** voting; on a passing tally calls the treasury to execute a transfer. |

> **Funds model:** the pool is denominated in **sBTC** — a SIP-010 fungible
> token. Fund-moving entrypoints take a `<sip010-trait>` token reference; the
> treasury validates it against the wired token principal (`set-token`). It is
> wired to the real testnet sBTC token
> `STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token`. The authorization model
> (gov wiring, `contract-caller`-gated outflows, effects-before-interaction)
> is unchanged from the original STX design.

> **Token wiring:** the deployer wires the sBTC token into the treasury once via
> `(contract-call? .legion-treasury set-token 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token)`.
> This mirrors `set-gov`: one-time, deployer-only, with a no-self
> guard, returning `(err u403)` on a second call and `(err u410)` if pointed at
> the treasury itself. Every `deposit` / `execute-transfer` then asserts the
> supplied trait's contract principal equals the wired token, returning
> `(err u412)` (`ERR_WRONG_TOKEN`) on a mismatch.

> **Voting model:** vote weight = the amount of sBTC a voter has staked through
> `legion-gov.stake` (which forwards into the treasury). This is a stand-in for
> heartbeat/reputation weighting — swap in an on-chain rep source later. Comment
> in `legion-gov.clar`.

> **Real token via Clarinet requirements:** the tests run against the **real**
> testnet sBTC contract (not a mock), pulled into simnet via
> `[[project.requirements]]` in `Clarinet.toml`. Test wallets are funded by
> calling the token's public `(faucet)` (mints 6.9 sBTC per call to `tx-sender`);
> wallets needing a larger stake call it multiple times.

## Quickstart

```bash
npm install
clarinet check     # static analysis (must be clean; pulls the sBTC requirement)
npm test           # run the full vitest suite (26 tests)
```

## Architecture & authorization

- The treasury **owns** the pooled sBTC (held under the contract principal via
  `as-contract`). Deposits pull from `tx-sender` with
  `(contract-call? ft transfer amount tx-sender (as-contract tx-sender) none)`;
  outflows use `(as-contract (contract-call? ft transfer amount tx-sender recipient none))`.
  An internal `Balance` uint tracks the pool-accounted total so `get-balance`
  (read-only, no trait param) is cheap for gov.
- `execute-transfer` is gated on **`contract-caller`** (the immediate caller),
  not `tx-sender`. Only the wired `gov` contract principal may move
  funds. A human cannot call it directly.
- `tx-sender` is preserved across inter-contract calls, so when a user calls
  `legion-gov.stake`, the treasury debits the **user**, not the gov contract.
- Effects-before-interaction: `tally-and-execute` marks a proposal `executed`
  **before** the external transfer, preventing re-entrancy / double-spend.

## Deploy + wiring call sequence

Contracts reference each other by principal, so deployment order and a one-time
wiring step matter.

1. **Deploy `legion-treasury`** first (it has no dependencies).
2. **Deploy `legion-gov`** (calls treasury by the `.legion-treasury` reference).
3. **Wire the treasury** — the deployer (and only the deployer) calls, once each:

   ```clarity
   (contract-call? .legion-treasury set-gov    .legion-gov)
   (contract-call? .legion-treasury set-token  'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token)
   ```

   Each wiring is one-time: a second call returns `(err u403)`.

Clarinet's default deployment plan handles ordering automatically because both
contracts are declared in `Clarinet.toml` (treasury first). The wiring in
step 3 is an explicit transaction you run after deploy (the test suite performs
it in a `wire()` helper before each scenario).

### Typical end-to-end usage

In all calls below, `SBTC` is `'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token`.

```clarity
;; agents stake sBTC (weight = staked sBTC, forwarded into treasury)
(contract-call? .legion-gov stake SBTC u1000000)         ;; agent A
(contract-call? .legion-gov stake SBTC u1000000)         ;; agent B

;; propose a transfer (rejects gov/treasury as recipient -> u407)
(contract-call? .legion-gov propose "pay bounty" 'SP...RECIPIENT u500000)

;; vote (one vote per principal; weight = stake)
(contract-call? .legion-gov vote u1 true)                ;; A
(contract-call? .legion-gov vote u1 true)                ;; B

;; in the exec window, with quorum + threshold + >= 2 voters + no veto:
(contract-call? .legion-gov conclude-proposal u1 SBTC)   ;; -> treasury pays out
```

## Error codes

| Code | Meaning | Where |
| --- | --- | --- |
| `u401` | unauthorized (treasury) / ineligible zero-stake voter (gov) | treasury, gov |
| `u402` | insufficient balance (treasury) | treasury |
| `u403` | already wired — gov/token (treasury) | treasury |
| `u404` | no such proposal | gov |
| `u405` | double vote | gov |
| `u407` | self-targeting proposal (recipient is gov/treasury) | gov |
| `u409` | zero / invalid amount | treasury |
| `u410` | wiring to treasury-self (treasury) / zero snapshot at propose (gov) | treasury, gov |
| `u411` | treasury self-recipient (treasury) / vote too soon (gov) | treasury, gov |
| `u412` | **`ERR_WRONG_TOKEN`** — supplied token != wired sBTC (treasury) / vote too late (gov) | treasury, gov |
| `u413`+ | gov lifecycle guards (concluded / veto window / exec window) | gov |

> **Note on `u412`:** in the treasury it is the new `ERR_WRONG_TOKEN`, raised by
> `deposit` / `execute-transfer` when `(contract-of ft)` does not equal the wired
> sBTC token principal. Because it aborts the whole transaction, a `stake` or
> `conclude-proposal` forwarded with the wrong token bubbles `u412` up unchanged.

## Governance rules (gov)

A proposal executes its transfer on `conclude-proposal` only when **all** hold:

- it is concluded inside the exec window `[execStart, execEnd)`,
- quorum: cast votes `>= 15%` of the total-staked snapshot,
- threshold: yes weight `>= 66%` of cast votes,
- distinct voter count `>= 2` (min-participant floor),
- the proposal was not veto-activated (`veto >= 15%` of snapshot AND `veto > yes`).

Otherwise it concludes as a failed proposal (`ok false`, no transfer). Voting is
restricted to `[voteStart, voteEnd)`, requires non-zero stake, allows one vote per
principal (changeable in-window), and the veto window is `[voteEnd, execStart)`.
The lifecycle uses **test-fast timing**: stacks-block windows with
`VOTING_DELAY=1` / `VOTING_PERIOD=15` (for production, revert to burn-block
timing — see the comment in `legion-gov.clar`). The other parameters (15% quorum,
66% threshold, 2-participant floor, total-staked snapshot) are unchanged.

## Testing

`tests/legion.test.ts` (vitest + clarinet-sdk simnet) runs **26 tests** against
the **real** testnet sBTC token, pulled into simnet via Clarinet requirements
(no mock). Each scenario funds its wallets through the token's public `(faucet)`
and wires the treasury's token with `set-token`. Coverage:

1. Happy path: stake → propose → vote → advance → conclude → transfer (all
   amounts in sBTC).
2. Threshold fail (`ok false`, no transfer) and quorum fail (`ok false`).
3. Veto blocks an otherwise-passing proposal.
4. Vote timing (`u412` too late), vote changing, double vote (`u405`),
   min-participant floor.
5. Unauthorized spend → `u401`, no state change.
6. Zero guards (`u409` / `u417`); self-targeting (`u407`); empty-desc (`u418`);
   missing proposal (`u404`); self-wiring (`u410`).
7. **Wrong token rejected (`u412`, `ERR_WRONG_TOKEN`)** on deposit, stake (via
   gov), and conclude (withdraw via treasury) — no balance change.

## Safety notes

- No `unwrap-panic` / `unwrap-err-panic` anywhere; every failure path returns an
  explicit `(err uNNN)`.
- The pool is sBTC: every fund-moving entrypoint takes a `<sip010-trait>` token
  and asserts `(contract-of ft)` equals the wired token before use, which both
  enforces the correct token and satisfies the `check_checker` analysis pass
  (the assert sanitizes the trait reference; amount asserts sanitize amounts).
- `clarinet check` is clean: **0 errors, 0 warnings, exit 0** — with no
  `#[allow(...)]` / `allow(unchecked_data)` annotations anywhere.
