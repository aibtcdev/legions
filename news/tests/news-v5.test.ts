import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
//
// v4 timing counts BURN blocks (get-timing-mode == "PROD-BURN"), so every window
// is crossed with simnet.mineEmptyBurnBlocks(). In simnet a callPublicFn advances
// the STACKS height but NOT the burn height, so burn height moves only when we
// mine it explicitly -- which makes the windows exact.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voter1 = accounts.get("wallet_2")!;
const voter2 = accounts.get("wallet_3")!;
const voter3 = accounts.get("wallet_4")!;
const outsider = accounts.get("wallet_5")!;

const TREASURY = "news-treasury-v5";
const GOV = "news-gov-v5";
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via [[project.requirements]].
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// Must match news-gov-v5.clar (burn blocks).
const VOTING_DELAY = 2;
const VOTE_WINDOW = 30;
const VETO_WINDOW = 6;
const CONCLUDE_WINDOW = 12;
const MIN_WEIGHT = 10_000;

// Statuses.
const PASSED = 1n;
const FAILED = 2n;
const EXPIRED = 3n;

// Three equal contributors, so pool == total weight == 30,000,000.
//   draw = 0.05% (5 bp) of 30,000,000 = 15,000   (v5 raised the rate 5x from v4)
// The whole draw goes to the proposer; there is no per-signal split anymore.
const CONTRIB = 10_000_000;
const POOL = 3 * CONTRIB;
const DRAW = 15_000;

const LINK =
  "https://ordinals.com/inscription/86d089c6166f33ff82927ef30b6167261f94da5dff343e1da9e2a57bc7063809i0";
const TITLE = "sBTC peg holds through the week's volatility";
const DESCRIPTION =
  "Bundle of three market pieces inscribed to one ordinal. Verify at the link; " +
  "voters judge the work against ordinals.com before voting.";

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

function hasLive(who: string) {
  return simnet.callReadOnlyFn(GOV, "has-live-proposal", [Cl.principal(who)], deployer)
    .result;
}

/** Send sBTC to the pool and receive voting weight. The only way in. */
function contribute(who: string, amount = CONTRIB) {
  faucet(who);
  const r = simnet.callPublicFn(GOV, "contribute", [Cl.uint(amount)], who);
  return r.result;
}

function wire() {
  expect(
    simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
  ).toBeOk(Cl.bool(true));
}

function propose(
  who = proposer,
  link = LINK,
  title = TITLE,
  description = DESCRIPTION,
) {
  return simnet.callPublicFn(
    GOV,
    "propose-story",
    [Cl.stringAscii(link), Cl.stringAscii(title), Cl.stringAscii(description)],
    who,
  );
}

function vote(who: string, id: number, support: boolean) {
  return simnet.callPublicFn(GOV, "vote", [Cl.uint(id), Cl.bool(support)], who);
}

function veto(who: string, id: number) {
  return simnet.callPublicFn(GOV, "veto", [Cl.uint(id)], who);
}

function conclude(id: number, who = outsider) {
  return simnet.callPublicFn(GOV, "conclude", [Cl.uint(id)], who);
}

function storyStatus(id: number): bigint {
  const r = simnet.callReadOnlyFn(GOV, "get-story-status", [Cl.uint(id)], deployer);
  return (r.result as any).value.value as bigint;
}

function phase(id: number): string {
  return Cl.prettyPrint(
    simnet.callReadOnlyFn(GOV, "get-phase", [Cl.uint(id)], deployer).result as any,
  );
}

function liveProposal(id: string) {
  return simnet.callReadOnlyFn(GOV, "get-live-proposal", [Cl.principal(id)], deployer).result;
}

/** Propose -> voting opens: mine the pending (VOTING_DELAY) period. Votes are
 *  rejected ERR_VOTE_NOT_STARTED before this. The mineToXxx helpers below measure
 *  from voting-open, so every flow is: propose -> mineToVotingOpen -> ... */
function mineToVotingOpen() {
  simnet.mineEmptyBurnBlocks(VOTING_DELAY);
}

/** From voting-open: burn -> voteEnd. Voting closed, veto window open. */
function mineToVeto() {
  simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
}

/** From a fresh propose: burn -> vetoEnd. conclude now allowed. */
function mineToConcludable() {
  simnet.mineEmptyBurnBlocks(VOTE_WINDOW + VETO_WINDOW);
}

/** From a fresh propose: burn -> lapseAt. conclude now rejected; piece EXPIRED. */
function mineToLapsed() {
  simnet.mineEmptyBurnBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW);
}

