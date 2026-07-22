import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voter1 = accounts.get("wallet_2")!;
const voter2 = accounts.get("wallet_3")!;
const corrA = accounts.get("wallet_4")!; // correspondent A -- 49 signals this week
const corrB = accounts.get("wallet_5")!; // correspondent B -- 35 signals this week
const outsider = accounts.get("wallet_6")!;

const TREASURY = "news-treasury";
const GOV = "news-gov";
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via [[project.requirements]].
// Its public `faucet` mints 6.9 sBTC (690_000_000 base units) to tx-sender.
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// Must match news-gov.clar.
const VOTE_WINDOW = 1008; // ~7 days in burn blocks
const MIN_STAKE = 10_000;

// The week's first brief date. Keyed per week, not per day.
const WEEK = "2026-07-20";
const INSCRIPTIONS = [
  Uint8Array.from([0x33, 0xed, 0xd6, 0x3e]),
  Uint8Array.from([0x44, 0xfe, 0xe7, 0x4f]),
];

// Arithmetic the worked example in the README depends on:
//   draw          = 0.5% of 100,000,000 = 500,000
//   proposer fee  = 1%   of 500,000     =   5,000
//   distributable =                       495,000
//   per signal    = 495,000 / 84        =   5,892  (remainder 72 stays in Pool)
const POOL = 100_000_000;
const STAKE = 10_000_000;
const DRAW = 500_000;
const FEE = 5_000;
const BOND = 50_000; // 10% of the draw
const SIGNALS_A = 49;
const SIGNALS_B = 35;
const PER_SIGNAL = 5_892;
const PAY_A = SIGNALS_A * PER_SIGNAL; // 288,708
const PAY_B = SIGNALS_B * PER_SIGNAL; // 206,220

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
  return (simnet.callReadOnlyFn(TREASURY, "get-pool", [], deployer).result as any).value as bigint;
}

function stakedOf(): bigint {
  return (simnet.callReadOnlyFn(TREASURY, "get-staked", [], deployer).result as any).value as bigint;
}

function stakeOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-stake", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}

function lockedOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(GOV, "locked-of", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}

/** One entry per correspondent: how many of their signals landed this week. */
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

function fundPool(amount = POOL) {
  faucet(deployer);
  expect(simnet.callPublicFn(TREASURY, "deposit", [Cl.uint(amount)], deployer).result).toBeOk(
    Cl.bool(true),
  );
}

function stake(who: string, amount = STAKE) {
  faucet(who);
  expect(simnet.callPublicFn(GOV, "stake", [Cl.uint(amount)], who).result).toBeOk(Cl.uint(amount));
}

function propose(who = proposer, week = WEEK, list = entries(), ins = inscriptions()) {
  return simnet.callPublicFn(GOV, "propose-brief", [Cl.stringAscii(week), ins, list], who);
}

function vote(who: string, support: boolean, week = WEEK) {
  return simnet.callPublicFn(GOV, "vote", [Cl.stringAscii(week), Cl.bool(support)], who);
}

function settle(week = WEEK, who = outsider) {
  return simnet.callPublicFn(GOV, "settle", [Cl.stringAscii(week)], who);
}

function briefStatus(week = WEEK): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-brief-status", [Cl.stringAscii(week)], deployer);
  return (r.result as any).value.value as bigint;
}

function closeWindow() {
  simnet.mineEmptyBurnBlocks(VOTE_WINDOW + 1);
}

// ---- tests ---------------------------------------------------------

describe("wiring and funding", () => {
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

  it("anyone may deposit, and deposits land in Pool, not Staked", () => {
    wire();
    fundPool();
    expect(poolOf()).toBe(BigInt(POOL));
    expect(stakedOf()).toBe(0n);
  });

  it("keeps stake out of the pool", () => {
    wire();
    fundPool();
    stake(proposer);
    expect(poolOf()).toBe(BigInt(POOL));
    expect(stakedOf()).toBe(BigInt(STAKE));
  });

  it("refuses a payout from anyone but gov", () => {
    wire();
    fundPool();
    const r = simnet.callPublicFn(
      TREASURY,
      "execute-payout",
      [Cl.principal(outsider), Cl.uint(1000), Cl.buffer(new Uint8Array(32))],
      outsider,
    );
    expect(r.result).toBeErr(Cl.uint(401));
  });

  it("refuses an unstake from anyone but gov", () => {
    wire();
    fundPool();
    const r = simnet.callPublicFn(
      TREASURY,
      "execute-unstake",
      [Cl.principal(outsider), Cl.uint(1000)],
      outsider,
    );
    expect(r.result).toBeErr(Cl.uint(401));
  });
});

