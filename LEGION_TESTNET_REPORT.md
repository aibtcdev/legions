# AIBTC Legion — Live Testnet Run Report

A "Legion" is an on-chain agent collective: agents pool **sBTC** into a shared treasury and govern it by **stake-weighted voting**. This report documents a complete live run on **Stacks testnet** — deploy → fund 10 agents → stake → propose → vote → conclude → payout — including the failure paths (quorum-not-met, threshold-not-met) and the non-staked-voter rejection.

All links: `https://explorer.hiro.so/txid/<txid>?chain=testnet`

---

## 1. Contracts (live on testnet)

Deployer / legion owner: **`STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J`** (legion-agent-01). Clarity version **3**, epoch 3.0.

| Contract | ID | Role |
|---|---|---|
| legion-treasury | [`STXGAS…​.legion-treasury`](https://explorer.hiro.so/address/STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J.legion-treasury?chain=testnet) | sBTC vault; moves funds only on gov/payout instruction |
| legion-gov | [`STXGAS…​.legion-gov`](https://explorer.hiro.so/address/STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J.legion-gov?chain=testnet) | stake-weighted proposals + voting |
| legion-payout | [`STXGAS…​.legion-payout`](https://explorer.hiro.so/address/STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J.legion-payout?chain=testnet) | milestone proof + pro-rata distribution |

External (referenced, not deployed by us):
- sBTC token (SIP-010, 8 dp, public faucet): `STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token`
- SIP-010 trait: `STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait`

**Governance rules** (enforced on-chain): quorum **15%** of total staked must vote · threshold **66%** of cast votes must be YES · min **2** distinct voters · veto path (≥15% & > yes). Test-fast timing: stacks-block windows `VOTING_DELAY=1`, `VOTING_PERIOD=15`.

---

## 2. The 10 agents

| Agent | Address |
|---|---|
| legion-agent-01 (deployer) | STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J |
| legion-agent-02 | ST38Y96G7WHWSWY7JTE3DVM77EBCA86WX63HY9HPV |
| legion-agent-03 | STBEMQQVSS3K3SQTF2NRZMF82JHMNTHQKQ2J7DW5 |
| legion-agent-04 | ST2KVMAENJ1V64YKT722HNQRPRR0W1A4JDA8KW8A4 |
| legion-agent-05 | ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW |
| legion-agent-06 | STGX5YP51NKM69ZMP6DVB6GAJAANCG5WB3718KD9 |
| legion-agent-07 | ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA |
| legion-agent-08 | ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD |
| legion-agent-09 | STH2TAB1VE615MXSQ3HSXVACC2ZEEM0EBY1V8GCK |
| legion-agent-10 | ST2BEBZJ8Y2H6F5DK9KC450238Y3HGJCS9B7P2JD3 |

---

## 3. Timeline

### Phase A — Deploy & wire
1. Deployed the 3 contracts at **Clarity 3** via Clarinet (the aibtc MCP publishes at Clarity 4, where `as-contract` is renamed `as-contract?` → publish aborts; Clarinet pins v3). Contracts confirmed live (addresses above).
2. Wired the treasury (deployer-only, one-time each):
   - set-gov → [`cdce7330`](https://explorer.hiro.so/txid/cdce7330d9c4587d6847beeb1ad5937b869279a83a5c10622b39bb4f49129f65?chain=testnet)
   - set-payout → [`3a9a41d3`](https://explorer.hiro.so/txid/3a9a41d3189c44b31886b8e1e888e8469be3dd45d94c4f3affcc67346203b6fd?chain=testnet)
   - set-token (sBTC) → [`d3c40966`](https://explorer.hiro.so/txid/d3c409668dba2669c251f174077faf95c06045fe043a48d229a410eb12a39e05?chain=testnet)

### Phase B — Fund the 10 agents
3. sBTC faucet (agent-01) → [`55350f4b`](https://explorer.hiro.so/txid/55350f4b6f02f64993c6e806bd5822adb4089e7182f0a01611504f1182907ee3?chain=testnet) (minted 6.9 test sBTC).
4. STX for fees → agents 02–10 (from agent-01): [02](https://explorer.hiro.so/txid/a8def0463385d2d14b2bc7b00f91211dca1c4555a31f5f7f722bc18a8e958c50?chain=testnet) · [03](https://explorer.hiro.so/txid/4857509f355202f3b2826cc7863ad6637414e7dcd71deb84ce079d919d9a0469?chain=testnet) · [04](https://explorer.hiro.so/txid/1215e231c755765783b13dcc994c7f347c71278b1d2c197815394b0babef4149?chain=testnet) · [05](https://explorer.hiro.so/txid/82d98e99e6c0ac0f5892573ab0dbba135467555e5cc24c3eb3951295d23b1229?chain=testnet) · [06](https://explorer.hiro.so/txid/116deadae51aab3c1c1ebd662ec882169bc31d7c2f382d9008273b7225a85e7a?chain=testnet) · [07](https://explorer.hiro.so/txid/51df95dee94dad0312339aaa2b0dac9b5ef8572633b5233b4291a613c7504db5?chain=testnet) · [08](https://explorer.hiro.so/txid/66ee1062ba471d063f8572b7e35bfcd11d5bf2679c2283f24eca81cf7bd3f1bf?chain=testnet) · [09](https://explorer.hiro.so/txid/09cf1de6be57907130dbc0503181b62a033e36a20d19ea54e5075798469734d4?chain=testnet) · [10](https://explorer.hiro.so/txid/22500ccea2bb7b363d50886e1ff04e3742052da89d3def052d1fa6d58976d3f6?chain=testnet)
5. sBTC distributed 0.6 each → agents 02–10: [02](https://explorer.hiro.so/txid/09de4731b11c981edd37534043b0e08b03f4c01bf0a3dfba0c0dc3fedcd98f7f?chain=testnet) · [03](https://explorer.hiro.so/txid/51a3542baca30d30e7abeec8d28c34f4d67831aa0471779045dc56fdcd60ca3a?chain=testnet) · [04](https://explorer.hiro.so/txid/ba1f3b883ae1c47e2910cfa475ffb734a267587aa931e45128ecd18a3243705f?chain=testnet) · [05](https://explorer.hiro.so/txid/b35da8ae4acd2ba68ca382e04deca8fdd269e36ad2cb7777b2063fba6e14517c?chain=testnet) · [06](https://explorer.hiro.so/txid/a0efa448d3a4221c38f78a8364b534c1501a9eb7cc6efc43c74d297eab447c6e?chain=testnet) · [07](https://explorer.hiro.so/txid/9f2d8684dd4809881eb832d2add92c11d9cd4a113a3696ed8fe4e97b62bfbd45?chain=testnet) · [08](https://explorer.hiro.so/txid/c994dc18cad00c647a627dd6004e6070042190d11266ecb8e36b9728c6b9b766?chain=testnet) · [09](https://explorer.hiro.so/txid/df8495936a10f84ce8f9c989ae19933eca78baf1859e627d5d1e77e50aedec4c?chain=testnet) · [10](https://explorer.hiro.so/txid/3e117622ded5c685c0eecc27a8a3d4325f6c3eb36789069d445627f9d540ffe2?chain=testnet)

### Phase C — Staking (join the legion; weight = stake)
All 10 staked 0.5 sBTC each (total **5.0 sBTC**). From agent-03 onward, stakes use `deny` + explicit sBTC post-conditions.

[01](https://explorer.hiro.so/txid/e616bcec53b1c2f6e687d38ad62f759def1d713b85816b697b3665ea3ea8617b?chain=testnet) · [02](https://explorer.hiro.so/txid/9afe1642a42687974248e4da3e308ccae3c380d91b5c93db4439dce5c843a29a?chain=testnet) · [03](https://explorer.hiro.so/txid/8de7e8ba538b38f55bbb628e2e8850c8ce3c5332ae108e2b1522ac06d8426578?chain=testnet) · [04](https://explorer.hiro.so/txid/5df8ee6fc832711abcf282d6a16d858ce913181cbf371eaa715aad53d9a2f8be?chain=testnet) · [05](https://explorer.hiro.so/txid/b4fea9c27c4eb31b0d8d86d8b656497a312aededb7fcff807b1e1e656be8195c?chain=testnet) · [06](https://explorer.hiro.so/txid/2b5fb2338eb57f276d1e3c2ca295a15a9e15ae07158ab9401e3f9c7f97a77cf9?chain=testnet) · [07](https://explorer.hiro.so/txid/9290eccca28006a66e9b5c34160c836c49cb6c9aff5054938b47aa1b7757cdbf?chain=testnet) · [08](https://explorer.hiro.so/txid/4e3250dd9cbc9458bfb68263ddadebaca8cb35c6b1e435cdf28db7de04104307?chain=testnet) · [09](https://explorer.hiro.so/txid/e4c77d2db10d58bbb8248135478646a527c2a0111d20ce104a18c439bf4d9db3?chain=testnet) · [10](https://explorer.hiro.so/txid/ddf3a10c0d0f770e04b961936ffe11f3f1236d03c2a8ab4900da0c79676734bb?chain=testnet)

### Phase D — Proposals (any staked agent can propose)
| # | Proposer | Pay | Amount | Description | Propose tx |
|---|---|---|---|---|---|
| 1 | agent-01 | agent-10 | 0.3 sBTC | Genesis bounty — first inscription | [`d9d954b5`](https://explorer.hiro.so/txid/d9d954b5145a157b8e83cf8e796b3ddfbf4f50e21b2b5f4408206cbfa48ccc44?chain=testnet) |
| 2 | agent-03 | agent-09 | 0.2 sBTC | Heartbeat relay grant | [`a20e33b8`](https://explorer.hiro.so/txid/a20e33b881228f5581a6f26d3d51c79958b57a36d82f42b0196c22142227d46e?chain=testnet) |
| 3 | agent-03 | agent-08 | 0.25 sBTC | Fund AI research — sBTC yield report | [`0d73a0f5`](https://explorer.hiro.so/txid/0d73a0f56c4ddc0d1287ce5c491f46449f48c5f6b7d912cf14cd407dd82a62dd?chain=testnet) |
| 4 | agent-10 | agent-05 | 0.4 sBTC | Research grant — quarterly agent-economy report (all-10 vote) | [`162231f0`](https://explorer.hiro.so/txid/162231f0908a34a13f5cf7b466b7c8fe144843db4b0e1b09354edc96dc0f89b7?chain=testnet) |

### Phase E — Voting, vetoes, conclusions (the test matrix)

**#1 — happy path (PASS + payout):**
- YES votes: [agent-01](https://explorer.hiro.so/txid/79d0ec66b5dc419dcce9235f0482d2e2c7f9552dac974b86940e5c8af4308fb5?chain=testnet), [agent-02](https://explorer.hiro.so/txid/945db17210ea90f2736c8cca9af3f11671074603132c9416693ede67fdc55bbe?chain=testnet), [agent-03](https://explorer.hiro.so/txid/74e600a5035d04649a916f66a1e998ea9f6c7163a31316427e58dcc8be2f6bc5?chain=testnet)
- Conclude → **`(ok true)`** → [`76883df3`](https://explorer.hiro.so/txid/76883df39a3ea6525a390b1c6589cc8e8cf9faf0a491f310f73568caea9f2f2d?chain=testnet) — treasury paid **0.3 sBTC to agent-10** (agent-10 0.6 → 0.9; treasury 1.5 → 1.2).

**Negative test — non-staked agent tries to vote:**
- agent-04 (funded, never staked) votes on #3 → **`abort_by_response (err u401)`** (ineligible) → [`271d3e84`](https://explorer.hiro.so/txid/271d3e84a2f3058622c26c7d2a8f89057885d973c6938b9fa9a219296d1070b5?chain=testnet)

**#3 — threshold NOT met (FAIL):**
- NO votes: [agent-03](https://explorer.hiro.so/txid/36878b310f6324d8ec3ff3c9787f0c21be397585fb4deb509357e0873cc4958c?chain=testnet), [agent-01](https://explorer.hiro.so/txid/c20759eaa9cc438523364f4fc7af8d1f4610caf41b933a08a0b828629a4d720e?chain=testnet) (0 YES, quorum met)
- Conclude → **`(ok false)`** (66% threshold not met, no payout) → [`65d577e8`](https://explorer.hiro.so/txid/65d577e816797b30b5a70395680e0dbda6454c4f9698cc7ad45e5489e173a6c3?chain=testnet)

**#2 — quorum NOT met (FAIL):**
- 0 votes cast → turnout 0% < 15%
- Conclude → **`(ok false)`** (quorum not met, no payout) → [`b5f91787`](https://explorer.hiro.so/txid/b5f91787772257160ed7dafe257619d6d70d8cb37085d0e7b2eecf3744f13f6e?chain=testnet)

**#4 — ALL 10 AGENTS PARTICIPATE (PASS + payout):** snapshot 5.0 sBTC. **All 10 agents voted YES** (100% turnout, 100% yes):
[01](https://explorer.hiro.so/txid/946e8ed91ec06cd452f5b27cca69543f7cadc6123a9258c01a32fcf587beb551?chain=testnet) · [02](https://explorer.hiro.so/txid/fcb9a50f91caf8d1a9f638d4553cc57cb1ab315e57f3bfad6680c580f93b325a?chain=testnet) · [03](https://explorer.hiro.so/txid/832643762ceb4a89c4e64a252cb614f28e274e78d137b5b000b539a3c16062c0?chain=testnet) · [04](https://explorer.hiro.so/txid/b615829f12656a6ac7a9ce12f81582509c8d8b4ff20235cbdad7002e90d3ec6d?chain=testnet) · [05](https://explorer.hiro.so/txid/e5b06f6f52f6c02da49e3c65617b2409285045c0434af3fe01095b1511accb30?chain=testnet) · [06](https://explorer.hiro.so/txid/c708488e497c93107cc279c5c2ba361248c5288927a6899ada2d9ccc04e43f6c?chain=testnet) · [07](https://explorer.hiro.so/txid/4cba94ab519907ff2e0e0c45ff1fe706156681fe96c4c0bc9a7ec287a27f3a81?chain=testnet) · [08](https://explorer.hiro.so/txid/aa5dfa89fdc2e2595fde2caa5dbf471d66150a32c45283a5631dce887d820ce8?chain=testnet) · [09](https://explorer.hiro.so/txid/7bbb63354c8b621e104fcb4eb9b306295e753a764a9e48e46f0a29f0af01b456?chain=testnet) · [10](https://explorer.hiro.so/txid/d51696f71f0f1c36e530e50ed8a9ae33beea4d97c34dc3a8e3df89ca474c9fe3?chain=testnet)
- Conclude → **`(ok true)`** → [`82a8fc00`](https://explorer.hiro.so/txid/82a8fc009f10f976b4fa1d7c3d7e5e21164bd965c43c6493c5bc0b76edde9950?chain=testnet) — treasury paid **0.4 sBTC to agent-05** (treasury 4.7 → 4.3; agent-05 → 0.5).

---

## 4. Result matrix

| Scenario | Mechanism exercised | On-chain result |
|---|---|---|
| #1 happy path | quorum ✓, threshold ✓, ≥2 voters ✓ | `(ok true)` + 0.3 sBTC payout ✅ |
| #2 quorum-not-met | turnout < 15% | `(ok false)`, no payout ✅ |
| #3 threshold-not-met | yes < 66% (quorum met) | `(ok false)`, no payout ✅ |
| non-staked vote | weight = 0 | `(err u401)` rejected ✅ |
| #4 all-10 participation | 10 voters, 5.0 sBTC, 100% yes | `(ok true)` + 0.4 sBTC payout to agent-05 ✅ |

**Verified balances:** treasury **4.3 sBTC** (5.0 staked − 0.3 [#1] − 0.4 [#4]) · total staked **5.0 sBTC** · agent-10 **0.9 sBTC** · agent-05 **0.5 sBTC** (both received payouts). Numbers reconcile exactly; the two failed proposals moved nothing.

---

## 5. Key engineering notes
- **Deploy at Clarity 3, not 4** — the MCP publishes at Clarity 4 (`as-contract` → `as-contract?`); deploy via Clarinet which pins v3.
- **sBTC** = the Faktory testnet token with a public `faucet` (the official sBTC has no faucet; DEX swaps like ALEX/Bitflow/Styx are mainnet-only).
- **Post-conditions**: all fund-moving calls use `postConditionMode: deny` + explicit FT post-conditions (never `allow`).
- Contracts are **immutable** (one-time wiring, no upgrade path) and **stake-weighted** (reputation/heartbeat weighting is a planned v2).
