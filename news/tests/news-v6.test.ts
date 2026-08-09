import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
//
// v6 timing counts BURN blocks (get-timing-mode == "PROD-BURN"), so every window
// is crossed with simnet.mineEmptyBurnBlocks(). In simnet a callPublicFn advances
// the STACKS height but NOT the burn height, so burn height moves only when we
// mine it explicitly -- which makes the windows exact.
//
// That split matters more in v6 than it did in v5: the vote-weight snapshot is a
// STACKS height (one block behind the propose transaction) while every window is
// a BURN height. Two clocks, deliberately. Each callPublicFn is its own stacks
// block, so "the block before propose" is exactly "the state after the previous
// transaction".
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voter1 = accounts.get("wallet_2")!;
const voter2 = accounts.get("wallet_3")!;
const latecomer = accounts.get("wallet_4")!;
const outsider = accounts.get("wallet_5")!;

const TREASURY = "news-treasury-v6";
const GOV = "news-gov-v6";
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via [[project.requirements]].
const SBTC = "ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW.sbtc-token";

// Must match news-gov-v6.clar (burn blocks). No VETO_WINDOW in v6.
const VOTING_DELAY = 2;
const VOTE_WINDOW = 30;
const CONCLUDE_WINDOW = 12;
const MIN_WEIGHT = 10_000;
const MIN_CONTRIBUTION = 10_000;
// 144 burn blocks a day / 18 = the 8-pieces-a-day mainnet ceiling.
const PROPOSE_INTERVAL = 18;
const PER_DAY = 144 / PROPOSE_INTERVAL;

// Statuses.
const PASSED = 1n;
const FAILED = 2n;
const EXPIRED = 3n;

// Errors that are new or re-purposed in v6.
const ERR_SELF_VOTE = 423n;
const ERR_EMPTY_RATIONALE = 440n;

// Three equal contributors, so pool == total weight == 30,000,000.
//   draw = 0.05% (5 bp) of 30,000,000 = 15,000
const CONTRIB = 10_000_000;
const POOL = 3 * CONTRIB;
const DRAW = 15_000;

const LINK =
  "https://ordinals.com/inscription/86d089c6166f33ff82927ef30b6167261f94da5dff343e1da9e2a57bc7063809i0";
const TITLE = "sBTC peg holds through the week's volatility";
const DESCRIPTION =
  "Bundle of three market pieces inscribed to one ordinal. Verify at the link; " +
  "voters judge the work against ordinals.com before voting.";
const WHY_YES =
  "Opened the inscription, cross-checked the peg figures against the treasury " +
  "contract, and the numbers hold. Worth paying for.";
const WHY_NO = "Link resolves to an inscription we already paid for last week.";

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

// Clarity values are read the way the rest of this suite reads them: pretty-
// printed and matched as text, rather than walking version-specific CV internals.
function dump(fn: string, args: any[] = []): string {
  return Cl.prettyPrint(
    simnet.callReadOnlyFn(GOV, fn, args, deployer).result as any,
  );
}

/** Pull one `field: uN` out of a pretty-printed tuple. */
function num(text: string, field: string): bigint {
  const m = text.match(new RegExp(`${field}: u(\\d+)`));
  if (!m) throw new Error(`no uint field "${field}" in: ${text}`);
  return BigInt(m[1]);
}

function storyDump(id: number): string {
  return dump("get-story", [Cl.uint(id)]);
}

function storyField(id: number, field: string): bigint {
  return num(storyDump(id), field);
}

function voteDump(id: number, who: string): string {
  return dump("get-vote-record", [Cl.uint(id), Cl.principal(who)]);
}

function votePowerDump(id: number, who: string): string {
  return dump("vote-power", [Cl.uint(id), Cl.principal(who)]);
}

function contribute(who: string, amount = CONTRIB) {
  faucet(who);
  return simnet.callPublicFn(GOV, "contribute", [Cl.uint(amount)], who).result;
}

function wire() {
  expect(
    simnet.callPublicFn(TREASURY, "set-gov", [Cl.principal(govPrincipal)], deployer).result,
  ).toBeOk(Cl.bool(true));
}

