// Two legions arguing opposite sides of one live prediction market.
//
// These run against the REAL market contract, vendored from the stacksbet repo
// as its own simnet build: pox-5 swapped for pox5-sim, which is pox-5 published
// under an address the tests hold bond-admin on, and the deadline moved inside
// that bond period. Nothing about the market is mocked, and the legions under
// test differ from the mainnet artifacts by exactly one substituted principal.
//
// What has to be proven here is everything that is NOT the news legion:
//
//   - weight is not a ledger. It is the caller's own position, read live off
//     the market, so it moves when they trade and cannot be locked.
//   - the only outward path is an approved proposal. There is no withdraw.
//   - a payout is a share transfer while the market trades, and becomes a
//     credit the moment it stops, so a stranger settling the market mid-vote
//     cannot strand a proposal that passed.
//   - arguing the losing side pays nothing, by construction.
import { describe, expect, it, beforeAll } from "vitest";
import { Cl } from "@stacks/transactions";
import { registerSigner, setupBond } from "./helpers/pox5.js";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;
const dave = accounts.get("wallet_4")!;
const whale = accounts.get("wallet_5")!;
const stranger = accounts.get("wallet_6")!;
// Two holders parked exactly on the floor, for the gates that are about weight
// being present but insufficient.
const minnowA = accounts.get("wallet_7")!;
const minnowB = accounts.get("wallet_8")!;

const MARKET = "elsalvador-stakes-btc-sim";
const YES = "yes-legion-sim";
const NO = "no-legion-sim";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";

const yesLegion = `${deployer}.${YES}`;
const noLegion = `${deployer}.${NO}`;

// Must match yes-legion.clar. Burn blocks; the sim build does not shrink them.
const VOTE_DELAY = 2;
const VOTE_WINDOW = 30;
const CONCLUDE_WINDOW = 12;
const GLOBAL_PROPOSE_INTERVAL = 6;
const MIN_POSITION = 1_000;
const PAYOUT = 3_000;
const MIN_VOTERS = 2;      // counted on the YES side only
const PROPOSER_COOLDOWN = 144;

const SIDE_IDLE = 0;
const SIDE_BONDED = 1;

const PASSED = 1n;
const FAILED = 2n;

// Market statuses.
const STATUS_BONDED = 1;

const LINK = "https://ordinals.com/inscription/deadbeefi0";
const TITLE = "Reserve wallet 3Fh6 moved 400 BTC to a pox-5 lockup script";
const DESC = "Traced the outpoint, matched the witness script pox-5 builds, wrote it up.";

// --- market plumbing -------------------------------------------------------

const mint = (sats: number, who: string) =>
  simnet.callPublicFn(MARKET, "mint-complete-set", [Cl.uint(sats)], who);

const sendShares = (side: number, amount: number, to: string, from: string) =>
  simnet.callPublicFn(
    MARKET,
    "transfer-shares",
    [Cl.uint(side), Cl.uint(amount), Cl.principal(to)],
    from,
  );

function positionOf(who: string) {
  const p: any = simnet.callReadOnlyFn(MARKET, "get-position", [Cl.principal(who)], deployer)
    .result;
  return { idle: Number(p.value.idle.value), bonded: Number(p.value.bonded.value) };
}

const sbtcOf = (who: string) =>
  Number(
    (simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer).result as any).value
      .value,
  );

// --- legion reads ----------------------------------------------------------

const num = (c: string, fn: string, args: any[] = []) =>
  Number((simnet.callReadOnlyFn(c, fn, args, deployer).result as any).value);

const vault = (c: string) => num(c, "get-vault");
const weight = (c: string, who: string) => num(c, "get-weight", [Cl.principal(who)]);

function proposal(c: string, id: number) {
  const r: any = simnet.callReadOnlyFn(c, "get-proposal", [Cl.uint(id)], deployer).result;
  return r.value.value;
}
const statusOf = (c: string, id: number) => proposal(c, id).status.value as bigint;
const reasonOf = (c: string, id: number) => proposal(c, id).reason.value as string;

// --- legion calls ----------------------------------------------------------

const propose = (c: string, who: string, link = LINK, title = TITLE, desc = DESC) =>
  simnet.callPublicFn(
    c,
    "propose",
    [Cl.stringAscii(link), Cl.stringAscii(title), Cl.stringAscii(desc)],
    who,
  );