/** Clear the 1-block global propose interval. */
function nextSlot() {
  simnet.mineEmptyBurnBlocks(1);
}

/** The standard three-contributor setup: pool == total weight == 30M. */
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

describe("propose-story: three fields, self-recipient, whole-weight lock", () => {
  beforeEach(() => {
    wire();
    contribute(proposer);
  });

  it("returns an auto-incrementing proposal id", () => {
    expect(propose().result).toBeOk(Cl.uint(1));
    const r = simnet.callReadOnlyFn(GOV, "get-last-proposal-id", [], deployer);
    expect((r.result as any).value).toBe(1n);
  });

  it("locks the proposer's ENTIRE weight while the piece is live", () => {
    expect(lockedOf(proposer)).toBe(0n); // nothing before
    expect(propose().result).toBeOk(Cl.uint(1));
    expect(lockedOf(proposer)).toBe(BigInt(CONTRIB)); // all of it
    expect(freeWeight(proposer)).toBe(0n); // none free
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB)); // held weight itself untouched
    expect(hasLive(proposer)).toBeBool(true);
  });

  it("requires a non-empty title and link, so the piece is legible", () => {
    expect(propose(proposer, LINK, "", DESCRIPTION).result).toBeErr(Cl.uint(433));
    expect(propose(proposer, "", TITLE, DESCRIPTION).result).toBeErr(Cl.uint(421));
  });

  it("records title, description and link for voters and the site to read", () => {
    expect(propose().result).toBeOk(Cl.uint(1));
    const dump = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "get-story-meta", [Cl.uint(1)], deployer).result as any,
    );
    expect(dump).toContain("ordinals.com/inscription");
    expect(dump).toContain("sBTC peg holds");
  });

  it("refuses a non-contributor / below the weight floor", () => {
    expect(propose(outsider).result).toBeErr(Cl.uint(401));
  });

  it("allows only ONE live proposal per principal", () => {
    expect(propose().result).toBeOk(Cl.uint(1));
    nextSlot(); // clear the global interval, so 434 (has-live) is the reason, not 432
    expect(propose().result).toBeErr(Cl.uint(434));
  });
});

describe("throttles: one global slot per block, concurrent across agents", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
  });

  it("refuses a second proposal from anyone in the same block", () => {
    expect(propose(voter1).result).toBeErr(Cl.uint(432));
  });

  it("lets a DIFFERENT agent propose once the 1-block interval elapses", () => {
    nextSlot();
    expect(propose(voter1).result).toBeOk(Cl.uint(2)); // #1 and #2 now both live
    expect(hasLive(proposer)).toBeBool(true);
    expect(hasLive(voter1)).toBeBool(true);
  });

  it("reports the next height at which a proposal is accepted", () => {
    const r = simnet.callReadOnlyFn(GOV, "get-next-propose-height", [], deployer);
    expect((r.result as any).value).toBeGreaterThan(0n);
  });
});

describe("voting", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
  });

  it("refuses the proposer voting on their own piece", () => {
    expect(vote(proposer, 1, true).result).toBeErr(Cl.uint(423));
  });

  it("refuses a second vote from the same principal", () => {
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter1, 1, false).result).toBeErr(Cl.uint(405)); // no changing a vote
  });

  it("refuses a voter below the weight floor", () => {
    faucet(outsider);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(100)], outsider);
    expect(vote(outsider, 1, true).result).toBeErr(Cl.uint(401));
  });

  it("refuses votes after the window closes", () => {
    mineToVeto();
    expect(vote(voter1, 1, true).result).toBeErr(Cl.uint(407));
  });

  it("refuses conclude before the veto window closes", () => {
    expect(conclude(1).result).toBeErr(Cl.uint(408));
    mineToVeto(); // in the veto window, still too early to conclude
    expect(conclude(1).result).toBeErr(Cl.uint(408));
  });

  it("records the vote so an agent can check before re-sending", () => {
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    const dump = Cl.prettyPrint(
      simnet.callReadOnlyFn(
        GOV,
        "get-vote-record",
        [Cl.uint(1), Cl.principal(voter1)],
        deployer,
      ).result as any,
    );
    expect(dump).toContain("support: true");
    expect(dump).toContain(`weight: u${CONTRIB}`);
  });
});

describe("pending period: voting opens only after VOTING_DELAY", () => {
  it("rejects a vote during pending (too early), accepts it once voting opens", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    expect(phase(1)).toContain("pending");
    // Voting has not opened yet: a vote is rejected as too early.
    expect(vote(voter1, 1, true).result).toBeErr(Cl.uint(436)); // ERR_VOTE_NOT_STARTED
    mineToVotingOpen();
    expect(phase(1)).toContain("voting");
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
  });
});