function propose(who = proposer, link = LINK, title = TITLE, description = DESCRIPTION) {
  return simnet.callPublicFn(
    GOV,
    "propose-story",
    [Cl.stringAscii(link), Cl.stringAscii(title), Cl.stringAscii(description)],
    who,
  );
}

function vote(who: string, id: number, support: boolean, why = support ? WHY_YES : WHY_NO) {
  return simnet.callPublicFn(
    GOV,
    "vote",
    [Cl.uint(id), Cl.bool(support), Cl.stringAscii(why)],
    who,
  );
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

function mineToVotingOpen() {
  simnet.mineEmptyBurnBlocks(VOTING_DELAY);
}

/** From a fresh propose: burn -> voteEnd. In v6 conclude is allowed from here,
 *  with no veto window in between. */
function mineToConcludable() {
  simnet.mineEmptyBurnBlocks(VOTING_DELAY + VOTE_WINDOW);
}

/** From a fresh propose: burn -> lapseAt. conclude now rejected; piece EXPIRED. */
function mineToLapsed() {
  simnet.mineEmptyBurnBlocks(VOTING_DELAY + VOTE_WINDOW + CONCLUDE_WINDOW);
}

/** Clear the global propose interval, whatever it is set to. */
function nextSlot() {
  simnet.mineEmptyBurnBlocks(PROPOSE_INTERVAL);
}

/** The standard three-contributor setup: pool == total weight == 30M. */
function fundedLegion() {
  wire();
  contribute(proposer);
  contribute(voter1);
  contribute(voter2);
}

// ---- tests ---------------------------------------------------------

describe("v6 parameters", () => {
  it("exposes the settled v6 constants and no veto dial at all", () => {
    const p = dump("get-params");
    expect(num(p, "votingQuorum")).toBe(10n);
    expect(num(p, "votingThreshold")).toBe(66n);
    expect(num(p, "minParticipants")).toBe(1n);
    expect(num(p, "minWeight")).toBe(BigInt(MIN_WEIGHT));
    expect(num(p, "minContribution")).toBe(BigInt(MIN_CONTRIBUTION));
    expect(num(p, "drawBps")).toBe(5n);
    expect(num(p, "concludeWindow")).toBe(BigInt(CONCLUDE_WINDOW));
    expect(num(p, "proposeInterval")).toBe(BigInt(PROPOSE_INTERVAL));
    // The veto is gone, so neither of its constants may be reported.
    expect(p).not.toContain("vetoQuorum");
    expect(p).not.toContain("vetoWindow");
  });

  it("caps the legion at 8 pieces a day: 144 burn blocks / 18", () => {
    expect(PER_DAY).toBe(8);
  });

  it("has no veto entry point at all", () => {
    fundedLegion();
    propose();
    mineToVotingOpen();
    // Not "rejected" -- absent. The function does not exist to be called.
    expect(() =>
      simnet.callPublicFn(GOV, "veto", [Cl.uint(1)], voter1),
    ).toThrow();
  });

  it("runs a 44-block lifecycle with no veto phase", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    expect(phase(1)).toBe('"pending"');
    mineToVotingOpen();
    expect(phase(1)).toBe('"voting"');
    // In v5 this landed in "veto". In v6 the vote closing makes it concludable.
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(phase(1)).toBe('"concludable"');
    simnet.mineEmptyBurnBlocks(CONCLUDE_WINDOW);
    expect(phase(1)).toBe('"expired"');
  });
});

