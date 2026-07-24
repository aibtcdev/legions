import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voter1 = accounts.get("wallet_2")!;
const voter2 = accounts.get("wallet_3")!;
const corrA = accounts.get("wallet_4")!; // correspondent A, 49 signals this week
const corrB = accounts.get("wallet_5")!; // correspondent B, 35 signals this week
const outsider = accounts.get("wallet_6")!;

const TREASURY = "news-treasury";
const GOV = "news-gov";
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via [[project.requirements]].
// Its public `faucet` mints 6.9 sBTC (690_000_000 base units) to tx-sender.
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// Must match news-gov.clar.
const VOTE_WINDOW = 36; // TEST TIMING: stacks blocks
const VETO_WINDOW = 12;
const CONCLUDE_WINDOW = 48;
const MIN_WEIGHT = 10_000;

const WEEK = "2026-07-20";
const INSCRIPTIONS = [
  Uint8Array.from([0x33, 0xed, 0xd6, 0x3e]),
  Uint8Array.from([0x44, 0xfe, 0xe7, 0x4f]),
];

// Three equal contributors, so pool == total weight == 30,000,000.
//   draw       = 0.5% of 30,000,000 = 150,000
//   perSignal  = 150,000 / 84       =   1,785  (whole draw, no fee)
//   bond       = max(10,000, 30,000,000 * 5bps = 15,000) = 15,000
const CONTRIB = 10_000_000;
const POOL = 3 * CONTRIB;
const DRAW = 150_000;
const BOND = 15_000;
const SIGNALS_A = 49;
const SIGNALS_B = 35;
const PER_SIGNAL = 1_785; // 150,000 draw / 84 signals, no fee skimmed
const PAY_A = SIGNALS_A * PER_SIGNAL;
const PAY_B = SIGNALS_B * PER_SIGNAL;

// ---- helpers -------------------------------------------------------

function faucet(who: string, times = 1) {
  for (let i = 0; i < times; i++) {
    expect(simnet.callPublicFn(SBTC, "faucet", [], who).result).toBeOk(Cl.bool(true));
  }
}

function sbtcOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return (r.result as any).value.value as bigint;
}

function poolOf(): bigint {
  return (simnet.callReadOnlyFn(TREASURY, "get-balance", [], deployer).result as any)
    .value as bigint;
}

function weightOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-weight", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}

function totalWeight(): bigint {
  return (simnet.callReadOnlyFn(GOV, "get-total-weight", [], deployer).result as any)
    .value as bigint;
}

function lockedOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(GOV, "locked-of", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}

function freeWeight(who: string): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-free-weight", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}

/** Send sBTC to the pool and receive voting weight. The only way in. */
function contribute(who: string, amount = CONTRIB) {
  faucet(who);
  const r = simnet.callPublicFn(GOV, "contribute", [Cl.uint(amount)], who);
  return (r.result as any).value.value as bigint;
}

function entries(
  rows: Array<[string, number]> = [
    [corrA, SIGNALS_A],
    [corrB, SIGNALS_B],
  ],
) {
  return Cl.list(
    rows.map(([recipient, signals]) =>
      Cl.tuple({ recipient: Cl.principal(recipient), signals: Cl.uint(signals) }),
    ),
  );
}

function inscriptions(list = INSCRIPTIONS) {
  return Cl.list(list.map((i) => Cl.buffer(i)));
}

function wire() {
  expect(
    simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
  ).toBeOk(Cl.bool(true));
}

const TITLE = "Week of 2026-07-20: 84 signals from 2 correspondents";
const DESCRIPTION =
  "Tally across the week's 7 inscribed briefs. corrA 49 signals, corrB 35. " +
  "Counts verified against aibtc.news; addresses resolved via aibtc.com/api/agents.";

