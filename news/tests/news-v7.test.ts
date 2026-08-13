import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

// `simnet` is injected globally by vitest-environment-clarinet.
//
// v7 = v6 + a membership floor on proposing (MIN_MEMBERS 21) and VOTING_QUORUM
// 10 -> 5. Everything else is v6 and is already covered by news-v6.test.ts, so
// this suite exercises the floor, the counter behind it, and the quorum
// arithmetic the floor forces. Timing still counts BURN blocks
// (get-timing-mode == "PROD-BURN"), so windows are crossed with
// simnet.mineEmptyBurnBlocks().
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const outsider = accounts.get("wallet_5")!;

const TREASURY = "news-treasury-v7";
const GOV = "news-gov-v7";
const govPrincipal = `${deployer}.${GOV}`;

// The REAL testnet sBTC token, pulled into simnet via [[project.requirements]].
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

// Must match news-gov-v7.clar (burn blocks).
const VOTING_DELAY = 2;
const VOTE_WINDOW = 30;
const CONCLUDE_WINDOW = 12;
const MIN_WEIGHT = 10_000;
const MIN_CONTRIBUTION = 10_000;
const PROPOSE_INTERVAL = 18;
const MIN_MEMBERS = 21;
const VOTING_QUORUM = 5;

// Statuses.
const PASSED = 1n;
const FAILED = 2n;

// Errors.
const ERR_INELIGIBLE = 401n;
const ERR_BELOW_MIN_CONTRIBUTION = 437n;
const ERR_TOO_FEW_MEMBERS = 441n;

// Every member contributes the same, so weight is uniform and the quorum
// arithmetic below is exact rather than approximate.
//   21 members -> pool 210,000,000, draw = 0.05% (5 bp) = 105,000
const CONTRIB = 10_000_000;
const POOL_AT_21 = MIN_MEMBERS * CONTRIB;
const DRAW_AT_21 = (POOL_AT_21 * 5) / 10_000;

// 25 deterministic testnet principals. simnet accepts any valid c32 address as a
// sender, so the 21-member floor needs no Devnet.toml accounts: these are funded
// straight from the sBTC faucet. Generated with c32address(26, ...) over
// "member<n>"; they are addresses and nothing else, no keys exist for them.
const MEMBERS = [
  "ST1PPAVB2CNS320000000000000000000020V27PS",
  "ST1PPAVB2CNS34000000000000000000000QA59M1",
  "ST1PPAVB2CNS36000000000000000000001S0CA39",
  "ST1PPAVB2CNS38000000000000000000002TQP2NZ",
  "ST1PPAVB2CNS3A000000000000000000000DYBFW3",
  "ST1PPAVB2CNS3C0000000000000000000003M4B5M",
  "ST1PPAVB2CNS3E000000000000000000003C3TDVV",
  "ST1PPAVB2CNS3G000000000000000000001XFYFFV",
  "ST1PPAVB2CNS3J000000000000000000003DFHDES",
  "ST1PPAVB2CNS32C00000000000000000000QNQ671",
  "ST1PPAVB2CNS32C80000000000000000000P29J74",
  "ST1PPAVB2CNS32CG0000000000000000001TV3879",
  "ST1PPAVB2CNS32CR0000000000000000001XT8QNN",
  "ST1PPAVB2CNS32D00000000000000000001V5PR5S",
  "ST1PPAVB2CNS32D80000000000000000003TZFTZ6",
  "ST1PPAVB2CNS32DG0000000000000000002FVRG74",
  "ST1PPAVB2CNS32DR00000000000000000030AFT5Z",
  "ST1PPAVB2CNS32E00000000000000000003V2X4H4",
  "ST1PPAVB2CNS32E80000000000000000001EZRMTZ",
  "ST1PPAVB2CNS34C00000000000000000003KKD0T4",
  "ST1PPAVB2CNS34C80000000000000000003TZ41DR",
  "ST1PPAVB2CNS34CG0000000000000000002XXW0PS",
  "ST1PPAVB2CNS34CR00000000000000000006FJNPV",
  "ST1PPAVB2CNS34D000000000000000000036Q3KZT",
  "ST1PPAVB2CNS34D800000000000000000001DDRZ2",
];

const proposer = MEMBERS[0];
const voter1 = MEMBERS[1];
const voter2 = MEMBERS[2];
/** Holds no weight in any legion built below. */
const stranger = MEMBERS[24];

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

function faucet(who: string) {
  expect(simnet.callPublicFn(SBTC, "faucet", [], who).result).toBeOk(Cl.bool(true));
}

function sbtcOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return (r.result as any).value.value as bigint;
}

function poolOf(): bigint {
  return (simnet.callReadOnlyFn(TREASURY, "get-balance", [], deployer).result as any)
    .value as bigint;
}

function dump(fn: string, args: any[] = []): string {
  return Cl.prettyPrint(simnet.callReadOnlyFn(GOV, fn, args, deployer).result as any);
}

/** Pull one `field: uN` out of a pretty-printed tuple. */
function num(text: string, field: string): bigint {
  const m = text.match(new RegExp(`${field}: u(\\d+)`));
  if (!m) throw new Error(`no uint field "${field}" in: ${text}`);
  return BigInt(m[1]);
}

function memberCount(): bigint {
  return BigInt(dump("get-member-count").replace("u", ""));
}

function membersMet(): boolean {
  return dump("members-met") === "true";
}

function weightOf(who: string): bigint {
  return BigInt(dump("get-weight", [Cl.principal(who)]).replace("u", ""));
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

function storyReason(id: number): string {
  const m = dump("get-story", [Cl.uint(id)]).match(/reason: "([^"]*)"/);
  return m ? m[1] : "";
}

function mineToVotingOpen() {
  simnet.mineEmptyBurnBlocks(VOTING_DELAY);
}

function mineToConcludable() {
  simnet.mineEmptyBurnBlocks(VOTING_DELAY + VOTE_WINDOW);
}

/** Wire the treasury and seat `n` equal-weight members. */
function legionOf(n: number) {
  wire();
  for (let i = 0; i < n; i++) {
    expect(contribute(MEMBERS[i])).toBeOk(Cl.uint(CONTRIB));
  }
}

// ---- tests ---------------------------------------------------------

describe("v7 parameters", () => {
  it("publishes the membership floor and the quorum that goes with it", () => {
    const p = dump("get-params");
    expect(num(p, "minMembers")).toBe(BigInt(MIN_MEMBERS));
    expect(num(p, "votingQuorum")).toBe(BigInt(VOTING_QUORUM));
    // Everything else is v6's, unchanged.
    expect(num(p, "votingThreshold")).toBe(66n);
    expect(num(p, "minParticipants")).toBe(1n);
    expect(num(p, "minWeight")).toBe(BigInt(MIN_WEIGHT));
    expect(num(p, "minContribution")).toBe(BigInt(MIN_CONTRIBUTION));
    expect(num(p, "drawBps")).toBe(5n);
    expect(num(p, "proposeInterval")).toBe(BigInt(PROPOSE_INTERVAL));
  });

  it("starts with no members", () => {
    expect(memberCount()).toBe(0n);
    expect(membersMet()).toBe(false);
  });
});

describe("membership accounting", () => {
  it("counts a principal once, on the contribution that gives it weight", () => {
    wire();
    expect(memberCount()).toBe(0n);
    contribute(proposer);
    expect(memberCount()).toBe(1n);
    expect(weightOf(proposer)).toBe(BigInt(CONTRIB));
  });

  it("does not count the same principal twice however often it tops up", () => {
    wire();
    contribute(proposer);
    contribute(proposer);
    contribute(proposer);
    expect(memberCount()).toBe(1n);
    expect(weightOf(proposer)).toBe(BigInt(3 * CONTRIB));
  });

  it("counts each distinct contributor exactly once", () => {
    legionOf(MIN_MEMBERS);
    expect(memberCount()).toBe(BigInt(MIN_MEMBERS));
    expect(BigInt(poolOf())).toBe(BigInt(POOL_AT_21));
  });

  it("rejects a sub-floor contribution and seats nobody for it", () => {
    wire();
    faucet(proposer);
    expect(
      simnet.callPublicFn(GOV, "contribute", [Cl.uint(MIN_CONTRIBUTION - 1)], proposer)
        .result,
    ).toBeErr(Cl.uint(ERR_BELOW_MIN_CONTRIBUTION));
    expect(memberCount()).toBe(0n);
  });

  it("flips members-met on the 21st member and not before", () => {
    legionOf(MIN_MEMBERS - 1);
    expect(memberCount()).toBe(20n);
    expect(membersMet()).toBe(false);
    contribute(MEMBERS[MIN_MEMBERS - 1]);
    expect(memberCount()).toBe(21n);
    expect(membersMet()).toBe(true);
  });
});