describe("the global propose interval is the drain ceiling", () => {
  function nextProposeHeight(): bigint {
    return BigInt(dump("get-next-propose-height").replace("u", ""));
  }

  it("refuses a second piece from anyone inside the interval", () => {
    fundedLegion();
    expect(propose(proposer).result).toBeOk(Cl.uint(1));
    // A DIFFERENT principal, so the one-live-proposal rule is not what bites.
    expect(propose(voter1).result).toBeErr(Cl.uint(432));
  });

  it("opens the slot exactly at get-next-propose-height, not a block sooner", () => {
    fundedLegion();
    expect(propose(proposer).result).toBeOk(Cl.uint(1));
    simnet.mineEmptyBurnBlocks(PROPOSE_INTERVAL - 1);
    expect(propose(voter1).result).toBeErr(Cl.uint(432));
    simnet.mineEmptyBurnBlocks(1);
    expect(propose(voter1).result).toBeOk(Cl.uint(2));
  });

  it("does not consume the slot on a lost race", () => {
    fundedLegion();
    expect(propose(proposer).result).toBeOk(Cl.uint(1));
    const before = nextProposeHeight();
    // Two agents race and lose; the winner's slot time must not move.
    expect(propose(voter1).result).toBeErr(Cl.uint(432));
    expect(propose(voter2).result).toBeErr(Cl.uint(432));
    expect(nextProposeHeight()).toBe(before);
  });

  it("holds at most three pieces open at once, given a 44-block lifecycle", () => {
    fundedLegion();
    contribute(latecomer);
    expect(propose(proposer).result).toBeOk(Cl.uint(1));
    nextSlot();
    expect(propose(voter1).result).toBeOk(Cl.uint(2));
    nextSlot();
    expect(propose(voter2).result).toBeOk(Cl.uint(3));
    // t=36 since the first piece opened; it lapses at t=44, so all three are live.
    expect(phase(1)).toBe('"concludable"');
    expect(phase(2)).toBe('"voting"');
    expect(phase(3)).toBe('"pending"');
    // The fourth slot opens at t=54, by which time the first has expired.
    nextSlot();
    expect(propose(latecomer).result).toBeOk(Cl.uint(4));
    expect(phase(1)).toBe('"expired"');
  });
});

describe("the verification rule: one other agent must vote yes", () => {
  it("pays when exactly one other agent verifies it", () => {
    fundedLegion();
    const before = sbtcOf(proposer);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(PASSED)));
    expect(storyStatus(1)).toBe(PASSED);
    expect(sbtcOf(proposer)).toBe(before + BigInt(DRAW));
    expect(poolOf()).toBe(BigInt(POOL - DRAW));
  });

  it("pays nobody on silence: unverified news is not paid", () => {
    fundedLegion();
    const before = sbtcOf(proposer);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToConcludable();
    expect(conclude(1).result).toBeOk(Cl.uint(Number(FAILED)));
    expect(storyStatus(1)).toBe(FAILED);
    expect(sbtcOf(proposer)).toBe(before);
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("pays nobody when the one agent who showed up voted no", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, false).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(FAILED)));
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("fails a contested piece: one yes against one equal no is 50%, under the 66% bar", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, 1, false).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(FAILED)));
    expect(poolOf()).toBe(BigInt(POOL));
  });

  it("still bars the proposer from verifying their own piece", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(proposer, 1, true).result).toBeErr(Cl.uint(Number(ERR_SELF_VOTE)));
  });
});

