# mainnet deploy

The two deployable contracts, copied from `../contracts/` under the names they
take on chain. Nothing else is in this project, so a mainnet apply cannot
publish a simnet artifact by accident.

```
elsalvador-yes-legion-v2   <- ../contracts/yes-legion.clar   (source of record)
elsalvador-no-legion-v2    <- ../contracts/no-legion.clar    (generated)
```

Re-copy after any change upstream:

```bash
node ../scripts/gen.mjs
cp ../contracts/yes-legion.clar contracts/elsalvador-yes-legion-v2.clar
cp ../contracts/no-legion.clar  contracts/elsalvador-no-legion-v2.clar
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

Budgeted at 0.3 STX per publish, 0.6 STX total. The market itself,
`elsalvador-stakes-btc` at 27,278 bytes, confirmed on mainnet for 250,000 uSTX;
these are 26,680. Confirm the deployer's balance before applying.

Do NOT publish through the aibtc MCP. Its `deploy_contract` clamps the fee to
50,000 uSTX, a fifth of what a contract this size needs, so the transaction
would sit in the mempool holding the sender's nonce and freeze every later
transaction from that wallet.

## Then seed

Two calls on the market, from any wallet holding sBTC. Nothing on the legion
side: the market writes `positions[to]` directly.

```
elsalvador-stakes-btc-v2.mint-complete-set(N)
elsalvador-stakes-btc-v2.transfer-shares(u1, N, <deployer>.elsalvador-yes-legion-v2)
elsalvador-stakes-btc-v2.transfer-shares(u0, N, <deployer>.elsalvador-no-legion-v2)
```

`u1` is Bonded, `u0` is Idle. Seeding N per vault costs exactly N sats, because
one mint yields both sides; whatever you do not hand over merges back to sBTC.

**Do not mint from inside a vault.** A vault holding both sides is inert today,
since neither contract has a `merge-complete-set` call, but `redeem` zeroes both
sides and pays only the winning one, so stray shares of the wrong side are burned
at settlement.
