import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voter1 = accounts.get("wallet_2")!;
const voter2 = accounts.get("wallet_3")!;
const corrA = accounts.get("wallet_4")!; // correspondent A, 49 signals
const corrB = accounts.get("wallet_5")!; // correspondent B, 35 signals
const challenger = accounts.get("wallet_6")!;
const outsider = accounts.get("wallet_7")!;

const TREASURY = "news-treasury";
const GOV = "news-gov";
const govPrincipal = `${deployer}.${GOV}`;

const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// Must match news-gov.clar.
const CHALLENGE_WINDOW = 144; // TEST TIMING: stacks blocks
const DISPUTE_WINDOW = 144;
const MIN_WEIGHT = 10_000;

const WEEK = "2026-07-20";
const INSCRIPTIONS = [Uint8Array.from([0x33, 0xed, 0xd6, 0x3e])];

// Three equal contributors: pool == total weight == 30,000,000.
//   draw      = 0.5% of 30,000,000 = 150,000
//   fee       = 1%   of 150,000    =   1,500
//   perSignal = 148,500 / 84       =   1,767
//   bond      = max(10,000, 5bps of 30,000,000 = 15,000) = 15,000
const CONTRIB = 10_000_000;
const POOL = 3 * CONTRIB;
const FEE = 1_500;
const BOND = 15_000;
const SIGNALS_A = 49;
const SIGNALS_B = 35;
const PER_SIGNAL = 1_767;
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

function canSettle(week = WEEK): boolean {
  const r = simnet.callReadOnlyFn(GOV, "can-settle", [Cl.stringAscii(week)], deployer);
  return (r.result as any).type === 3; // ClarityType.BoolTrue
}

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

function wire() {
  expect(
    simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
  ).toBeOk(Cl.bool(true));
}

function propose(who = proposer, week = WEEK, list = entries()) {
  return simnet.callPublicFn(
    GOV,
    "propose-brief",
    [Cl.stringAscii(week), Cl.list(INSCRIPTIONS.map((i) => Cl.buffer(i))), list],
    who,
  );
}

const REASON = "agent-07 shows 30 signals, the briefs show 12";

function challenge(who = challenger, week = WEEK, reason = REASON) {
  return simnet.callPublicFn(
    GOV,
    "challenge",
    [Cl.stringAscii(week), Cl.stringAscii(reason)],
    who,
  );
}

function vote(who: string, overturn: boolean, week = WEEK) {
  return simnet.callPublicFn(GOV, "vote", [Cl.stringAscii(week), Cl.bool(overturn)], who);
}

function settle(week = WEEK, who = outsider) {
  return simnet.callPublicFn(GOV, "settle", [Cl.stringAscii(week)], who);
}

function briefStatus(week = WEEK): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-brief-status", [Cl.stringAscii(week)], deployer);
  return (r.result as any).value.value as bigint;
}

function passChallengeWindow() {
  simnet.mineEmptyBlocks(CHALLENGE_WINDOW + 1);
}

function passDisputeWindow() {
  simnet.mineEmptyBlocks(DISPUTE_WINDOW + 1);
}

/** Three contributors, 30,000,000 pool. */
function fundedLegion() {
  wire();
  contribute(proposer);
  contribute(voter1);
  contribute(voter2);
}

/** Four contributors, so a challenger has weight to post a bond with. */
function fundedWithChallenger() {
  fundedLegion();
  contribute(challenger);
}

// ---- tests ---------------------------------------------------------

describe("the normal week: nobody votes at all", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("pays everyone once the challenge window passes, with zero votes cast", () => {
    const aBefore = sbtcOf(corrA);
    const bBefore = sbtcOf(corrB);
    const pBefore = sbtcOf(proposer);

    passChallengeWindow();
    expect(settle().result).toBeOk(Cl.uint(1)); // SETTLED

    expect(sbtcOf(corrA)).toBe(aBefore + BigInt(PAY_A));
    expect(sbtcOf(corrB)).toBe(bBefore + BigInt(PAY_B));
    expect(sbtcOf(proposer)).toBe(pBefore + BigInt(FEE));
  });

  it("silence is assent: no quorum is required for the happy path", () => {
    // This is the whole difference from affirmative voting, where zero votes
    // meant zero quorum meant nobody got paid.
    passChallengeWindow();
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(poolOf()).toBe(BigInt(POOL - PAY_A - PAY_B - FEE));
  });

  it("refuses to settle before the challenge window closes", () => {
    expect(canSettle()).toBe(false);
    expect(settle().result).toBeErr(Cl.uint(408));
  });

  it("reports when settlement becomes possible", () => {
    expect(canSettle()).toBe(false);
    passChallengeWindow();
    expect(canSettle()).toBe(true);
  });

  it("releases the proposer's bond and leaves weight untouched", () => {
    passChallengeWindow();
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(lockedOf(proposer)).toBe(0n);
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
    expect(totalWeight()).toBe(BigInt(POOL));
  });

  it("is terminal", () => {
    passChallengeWindow();
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(settle().result).toBeErr(Cl.uint(410));
    expect(propose().result).toBeErr(Cl.uint(410));
  });
});