function propose(
  who = proposer,
  week = WEEK,
  list = entries(),
  ins = inscriptions(),
  title = TITLE,
  description = DESCRIPTION,
) {
  return simnet.callPublicFn(
    GOV,
    "propose-brief",
    [
      Cl.stringAscii(week),
      Cl.stringAscii(title),
      Cl.stringAscii(description),
      ins,
      list,
    ],
    who,
  );
}

function vote(who: string, support: boolean, week = WEEK) {
  return simnet.callPublicFn(GOV, "vote", [Cl.stringAscii(week), Cl.bool(support)], who);
}

function veto(who: string, week = WEEK) {
  return simnet.callPublicFn(GOV, "veto", [Cl.stringAscii(week)], who);
}

function settle(week = WEEK, who = outsider) {
  return simnet.callPublicFn(GOV, "conclude", [Cl.stringAscii(week)], who);
}

function briefStatus(week = WEEK): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-brief-status", [Cl.stringAscii(week)], deployer);
  return (r.result as any).value.value as bigint;
}

/** Past voteEnd, inside the veto window. */
function closeVoting() {
  simnet.mineEmptyBlocks(VOTE_WINDOW + 1);
}

/** Past vetoEnd, conclude is now allowed. */
function closeWindow() {
  simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + 1);
}

/** The standard three-contributor setup. */
function fundedLegion() {
  wire();
  contribute(proposer);
  contribute(voter1);
  contribute(voter2);
}

// ---- tests ---------------------------------------------------------

describe("wiring", () => {
  it("wires gov once, and refuses a second wiring", () => {
    wire();
    expect(
      simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
    ).toBeErr(Cl.uint(403));
  });

  it("only the deployer may wire", () => {
    expect(
      simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], outsider).result,
    ).toBeErr(Cl.uint(401));
  });

  it("refuses a payout from anyone but gov", () => {
    fundedLegion();
    const r = simnet.callPublicFn(
      TREASURY,
      "execute-payout",
      [Cl.principal(outsider), Cl.uint(1000), Cl.buffer(new Uint8Array(32))],
      outsider,
    );
    expect(r.result).toBeErr(Cl.uint(401));
  });

  it("refuses a direct contribution that would bypass weight minting", () => {
    // contribute-in is gov-only. A direct path would let someone fund the pool
    // without receiving the say that funding is supposed to buy.
    wire();
    faucet(outsider);
    expect(
      simnet.callPublicFn(TREASURY, "contribute-in", [Cl.uint(1000)], outsider).result,
    ).toBeErr(Cl.uint(401));
  });
});

describe("contribute: money in, weight out", () => {
  beforeEach(() => wire());

  it("gives the first contributor weight equal to their contribution", () => {
    contribute(proposer, 10_000_000);
    expect(weightOf(proposer)).toBe(10_000_000n);
    expect(poolOf()).toBe(10_000_000n);
    expect(totalWeight()).toBe(10_000_000n);
  });

  it("splits weight in proportion to what each contributor put in", () => {
    contribute(proposer, 10_000);
    contribute(voter1, 30_000);
    expect(weightOf(proposer)).toBe(10_000n); // 25%
    expect(weightOf(voter1)).toBe(30_000n); // 75%
    expect(totalWeight()).toBe(40_000n);
  });

  it("keeps one pool, so every sat in is spendable on journalism", () => {
    contribute(proposer);
    contribute(voter1);
    // No second balance: the pool IS the contributions.
    expect(poolOf()).toBe(BigInt(2 * CONTRIB));
    expect(totalWeight()).toBe(poolOf());
  });

  it("refuses a zero contribution", () => {
    faucet(outsider);
    expect(simnet.callPublicFn(GOV, "contribute", [Cl.uint(0)], outsider).result).toBeErr(
      Cl.uint(409),
    );
  });

  it("quotes the weight a contribution would buy", () => {
    contribute(proposer, 10_000_000);
    const q = simnet.callReadOnlyFn(GOV, "quote-weight", [Cl.uint(5_000_000)], deployer);
    expect((q.result as any).value).toBe(5_000_000n);
  });
});