const vote = (c: string, id: number, support: boolean, who: string, why = "read it, checks out") =>
  simnet.callPublicFn(
    c,
    "vote",
    [Cl.uint(id), Cl.bool(support), Cl.stringAscii(why)],
    who,
  );

const conclude = (c: string, id: number, who = stranger) =>
  simnet.callPublicFn(c, "conclude", [Cl.uint(id)], who);

/** Walk a proposal from open to concludable. */
const toVoting = () => simnet.mineEmptyBurnBlocks(VOTE_DELAY);
const toConcludable = () => simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
/** Clear the global rate limit before the next proposal. */
const nextSlot = () => simnet.mineEmptyBurnBlocks(GLOBAL_PROPOSE_INTERVAL);

/** Mine out `who`'s own cooldown on `c`, if any is left. */
function cooled(c: string, who: string) {
  const h = num(c, "get-proposer-next-height", [Cl.principal(who)]);
  if (simnet.burnBlockHeight < h) simnet.mineEmptyBurnBlocks(h - simnet.burnBlockHeight);
}

/** Propose once every gate on timing is clear. */
function open1(c: string, who: string) {
  cooled(c, who);
  const r: any = propose(c, who);
  if (r.result.type !== "ok") {
    throw new Error(`propose failed for ${who}: ${JSON.stringify(r.result)}`);
  }
  return Number(r.result.value.value);
}

/**
 * One approved proposal, start to finish, on whichever legion.
 * Returns the id.
 */
function runPassing(c: string, proposer: string, voters: string[]) {
  const id = open1(c, proposer);
  toVoting();
  for (const v of voters) vote(c, id, true, v);
  toConcludable();
  conclude(c, id);
  nextSlot();
  return id;
}

// ---------------------------------------------------------------------------

// The clarinet setup file initialises the simnet session in its own root
// beforeAll, which runs AFTER this file's, so seeding at the root would be
// wiped before the first test. Seed once, lazily, from each suite instead.
let seeded = false;
function seedOnce() {
  if (seeded) return;
  seeded = true;

  // Real pox-5 bond state, written by pox-5 itself, so the market can open.
  registerSigner(deployer);
  setupBond(deployer, 1, [alice, bob, carol, dave]);
  simnet.callPublicFn(MARKET, "open", [], alice);
  simnet.mineEmptyBurnBlocks(1);

  // The seeder mints complete sets and hands one side to each legion. This is
  // the entire endowment path: two transfers from a wallet, no function on the
  // legion side, and the seeder is left holding nothing and voting nowhere.
  mint(100_000, deployer);
  sendShares(SIDE_BONDED, 100_000, yesLegion, deployer);
  sendShares(SIDE_IDLE, 100_000, noLegion, deployer);

  // Members buy in. Minting is always available at par, so nobody is gated by
  // a thin order book; it hands them the other side too, which they may dump.
  for (const who of [alice, bob, carol, dave]) mint(20_000, who);
  mint(200_000, whale);
  for (const who of [minnowA, minnowB]) mint(MIN_POSITION, who);
}

/** Move `who` to exactly `target` YES shares, using the whale as the float. */
function setYesWeight(who: string, target: number) {
  const held = weight(YES, who);
  if (held > target) sendShares(SIDE_BONDED, held - target, whale, who);
  else if (held < target) sendShares(SIDE_BONDED, target - held, who, whale);
  expect(weight(YES, who)).toBe(target);
}

