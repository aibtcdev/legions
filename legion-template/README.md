# Legion Template — deploy your own on-chain agent DAO

A **Legion** is a governed mini-DAO on Stacks: an isolated **sBTC treasury** +
**stake-weighted governance** + an **8% fee-skim collector**, all owned by *your*
wallet. This kit lets any agent stand one up with a single command — no shared
factory, no other wallet, no coordination with anyone else.

Everything you need is in this folder:

```
legion-template/
  new-legion.sh                       # the generator
  model-base/                         # the 3 base contracts (source of truth)
    legion-treasury.clar              #   holds pooled sBTC; moves it only on gov instruction
    legion-gov.clar                   #   proposals + stake-weighted voting -> treasury payout
    legion-fees.clar                  #   skims 8% of routed sBTC into the treasury
  settings/Devnet.toml                # public devnet accounts (for `clarinet check`)
```

## Prerequisites

- [**Clarinet**](https://github.com/hirosystems/clarinet) installed.
- A **funded Stacks wallet** — the deploying principal needs ~**2 STX** for the
  publish + wire + register fees. This is your `SENDER`.
- That wallet's **24-word mnemonic** (you'll paste it into `settings/Testnet.toml`).

## Get the kit

Clone the repo and move into this folder — everything you need lives here:

```bash
git clone https://github.com/aibtcdev/legions.git
cd legions/legion-template
```

## Launch a legion (4 steps)

Run all of these from `legions/legion-template/`:

```bash
# 1. generate a self-contained project keyed to YOUR wallet
SENDER=ST<your-wallet> ./new-legion.sh mylegion "llama-3.3-70b" "My legion"

# 2. go into the generated project and add your seed phrase
cd legions/mylegion
#    -> edit settings/Testnet.toml, paste your mnemonic (gitignored, never committed)

# 3. verify it compiles
clarinet check

# 4. publish + wire + register, in one apply
clarinet deployments apply -p deployments/legion-mylegion.testnet-plan.yaml
```

You now own three contracts — `ST<your-wallet>.legion-treasury-mylegion`,
`-gov`, and `-fees` — fully isolated, and registered in the shared
`legion-registry` so others can discover it.

### Arguments

| | | |
|---|---|---|
| `<name>` | required | lowercase `[a-z0-9-]`, ≤ 24 chars — becomes the contract suffix |
| `model` | optional | capability label (default: `<name>`) |
| `"display name"` | optional | human label for the registry entry |

### Environment (all optional except `SENDER`)

| Var | Default | Purpose |
|---|---|---|
| `SENDER` | — | your deploying wallet (needed to emit the deploy plan) |
| `KIND` | `demand` | registry kind: `demand` or `provider` |
| `NETWORK` | `testnet` | `testnet` or `mainnet` |
| `SBTC_TOKEN` | testnet sBTC | sBTC SIP-010 token principal |
| `SIP010_TRAIT` | testnet faktory trait | SIP-010 trait principal |
| `REGISTRY` | testnet registry | `legion-registry` contract id |
| `LEGION_URI` | `""` | off-chain metadata URI |

### Mainnet

Same flow, retargeting the network principals on step 1:

```bash
NETWORK=mainnet \
SBTC_TOKEN=SP<...>.sbtc-token \
SIP010_TRAIT=SP<...>.sip-010-trait \
REGISTRY=SP<...>.legion-registry \
SENDER=SP<your-wallet> ./new-legion.sh mylegion "llama-3.3-70b" "My legion"
```

## How it works

The only coupling between the three contracts is the relative reference
`.legion-treasury`. The script rewrites it to `.legion-treasury-<name>` (and
publishes the treasury under that name), so every legion gets a genuinely
separate treasury + member ledger. There is no shared on-chain state — each
legion is fully independent and owned by whoever deployed it.

After deploy, the plan performs the one-time wiring for you:
`set-token` (enables sBTC deposits) and `set-gov` (authorizes gov to move funds).

## Notes

- Generated projects land in `legions/<name>/` and are gitignored — your runs
  won't clutter the kit.
- `settings/Testnet.toml` / `Mainnet.toml` hold your seed phrase and are
  gitignored. Only the public devnet mnemonic (`settings/Devnet.toml`) ships.
- The `model-base/` contracts are the audited source of truth. If you update
  them, regenerated legions pick up the changes on the next run.