describe("the whole-weight lock does NOT silence a proposer elsewhere", () => {
  it("a proposer with a live piece still votes on other pieces at full weight", () => {
    fundedLegion();
    expect(propose(proposer).result).toBeOk(Cl.uint(1)); // proposer's own piece
    expect(freeWeight(proposer)).toBe(0n); // all weight locked
    nextSlot();
    expect(propose(voter1).result).toBeOk(Cl.uint(2)); // someone else's piece
    mineToVotingOpen();

    // Proposer votes on #2 with FULL held weight, despite their own #1 being live.
    expect(vote(proposer, 2, true).result).toBeOk(Cl.bool(true));
    const dump = Cl.prettyPrint(
      simnet.callReadOnlyFn(
        GOV,
        "get-vote-record",
        [Cl.uint(2), Cl.principal(proposer)],
        deployer,
      ).result as any,
    );
    expect(dump).toContain(`weight: u${CONTRIB}`); // not reduced by the lock

    // ...but still cannot vote on their own.
    expect(vote(proposer, 1, true).result).toBeErr(Cl.uint(423));
  });
});

describe("conclude: passed pays the proposer the whole draw", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, 1, true).result).toBeOk(Cl.bool(true));
    mineToConcludable();
  });

  it("pays the proposer exactly the 5 bp draw", () => {
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(sbtcOf(proposer)).toBe(before + BigInt(DRAW));
    expect(poolOf()).toBe(BigInt(POOL - DRAW));
  });

  it("leaves every voting weight untouched", () => {
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(totalWeight()).toBe(BigInt(POOL));
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
  });

  it("marks the payout ref as paid", () => {
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    const ref = simnet.callReadOnlyFn(
      GOV,
      "payout-ref",
      [Cl.uint(1), Cl.principal(proposer)],
      deployer,
    );
    const paid = simnet.callReadOnlyFn(TREASURY, "is-paid", [ref.result as any], deployer);
    expect(paid.result).toBeBool(true);
  });

  it("frees the proposer's lock and live slot, and is terminal", () => {
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(lockedOf(proposer)).toBe(0n);
    expect(hasLive(proposer)).toBeBool(false);
    expect(liveProposal(proposer)).toBeNone();
    expect(conclude(1).result).toBeErr(Cl.uint(410)); // already concluded
  });

  it("lets the proposer open a fresh piece afterward, no cooldown", () => {
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(propose().result).toBeOk(Cl.uint(2));
  });
});

describe("conclude: the ways a piece fails", () => {
  it("FAILS voted-down when yes falls under the 66% threshold", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true)); // 10M yes
    expect(vote(voter2, 1, false).result).toBeOk(Cl.bool(true)); // 10M no -> 50%
    mineToConcludable();
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(FAILED));
    expect(sbtcOf(proposer)).toBe(before); // paid nothing
    expect(lockedOf(proposer)).toBe(0n); // lock returned
    // No cooldown: the proposer may open a new piece immediately.
    expect(propose().result).toBeOk(Cl.uint(2));
  });

  it("FAILS no-quorum when nobody votes", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    mineToConcludable(); // nobody voted
    expect(conclude(1).result).toBeOk(Cl.uint(FAILED));
    expect(poolOf()).toBe(BigInt(POOL));
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
  });

  it("FAILS no-quorum on a lone voter: MIN_PARTICIPANTS is load-bearing", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true)); // one voter, 100% yes
    mineToConcludable();
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(FAILED)); // still fails: < 2 participants
    expect(sbtcOf(proposer)).toBe(before);
  });
});

describe("veto blocks a piece that would otherwise pass", () => {
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, 1, true).result).toBeOk(Cl.bool(true));
    mineToVeto(); // into the veto window
  });

  it("refuses a second veto from the same principal", () => {
    expect(veto(voter1, 1).result).toBeOk(Cl.bool(true));
    expect(veto(voter1, 1).result).toBeErr(Cl.uint(425));
  });

  it("blocks the piece when objections reach the veto quorum", () => {
    // voter1 holds 10M of a 20M eligible base = 50%, well past the 15% bar.
    expect(veto(voter1, 1).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VETO_WINDOW);
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(FAILED)); // vetoed
    expect(sbtcOf(proposer)).toBe(before);
    expect(poolOf()).toBe(BigInt(POOL));
    expect(lockedOf(proposer)).toBe(0n); // lock still returned
  });

  it("still pays out when objections fall short of the quorum", () => {
    // A small objector: 1M of ~21M eligible ~ 4.7%, under 15%.
    contribute(outsider, 1_000_000);
    expect(veto(outsider, 1).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VETO_WINDOW);
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(sbtcOf(proposer)).toBe(before + BigInt(DRAW));
  });
});