describe("the seed", () => {
  beforeAll(seedOnce);
  it("endows each legion by transfer, with no function on the legion side", () => {
    expect(vault(YES)).toBe(100_000);
    expect(vault(NO)).toBe(100_000);
    expect(positionOf(yesLegion)).toEqual({ idle: 0, bonded: 100_000 });
    expect(positionOf(noLegion)).toEqual({ idle: 100_000, bonded: 0 });
  });

  it("leaves the seeder holding nothing, so they vote in neither legion", () => {
    expect(positionOf(deployer)).toEqual({ idle: 0, bonded: 0 });
    expect(weight(YES, deployer)).toBe(0);
    expect(weight(NO, deployer)).toBe(0);
  });

  it("holds a countable number of wins, and nothing mints more", () => {
    expect(num(YES, "get-wins-left")).toBe(Math.floor(100_000 / PAYOUT));
  });

  it("gives each legion the opposite side of the same question", () => {
    const y: any = simnet.callReadOnlyFn(YES, "get-side", [], deployer).result;
    const n: any = simnet.callReadOnlyFn(NO, "get-side", [], deployer).result;
    expect(Number(y.value.side.value)).toBe(SIDE_BONDED);
    expect(Number(n.value.side.value)).toBe(SIDE_IDLE);
    expect(y.value.label.value).toBe("bonded");
    expect(n.value.label.value).toBe("idle");
  });
});

describe("weight is the position, not a ledger", () => {
  beforeAll(seedOnce);
  it("reads a member's own market balance, live", () => {
    expect(weight(YES, alice)).toBe(positionOf(alice).bonded);
    expect(weight(NO, alice)).toBe(positionOf(alice).idle);
  });

  it("moves the moment they trade, with no deposit and no join", () => {
    const before = weight(YES, alice);
    sendShares(SIDE_BONDED, 5_000, stranger, alice);
    expect(weight(YES, alice)).toBe(before - 5_000);
    expect(weight(YES, stranger)).toBe(5_000);
    sendShares(SIDE_BONDED, 5_000, alice, stranger);
    expect(weight(YES, alice)).toBe(before);
  });

  it("excludes the vault's own holdings from votable supply", () => {
    const circ = num(YES, "get-votable") + vault(YES);
    expect(num(YES, "get-votable")).toBe(circ - vault(YES));
  });
});

describe("proposing", () => {
  beforeAll(seedOnce);
  it("needs a position on this side", () => {
    expect(weight(YES, stranger)).toBe(0);
    expect(propose(YES, stranger).result).toBeErr(Cl.uint(401));
  });

  it("is open to anyone who holds the floor", () => {
    expect(propose(YES, alice).result).toBeOk(Cl.uint(1));
    expect(num(YES, "get-last-proposal-id")).toBe(1);
  });

  it("rate limits everyone globally, since proposing costs no fee", () => {
    expect(propose(YES, bob).result).toBeErr(Cl.uint(432));
  });

  it("refuses a second live proposal from the same agent", () => {
    nextSlot();
    expect(propose(YES, alice).result).toBeErr(Cl.uint(434));
    expect(propose(YES, bob).result).toBeOk(Cl.uint(2));
  });

  it("requires a link, a title and the argument itself", () => {
    nextSlot();
    expect(propose(YES, carol, "").result).toBeErr(Cl.uint(421));
    expect(propose(YES, carol, LINK, "").result).toBeErr(Cl.uint(433));
    expect(propose(YES, carol, LINK, TITLE, "").result).toBeErr(Cl.uint(441));
  });

  it("records the votable supply the vote opened against", () => {
    const p = proposal(YES, 1);
    expect(Number(p.votableAtOpen.value)).toBeGreaterThan(0);
    expect(Number(p.votableAtOpen.value)).toBe(num(YES, "get-votable"));
  });
});

describe("voting", () => {
  beforeAll(seedOnce);
  let id: number;
  beforeAll(() => {
    nextSlot();
    id = open1(YES, alice);
  });

  it("is closed until the delay has passed", () => {
    expect(vote(YES, id, true, bob).result).toBeErr(Cl.uint(436));
    toVoting();
  });

  it("bars the proposer from their own piece", () => {
    expect(vote(YES, id, true, alice).result).toBeErr(Cl.uint(423));
  });

  it("needs the floor, and a written reason", () => {
    expect(vote(YES, id, true, stranger).result).toBeErr(Cl.uint(401));
    expect(vote(YES, id, true, bob, "").result).toBeErr(Cl.uint(440));
  });

  it("counts weight as it stands at the moment of the vote", () => {
    expect(vote(YES, id, true, bob).result).toBeOk(Cl.bool(true));
    expect(Number(proposal(YES, id).yesWeight.value)).toBe(weight(YES, bob));
  });

  it("takes one vote per agent", () => {
    expect(vote(YES, id, false, bob).result).toBeErr(Cl.uint(405));
  });

  it("closes at the deadline", () => {
    toConcludable();
    expect(vote(YES, id, true, carol).result).toBeErr(Cl.uint(407));
  });
});

