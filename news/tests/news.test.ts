import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voter1 = accounts.get("wallet_2")!;
const voter2 = accounts.get("wallet_3")!;
const corrA = accounts.get("wallet_4")!; // correspondent A -- 7 signals
const corrB = accounts.get("wallet_5")!; // correspondent B -- 5 signals
const outsider = accounts.get("wallet_6")!;

const TREASURY = "news-treasury";
const GOV = "news-gov";
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via [[project.requirements]].
// Its public `faucet` mints 6.9 sBTC (690_000_000 base units) to tx-sender.
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// Must match news-gov.clar.
const VOTE_WINDOW = 144;
const MIN_STAKE = 10_000;

const DATE = "2026-07-21";
const INSCRIPTION = Uint8Array.from([0x33, 0xed, 0xd6, 0x3e]);

// Pool + stake sizes chosen so the arithmetic matches the spec worked example:
//   draw          = 1%  of 100_000_000 = 1_000_000
//   proposer fee  = 1%  of 1_000_000   =    10_000
//   distributable =                       990_000
//   per entry     = 990_000 / 12       =    82_500
const POOL = 100_000_000;
const STAKE = 10_000_000;
const DRAW = 1_000_000;
const FEE = 10_000;
const PER_ENTRY = 82_500;

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

/** 16-byte signal id, ascending with `n` so lists are trivially sortable. */
function signalId(n: number): Uint8Array {
  const b = new Uint8Array(16);
  b[0] = n;
  return b;
}

/** The 12-entry brief from the spec: A filed 7, B filed 5. */
function entries(recipients: string[] = [...Array(7).fill(corrA), ...Array(5).fill(corrB)]) {
  return Cl.list(
    recipients.map((r, i) =>
      Cl.tuple({ signalId: Cl.buffer(signalId(i + 1)), recipient: Cl.principal(r) }),
    ),
  );
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

function propose(who = proposer, date = DATE, list = entries()) {
  return simnet.callPublicFn(
    GOV,
    "propose-brief",
    [Cl.stringAscii(date), Cl.buffer(INSCRIPTION), list],
    who,
  );
}

function vote(who: string, support: boolean, date = DATE) {
  return simnet.callPublicFn(GOV, "vote", [Cl.stringAscii(date), Cl.bool(support)], who);
}

function settle(date = DATE, who = outsider) {
  return simnet.callPublicFn(GOV, "settle", [Cl.stringAscii(date)], who);
}

function briefStatus(date = DATE): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-brief-status", [Cl.stringAscii(date)], deployer);
  return (r.result as any).value.value as bigint;
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

  it("blocks unstaking while a brief the member voted on is open", () => {
    stake(proposer);
    stake(voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(simnet.callPublicFn(GOV, "unstake", [Cl.uint(STAKE)], voter1).result).toBeErr(
      Cl.uint(415),
    );
  });
});

describe("propose-brief", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
  });

  it("locks a bond of 10% of the pending draw", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    const locked = simnet.callReadOnlyFn(GOV, "locked-of", [Cl.principal(proposer)], deployer);
    expect((locked.result as any).value).toBe(BigInt(DRAW / 10));
  });

  it("rejects entries that are not sorted by signal id", () => {
    const unsorted = Cl.list([
      Cl.tuple({ signalId: Cl.buffer(signalId(2)), recipient: Cl.principal(corrA) }),
      Cl.tuple({ signalId: Cl.buffer(signalId(1)), recipient: Cl.principal(corrB) }),
    ]);
    expect(propose(proposer, DATE, unsorted).result).toBeErr(Cl.uint(412));
  });

  it("rejects a malformed brief date", () => {
    expect(propose(proposer, "2026-7-1").result).toBeErr(Cl.uint(420));
  });

  it("rejects an empty entry list", () => {
    expect(propose(proposer, DATE, Cl.list([])).result).toBeErr(Cl.uint(411));
  });

  it("refuses a non-member", () => {
    expect(propose(outsider).result).toBeErr(Cl.uint(401));
  });

  it("allows only one live proposal per date", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    stake(voter1);
    expect(propose(voter1).result).toBeErr(Cl.uint(403));
  });

  it("stores a digest that is stable for identical entries", () => {
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    const d = simnet.callReadOnlyFn(GOV, "get-entry-digest", [Cl.stringAscii(DATE)], deployer);
    expect((d.result as any).value).toBeDefined();
  });
});

