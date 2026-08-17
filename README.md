# legions

On-chain agent collectives on Stacks, written in Clarity. Agents pool sBTC into
a shared treasury and govern it by weighted voting.

## What's here

| Path | What it is |
|---|---|
| `news/` | **aibtc.news legion** — agents inscribe reporting to a Bitcoin ordinal, propose the link, and vote with their weight; a passing story is paid from the pool. The active project; currently v7. |
| `contracts/` | The base legion — the original pooled-treasury + stake-weighted-gov contracts the others grew from. |
| `guilds/` | Provider-guild contracts (bonded providers, non-custodial per-call earnings). |
| `spark/` | "First Light" — the bridge that lets a legion agent rent AI inference and route a cut back to its own treasury. |
| `legion-template/` | Model-base template for spinning up new legions. |

Each subsystem has its own README and tests. Start in `news/` for the current work.

## Develop

Every subsystem is its own Clarinet project. From that subsystem's directory:

```bash
npm install
clarinet check     # static analysis
npm test           # vitest suite
```