describe("staking", () => {
  beforeEach(() => {
    wire();
    fundPool();
  });

  it("enforces the membership floor", () => {
    faucet(proposer);
    expect(simnet.callPublicFn(GOV, "stake", [Cl.uint(MIN_STAKE - 1)], proposer).result).toBeErr(
      Cl.uint(414),
    );
  });

  it("returns stake on unstake when nothing is locked", () => {
    stake(proposer);
    const before = sbtcOf(proposer);
    expect(simnet.callPublicFn(GOV, "unstake", [Cl.uint(STAKE)], proposer).result).toBeOk(
      Cl.uint(0),
    );
    expect(sbtcOf(proposer)).toBe(before + BigInt(STAKE));
    expect(stakedOf()).toBe(0n);
  });

  it("blocks unstaking while a week the member voted on is open", () => {
    stake(proposer);
    stake(voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(simnet.callPublicFn(GOV, "unstake", [Cl.uint(STAKE)], voter1).result).toBeErr(
      Cl.uint(415),
    );
  });

  it("keeps a proposer's bond unwithdrawable while the vote is live", () => {
    stake(proposer);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    closeWindow(); // lock expires, but the bond is still earmarked
    const free = simnet.callReadOnlyFn(GOV, "get-free-stake", [Cl.principal(proposer)], deployer);
    expect((free.result as any).value).toBe(BigInt(STAKE - BOND));
  });
});

describe("propose-brief", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
  });

  it("locks a bond of 10% of the pending draw", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(lockedOf(proposer)).toBe(BigInt(BOND));
  });

  it("rejects a duplicate correspondent", () => {
    // Two entries for the same principal would collide on payout-ref and revert
    // the whole settlement, so they are refused at propose time.
    const dupes = entries([
      [corrA, 10],
      [corrA, 5],
    ]);
    expect(propose(proposer, WEEK, dupes).result).toBeErr(Cl.uint(412));
  });

  it("rejects a zero signal count", () => {
    expect(propose(proposer, WEEK, entries([[corrA, 0]])).result).toBeErr(Cl.uint(412));
  });

  it("rejects a malformed week date", () => {
    expect(propose(proposer, "2026-7-1").result).toBeErr(Cl.uint(420));
  });

  it("rejects a correctly-sized date with separators in the wrong place", () => {
    expect(propose(proposer, "20-07-2026").result).toBeErr(Cl.uint(420));
  });

  it("rejects an empty entry list", () => {
    expect(propose(proposer, WEEK, Cl.list([])).result).toBeErr(Cl.uint(411));
  });

  it("rejects an empty inscription list", () => {
    expect(propose(proposer, WEEK, entries(), Cl.list([])).result).toBeErr(Cl.uint(421));
  });

  it("refuses a non-member", () => {
    expect(propose(outsider).result).toBeErr(Cl.uint(401));
  });

  it("allows only one live proposal per week", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    stake(voter1);
    expect(propose(voter1).result).toBeErr(Cl.uint(403));
  });

  it("stores a digest over the entries", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    const d = simnet.callReadOnlyFn(GOV, "get-entry-digest", [Cl.stringAscii(WEEK)], deployer);
    expect((d.result as any).value).toBeDefined();
  });
});

describe("voting", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });

  it("refuses the proposer voting on their own week", () => {
    expect(vote(proposer, true).result).toBeErr(Cl.uint(423));
  });

  it("refuses a correspondent named in the week", () => {
    stake(corrA);
    expect(vote(corrA, true).result).toBeErr(Cl.uint(406));
  });

  it("refuses a second vote from the same principal", () => {
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter1, false).result).toBeErr(Cl.uint(405));
  });

  it("refuses votes after the window closes", () => {
    closeWindow();
    expect(vote(voter1, true).result).toBeErr(Cl.uint(407));
  });

  it("refuses settle before the window closes", () => {
    expect(settle().result).toBeErr(Cl.uint(408));
  });
});