describe("veto timing", () => {
  it("refuses a veto while voting is still open", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    expect(veto(voter1, 1).result).toBeErr(Cl.uint(424)); // still in the vote window
  });
});

describe("the draw is snapshotted at propose, so a late conclude cannot inflate it", () => {
  it("pays what the voters were shown even if the pool has since grown", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1)); // draw fixed at 15,000 (0.05% of 30M)
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, 1, true).result).toBeOk(Cl.bool(true));
    mineToConcludable();

    // Someone triples the pool AFTER the vote. Reading the pool at conclude time
    // would pay ~3x what was approved; the snapshot prevents it.
    contribute(outsider, 60_000_000);
    expect(poolOf()).toBeGreaterThan(BigInt(POOL));

    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(sbtcOf(proposer)).toBe(before + BigInt(DRAW)); // still the snapshot
  });
});

describe("the conclude window is a hard deadline: past it, conclude is REJECTED", () => {
  // This is the v4 rule: once lapsed, a piece cannot be concluded at all. It
  // EXPIRES through the views on its own, and the lock has already freed itself.
  beforeEach(() => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, 1, true).result).toBeOk(Cl.bool(true));
  });

  it("pays a late conclude that is still inside the window", () => {
    // Cross into the conclude window, but not past it.
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW - 1);
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeOk(Cl.uint(PASSED));
    expect(sbtcOf(proposer)).toBe(before + BigInt(DRAW));
  });

  it("rejects conclude once the window has passed (ERR_CONCLUDE_WINDOW_PASSED)", () => {
    mineToLapsed();
    const before = sbtcOf(proposer);
    expect(conclude(1).result).toBeErr(Cl.uint(435));
    expect(sbtcOf(proposer)).toBe(before); // nobody paid
    expect(poolOf()).toBe(BigInt(POOL)); // no money moved
  });

  it("reports EXPIRED / not-concluded to every view once lapsed, with no tx", () => {
    mineToLapsed();
    expect(storyStatus(1)).toBe(EXPIRED);
    expect(phase(1)).toContain("expired");
    const story = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "get-story", [Cl.uint(1)], deployer).result as any,
    );
    expect(story).toContain("status: u3");
    expect(story).toContain('reason: "not-concluded"');
  });

  it("frees the lock by the clock and lets the proposer move on with no conclude", () => {
    mineToLapsed();
    expect(lockedOf(proposer)).toBe(0n); // freed by BondUnlockAt, not a tx
    expect(hasLive(proposer)).toBeBool(false);
    expect(liveProposal(proposer)).toBeNone();
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB)); // nothing burned
    expect(propose().result).toBeOk(Cl.uint(2)); // fresh piece, no conclude first
  });

  it("holds the lock until exactly the deadline, not a block before", () => {
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW + VETO_WINDOW + CONCLUDE_WINDOW - 1);
    expect(lockedOf(proposer)).toBe(BigInt(CONTRIB)); // still fully locked
  });
});