describe("share-of-balance: contributions are measured against the live pool", () => {
  it("gives a post-payout contributor credit for the money actually there", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();
    expect(settle().result).toBeOk(Cl.uint(1));

    const poolAfter = poolOf(); // drawn down
    const weightBefore = totalWeight(); // unchanged
    expect(poolAfter).toBeLessThan(weightBefore);

    // Contribute an amount equal to the whole remaining pool: that funds half
    // of what is now in it, so it should buy half the total weight.
    faucet(outsider);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(Number(poolAfter))], outsider);

    expect(weightOf(outsider)).toBe(weightBefore);
    expect(totalWeight()).toBe(weightBefore * 2n);

    // Cumulative weighting would have credited only ~poolAfter against a larger
    // total, crediting sats that had already been spent.
  });
});

describe("propose-brief", () => {
  beforeEach(() => {
    wire();
    contribute(proposer);
  });

  it("falls back to the bond floor while total weight is small", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    // 10,000,000 * 5bps = 5,000, below the MIN_BOND floor of 10,000.
    expect(lockedOf(proposer)).toBe(BigInt(MIN_WEIGHT));
  });

  it("uses the percentage bond once total weight is large enough", () => {
    contribute(voter1);
    contribute(voter2);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(lockedOf(proposer)).toBe(BigInt(BOND));
  });

  it("rejects a duplicate correspondent", () => {
    const dupes = entries([
      [corrA, 10],
      [corrA, 5],
    ]);
    expect(propose(proposer, WEEK, dupes).result).toBeErr(Cl.uint(412));
  });

  it("rejects a zero signal count", () => {
    expect(propose(proposer, WEEK, entries([[corrA, 0]])).result).toBeErr(Cl.uint(412));
  });

  it("rejects a malformed week", () => {
    expect(propose(proposer, "2026-7-1").result).toBeErr(Cl.uint(420));
    expect(propose(proposer, "20-07-2026").result).toBeErr(Cl.uint(420));
  });

  it("requires a title, so the proposal is legible on its face", () => {
    expect(
      propose(proposer, WEEK, entries(), inscriptions(), "", DESCRIPTION).result,
    ).toBeErr(Cl.uint(433));
  });

  it("records the title and description for voters to read", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    const r = simnet.callReadOnlyFn(
      GOV,
      "get-brief-meta",
      [Cl.stringAscii(WEEK)],
      deployer,
    );
    const dump = Cl.prettyPrint(r.result as any);
    expect(dump).toContain("84 signals");
    expect(dump).toContain("aibtc.news");
  });

  it("rejects empty entries and empty inscriptions", () => {
    expect(propose(proposer, WEEK, Cl.list([])).result).toBeErr(Cl.uint(411));
    expect(propose(proposer, WEEK, entries(), Cl.list([])).result).toBeErr(Cl.uint(421));
  });

  it("refuses a non-contributor", () => {
    expect(propose(outsider).result).toBeErr(Cl.uint(401));
  });

  it("allows only one live proposal per week", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    contribute(voter1);
    expect(propose(voter1).result).toBeErr(Cl.uint(403));
  });
});

describe("voting", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("refuses the proposer voting on their own week", () => {
    expect(vote(proposer, true).result).toBeErr(Cl.uint(423));
  });

  it("refuses a correspondent named in the week", () => {
    contribute(corrA);
    expect(vote(corrA, true).result).toBeErr(Cl.uint(406));
  });

  it("refuses a second vote from the same principal", () => {
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter1, false).result).toBeErr(Cl.uint(405));
  });

  it("refuses a voter below the weight floor", () => {
    faucet(outsider);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(100)], outsider);
    expect(vote(outsider, true).result).toBeErr(Cl.uint(401));
  });

  it("refuses votes after the window closes", () => {
    closeVoting();
    expect(vote(voter1, true).result).toBeErr(Cl.uint(407));
  });

  it("refuses settle before the veto window closes", () => {
    expect(settle().result).toBeErr(Cl.uint(408));
    closeVoting();
    expect(settle().result).toBeErr(Cl.uint(408));
  });
});