describe("challenge", () => {
  beforeEach(() => {
    fundedWithChallenger();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("freezes settlement past the original challenge deadline", () => {
    // Challenge late in the window so the dispute window clearly outlives it:
    // there is a stretch where the challenge deadline has passed but the
    // dispute has not been decided, and settlement must be blocked there.
    simnet.mineEmptyBlocks(CHALLENGE_WINDOW - 40);
    expect(challenge().result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBlocks(60); // past challengeEnd, well inside disputeEnd

    expect(canSettle()).toBe(false);
    expect(settle().result).toBeErr(Cl.uint(408));

    passDisputeWindow();
    expect(canSettle()).toBe(true);
  });

  it("locks a matching bond from the challenger", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    expect(lockedOf(challenger)).toBe(lockedOf(proposer));
  });

  it("refuses a challenge after the window closes", () => {
    passChallengeWindow();
    expect(challenge().result).toBeErr(Cl.uint(428));
  });

  it("refuses a second challenge", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    expect(challenge(voter1).result).toBeErr(Cl.uint(427));
  });

  it("refuses the proposer challenging their own week", () => {
    expect(challenge(proposer).result).toBeErr(Cl.uint(430));
  });

  it("refuses a challenger with no weight", () => {
    expect(challenge(outsider).result).toBeErr(Cl.uint(401));
  });

  it("requires the challenger to say what is wrong", () => {
    // Voters cannot verify an unstated claim. Without a reason, every voter has
    // to independently reverse-engineer the objection.
    expect(challenge(challenger, WEEK, "").result).toBeErr(Cl.uint(431));
  });

  it("records the objection for voters to check", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    const r = simnet.callReadOnlyFn(
      GOV,
      "get-challenge",
      [Cl.stringAscii(WEEK)],
      deployer,
    );
    // Shape-agnostic: assert the record round-trips both fields.
    const dump = Cl.prettyPrint(r.result as any);
    expect(dump).toContain(REASON);
    expect(dump).toContain(challenger);
  });
});

describe("voting happens only in a dispute", () => {
  beforeEach(() => {
    fundedWithChallenger();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("refuses a vote when no challenge is open", () => {
    expect(vote(voter1, true).result).toBeErr(Cl.uint(429));
  });

  it("refuses both parties to the dispute", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    expect(vote(proposer, false).result).toBeErr(Cl.uint(423));
    expect(vote(challenger, true).result).toBeErr(Cl.uint(423));
  });

  it("refuses a correspondent named in the week", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    contribute(corrA);
    expect(vote(corrA, false).result).toBeErr(Cl.uint(406));
  });

  it("refuses a second vote from the same principal", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter1, false).result).toBeErr(Cl.uint(405));
  });

  it("refuses votes after the dispute window closes", () => {
    expect(challenge().result).toBeOk(Cl.bool(true));
    passDisputeWindow();
    expect(vote(voter1, true).result).toBeErr(Cl.uint(407));
  });
});

describe("dispute: challenger wins", () => {
  beforeEach(() => {
    fundedWithChallenger();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(challenge().result).toBeOk(Cl.bool(true));
    // Both remaining contributors back the challenger: 100% overturn.
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    passDisputeWindow();
  });

  it("pays nobody and leaves the pool untouched", () => {
    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // OVERTURNED
    expect(sbtcOf(corrA)).toBe(aBefore);
    expect(poolOf()).toBe(BigInt(4 * CONTRIB));
  });

  it("transfers the proposer's bond to the challenger", () => {
    const bond = BigInt(4 * CONTRIB) / 2000n; // 5 bps of total weight
    const proposerBefore = weightOf(proposer);
    const challengerBefore = weightOf(challenger);
    const totalBefore = totalWeight();

    expect(settle().result).toBeOk(Cl.uint(2));

    expect(weightOf(proposer)).toBe(proposerBefore - bond);
    expect(weightOf(challenger)).toBe(challengerBefore + bond);
    // A transfer, not a burn: catching a bad week is paid out of the loser.
    expect(totalWeight()).toBe(totalBefore);
  });

  it("reopens the week for someone else", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose(voter1).result).toBeOk(Cl.stringAscii(WEEK));
    expect(briefStatus()).toBe(0n);
  });

  it("bars the losing proposer from immediately re-proposing", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose().result).toBeErr(Cl.uint(422));
  });
});