describe("vote weight is live, deliberately", () => {
  it("lets an agent who joins mid-vote vote on the piece that is already open", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    // Reads the piece, wants in, joins. They can act on the thing that
    // motivated them rather than sitting out until the next cycle.
    expect(contribute(latecomer)).toBeOk(Cl.uint(CONTRIB));
    mineToVotingOpen();
    expect(vote(latecomer, 1, true).result).toBeOk(Cl.bool(true));
    expect(voteDump(1, latecomer)).toContain(`weight: u${CONTRIB}`);
  });

  it("counts an existing member's topped-up weight at its current value", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    faucet(voter1, 3);
    simnet.callPublicFn(GOV, "contribute", [Cl.uint(3 * CONTRIB)], voter1);
    const topped = weightOf(voter1);
    expect(topped).toBeGreaterThan(BigInt(CONTRIB));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(storyField(1, "yesWeight")).toBe(topped);
  });

  it("excludes the proposer from the eligible denominator", () => {
    wire();
    contribute(voter1);
    contribute(voter2);
    expect(contribute(proposer)).toBeOk(Cl.uint(CONTRIB));
    expect(propose().result).toBeOk(Cl.uint(1));
    expect(storyField(1, "eligibleSnapshot")).toBe(BigInt(2 * CONTRIB));
  });

  it("can cast MORE than the eligible denominator once late capital votes", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    // eligible was frozen at propose (30M total - 10M proposer = 20M), but the
    // latecomer's 10M is live and countable, so cast reaches 30M.
    expect(storyField(1, "eligibleSnapshot")).toBe(BigInt(2 * CONTRIB));
    expect(contribute(latecomer)).toBeOk(Cl.uint(CONTRIB));
    mineToVotingOpen();
    vote(voter1, 1, true);
    vote(voter2, 1, true);
    vote(latecomer, 1, true);
    const cast = storyField(1, "yesWeight") + storyField(1, "noWeight");
    // ACCEPTED CONSEQUENCE of live weight, not a bug: participation can read
    // over 100%, so quorum is easier to clear than the denominator suggests.
    // Passing still needs 66% of cast, which is what actually gates the payout.
    expect(cast).toBeGreaterThan(storyField(1, "eligibleSnapshot"));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(PASSED)));
  });

  it("reports vote-power so an agent can check before spending gas", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    const v1 = votePowerDump(1, voter1);
    expect(v1).toContain(`weight: u${CONTRIB}`);
    expect(v1).toContain("meetsFloor: true");
    expect(v1).toContain("isProposer: false");
    expect(votePowerDump(1, proposer)).toContain("isProposer: true");
    expect(votePowerDump(1, outsider)).toContain("meetsFloor: false");
    expect(votePowerDump(99, voter1)).toBe("none");
  });

  it("lets a floor-sized joiner act immediately: no dead tier", () => {
    wire();
    contribute(voter1);
    contribute(voter2);
    // MIN_CONTRIBUTION is set equal to MIN_WEIGHT precisely so this holds.
    faucet(latecomer);
    expect(
      simnet.callPublicFn(GOV, "contribute", [Cl.uint(MIN_CONTRIBUTION)], latecomer).result,
    ).toBeOk(Cl.uint(MIN_CONTRIBUTION));
    contribute(proposer);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(latecomer, 1, true).result).toBeOk(Cl.bool(true));
  });
});

describe("votes carry an on-chain reason", () => {
  it("stores the rationale beside the vote", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    const rec = voteDump(1, voter1);
    expect(rec).toContain(`rationale: "${WHY_YES}"`);
    expect(rec).toContain("support: true");
  });

  it("keeps the reason for a no vote too", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, false).result).toBeOk(Cl.bool(true));
    expect(voteDump(1, voter1)).toContain(`rationale: "${WHY_NO}"`);
  });

  it("refuses an empty rationale", () => {
    fundedLegion();
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true, "").result).toBeErr(
      Cl.uint(Number(ERR_EMPTY_RATIONALE)),
    );
    // And the tally is untouched.
    expect(storyField(1, "yesWeight")).toBe(0n);
    expect(storyField(1, "voterCount")).toBe(0n);
  });

  it("emits the rationale in the vote event for indexers", () => {
    fundedLegion();
    propose();
    mineToVotingOpen();
    const r = simnet.callPublicFn(
      GOV,
      "vote",
      [Cl.uint(1), Cl.bool(true), Cl.stringAscii(WHY_YES)],
      voter1,
    );
    const printed = r.events.find((e) => e.event === "print_event");
    expect(Cl.prettyPrint(printed!.data.value as any)).toContain(WHY_YES);
  });
});

describe("conclude timing without a veto window", () => {
  it("rejects conclude while the vote is still open", () => {
    fundedLegion();
    propose();
    mineToVotingOpen();
    vote(voter1, 1, true);
    expect(conclude(1).result).toBeErr(Cl.uint(408));
  });

  it("allows conclude the moment the vote closes, with no veto wait", () => {
    fundedLegion();
    propose();
    mineToVotingOpen();
    vote(voter1, 1, true);
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(PASSED)));
  });

  it("expires a piece nobody concluded, and frees the proposer's slot", () => {
    fundedLegion();
    propose();
    mineToVotingOpen();
    vote(voter1, 1, true);
    mineToLapsed();
    expect(storyStatus(1)).toBe(EXPIRED);
    expect(conclude(1).result).toBeErr(Cl.uint(435));
    // The bond freed itself, so the proposer can publish again.
    nextSlot();
    expect(propose().result).toBeOk(Cl.uint(2));
  });
});