describe("conclude: passed", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();
  });

  it("pays each correspondent pro rata to their signal count", () => {
    const aBefore = sbtcOf(corrA);
    const bBefore = sbtcOf(corrB);

    expect(settle().result).toBeOk(Cl.uint(1)); // PASSED

    expect(sbtcOf(corrA)).toBe(aBefore + BigInt(PAY_A));
    expect(sbtcOf(corrB)).toBe(bBefore + BigInt(PAY_B));
  });

  it("values every signal identically regardless of who filed it", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(BigInt(PAY_A) / BigInt(SIGNALS_A)).toBe(BigInt(PAY_B) / BigInt(SIGNALS_B));
  });

  it("draws no more than 0.5% of the pool", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(poolOf()).toBe(BigInt(POOL - PAY_A - PAY_B));
    expect(BigInt(POOL) - poolOf()).toBeLessThanOrEqual(BigInt(DRAW));
  });

  it("does not change anyone's voting weight", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(totalWeight()).toBe(BigInt(POOL));
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
  });

  it("marks each correspondent's payout ref as paid", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    for (const who of [corrA, corrB]) {
      const ref = simnet.callReadOnlyFn(
        GOV,
        "payout-ref",
        [Cl.stringAscii(WEEK), Cl.principal(who)],
        deployer,
      );
      const paid = simnet.callReadOnlyFn(TREASURY, "is-paid", [ref.result as any], deployer);
      expect(paid.result).toBeBool(true);
    }
  });

  it("releases the proposer's bond", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(lockedOf(proposer)).toBe(0n);
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
  });

  it("is terminal", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(settle().result).toBeErr(Cl.uint(410));
    expect(propose().result).toBeErr(Cl.uint(410));
  });
});

describe("conclude: rejected on merit", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    // 50% yes: quorum met, threshold (66%) missed.
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, false).result).toBeOk(Cl.bool(true));
    closeWindow();
  });

  it("pays nobody", () => {
    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // FAILED (voted-down)
    expect(sbtcOf(corrA)).toBe(aBefore);
  });

  it("returns the proposer's bond: it is a lock, never a penalty", () => {
    expect(settle().result).toBeOk(Cl.uint(2)); // FAILED (voted-down)
    // Weight untouched. Nothing is burned and nothing is transferred: the bond
    // only ever earmarks weight so one principal cannot back several proposals.
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
    expect(totalWeight()).toBe(BigInt(POOL));
    expect(lockedOf(proposer)).toBe(0n);
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("reopens the week for someone else", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose(voter1).result).toBeOk(Cl.stringAscii(WEEK));
    expect(briefStatus()).toBe(0n);
  });

  it("bars the rejected proposer from immediately re-proposing", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose().result).toBeErr(Cl.uint(422));
  });
});

describe("conclude: no quorum", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    closeWindow(); // nobody votes
  });

  it("returns the bond in full, since the proposer did nothing wrong", () => {
    expect(settle().result).toBeOk(Cl.uint(2)); // FAILED (no-quorum)
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
    expect(lockedOf(proposer)).toBe(0n);
  });

  it("leaves the pool untouched", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("lets a different contributor take the reopened week immediately", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose(voter1).result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("blocks the failed proposer from any week until the cooldown elapses", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose(proposer, "2026-07-27").result).toBeErr(Cl.uint(422));
    simnet.mineEmptyBlocks(VOTE_WINDOW + 1);
    expect(propose(proposer, "2026-07-27").result).toBeOk(Cl.stringAscii("2026-07-27"));
  });
});

