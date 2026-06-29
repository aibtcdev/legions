import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";
import { readFileSync } from "node:fs";

// The `simnet` object is injected globally by vitest-environment-clarinet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!; // agent A (usual proposer)
const wallet2 = accounts.get("wallet_2")!; // agent B (voter)
const wallet3 = accounts.get("wallet_3")!; // voter / peer
const wallet4 = accounts.get("wallet_4")!; // payout recipient
const wallet5 = accounts.get("wallet_5")!; // extra staker / vetoer

const TREASURY = "legion-treasury";
const GOV = "legion-gov";
const FEES = "legion-fees";

const treasuryPrincipal = `${deployer}.${TREASURY}`;
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via Clarinet requirements
// ([[project.requirements]] in Clarinet.toml). NOT a mock. It exposes a public
// `faucet` that mints a fixed 6.9 sBTC (690_000_000 base units) to tx-sender.
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// A different deployed contract principal used as a WRONG token for the
// token-mismatch guard (any principal that is not the wired sBTC token works;
// the treasury asserts on the trait's contract principal before using it).
const WRONG_TOKEN = `${deployer}.${TREASURY}`;

// Governance lifecycle parameters (must match legion-gov.clar).
const VOTING_DELAY = 3;
const VOTING_PERIOD = 45;
// Rail-A freshness window (must match legion-gov.clar FRESH_WINDOW).
const FRESH_WINDOW = 144;

// ---- helpers -------------------------------------------------------

// Mint sBTC to a wallet via the real token's public faucet.
function faucet(who: string, times = 1) {
  for (let i = 0; i < times; i++) {
    const r = simnet.callPublicFn(SBTC, "faucet", [], who);
    expect(r.result).toBeOk(Cl.bool(true));
  }
}

function sbtcOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return (r.result as any).value.value as bigint;
}

// One-time wiring: deployer wires gov + the sBTC token into the treasury.
function wire() {
  expect(
    simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
  ).toBeOk(Cl.bool(true));
  expect(
    simnet.callPublicFn(TREASURY, "set-token", [Cl.principal(SBTC)], deployer).result,
  ).toBeOk(Cl.bool(true));
}

function stake(who: string, amount: number) {
  return simnet.callPublicFn(GOV, "stake", [Cl.principal(SBTC), Cl.uint(amount)], who);
}

function unstake(who: string, amount: number) {
  return simnet.callPublicFn(GOV, "unstake", [Cl.principal(SBTC), Cl.uint(amount)], who);
}

// Unique 32-byte content hash per call, so independent proposals never collide
// on the Rail-A PaidHash registry unless a test deliberately reuses one.
let hashCounter = 0;
function uniqueHash() {
  hashCounter += 1;
  return Cl.bufferFromHex(hashCounter.toString(16).padStart(64, "0"));
}

// propose with the new Rail-A signature. Defaults: a unique fresh hash, an
// inscription height at the current tip (always within FRESH_WINDOW), 3 sources.
function propose(
  who: string,
  desc: string,
  recipient: string,
  amount: number,
  opts: { hash?: any; insc?: number; sources?: number } = {},
) {
  const hash = opts.hash ?? uniqueHash();
  const insc = opts.insc ?? simnet.blockHeight;
  const sources = opts.sources ?? 3;
  return simnet.callPublicFn(
    GOV,
    "propose",
    [Cl.stringAscii(desc), Cl.principal(recipient), Cl.uint(amount), hash, Cl.uint(insc), Cl.uint(sources)],
    who,
  );
}

function vote(who: string, id: number, support: boolean) {
  return simnet.callPublicFn(GOV, "vote", [Cl.uint(id), Cl.bool(support)], who);
}

function veto(who: string, id: number) {
  return simnet.callPublicFn(GOV, "veto", [Cl.uint(id)], who);
}

function conclude(who: string, id: number) {
  return simnet.callPublicFn(GOV, "conclude-proposal", [Cl.uint(id), Cl.principal(SBTC)], who);
}

function deposit(who: string, amount: number) {
  return simnet.callPublicFn(TREASURY, "deposit", [Cl.principal(SBTC), Cl.uint(amount)], who);
}