describe("regression: a stale lapsed piece cannot corrupt a newer one", () => {
  // The bug: conclude on a long-lapsed piece used to run the release path against
  // the proposer's CURRENT lock/slot, wiping a newer proposal's lock and breaking
  // the one-live invariant. v4 rejects conclude past the window, which removes it.
  it("keeps the one-live invariant when an old piece is concluded after re-proposing", () => {
    fundedLegion();
    // 1. P proposes X (#1) and nobody concludes it.
    expect(propose(proposer).result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    // 2. X lapses; its lock frees itself by the clock.
    mineToLapsed();
    expect(lockedOf(proposer)).toBe(0n);
    expect(liveProposal(proposer)).toBeNone();
    // 3. P proposes Y (#2). Now the lock and live slot belong to Y.
    expect(propose(proposer).result).toBeOk(Cl.uint(2));
    expect(lockedOf(proposer)).toBe(BigInt(CONTRIB));
    expect(liveProposal(proposer)).toBeSome(Cl.uint(2));
    // 4. The exploit attempt: conclude the stale X. It is REJECTED, so it can no
    //    longer touch Y's state.
    expect(conclude(1).result).toBeErr(Cl.uint(435));
    // 5. Y is intact and P still cannot open a third piece.
    expect(lockedOf(proposer)).toBe(BigInt(CONTRIB));
    expect(liveProposal(proposer)).toBeSome(Cl.uint(2));
    expect(hasLive(proposer)).toBeBool(true);
    nextSlot();
    expect(propose(proposer).result).toBeErr(Cl.uint(434)); // Y still live
  });
});

describe("sponsor-in: weight-less deposit funds the pool without a vote (v5)", () => {
  it("grows the pool but mints NO voting weight", () => {
    fundedLegion(); // pool 30M, total weight 30M
    faucet(outsider);
    const poolBefore = poolOf();
    const weightBefore = totalWeight();
    expect(
      simnet.callPublicFn(
        TREASURY,
        "sponsor-in",
        [Cl.uint(20_000_000), Cl.stringAscii("acme corp")],
        outsider,
      ).result,
    ).toBeOk(Cl.bool(true));
    expect(poolOf()).toBe(poolBefore + 20_000_000n); // pool grew
    expect(totalWeight()).toBe(weightBefore); // total weight unchanged
    expect(weightOf(outsider)).toBe(0n); // sponsor got zero governance power
  });

  it("is public: a non-contributor with zero weight can sponsor", () => {
    wire();
    faucet(outsider);
    expect(
      simnet.callPublicFn(
        TREASURY,
        "sponsor-in",
        [Cl.uint(1_000_000), Cl.stringAscii("x")],
        outsider,
      ).result,
    ).toBeOk(Cl.bool(true));
    expect(poolOf()).toBe(1_000_000n);
    expect(weightOf(outsider)).toBe(0n);
  });

  it("rejects a zero deposit", () => {
    wire();
    faucet(outsider);
    expect(
      simnet.callPublicFn(
        TREASURY,
        "sponsor-in",
        [Cl.uint(0), Cl.stringAscii("x")],
        outsider,
      ).result,
    ).toBeErr(Cl.uint(409));
  });

  it("makes the next proposal's draw bigger (0.05% of the larger pool)", () => {
    fundedLegion(); // pool 30M
    faucet(outsider);
    // sponsor 70M -> pool 100M -> draw = 0.05% of 100M = 50,000 (vs 15,000 without)
    simnet.callPublicFn(
      TREASURY,
      "sponsor-in",
      [Cl.uint(70_000_000), Cl.stringAscii("acme")],
      outsider,
    );
    expect(poolOf()).toBe(100_000_000n);
    expect(propose().result).toBeOk(Cl.uint(1));
    const story = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "get-story", [Cl.uint(1)], deployer).result as any,
    );
    expect(story).toContain("draw: u50000");
  });
});

describe("read surface: params, phase, propose-status", () => {
  it("exposes governance constants and the PROD-BURN timing mode", () => {
    wire();
    const params = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "get-params", [], deployer).result as any,
    );
    expect(params).toContain("votingQuorum: u15");
    expect(params).toContain("votingThreshold: u66");
    expect(params).toContain("vetoQuorum: u15");
    expect(params).toContain("drawBps: u5");
    expect(params).toContain("votingDelay: u2");
    expect(params).not.toContain("bondBps"); // no partial bond in v4
    const mode = simnet.callReadOnlyFn(GOV, "get-timing-mode", [], deployer);
    expect(mode.result).toBeAscii("PROD-BURN");
  });

  it("walks the lifecycle phase none -> pending -> voting -> veto -> concludable -> expired", () => {
    fundedLegion();
    expect(phase(1)).toContain("none"); // nothing proposed at id 1 yet
    expect(propose().result).toBeOk(Cl.uint(1));
    expect(phase(1)).toContain("pending"); // votes not accepted yet
    mineToVotingOpen();
    expect(phase(1)).toContain("voting");
    mineToVeto();
    expect(phase(1)).toContain("veto");
    simnet.mineEmptyBurnBlocks(VETO_WINDOW);
    expect(phase(1)).toContain("concludable");
    simnet.mineEmptyBurnBlocks(CONCLUDE_WINDOW);
    expect(phase(1)).toContain("expired");
  });

  it("folds every propose precondition into propose-status", () => {
    fundedLegion();
    const before = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "propose-status", [Cl.principal(proposer)], deployer)
        .result as any,
    );
    expect(before).toContain("canPropose: true");
    expect(before).toContain("noLiveProposal: true");
    expect(before).toContain(`lockOnPropose: u${CONTRIB}`);

    expect(propose().result).toBeOk(Cl.uint(1));
    const after = Cl.prettyPrint(
      simnet.callReadOnlyFn(GOV, "propose-status", [Cl.principal(proposer)], deployer)
        .result as any,
    );
    expect(after).toContain("canPropose: false"); // now has a live piece
    expect(after).toContain("noLiveProposal: false");
  });
});