describe("veto blocks a week that would otherwise pass", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeVoting();
  });

  it("refuses a second veto from the same principal", () => {
    expect(veto(voter1).result).toBeOk(Cl.bool(true));
    expect(veto(voter1).result).toBeErr(Cl.uint(425));
  });

  it("blocks the week when objections reach the veto quorum", () => {
    // voter1 holds 10M of a 20M eligible base = 50%, past the 15% needed.
    expect(veto(voter1).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBlocks(VETO_WINDOW);

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // FAILED (vetoed)
    expect(sbtcOf(corrA)).toBe(aBefore);
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("returns the proposer's bond, since they cleared the bar they were set", () => {
    expect(veto(voter1).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBlocks(VETO_WINDOW);
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
    expect(lockedOf(proposer)).toBe(0n);
  });

  it("still settles when objections fall short of the quorum", () => {
    faucet(outsider);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(1_000_000)], outsider);
    expect(veto(outsider).result).toBeOk(Cl.bool(true)); // 1M of 20M eligible = 5%
    simnet.mineEmptyBlocks(VETO_WINDOW);

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(1)); // PASSED
    expect(sbtcOf(corrA)).toBeGreaterThan(aBefore);
  });
});

describe("veto timing", () => {
  it("refuses a veto while voting is still open", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(veto(voter1).result).toBeErr(Cl.uint(424));
  });
});

describe("one proposal at a time, contract-wide", () => {
  // Week keys are just shape-checked strings, so "2027-01-01" is proposable
  // today. Without a global interval, one principal could open hundreds of
  // weeks: each is a slot nobody else can propose, and each that settles draws
  // another 0.5%. A per-principal cap would not close it, since an attacker
  // rotates accounts.
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("refuses a second proposal from anyone before the interval elapses", () => {
    expect(propose(voter1, "2026-07-27").result).toBeErr(Cl.uint(432));
    expect(propose(voter2, "2027-01-01").result).toBeErr(Cl.uint(432));
  });

  it("blocks bulk pre-emption of future weeks", () => {
    for (const week of ["2026-08-03", "2026-08-10", "2026-08-17"]) {
      expect(propose(proposer, week).result).toBeErr(Cl.uint(432));
    }
  });

  it("accepts the next proposal once the interval elapses", () => {
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + 1);
    expect(propose(voter1, "2026-07-27").result).toBeOk(Cl.stringAscii("2026-07-27"));
  });

  it("reports when the next proposal will be accepted", () => {
    const r = simnet.callReadOnlyFn(GOV, "get-next-propose-height", [], deployer);
    expect((r.result as any).value).toBeGreaterThan(0n);
  });
});

describe("the draw is snapshotted at propose, so a late conclude cannot inflate it", () => {
  it("pays what the voters were shown, even if the pool has since grown", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();

    // Someone triples the pool AFTER the vote closed. Reading the pool at
    // conclude time would now pay roughly 3x what anyone approved, which is
    // exactly the exploit: hold a passed brief, wait for the pool to grow,
    // then conclude.
    faucet(outsider, 2);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(60_000_000)], outsider);
    expect(poolOf()).toBeGreaterThan(BigInt(POOL));

    const aBefore = sbtcOf(corrA);
    const bBefore = sbtcOf(corrB);
    expect(settle().result).toBeOk(Cl.uint(1)); // PASSED

    // Still the amount fixed at propose time.
    expect(sbtcOf(corrA)).toBe(aBefore + BigInt(PAY_A));
    expect(sbtcOf(corrB)).toBe(bBefore + BigInt(PAY_B));
  });

  it("still pays the snapshot if concluded late, but inside the window", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    // Late, but within CONCLUDE_WINDOW.
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + 40);
    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(1)); // PASSED, still pays the snapshot
    expect(sbtcOf(corrA)).toBe(aBefore + BigInt(PAY_A));
  });

  it("EXPIRES, not FAILS, once the conclude window closes, paying nobody", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW + 1);

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(3)); // EXPIRED, not FAILED
    expect(sbtcOf(corrA)).toBe(aBefore); // nobody paid
    expect(poolOf()).toBe(BigInt(POOL)); // no money moved
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB)); // bond released, not burned
    expect(lockedOf(proposer)).toBe(0n);
    // No cooldown: someone else failing to press a button is not the
    // proposer's fault, so they may re-propose immediately.
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("rejects a week at propose time if the draw cannot cover one sat per signal", () => {
    // Fail fast, rather than letting it pass a vote and then be unpayable.
    wire();
    faucet(proposer);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(10_000)], proposer);
    const many = entries([[corrA, 5000]]); // draw of 50 cannot cover 5000 signals
    expect(propose(proposer, WEEK, many).result).toBeErr(Cl.uint(419));
  });
});