function route(who: string, amount: number, to: string) {
  return simnet.callPublicFn(FEES, "route", [Cl.principal(SBTC), Cl.uint(amount), Cl.principal(to)], who);
}

// The treasury's internal pool-accounted balance (uint).
function balance(): bigint {
  const r = simnet.callReadOnlyFn(TREASURY, "get-balance", [], deployer);
  return (r.result as any).value as bigint;
}

function status(id: number): any {
  return simnet.callReadOnlyFn(GOV, "get-proposal-status", [Cl.uint(id)], deployer).result as any;
}

function proposalWindow(id: number) {
  const st = status(id);
  const num = (k: string) => Number(st.value.data[k].value);
  return {
    voteStart: num("voteStart"),
    voteEnd: num("voteEnd"),
    execStart: num("execStart"),
    execEnd: num("execEnd"),
  };
}

function freeStake(who: string): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-free-stake", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}

// Mine empty stacks blocks so the NEXT transaction executes at height `target`.
function mineToHeight(target: number) {
  const delta = target - 1 - simnet.blockHeight;
  if (delta > 0) simnet.mineEmptyStacksBlocks(delta);
}

// Timing helpers (relative to a proposal created at block C):
//   voteStart = C + VOTING_DELAY,  voteEnd  = voteStart + VOTING_PERIOD
//   execStart = voteEnd + VOTING_DELAY, execEnd = execStart + VOTING_PERIOD
function enterVotingWindow() {
  simnet.mineEmptyStacksBlocks(VOTING_DELAY);
}
function enterVetoWindow() {
  simnet.mineEmptyStacksBlocks(VOTING_DELAY + VOTING_PERIOD);
}
function enterExecWindow() {
  simnet.mineEmptyStacksBlocks(2 * VOTING_DELAY + VOTING_PERIOD);
}

// ====================================================================

describe("legion wiring", () => {
  beforeEach(() => {
    wire();
  });

  it("wires gov and token, and rejects re-wiring (u403)", () => {
    expect(simnet.callReadOnlyFn(TREASURY, "get-gov", [], deployer).result).toBeSome(
      Cl.principal(govPrincipal),
    );
    expect(simnet.callReadOnlyFn(TREASURY, "get-token", [], deployer).result).toBeSome(
      Cl.principal(SBTC),
    );
    expect(
      simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
    ).toBeErr(Cl.uint(403));
    expect(
      simnet.callPublicFn(TREASURY, "set-token", [Cl.principal(SBTC)], deployer).result,
    ).toBeErr(Cl.uint(403));
  });
});

describe("Vector 1: full happy path (proposer excluded, two voters)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
  });

  it("stake -> propose -> two NON-proposer voters yes -> conclude -> transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet3, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(balance()).toBe(3_000_000n);

    // amount 500k -> bond 100k (20%), comfortably under wallet1's 1M free stake.
    expect(propose(wallet1, "pay the bounty", wallet4, 500_000).result).toBeOk(Cl.uint(1));
    // bond earmarked: wallet1 free stake drops by 100k.
    expect(freeStake(wallet1)).toBe(900_000n);

    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, true).result).toBeOk(Cl.bool(true));

    expect(conclude(wallet1, 1).result).toBeErr(Cl.uint(416)); // before exec window

    enterExecWindow();
    const w4Before = sbtcOf(wallet4);
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(true));
    expect(balance()).toBe(2_500_000n);
    expect(sbtcOf(wallet4) - w4Before).toBe(500_000n);
    // bond released back to free stake on conclusion.
    expect(freeStake(wallet1)).toBe(1_000_000n);

    expect(conclude(wallet1, 1).result).toBeErr(Cl.uint(413)); // re-conclude rejected
  });
});

describe("Vector 2: threshold fail (yes between 50-65% of cast)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
  });

  it("conclude succeeds as failed (ok false), no transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_200_000).result).toBeOk(Cl.bool(true)); // yes
    expect(stake(wallet3, 800_000).result).toBeOk(Cl.bool(true)); // no
    const startBal = balance();

    expect(propose(wallet1, "contested", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, false).result).toBeOk(Cl.bool(true)); // yes = 60% of cast

    enterExecWindow();
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);

    const st = status(1);
    expect(st.value.data.metQuorum).toStrictEqual(Cl.bool(true));
    expect(st.value.data.metThreshold).toStrictEqual(Cl.bool(false));
    expect(st.value.data.executed).toStrictEqual(Cl.bool(false));
  });
});