describe("dispute: challenger loses", () => {
  it("settles and hands the challenger's bond to the proposer when voters uphold", () => {
    fundedWithChallenger();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(challenge().result).toBeOk(Cl.bool(true));
    expect(vote(voter1, false).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, false).result).toBeOk(Cl.bool(true));
    passDisputeWindow();

    const bond = BigInt(4 * CONTRIB) / 2000n;
    const proposerBefore = weightOf(proposer);
    const challengerBefore = weightOf(challenger);
    const aBefore = sbtcOf(corrA);

    expect(settle().result).toBeOk(Cl.uint(1)); // SETTLED

    expect(sbtcOf(corrA)).toBeGreaterThan(aBefore);
    expect(weightOf(challenger)).toBe(challengerBefore - bond);
    expect(weightOf(proposer)).toBe(proposerBefore + bond);
  });

  it("settles when a challenge draws no turnout at all", () => {
    // The proposal stands by default. A cheap objection cannot freeze a week
    // that nobody actually disputes, and the challenger pays for trying.
    fundedWithChallenger();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(challenge().result).toBeOk(Cl.bool(true));
    passDisputeWindow(); // nobody votes

    const bond = BigInt(4 * CONTRIB) / 2000n;
    const challengerBefore = weightOf(challenger);
    const aBefore = sbtcOf(corrA);

    expect(settle().result).toBeOk(Cl.uint(1)); // SETTLED
    expect(sbtcOf(corrA)).toBeGreaterThan(aBefore);
    expect(weightOf(challenger)).toBe(challengerBefore - bond);
  });

  it("settles when the overturn vote falls short of the threshold", () => {
    fundedWithChallenger();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(challenge().result).toBeOk(Cl.bool(true));
    // Split 50/50, below the 66% needed to overturn.
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, false).result).toBeOk(Cl.bool(true));
    passDisputeWindow();

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(1)); // SETTLED
    expect(sbtcOf(corrA)).toBeGreaterThan(aBefore);
  });
});

describe("contribute: money in, weight out", () => {
  beforeEach(() => wire());

  it("gives the first contributor weight equal to their contribution", () => {
    contribute(proposer, 10_000_000);
    expect(weightOf(proposer)).toBe(10_000_000n);
    expect(poolOf()).toBe(10_000_000n);
  });

  it("splits weight in proportion to what each contributor put in", () => {
    contribute(proposer, 10_000);
    contribute(voter1, 30_000);
    expect(weightOf(proposer)).toBe(10_000n); // 25%
    expect(weightOf(voter1)).toBe(30_000n); // 75%
  });

  it("keeps one pool, so every sat in is spendable on journalism", () => {
    contribute(proposer);
    contribute(voter1);
    expect(totalWeight()).toBe(poolOf());
  });

  it("refuses a zero contribution", () => {
    faucet(outsider);
    expect(simnet.callPublicFn(GOV, "contribute", [Cl.uint(0)], outsider).result).toBeErr(
      Cl.uint(409),
    );
  });
});

describe("share-of-balance: contributions are measured against the live pool", () => {
  it("gives a post-payout contributor credit for the money actually there", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    passChallengeWindow();
    expect(settle().result).toBeOk(Cl.uint(1));

    const poolAfter = poolOf();
    const weightBefore = totalWeight();
    expect(poolAfter).toBeLessThan(weightBefore);

    faucet(outsider);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(Number(poolAfter))], outsider);

    // Funded half of what is now in the pool, so holds half the total weight.
    expect(weightOf(outsider)).toBe(weightBefore);
    expect(totalWeight()).toBe(weightBefore * 2n);
  });
});

describe("proposal validation", () => {
  beforeEach(() => {
    wire();
    contribute(proposer);
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

  it("rejects empty entries", () => {
    expect(propose(proposer, WEEK, Cl.list([])).result).toBeErr(Cl.uint(411));
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

describe("wiring", () => {
  it("wires gov once, and refuses a second wiring", () => {
    wire();
    expect(
      simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
    ).toBeErr(Cl.uint(403));
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
    wire();
    faucet(outsider);
    expect(
      simnet.callPublicFn(TREASURY, "contribute-in", [Cl.uint(1000)], outsider).result,
    ).toBeErr(Cl.uint(401));
  });
});

describe("fee ref cannot collide with a payout ref", () => {
  it("produces different refs for the same week and principal", () => {
    wire();
    const payout = simnet.callReadOnlyFn(
      GOV,
      "payout-ref",
      [Cl.stringAscii(WEEK), Cl.principal(proposer)],
      deployer,
    );
    const fee = simnet.callReadOnlyFn(
      GOV,
      "fee-ref",
      [Cl.stringAscii(WEEK), Cl.principal(proposer)],
      deployer,
    );
    expect((payout.result as any).buffer).not.toEqual((fee.result as any).buffer);
  });

  it("settles a week in which the proposer is also a paid correspondent", () => {
    fundedLegion();
    const both = entries([
      [proposer, 10],
      [corrA, 10],
    ]);
    expect(propose(proposer, WEEK, both).result).toBeOk(Cl.stringAscii(WEEK));
    passChallengeWindow();
    expect(settle().result).toBeOk(Cl.uint(1));
  });
});