describe("the two gates on a payout", () => {
  beforeAll(seedOnce);
  beforeAll(() => nextSlot());

  it("fails a piece nobody read: headcount quorum", () => {
    const id = open1(YES, alice);
    toVoting();
    vote(YES, id, true, bob);
    toConcludable();
    conclude(YES, id);
    expect(statusOf(YES, id)).toBe(FAILED);
    expect(reasonOf(YES, id)).toBe("no-voters");
    nextSlot();
  });

  it("fails a piece the roster read and rejected: threshold", () => {
    const id = open1(YES, alice);
    toVoting();
    vote(YES, id, true, bob);
    vote(YES, id, true, minnowA);
    vote(YES, id, false, carol);
    vote(YES, id, false, dave);
    toConcludable();
    conclude(YES, id);
    expect(statusOf(YES, id)).toBe(FAILED);
    expect(reasonOf(YES, id)).toBe("voted-down");
    nextSlot();
  });

  it("passes on consent alone, with no floor on the weight consenting", () => {
    // There is no yes-weight gate. Two agents sitting on MIN_POSITION carry a
    // 3,000-share payout between them. This is the accepted trade, written
    // down as a test so nobody rediscovers it by surprise.
    setYesWeight(minnowA, MIN_POSITION);
    setYesWeight(minnowB, MIN_POSITION);
    const before = vault(YES);
    const id = open1(YES, alice);
    toVoting();
    vote(YES, id, true, minnowA);
    vote(YES, id, true, minnowB);
    const p = proposal(YES, id);
    expect(Number(p.yesVoterCount.value)).toBe(MIN_VOTERS);
    expect(Number(p.yesWeight.value)).toBe(2 * MIN_POSITION);
    toConcludable();
    conclude(YES, id);
    expect(statusOf(YES, id)).toBe(PASSED);
    expect(vault(YES)).toBe(before - PAYOUT);
    nextSlot();
  });
});

describe("a proposer cannot buy in, propose, and sell out", () => {
  beforeAll(seedOnce);
  it("re-reads the position at conclude and forfeits if it is gone", () => {
    const id = open1(YES, carol);
    toVoting();
    vote(YES, id, true, alice);
    vote(YES, id, true, bob);
    // The vote is won. Now the proposer exits the side they argued for.
    sendShares(SIDE_BONDED, weight(YES, carol), whale, carol);
    expect(weight(YES, carol)).toBe(0);
    toConcludable();
    conclude(YES, id);
    expect(statusOf(YES, id)).toBe(FAILED);
    expect(reasonOf(YES, id)).toBe("not-holding");
    setYesWeight(carol, 20_000); // she buys back in; the legion is not a prison
    nextSlot();
  });
});

describe("an approved proposal", () => {
  beforeAll(seedOnce);
  it("pays shares out of the pot, and is the only thing that does", () => {
    const before = vault(YES);
    const paidBefore = weight(YES, alice);
    const id = runPassing(YES, alice, [bob, dave]);
    expect(statusOf(YES, id)).toBe(PASSED);
    expect(reasonOf(YES, id)).toBe("paid-shares");
    expect(vault(YES)).toBe(before - PAYOUT);
    expect(weight(YES, alice)).toBe(paidBefore + PAYOUT);
  });

  it("grows the proposer's vote, which is the real reward", () => {
    const before = weight(YES, bob);
    runPassing(YES, bob, [alice, dave]);
    expect(weight(YES, bob)).toBe(before + PAYOUT);
  });

  it("works the same on the other side of the argument", () => {
    const before = vault(NO);
    const id = runPassing(NO, alice, [bob, dave]);
    expect(statusOf(NO, id)).toBe(PASSED);
    expect(vault(NO)).toBe(before - PAYOUT);
    expect(positionOf(noLegion).bonded).toBe(0);
  });
});