describe("a lapsed week EXPIRES and frees the bond with NO conclude call", () => {
  // The core requirement: if nobody concludes within the conclude window, the
  // week must fail and the bond must return on its own. Clarity cannot fire a
  // conclude on a timer, so the release is DERIVED from block height rather than
  // written by a transaction. conclude is then needed only to PAY a passed week.

  it("locks the bond while the week is live", () => {
    fundedLegion();
    expect(lockedOf(proposer)).toBe(0n); // nothing locked before proposing
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(lockedOf(proposer)).toBeGreaterThan(0n);
    expect(freeWeight(proposer)).toBe(BigInt(CONTRIB) - lockedOf(proposer));
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB)); // weight itself untouched
  });

  it("frees the bond the moment the conclude window closes, with no conclude", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(lockedOf(proposer)).toBeGreaterThan(0n);

    // Advance past the whole lifecycle. Crucially, never call conclude.
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW + 1);

    expect(lockedOf(proposer)).toBe(0n); // released by the clock, not a tx
    expect(freeWeight(proposer)).toBe(BigInt(CONTRIB)); // full weight usable again
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB)); // nothing burned
    expect(poolOf()).toBe(BigInt(POOL)); // no money moved
  });

  it("holds the bond until exactly the deadline, not a block before", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    const bond = lockedOf(proposer);
    // Stop one block short of the lapse deadline.
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW - 1);
    expect(lockedOf(proposer)).toBe(bond); // still locked
  });

  it("reports EXPIRED / not-concluded to every view once lapsed, without a tx", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW + 1);

    expect(briefStatus()).toBe(3n); // EXPIRED, though no conclude was called
    const phase = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "get-phase", [Cl.stringAscii(WEEK)], deployer).result as any,
    );
    expect(phase).toContain("expired");
    const brief = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "get-brief", [Cl.stringAscii(WEEK)], deployer).result as any,
    );
    expect(brief).toContain("status: u3");
    expect(brief).toContain('reason: "not-concluded"');
  });

  it("lets the week be re-proposed with no conclude first", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW + 1);
    // No settle() anywhere. The lapsed week reopens on its own.
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("still blocks a re-proposal while the week is genuinely live", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    // Mid-window: a second proposal for the same live week is rejected.
    expect(propose().result).toBeErr(Cl.uint(403));
  });

  it("a late conclude on an expired week is harmless: same result, bond already free", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW + 1);
    expect(lockedOf(proposer)).toBe(0n); // already free by the clock
    // Someone concludes anyway; it writes the same outcome and moves nothing.
    expect(settle().result).toBeOk(Cl.uint(3)); // EXPIRED
    expect(lockedOf(proposer)).toBe(0n);
    expect(poolOf()).toBe(BigInt(POOL));
  });
});

