# mainnet deploy

The two deployable contracts, copied from `../contracts/` under the names they
take on chain. Nothing else is in this project, so a mainnet apply cannot
publish a simnet artifact by accident.

```
elsalvador-yes-legion   <- ../contracts/yes-legion.clar   (source of record)
elsalvador-no-legion    <- ../contracts/no-legion.clar    (generated)
```

Re-copy after any change upstream:

```bash
node ../scripts/gen.mjs
cp ../contracts/yes-legion.clar contracts/elsalvador-yes-legion.clar
cp ../contracts/no-legion.clar  contracts/elsalvador-no-legion.clar
clarinet check
```

## Publish

There is no wiring step. No `set-gov`, no `set-token`, no setter of any kind, so
the contracts are live the moment they confirm and there is no window in which
one is published but misconfigured.

```bash
# settings/Mainnet.toml is gitignored; add the deployer mnemonic, then remove it
clarinet deployments apply -p deployments/default.mainnet-plan.yaml
```

Budgeted at 1.6 STX per publish, 3.2 STX total, for ~27 KB each. Confirm the
deployer's balance covers it before applying.

## Then seed

Two calls on the market, from any wallet holding sBTC. Nothing on the legion
side: the market writes `positions[to]` directly.

```
elsalvador-stakes-btc.mint-complete-set(N)
elsalvador-stakes-btc.transfer-shares(u1, N, <deployer>.elsalvador-yes-legion)
elsalvador-stakes-btc.transfer-shares(u0, N, <deployer>.elsalvador-no-legion)
```

`u1` is Bonded, `u0` is Idle. Seeding N per vault costs exactly N sats, because
one mint yields both sides; whatever you do not hand over merges back to sBTC.

**Do not mint from inside a vault.** A vault holding both sides is inert today,
since neither contract has a `merge-complete-set` call, but `redeem` zeroes both
sides and pays only the winning one, so stray shares of the wrong side are burned
at settlement.