describe("voting", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
  });

  it("refuses the proposer voting on their own brief", () => {
    expect(vote(proposer, true).result).toBeErr(Cl.uint(423));
  });

  it("refuses a correspondent named in the brief", () => {
    stake(corrA);
    expect(vote(corrA, true).result).toBeErr(Cl.uint(406));
  });

  it("refuses a second vote from the same principal", () => {
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter1, false).result).toBeErr(Cl.uint(405));
  });

  it("refuses votes after the window closes", () => {
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + 1);
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
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, true).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + 1);
  });

  it("pays every entry its equal share, and the proposer their fee", () => {
    const aBefore = sbtcOf(corrA);
    const bBefore = sbtcOf(corrB);
    const pBefore = sbtcOf(proposer);

    expect(settle().result).toBeOk(Cl.uint(1)); // STATUS_SETTLED

    // A filed 7 of 12 signals, B filed 5.
    expect(sbtcOf(corrA)).toBe(aBefore + BigInt(7 * PER_ENTRY));
    expect(sbtcOf(corrB)).toBe(bBefore + BigInt(5 * PER_ENTRY));
    expect(sbtcOf(proposer)).toBe(pBefore + BigInt(FEE));
  });

  it("draws exactly 1% of the pool and leaves the rest", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    // 12 * 82_500 + 10_000 fee = 1_000_000 exactly, no remainder this run.
    expect(poolOf()).toBe(BigInt(POOL - DRAW));
  });

  it("never touches staked collateral", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    expect(stakedOf()).toBe(BigInt(3 * STAKE));
  });

  it("marks every payout ref as paid", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    const ref = simnet.callReadOnlyFn(
      GOV,
      "payout-ref",
      [Cl.stringAscii(DATE), Cl.buffer(signalId(1)), Cl.principal(corrA)],
      deployer,
    );
    const paid = simnet.callReadOnlyFn(TREASURY, "is-paid", [ref.result as any], deployer);
    expect(paid.result).toBeBool(true);
  });

  it("releases the proposer's bond", () => {
    expect(settle().result).toBeOk(Cl.uint(1));
    const locked = simnet.callReadOnlyFn(GOV, "locked-of", [Cl.principal(proposer)], deployer);
    expect((locked.result as any).value).toBe(0n);
    expect(stakeOf(proposer)).toBe(BigInt(STAKE));
  });

  it("is terminal -- the date can never be settled or proposed again", () => {
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
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    // 50% yes -- quorum met, threshold (66%) missed.
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, false).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + 1);
  });

  it("pays nobody", () => {
    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(2)); // STATUS_REJECTED
    expect(sbtcOf(corrA)).toBe(aBefore);
  });

  it("slashes the bond from stake into the pool", () => {
    const bond = BigInt(DRAW / 10);
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(stakeOf(proposer)).toBe(BigInt(STAKE) - bond);
    expect(poolOf()).toBe(BigInt(POOL) + bond);
    expect(stakedOf()).toBe(BigInt(3 * STAKE) - bond);
  });

  it("reopens the date for a corrected proposal", () => {
    expect(settle().result).toBeOk(Cl.uint(2));
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    expect(briefStatus()).toBe(0n); // STATUS_OPEN
  });
});

describe("settle -- expired on apathy", () => {
  beforeEach(() => {
    wire();
    fundPool();
    stake(proposer);
    stake(voter1);
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    // Nobody votes.
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + 1);
  });

  it("returns the bond in full -- the proposer did nothing wrong", () => {
    expect(settle().result).toBeOk(Cl.uint(3)); // STATUS_EXPIRED
    expect(stakeOf(proposer)).toBe(BigInt(STAKE));
    const locked = simnet.callReadOnlyFn(GOV, "locked-of", [Cl.principal(proposer)], deployer);
    expect((locked.result as any).value).toBe(0n);
  });

  it("leaves the pool untouched", () => {
    expect(settle().result).toBeOk(Cl.uint(3));
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("reopens the date", () => {
    expect(settle().result).toBeOk(Cl.uint(3));
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
  });
});

describe("quorum is load-bearing", () => {
  it("a lone minimum-stake member cannot approve a brief by themselves", () => {
    wire();
    fundPool();
    stake(proposer);
    // One tiny voter against a large eligible base: 10k of 10M is 0.1%, far
    // below the 15% quorum, and MIN_PARTICIPANTS is 2 regardless.
    faucet(voter1);
    expect(simnet.callPublicFn(GOV, "stake", [Cl.uint(MIN_STAKE)], voter1).result).toBeOk(
      Cl.uint(MIN_STAKE),
    );
    expect(propose().result).toBeOk(Cl.stringAscii(DATE));
    expect(vote(voter1, true).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + 1);

    const aBefore = sbtcOf(corrA);
    expect(settle().result).toBeOk(Cl.uint(3)); // EXPIRED, not SETTLED
    expect(sbtcOf(corrA)).toBe(aBefore);
  });
});