describe("settle -- passed", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    stake(voter2);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();
  });

  it("pays each correspondent pro rata to their signal count", () => {
    const aBefore = sbtcOf(corrA);
    const bBefore = sbtcOf(corrB);
    const pBefore = sbtcOf(proposer);

    expect(settle().result).toBeOk(Cl.uint(1)); // STATUS_SETTLED

    expect(sbtcOf(corrA)).toBe(aBefore + BigInt(PAY_A));
    expect(sbtcOf(corrB)).toBe(bBefore + BigInt(PAY_B));
    expect(sbtcOf(proposer)).toBe(pBefore + BigInt(FEE));
  });

  it("values every signal identically regardless of who filed it", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(BigInt(PAY_A) / BigInt(SIGNALS_A)).toBe(BigInt(PAY_B) / BigInt(SIGNALS_B));
  });

  it("draws no more than 0.5% of the pool, keeping the rounding remainder", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    // 84 * 5,892 + 5,000 fee = 499,928 -- 72 sats of rounding stay in the pool.
    expect(poolOf()).toBe(BigInt(POOL - PAY_A - PAY_B - FEE));
    expect(BigInt(POOL) - poolOf()).toBeLessThanOrEqual(BigInt(DRAW));
  });

  it("never touches staked collateral", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(stakedOf()).toBe(BigInt(3 * STAKE));
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
    expect(stakeOf(proposer)).toBe(BigInt(STAKE));
  });

  it("is terminal -- the week can never be settled or proposed again", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(settle().result).toBeErr(Cl.uint(410));
    expect(propose().result).toBeErr(Cl.uint(410));
  });
});

describe("settle -- rejected on merit", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    stake(voter2);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    // 50% yes -- quorum met, threshold (66%) missed.
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, false).result).toBeOk(Cl.bool(true));
    closeWindow();
  });

  it("pays nobody", () => {
    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // STATUS_REJECTED
    expect(sbtcOf(corrA)).toBe(aBefore);
  });

  it("slashes the bond from stake into the pool", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(stakeOf(proposer)).toBe(BigInt(STAKE - BOND));
    expect(poolOf()).toBe(BigInt(POOL + BOND));
    expect(stakedOf()).toBe(BigInt(3 * STAKE - BOND));
  });

  it("reopens the week for a corrected proposal", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(briefStatus()).toBe(0n); // STATUS_OPEN
  });
});

describe("settle -- expired on apathy", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    // Nobody votes.
    closeWindow();
  });

  it("returns the bond in full -- the proposer did nothing wrong", () => {
    expect(settle().result).toBeOk(Cl.uint(3)); // STATUS_EXPIRED
    expect(stakeOf(proposer)).toBe(BigInt(STAKE));
    expect(lockedOf(proposer)).toBe(0n);
  });

  it("leaves the pool untouched", () => {
    expect(settle().result).toBeOk(Cl.uint(3));
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("reopens the week", () => {
    expect(settle().result).toBeOk(Cl.uint(3));
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
  });
});

describe("fee ref cannot collide with a payout ref", () => {
  // The fee hashes {f,r}; an entry payout hashes {d,r}. Consensus serialization
  // encodes tuple field names, so the shapes can never produce equal bytes --
  // even when the proposer is also a correspondent in their own week.
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    stake(voter2);
  });

  it("produces different refs for the same (week, principal)", () => {
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
    const hostile = entries([
      [proposer, 10],
      [corrA, 10],
    ]);
    expect(propose(proposer, WEEK, hostile).result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    closeWindow();
    expect(settle().result).toBeOk(Cl.uint(1)); // settles, does not revert
  });
});

describe("quorum is load-bearing", () => {
  it("a lone minimum-stake member cannot approve a week by themselves", () => {
    wire();
    fundPool();
    stake(proposer);
    // 10k of a 10M eligible base is 0.1%, far below the 15% quorum -- and
    // MIN_PARTICIPANTS is 2 regardless of weight.
    faucet(voter1);
    expect(simnet.callPublicFn(GOV, "stake", [Cl.uint(MIN_STAKE)], voter1).result).toBeOk(
      Cl.uint(MIN_STAKE),
    );
    expect(propose().result).toBeOk(Cl.stringAscii(WEEK));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    closeWindow();

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(3)); // EXPIRED, not SETTLED
    expect(sbtcOf(corrA)).toBe(aBefore);
  });
});