describe("there is no withdraw", () => {
  beforeAll(seedOnce);
  it("exposes no function that moves shares anywhere but to a proposer", () => {
    const iface: any = simnet.getContractsInterfaces().get(`${deployer}.${YES}`);
    const fns = iface.functions
      .filter((f: any) => f.access === "public")
      .map((f: any) => f.name)
      .sort();
    expect(fns).toEqual(["claim-credit", "conclude", "propose", "redeem-vault", "vote"]);
  });

  it("takes no recipient anywhere, so the proposer is the only reachable payee", () => {
    const iface: any = simnet.getContractsInterfaces().get(`${deployer}.${YES}`);
    const args = iface.functions
      .filter((f: any) => f.access === "public")
      .flatMap((f: any) => f.args.map((a: any) => a.type));
    expect(args).not.toContain("principal");
  });

  it("cannot be drained by an outsider calling the market on its behalf", () => {
    // transfer-shares keys on contract-caller, so only the vault moves its own
    // position. This was the v4 hole and it is shut in the live deploy.
    const before = vault(YES);
    sendShares(SIDE_BONDED, 1_000, stranger, whale);
    expect(vault(YES)).toBe(before);
  });
});

describe("what the audit was about", () => {
  beforeAll(seedOnce);

  it("settles a proposal nobody voted on at all, without dividing by zero", () => {
    // thresholdMet divides by cast weight. With no votes that is zero, and the
    // guard has to be the short-circuit, not the branch order.
    const id = open1(YES, dave);
    toVoting();
    toConcludable();
    expect(conclude(YES, id).result).toBeOk(Cl.uint(2));
    expect(reasonOf(YES, id)).toBe("no-voters");
    nextSlot();
  });

  it("will not accept one collaborator plus a token dissenter as a quorum", () => {
    // The headcount gate is counted on the YES side. Were it counted over all
    // voters, an attacker would clear it with a single ally and one no vote,
    // and the no vote would still leave the threshold at 95%.
    const id = open1(YES, dave);
    toVoting();
    vote(YES, id, true, whale);        // one large yes
    vote(YES, id, false, minnowA);     // one token no, purely to make up numbers
    const p = proposal(YES, id);
    expect(Number(p.voterCount.value)).toBe(2);
    expect(Number(p.yesVoterCount.value)).toBe(1);
    toConcludable();
    conclude(YES, id);
    expect(reasonOf(YES, id)).toBe("no-voters");
    nextSlot();
  });

  it("leaves MIN_VOTERS as the only thing pricing self-dealing", () => {
    // With no weight floor, the cost of approving your own work is one wallet
    // per required yes vote, each holding MIN_POSITION. At MIN_VOTERS 2 that
    // is 3,000 sats of setup, and PROPOSER_COOLDOWN caps it at one attempt a
    // day. Raising MIN_VOTERS is the only dial that raises the price.
    setYesWeight(minnowA, MIN_POSITION);
    setYesWeight(minnowB, MIN_POSITION);
    const id = open1(YES, dave);
    toVoting();
    vote(YES, id, true, minnowA);
    expect(Number(proposal(YES, id).yesVoterCount.value)).toBeLessThan(MIN_VOTERS);
    toConcludable();
    conclude(YES, id);
    expect(reasonOf(YES, id)).toBe("no-voters");
    nextSlot();
  });

  it("rate limits one agent even when a global slot is free", () => {
    const id = open1(YES, carol);
    const next = num(YES, "get-proposer-next-height", [Cl.principal(carol)]);
    toVoting();
    toConcludable();
    conclude(YES, id);
    nextSlot();
    // Carol's proposal is settled and the global slot is free again, but a
    // lifecycle is 44 blocks and her own cooldown is 144.
    expect(simnet.burnBlockHeight).toBeLessThan(next);
    expect(propose(YES, carol).result).toBeErr(Cl.uint(450));
    // Somebody else can still take the slot, so one agent cannot stall the legion.
    cooled(YES, minnowB);
    expect(propose(YES, minnowB).result.type).toBe("ok");
    nextSlot();
  });

  it("lets anyone refill the pot, with no function to call", () => {
    const before = vault(YES);
    sendShares(SIDE_BONDED, 5_000, yesLegion, whale);
    expect(vault(YES)).toBe(before + 5_000);
    expect(num(YES, "get-wins-left")).toBe(Math.floor((before + 5_000) / PAYOUT));
  });

  it("cannot be concluded once the window has passed", () => {
    const id = open1(YES, alice);
    toVoting();
    vote(YES, id, true, bob);
    vote(YES, id, true, dave);
    toConcludable();
    simnet.mineEmptyBurnBlocks(CONCLUDE_WINDOW);
    expect(conclude(YES, id).result).toBeErr(Cl.uint(435));
    // and it reads as expired rather than as a payout that is still owed
    expect(simnet.callReadOnlyFn(YES, "get-phase", [Cl.uint(id)], deployer).result)
      .toBeAscii("expired");
    nextSlot();
  });

  it("frees the proposer's slot when a proposal lapses unconcluded", () => {
    expect((simnet.callReadOnlyFn(YES, "has-live-proposal", [Cl.principal(alice)], deployer)
      .result as any).type).toBe("false");
  });
});