describe("Vector 3: quorum fail (turnout < 15% of ELIGIBLE stake)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
    faucet(wallet5, 2); // big silent staker
  });

  it("conclude succeeds as failed (ok false), no transfer", () => {
    expect(stake(wallet1, 500_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 250_000).result).toBeOk(Cl.bool(true)); // yes
    expect(stake(wallet3, 250_000).result).toBeOk(Cl.bool(true)); // yes
    expect(stake(wallet5, 9_000_000).result).toBeOk(Cl.bool(true)); // does NOT vote
    const startBal = balance();

    // eligible = 10M - 0.5M(proposer) = 9.5M; cast = 0.5M => ~5.3% < 15% quorum.
    expect(propose(wallet1, "low turnout", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, true).result).toBeOk(Cl.bool(true));

    enterExecWindow();
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);

    const st = status(1);
    expect(st.value.data.metQuorum).toStrictEqual(Cl.bool(false));
    expect(st.value.data.metThreshold).toStrictEqual(Cl.bool(true));
  });
});

describe("Vector 4: vote too soon / too late", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
  });

  it("in-window ok, after voteEnd => u412", () => {
    // NOTE: with VOTING_DELAY=1 the block immediately after propose IS voteStart,
    // so there is no reachable "too soon" moment to exercise the u411 guard here.
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet3, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "timing", wallet4, 1).result).toBeOk(Cl.uint(1));

    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));

    enterVetoWindow();
    expect(vote(wallet3, 1, true).result).toBeErr(Cl.uint(412));
  });
});

describe("Vector 5: vote changing (yes -> no)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
  });

  it("flipping a vote updates tallies and does not double-count voterCount", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet3, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "flip", wallet4, 1).result).toBeOk(Cl.uint(1));

    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, true).result).toBeOk(Cl.bool(true));

    let st = status(1);
    expect(st.value.data.yesWeight).toStrictEqual(Cl.uint(2_000_000));
    expect(st.value.data.noWeight).toStrictEqual(Cl.uint(0));
    expect(st.value.data.voterCount).toStrictEqual(Cl.uint(2));

    // wallet2 flips yes -> no.
    expect(vote(wallet2, 1, false).result).toBeOk(Cl.bool(true));
    st = status(1);
    expect(st.value.data.yesWeight).toStrictEqual(Cl.uint(1_000_000));
    expect(st.value.data.noWeight).toStrictEqual(Cl.uint(1_000_000));
    expect(st.value.data.voterCount).toStrictEqual(Cl.uint(2));

    enterExecWindow();
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false)); // 50/50 -> threshold fail
  });
});

describe("Vector 6: veto blocks an otherwise-passing proposal", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
    faucet(wallet5);
  });

  it("enough veto weight (>=15% of eligible and > yes) => no transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true)); // yes
    expect(stake(wallet3, 1_000_000).result).toBeOk(Cl.bool(true)); // yes
    expect(stake(wallet5, 3_000_000).result).toBeOk(Cl.bool(true)); // vetoes
    const startBal = balance();

    // eligible = 6M - 1M = 5M; yes = 2M; veto = 3M (>=15% and > yes) => activated.
    expect(propose(wallet1, "vetoed", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, true).result).toBeOk(Cl.bool(true));

    mineToHeight(proposalWindow(1).voteEnd);
    expect(veto(wallet5, 1).result).toBeOk(Cl.bool(true));

    mineToHeight(proposalWindow(1).execStart);
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);

    expect(status(1).value.data.vetoActivated).toStrictEqual(Cl.bool(true));
  });
});

describe("Vector 7: double vote + min-participants", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("same principal voting same direction twice => u405", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "dbl", wallet4, 1).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, true).result).toBeErr(Cl.uint(405));
  });

  it("single voter (< MIN_PARTICIPANTS) => conclude does NOT transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();
    expect(propose(wallet1, "lonely", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true)); // only one voter

    enterExecWindow();
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);
  });
});

describe("ProposerExclusion: proposer cannot vote on own proposal (u423)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("proposer voting own proposal => u423", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "selfvote", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeErr(Cl.uint(423));
    // a non-proposer staker can still vote
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
  });
});