describe("the 21-member floor on proposing", () => {
  it("refuses a story at 20 members", () => {
    legionOf(MIN_MEMBERS - 1);
    expect(propose().result).toBeErr(Cl.uint(ERR_TOO_FEW_MEMBERS));
  });

  it("accepts the first story at exactly 21", () => {
    legionOf(MIN_MEMBERS);
    expect(propose().result).toBeOk(Cl.uint(1));
  });

  it("says why through propose-status before the floor is met", () => {
    legionOf(MIN_MEMBERS - 1);
    const s = dump("propose-status", [Cl.principal(proposer)]);
    expect(s).toContain("membersOk: false");
    expect(s).toContain("canPropose: false");
    expect(num(s, "memberCount")).toBe(20n);
    expect(num(s, "minMembers")).toBe(BigInt(MIN_MEMBERS));
    // The floor is the ONLY thing blocking this proposer.
    expect(s).toContain("eligible: true");
    expect(s).toContain("slotOpen: true");
    expect(s).toContain("noLiveProposal: true");
    expect(s).toContain("poolOk: true");
  });

  it("clears propose-status once the floor is met", () => {
    legionOf(MIN_MEMBERS);
    const s = dump("propose-status", [Cl.principal(proposer)]);
    expect(s).toContain("membersOk: true");
    expect(s).toContain("canPropose: true");
    expect(num(s, "memberCount")).toBe(BigInt(MIN_MEMBERS));
  });

  it("still checks the proposer's own weight first", () => {
    legionOf(MIN_MEMBERS);
    // A full legion, but this principal holds nothing: ineligible, not too-few.
    expect(propose(stranger).result).toBeErr(Cl.uint(ERR_INELIGIBLE));
  });
});

describe("quorum 5 keeps one reader enough at 21 members", () => {
  it("pays on a single yes vote", () => {
    legionOf(MIN_MEMBERS);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));

    const paidBefore = sbtcOf(proposer);
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(PASSED)));

    expect(storyStatus(1)).toBe(PASSED);
    expect(storyReason(1)).toBe("paid");
    expect(sbtcOf(proposer) - paidBefore).toBe(BigInt(DRAW_AT_21));
    expect(BigInt(poolOf())).toBe(BigInt(POOL_AT_21 - DRAW_AT_21));
  });

  it("is exactly at the line: one vote is 5% of the 20 eligible shares", () => {
    legionOf(MIN_MEMBERS);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));

    const story = dump("get-story", [Cl.uint(1)]);
    const eligible = num(story, "eligibleSnapshot");
    const cast = num(story, "yesWeight") + num(story, "noWeight");
    // The proposer's own weight is excluded from the denominator.
    expect(eligible).toBe(BigInt(POOL_AT_21 - CONTRIB));
    expect((cast * 100n) / eligible).toBe(BigInt(VOTING_QUORUM));
  });

  it("still pays nobody on silence", () => {
    legionOf(MIN_MEMBERS);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToConcludable();
    expect(conclude(1).result).toBeOk(Cl.uint(Number(FAILED)));
    expect(storyStatus(1)).toBe(FAILED);
    expect(storyReason(1)).toBe("no-quorum");
    expect(BigInt(poolOf())).toBe(BigInt(POOL_AT_21));
  });

  it("clears quorum but fails the threshold on a lone no vote", () => {
    legionOf(MIN_MEMBERS);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, false).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(FAILED)));
    expect(storyReason(1)).toBe("voted-down");
    expect(BigInt(poolOf())).toBe(BigInt(POOL_AT_21));
  });
});

describe("quorum 5 is exact at 21 and degrades as the legion grows", () => {
  // KNOWN BOUNDARY, documented rather than fixed: MIN_MEMBERS is a floor, not a
  // cap. At 21 equal members one vote is exactly 5% of eligible. At 22 it is
  // 4.76%, which integer division floors to 4, so a single reader is no longer
  // enough and two are required. If the legion is expected to grow past 21,
  // VOTING_QUORUM has to come down again or be made to scale.
  it("needs two readers once a 22nd member joins", () => {
    legionOf(MIN_MEMBERS + 1);
    expect(memberCount()).toBe(22n);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(FAILED)));
    expect(storyReason(1)).toBe("no-quorum");
  });

  it("pays at 22 members when a second reader votes", () => {
    legionOf(MIN_MEMBERS + 1);
    expect(propose().result).toBeOk(Cl.uint(1));
    mineToVotingOpen();
    expect(vote(voter1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(voter2, 1, true).result).toBeOk(Cl.bool(true));
    simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
    expect(conclude(1).result).toBeOk(Cl.uint(Number(PASSED)));
    expect(storyReason(1)).toBe("paid");
  });
});