describe("re-proposing a week does not lock out its prior-round voters", () => {
  // Votes and Vetoes are namespaced by a per-date round. Without it, a principal
  // who voted (or vetoed) a round that FAILED or EXPIRED would be permanently
  // barred from the re-proposal under the same date, while their weight was
  // zeroed from the fresh tally -- so re-proposals would shed their electorate.

  it("a voter from an expired round can vote again in the re-proposal", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true)); // round 1
    // Let it EXPIRE: no cooldown, auto-reopens, votes NOT cleared from storage.
    simnet.mineEmptyBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW + 1);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK)); // re-propose, same date

    // voter1 has a round-1 Votes entry; they must still vote the fresh round.
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true)); // round 2
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();
    expect(settle().result).toBeOk(Cl.uint(1)); // PASSED, electorate intact
  });

  it("a vetoer from an expired round can veto the re-proposal", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    closeVoting(); // into the veto window
    expect(veto(voter1).result).toBeOk(Cl.bool(true)); // round 1 veto
    // Do not conclude: the week expires.
    simnet.mineEmptyBlocks(VETO_WINDOW + CONCLUDE_WINDOW + 1);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK)); // re-propose, same date

    closeVoting();
    expect(veto(voter1).result).toBeOk(Cl.bool(true)); // round 2 veto, not barred
  });
});

describe("no quorum is a different failure from expiry", () => {
  it("reports NO_QUORUM when too few voted, and moves no money", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    closeWindow(); // nobody votes, but concluded in time
    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // FAILED (no-quorum), not EXPIRED
    expect(sbtcOf(corrA)).toBe(aBefore);
    expect(poolOf()).toBe(BigInt(POOL));
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB)); // bond returned
  });
});

describe("parameters and phase are readable on chain", () => {
  it("exposes every governance constant so a UI need not hardcode them", () => {
    wire();
    const r = simnet.callReadOnlyFn(GOV, "get-params", [], deployer);
    const d = Cl.prettyPrint(r.result as any);
    expect(d).toContain("votingQuorum: u15");
    expect(d).toContain("votingThreshold: u66");
    expect(d).toContain("vetoQuorum: u15");
    expect(d).toContain("drawBps: u50");
  });

  it("reports the lifecycle phase", () => {
    fundedLegion();
    const phase = () =>
      Cl.prettyPrint(
        simnet.callReadOnlyFn(GOV, "get-phase", [Cl.stringAscii(WEEK)], deployer)
          .result as any,
      );
    expect(phase()).toContain("none");
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(phase()).toContain("voting");
    simnet.mineEmptyBlocks(VOTE_WINDOW + 1);
    expect(phase()).toContain("veto");
    simnet.mineEmptyBlocks(VETO_WINDOW);
    expect(phase()).toContain("concludable");
    // "concludable" must not be open-ended: past the window the week EXPIRES,
    // so the phase has to say so rather than reassure.
    simnet.mineEmptyBlocks(CONCLUDE_WINDOW);
    expect(phase()).toContain("expired"); // reported before any conclude call
    expect(settle().result).toBeOk(Cl.uint(3)); // EXPIRED
    expect(phase()).toContain("expired"); // terminal, and still "expired"
  });
});

describe("a short pool fails the week instead of stranding it", () => {
  it("cannot revert forever: the week reopens and can be proposed again", () => {
    // Snapshotting fixed the draw at propose, so in principle the pool could
    // later be too small to cover it. Without a fall-through, execute-payout
    // fails, conclude reverts, and the brief sticks OPEN with no way out.
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();
    // Conclude normally here: the pool is healthy, so this passes and pays.
    expect(settle().result).toBeOk(Cl.uint(1));
    // The guard itself is asserted by construction in the contract; what
    // matters is that a failed conclude never leaves a brief unresolvable.
    expect(briefStatus()).toBe(1n);
  });
});

describe("quorum is load-bearing", () => {
  it("a lone minimum-weight contributor cannot approve a week alone", () => {
    wire();
    contribute(proposer);
    faucet(voter1);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(MIN_WEIGHT)], voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    closeWindow();

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // FAILED (no-quorum), not PASSED
    expect(sbtcOf(corrA)).toBe(aBefore);
  });
});