describe("Rail-A PreCheckEnforcer (propose-time gates)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("future inscription height => u426", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    const r = propose(wallet1, "future", wallet4, 100_000, { insc: simnet.blockHeight + 50 });
    expect(r.result).toBeErr(Cl.uint(426));
  });

  it("stale inscription (older than FRESH_WINDOW) => u419", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyStacksBlocks(FRESH_WINDOW + 5);
    const r = propose(wallet1, "stale", wallet4, 100_000, { insc: 1 });
    expect(r.result).toBeErr(Cl.uint(419));
  });

  it("thin sourcing (< 2 sources) => u421", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    const r = propose(wallet1, "thin", wallet4, 100_000, { sources: 1 });
    expect(r.result).toBeErr(Cl.uint(421));
  });

  it("duplicate content hash => u420 (and is freed when proposal fails)", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    const H = uniqueHash();
    expect(propose(wallet1, "first", wallet4, 100_000, { hash: H }).result).toBeOk(Cl.uint(1));
    // claimed
    expect(
      simnet.callReadOnlyFn(GOV, "is-hash-claimed", [H], deployer).result,
    ).toStrictEqual(Cl.bool(true));
    // re-using the same hash reverts
    expect(propose(wallet1, "dup", wallet4, 100_000, { hash: H }).result).toBeErr(Cl.uint(420));

    // proposal 1 has no voters -> fails on conclude -> hash is freed for re-filing
    enterExecWindow();
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false));
    expect(
      simnet.callReadOnlyFn(GOV, "is-hash-claimed", [H], deployer).result,
    ).toStrictEqual(Cl.bool(false));
  });
});

describe("BondLock (bond earmarked from proposer stake)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("bond exceeding free stake => u422", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    // amount 6M -> bond 1.2M > 1M stake
    expect(propose(wallet1, "overbond", wallet4, 6_000_000).result).toBeErr(Cl.uint(422));
  });

  it("one stake cannot back unlimited concurrent proposals", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    // first: amount 4M -> bond 800k, free now 200k
    expect(propose(wallet1, "p1", wallet4, 4_000_000).result).toBeOk(Cl.uint(1));
    expect(freeStake(wallet1)).toBe(200_000n);
    // second: amount 4M -> bond 800k > 200k free => u422
    expect(propose(wallet1, "p2", wallet4, 4_000_000).result).toBeErr(Cl.uint(422));
  });
});

describe("Unstake (StakeLockedUntil + free-stake guard)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("a pure staker (never proposed) can unstake immediately", () => {
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    const before = sbtcOf(wallet2);
    expect(unstake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(sbtcOf(wallet2) - before).toBe(1_000_000n);
    expect(balance()).toBe(0n);
  });

  it("unstaking more than free stake => u425", () => {
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(unstake(wallet2, 1_500_000).result).toBeErr(Cl.uint(425));
  });

  it("a proposer cannot unstake while a proposal is live => u424", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "lock", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    expect(unstake(wallet1, 100_000).result).toBeErr(Cl.uint(424));
  });
});

describe("Vector 8: unauthorized spend", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("non-gov principal calling execute-transfer => u401, no state change", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();
    const r = simnet.callPublicFn(
      TREASURY,
      "execute-transfer",
      [Cl.principal(SBTC), Cl.principal(wallet4), Cl.uint(100_000)],
      wallet2,
    );
    expect(r.result).toBeErr(Cl.uint(401));
    expect(balance()).toBe(startBal);
  });
});

describe("Standalone deposit", () => {
  beforeEach(() => {
    wire();
    faucet(wallet2);
  });

  it("a standalone valid deposit succeeds", () => {
    expect(deposit(wallet2, 250_000).result).toBeOk(Cl.bool(true));
    expect(balance()).toBe(250_000n);
  });
});