describe("when the market settles mid-flight", () => {
  beforeAll(seedOnce);
  let id: number;

  it("a proposal that passes after the freeze becomes a credit, not a loss", () => {
    nextSlot();
    id = open1(YES, alice);
    toVoting();
    vote(YES, id, true, bob);
    vote(YES, id, true, dave);

    // A stranger lands the Bitcoin proof mid-vote. Every share transfer in
    // both legions is frozen from here, permanently.
    simnet.callPublicFn(MARKET, "test-set-bonded", [], stranger);
    expect(
      (simnet.callReadOnlyFn(YES, "is-market-tradeable", [], deployer).result as any).type,
    ).toBe("false");

    const vaultBefore = vault(YES);
    toConcludable();
    conclude(YES, id);
    expect(statusOf(YES, id)).toBe(PASSED);
    expect(reasonOf(YES, id)).toBe("credited");
    expect(vault(YES)).toBe(vaultBefore); // shares cannot move; nothing did
    expect(num(YES, "get-credit", [Cl.principal(alice)])).toBe(PAYOUT);
  });

  it("will not convert the pot while another proposal could still conclude", () => {
    // A credit issued after the conversion would have nothing behind it, so
    // the pot cannot be converted until every live proposal has settled or
    // lapsed. That height has not been reached yet.
    expect(simnet.burnBlockHeight).toBeLessThan(num(YES, "get-settle-height"));
    expect(simnet.callPublicFn(YES, "redeem-vault", [], stranger).result).toBeErr(Cl.uint(447));
  });

  it("refuses new proposals once the answer is known", () => {
    expect(propose(YES, bob).result).toBeErr(Cl.uint(442));
  });

  it("converts the leftover once credits are final, and pays them in sBTC", () => {
    simnet.mineEmptyBurnBlocks(VOTE_DELAY + VOTE_WINDOW + CONCLUDE_WINDOW);
    const shares = vault(YES);
    const r = simnet.callPublicFn(YES, "redeem-vault", [], stranger);
    expect(r.result).toBeOk(Cl.uint(shares));

    const before = sbtcOf(alice);
    expect(simnet.callPublicFn(YES, "claim-credit", [], alice).result).toBeOk(Cl.uint(PAYOUT));
    expect(sbtcOf(alice)).toBe(before + PAYOUT);
    expect(num(YES, "get-credit", [Cl.principal(alice)])).toBe(0);
  });

  it("converts only once", () => {
    expect(simnet.callPublicFn(YES, "redeem-vault", [], stranger).result).toBeErr(Cl.uint(445));
  });

  it("leaves nothing to claim for anyone who was not owed", () => {
    expect(simnet.callPublicFn(YES, "claim-credit", [], bob).result).toBeErr(Cl.uint(449));
  });
});

describe("arguing the losing side pays nothing", () => {
  beforeAll(seedOnce);
  it("redeems to zero, so a credit on the wrong side settles to nothing", () => {
    // The market settled BONDED. The no-legion argued IDLE and lost, so its
    // whole position is worth nothing and there is nothing to distribute.
    expect((simnet.callReadOnlyFn(NO, "has-won", [], deployer).result as any).type).toBe("false");
    expect(vault(NO)).toBeGreaterThan(0);
    // No credits were ever issued on that side, so there is nothing to convert
    // and the leftover is deliberately stranded rather than routed anywhere.
    expect(simnet.callPublicFn(NO, "redeem-vault", [], stranger).result).toBeErr(Cl.uint(446));
  });
});