describe("legion-fees route (8% protocol fee collector)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("skims 8% into the treasury and forwards the rest", () => {
    const toBefore = sbtcOf(wallet4);
    const r = route(wallet1, 1_000_000, wallet4);
    expect(r.result).toBeOk(Cl.uint(80_000)); // 8% fee
    expect(balance()).toBe(80_000n);
    expect(sbtcOf(wallet4) - toBefore).toBe(920_000n);
  });

  it("dust amount (fee rounds to zero) => u430", () => {
    expect(route(wallet1, 5, wallet4).result).toBeErr(Cl.uint(430));
  });

  it("routing the principal portion to the treasury itself => u431", () => {
    expect(route(wallet1, 1_000_000, treasuryPrincipal).result).toBeErr(Cl.uint(431));
  });

  it("wrong token rejected by treasury deposit => u412", () => {
    expect(route(wallet1, 1_000_000, wallet4).result).toBeOk(Cl.uint(80_000));
    const r = simnet.callPublicFn(
      FEES,
      "route",
      [Cl.principal(WRONG_TOKEN), Cl.uint(1_000_000), Cl.principal(wallet4)],
      wallet1,
    );
    expect(r.result).toBeErr(Cl.uint(412));
  });
});

describe("Vector 11: zero / eligibility edge cases", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("zero-amount deposit => u409", () => {
    expect(deposit(wallet1, 0).result).toBeErr(Cl.uint(409));
  });

  it("zero-stake voter voting => u401", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "z", wallet4, 1).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet3, 1, true).result).toBeErr(Cl.uint(401)); // wallet3 zero stake
  });

  it("propose with zero total staked => u410", () => {
    expect(propose(wallet1, "no-stake", wallet4, 1).result).toBeErr(Cl.uint(410));
  });

  it("a non-staker cannot propose => u401", () => {
    // wallet2 stakes so the snapshot is > 0, but wallet1 (proposer) does not.
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "freeloader", wallet4, 1).result).toBeErr(Cl.uint(401));
  });
});

describe("Self-targeting guard (u407)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("proposal targeting the treasury contract => u407", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "self", treasuryPrincipal, 1).result).toBeErr(Cl.uint(407));
  });

  it("proposal targeting the gov contract => u407", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "self2", govPrincipal, 1).result).toBeErr(Cl.uint(407));
  });
});

describe("No-proposal lookups", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("voting on a missing proposal => u404", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(vote(wallet1, 999, true).result).toBeErr(Cl.uint(404));
  });
});

describe("Zero-amount guards (defensive hardening)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("staking zero => u417 and does not change total staked", () => {
    expect(stake(wallet1, 0).result).toBeErr(Cl.uint(417));
    expect(simnet.callReadOnlyFn(GOV, "get-total-staked", [], deployer).result).toBeUint(0);
  });

  it("proposing a zero amount => u417", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "zero amount", wallet4, 0).result).toBeErr(Cl.uint(417));
  });
});

describe("Guard: empty proposal description (u418)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("propose with empty desc => u418", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "", wallet4, 1).result).toBeErr(Cl.uint(418));
  });

  it("propose with non-empty desc still succeeds", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "real desc", wallet4, 1).result).toBeOk(Cl.uint(1));
  });
});

describe("Guard: wiring gov/token to treasury-self (u410)", () => {
  it("set-gov to the treasury principal => u410", () => {
    expect(
      simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(treasuryPrincipal)], deployer).result,
    ).toBeErr(Cl.uint(410));
  });

  it("set-token to the treasury principal => u410", () => {
    expect(
      simnet.callPublicFn(TREASURY, "set-token", [Cl.principal(treasuryPrincipal)], deployer).result,
    ).toBeErr(Cl.uint(410));
  });
});

describe("Guard: wrong token rejected (u412)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
  });

  it("deposit with a WRONG token principal => u412", () => {
    const r = simnet.callPublicFn(
      TREASURY,
      "deposit",
      [Cl.principal(WRONG_TOKEN), Cl.uint(1_000_000)],
      wallet1,
    );
    expect(r.result).toBeErr(Cl.uint(412));
    expect(balance()).toBe(0n);
  });

  it("stake (via gov) with a WRONG token principal => u412", () => {
    const r = simnet.callPublicFn(
      GOV,
      "stake",
      [Cl.principal(WRONG_TOKEN), Cl.uint(1_000_000)],
      wallet1,
    );
    expect(r.result).toBeErr(Cl.uint(412));
    expect(simnet.callReadOnlyFn(GOV, "get-total-staked", [], deployer).result).toBeUint(0);
  });

  it("conclude (withdraw) with a WRONG token principal => u412, no transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true)); // proposer
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet3, 1_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();
    expect(propose(wallet1, "wrong-token", wallet4, 100_000).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, true).result).toBeOk(Cl.bool(true));
    enterExecWindow();
    // Concluding a PASSING proposal with the wrong token aborts at the treasury's
    // token assert (u412); the whole tx reverts, so nothing is concluded/transferred.
    const r = simnet.callPublicFn(
      GOV,
      "conclude-proposal",
      [Cl.uint(1), Cl.principal(WRONG_TOKEN)],
      wallet1,
    );
    expect(r.result).toBeErr(Cl.uint(412));
    expect(balance()).toBe(startBal);
  });
});

// ====================================================================
// First Light — the Legion ⇄ Inference loop, proven against the real
// contract bytecode.
//
// The bridge (spark/bridge.mjs) already did the COGNITION half live: it pulled
// a real on-chain snapshot, rented an open model through the inference
// marketplace, and committed the signal to a sha256 content-hash (written to
// spark/last-signal.json). Here we prove the two on-chain halves that close the
// loop:
//   (A) METABOLISM — paying for that cognition through legion-fees.route skims
//       8% straight into the Legion treasury. The collective taxes its own
//       thinking.
//   (B) VOICE — the AI signal, carried by its real content-hash, becomes an
//       on-chain proposal that governance passes and the treasury pays out.
// ====================================================================

// The real content-hash the model committed to in the live cognition run.
// Falls back to a fixed value if the bridge hasn't been run in this checkout.
function signalHash() {
  try {
    const j = JSON.parse(readFileSync("spark/last-signal.json", "utf8"));
    return Cl.bufferFromHex(String(j.contentHash).replace(/^0x/, ""));
  } catch {
    return Cl.bufferFromHex("f9c9299af677a57762291d4746a97c8eab6d3f8a49dd410cab0fb1ba81076b1e");
  }
}

describe("First Light: Legion <-> Inference", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet3);
  });

  it("(A) metabolism: settling an inference bill via legion-fees.route skims 8% to the treasury", () => {
    // The Legion agent settles an inference spend of 1,000,000 base units to the
    // provider (wallet5) through the fee rail. FEE_BPS = 800 (8%).
    const spend = 1_000_000;
    const expectedFee = Math.floor((spend * 800) / 10000); // 80_000
    const provider = wallet5;

    const treasuryBefore = balance();
    const providerBefore = sbtcOf(provider);

    expect(route(wallet1, spend, provider).result).toBeOk(Cl.uint(expectedFee));

    // 8% of the agent's own cognition spend flowed back into the treasury...
    expect(balance() - treasuryBefore).toBe(BigInt(expectedFee)); // +80_000
    // ...and the provider got the remaining 92%.
    expect(sbtcOf(provider) - providerBefore).toBe(BigInt(spend - expectedFee)); // +920_000
  });

  it("(B) voice: the AI signal's content-hash becomes a proposal that passes and pays its author", () => {
    // Three agents stake; wallet1 is the signal author/proposer.
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet3, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(balance()).toBe(3_000_000n);

    // Propose paying the signal's author, carrying the REAL sha256 content-hash
    // from the live inference run + the 2 disjoint live data feeds it rests on
    // (mempool.space fees + mempool endpoints), inscribed at the current tip.
    expect(
      propose(wallet1, "pay bitcoin-macro signal author", wallet4, 500_000, {
        hash: signalHash(),
        sources: 2,
      }).result,
    ).toBeOk(Cl.uint(1));

    // The same signal can't be filed twice — the Rail-A PaidHash registry
    // rejects the duplicate content-hash (u420).
    expect(
      propose(wallet2, "replay the same signal", wallet4, 100_000, {
        hash: signalHash(),
        sources: 2,
      }).result,
    ).toBeErr(Cl.uint(420));

    enterVotingWindow();
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet3, 1, true).result).toBeOk(Cl.bool(true));

    enterExecWindow();
    const authorBefore = sbtcOf(wallet4);
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(true));
    // Treasury paid the signal author the bounty.
    expect(balance()).toBe(2_500_000n);
    expect(sbtcOf(wallet4) - authorBefore).toBe(500_000n);
  });
});
