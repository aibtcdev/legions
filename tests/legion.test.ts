import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

// The `simnet` object is injected globally by vitest-environment-clarinet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!; // agent A
const wallet2 = accounts.get("wallet_2")!; // agent B
const wallet3 = accounts.get("wallet_3")!; // recipient / peer
const wallet4 = accounts.get("wallet_4")!; // extra peer / recipient
const wallet5 = accounts.get("wallet_5")!; // extra staker

const TREASURY = "legion-treasury";
const GOV = "legion-gov";

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
// The gov contract uses test-fast timing: stacks-block windows with
// VOTING_DELAY=1, VOTING_PERIOD=15.
const VOTING_DELAY = 1;
const VOTING_PERIOD = 15;

// Mint sBTC to a wallet via the real token's public faucet. Each call mints
// FAUCET_AMOUNT; pass `times` to mint more for wallets that need a bigger stake.
function faucet(who: string, times = 1) {
  for (let i = 0; i < times; i++) {
    const r = simnet.callPublicFn(SBTC, "faucet", [], who);
    expect(r.result).toBeOk(Cl.bool(true));
  }
}

// sBTC balance of a principal (reads the real token's get-balance).
function sbtcOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return (r.result as any).value.value as bigint;
}

// One-time wiring: deployer wires gov + the sBTC token into the treasury.
function wire() {
  const a = simnet.callPublicFn(
    TREASURY,
    "set-gov",
    [Cl.principal(govPrincipal)],
    deployer,
  );
  expect(a.result).toBeOk(Cl.bool(true));
  const c = simnet.callPublicFn(
    TREASURY,
    "set-token",
    [Cl.principal(SBTC)],
    deployer,
  );
  expect(c.result).toBeOk(Cl.bool(true));
}

function stake(who: string, amount: number) {
  return simnet.callPublicFn(
    GOV,
    "stake",
    [Cl.principal(SBTC), Cl.uint(amount)],
    who,
  );
}

function propose(who: string, desc: string, recipient: string, amount: number) {
  return simnet.callPublicFn(
    GOV,
    "propose",
    [Cl.stringAscii(desc), Cl.principal(recipient), Cl.uint(amount)],
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
  return simnet.callPublicFn(
    GOV,
    "conclude-proposal",
    [Cl.uint(id), Cl.principal(SBTC)],
    who,
  );
}

function deposit(who: string, amount: number) {
  return simnet.callPublicFn(
    TREASURY,
    "deposit",
    [Cl.principal(SBTC), Cl.uint(amount)],
    who,
  );
}

// The treasury's internal pool-accounted balance (uint).
function balance(): bigint {
  const r = simnet.callReadOnlyFn(TREASURY, "get-balance", [], deployer);
  return (r.result as any).value as bigint;
}

// Read a proposal's lifecycle window boundaries (stacks-block heights).
function proposalWindow(id: number) {
  const st = simnet.callReadOnlyFn(
    GOV,
    "get-proposal-status",
    [Cl.uint(id)],
    deployer,
  ).result as any;
  const num = (k: string) => Number(st.value.data[k].value);
  return {
    voteStart: num("voteStart"),
    voteEnd: num("voteEnd"),
    execStart: num("execStart"),
    execEnd: num("execEnd"),
  };
}

// Mine empty stacks blocks so the NEXT transaction executes at height `target`.
// `simnet.blockHeight` is the height the last tx ran at, so the next tx runs at
// `blockHeight + 1`; mine until `blockHeight === target - 1`.
function mineToHeight(target: number) {
  const delta = target - 1 - simnet.blockHeight;
  if (delta > 0) simnet.mineEmptyStacksBlocks(delta);
}

// Timing uses stacks-block-height (gov test-fast windows). Helpers mine empty
// stacks blocks relative to a proposal created at block C:
//   voteStart = C + VOTING_DELAY,  voteEnd  = voteStart + VOTING_PERIOD
//   execStart = voteEnd + VOTING_DELAY, execEnd = execStart + VOTING_PERIOD
// The propose tx itself mines block C, leaving height at C+1 afterwards.

// Advance into the voting window [voteStart, voteEnd).
function enterVotingWindow() {
  simnet.mineEmptyStacksBlocks(VOTING_DELAY);
}

// Advance from just-after creation to the veto window [voteEnd, execStart).
function enterVetoWindow() {
  simnet.mineEmptyStacksBlocks(VOTING_DELAY + VOTING_PERIOD);
}

// Advance from just-after creation to the exec window [execStart, execEnd).
function enterExecWindow() {
  simnet.mineEmptyStacksBlocks(2 * VOTING_DELAY + VOTING_PERIOD);
}

describe("legion wiring", () => {
  beforeEach(() => {
    wire();
  });

  it("wires gov and token, and rejects re-wiring (u403)", () => {
    expect(
      simnet.callReadOnlyFn(TREASURY, "get-gov", [], deployer).result,
    ).toBeSome(Cl.principal(govPrincipal));
    expect(
      simnet.callReadOnlyFn(TREASURY, "get-token", [], deployer).result,
    ).toBeSome(Cl.principal(SBTC));

    const re = simnet.callPublicFn(
      TREASURY,
      "set-gov",
      [Cl.principal(govPrincipal)],
      deployer,
    );
    expect(re.result).toBeErr(Cl.uint(403));

    const reToken = simnet.callPublicFn(
      TREASURY,
      "set-token",
      [Cl.principal(SBTC)],
      deployer,
    );
    expect(reToken.result).toBeErr(Cl.uint(403));
  });
});

describe("Vector 1: full happy path (gov conclude)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("two agents stake -> propose -> both vote yes -> advance -> conclude -> transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(balance()).toBe(2_000_000n);
    expect(
      simnet.callReadOnlyFn(GOV, "get-total-staked", [], deployer).result,
    ).toBeUint(2_000_000);

    expect(propose(wallet1, "pay the bounty", wallet3, 500_000).result).toBeOk(
      Cl.uint(1),
    );

    enterVotingWindow();

    // Both vote yes: 100% yes, 100% turnout, 2 participants.
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));

    // Cannot conclude before the exec window.
    expect(conclude(wallet1, 1).result).toBeErr(Cl.uint(416));

    enterExecWindow();

    const w3Before = sbtcOf(wallet3);
    const exec = conclude(wallet1, 1);
    expect(exec.result).toBeOk(Cl.bool(true)); // passed
    expect(balance()).toBe(1_500_000n);
    expect(sbtcOf(wallet3) - w3Before).toBe(500_000n);

    // Re-conclusion is rejected.
    expect(conclude(wallet1, 1).result).toBeErr(Cl.uint(413));
  });
});

describe("Vector 2: threshold fail (yes between 50-65% of cast)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("conclude succeeds as failed (ok false), no transfer", () => {
    // wallet1 yes = 1.2M, wallet2 no = 0.8M => yes = 60% of cast (< 66%).
    expect(stake(wallet1, 1_200_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 800_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();

    expect(propose(wallet1, "contested", wallet3, 100_000).result).toBeOk(
      Cl.uint(1),
    );
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, false).result).toBeOk(Cl.bool(true));

    enterExecWindow();
    const res = conclude(wallet1, 1);
    expect(res.result).toBeOk(Cl.bool(false)); // did not pass
    expect(balance()).toBe(startBal);

    const status = simnet.callReadOnlyFn(
      GOV,
      "get-proposal-status",
      [Cl.uint(1)],
      deployer,
    ).result as any;
    expect(status.value.data.metQuorum).toStrictEqual(Cl.bool(true));
    expect(status.value.data.metThreshold).toStrictEqual(Cl.bool(false));
    expect(status.value.data.executed).toStrictEqual(Cl.bool(false));
  });
});

describe("Vector 3: quorum fail (turnout < 15% of total staked)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    // wallet5 stakes 9M; one faucet call (6.9M) is not enough, so mint twice.
    faucet(wallet5, 2);
  });

  it("conclude succeeds as failed (ok false), no transfer", () => {
    // Total staked = 10M (wallet5 holds the bulk). Only wallet1 + wallet2 vote
    // with 1M combined = 10% turnout (< 15% quorum). Both yes for unanimity.
    expect(stake(wallet1, 500_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 500_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet5, 9_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();

    expect(propose(wallet1, "low turnout", wallet3, 100_000).result).toBeOk(
      Cl.uint(1),
    );
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));

    enterExecWindow();
    const res = conclude(wallet1, 1);
    expect(res.result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);

    const status = simnet.callReadOnlyFn(
      GOV,
      "get-proposal-status",
      [Cl.uint(1)],
      deployer,
    ).result as any;
    expect(status.value.data.metQuorum).toStrictEqual(Cl.bool(false));
    expect(status.value.data.metThreshold).toStrictEqual(Cl.bool(true));
  });
});

describe("Vector 4: vote too soon / too late", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("voting in-window succeeds, after voteEnd => u412", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "timing", wallet3, 1).result).toBeOk(Cl.uint(1));

    // In the voting window: a vote succeeds.
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));

    // Past the voting window (into the veto window): too late.
    enterVetoWindow();
    expect(vote(wallet2, 1, true).result).toBeErr(Cl.uint(412));
  });
});

describe("Vector 5: vote changing (yes -> no)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
  });

  it("flipping a vote updates tallies and does not double-count voterCount", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "flip", wallet3, 1).result).toBeOk(Cl.uint(1));

    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));

    // Snapshot after both yes.
    let status = simnet.callReadOnlyFn(
      GOV,
      "get-proposal-status",
      [Cl.uint(1)],
      deployer,
    ).result as any;
    expect(status.value.data.yesWeight).toStrictEqual(Cl.uint(2_000_000));
    expect(status.value.data.noWeight).toStrictEqual(Cl.uint(0));
    expect(status.value.data.voterCount).toStrictEqual(Cl.uint(2));

    // wallet1 flips yes -> no.
    expect(vote(wallet1, 1, false).result).toBeOk(Cl.bool(true));

    status = simnet.callReadOnlyFn(
      GOV,
      "get-proposal-status",
      [Cl.uint(1)],
      deployer,
    ).result as any;
    expect(status.value.data.yesWeight).toStrictEqual(Cl.uint(1_000_000));
    expect(status.value.data.noWeight).toStrictEqual(Cl.uint(1_000_000));
    expect(status.value.data.voterCount).toStrictEqual(Cl.uint(2));

    // Now it is a 50/50 split: threshold not met -> fails on conclude.
    enterExecWindow();
    expect(conclude(wallet1, 1).result).toBeOk(Cl.bool(false));
  });
});

describe("Vector 6: veto blocks an otherwise-passing proposal", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
    faucet(wallet2);
    faucet(wallet5);
  });

  it("enough veto weight (>=15% and > yes) => conclude does NOT transfer", () => {
    // wallet1 yes = 1M, wallet2 yes = 1M (would pass). wallet5 holds 3M and
    // vetoes: veto = 3M >= 15% of 5M snapshot AND 3M > yes(2M) => activated.
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(stake(wallet5, 3_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();

    expect(propose(wallet1, "vetoed", wallet3, 100_000).result).toBeOk(
      Cl.uint(1),
    );
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));

    // The veto window [voteEnd, execStart) is one stacks block wide. Mine up to
    // voteEnd exactly so the veto tx lands inside it, then conclude in exec.
    mineToHeight(proposalWindow(1).voteEnd);
    expect(veto(wallet5, 1).result).toBeOk(Cl.bool(true));

    // Move into the exec window [execStart, execEnd).
    mineToHeight(proposalWindow(1).execStart);
    const res = conclude(wallet1, 1);
    expect(res.result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);

    const status = simnet.callReadOnlyFn(
      GOV,
      "get-proposal-status",
      [Cl.uint(1)],
      deployer,
    ).result as any;
    expect(status.value.data.vetoActivated).toStrictEqual(Cl.bool(true));
  });
});

describe("Vector 7: double vote + min-participants", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("same principal voting same direction twice => u405", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "dbl", wallet3, 1).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet1, 1, true).result).toBeErr(Cl.uint(405));
  });

  it("single voter (< MIN_PARTICIPANTS) => conclude does NOT transfer", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();
    expect(propose(wallet1, "lonely", wallet3, 100_000).result).toBeOk(
      Cl.uint(1),
    );
    enterVotingWindow();
    // Only one voter, 100% yes, 100% turnout -> quorum & threshold met but
    // participant floor not met.
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));

    enterExecWindow();
    const res = conclude(wallet1, 1);
    expect(res.result).toBeOk(Cl.bool(false));
    expect(balance()).toBe(startBal);
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
      [Cl.principal(SBTC), Cl.principal(wallet3), Cl.uint(100_000)],
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
    const dep = deposit(wallet2, 250_000);
    expect(dep.result).toBeOk(Cl.bool(true));
    expect(balance()).toBe(250_000n);
  });
});

describe("Vector 11: zero / eligibility edge cases", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("zero-amount deposit => u409", () => {
    const r = deposit(wallet1, 0);
    expect(r.result).toBeErr(Cl.uint(409));
  });

  it("zero-stake voter voting => u401", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "z", wallet4, 1).result).toBeOk(Cl.uint(1));
    enterVotingWindow();
    const r = vote(wallet3, 1, true); // zero stake
    expect(r.result).toBeErr(Cl.uint(401));
  });

  it("propose with zero total staked => u410", () => {
    const r = propose(wallet1, "no-stake", wallet3, 1);
    expect(r.result).toBeErr(Cl.uint(410));
  });
});

describe("Self-targeting guard (u407)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("proposal targeting the treasury contract => u407", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "self", treasuryPrincipal, 1).result).toBeErr(
      Cl.uint(407),
    );
  });

  it("proposal targeting the gov contract => u407", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "self2", govPrincipal, 1).result).toBeErr(
      Cl.uint(407),
    );
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
    expect(
      simnet.callReadOnlyFn(GOV, "get-total-staked", [], deployer).result,
    ).toBeUint(0);
  });

  it("proposing a zero amount => u417", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "zero amount", wallet3, 0).result).toBeErr(
      Cl.uint(417),
    );
  });
});

describe("New guard: empty proposal description (u418)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("propose with empty desc => u418", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "", wallet3, 1).result).toBeErr(Cl.uint(418));
  });

  it("propose with non-empty desc still succeeds", () => {
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    expect(propose(wallet1, "real desc", wallet3, 1).result).toBeOk(Cl.uint(1));
  });
});

describe("New guard: wiring gov/token to treasury-self (u410)", () => {
  // NOTE: do NOT call wire() here; these must run against an unwired treasury.
  it("set-gov to the treasury principal => u410", () => {
    const r = simnet.callPublicFn(
      TREASURY,
      "set-gov",
      [Cl.principal(treasuryPrincipal)],
      deployer,
    );
    expect(r.result).toBeErr(Cl.uint(410));
  });

  it("set-token to the treasury principal => u410", () => {
    const r = simnet.callPublicFn(
      TREASURY,
      "set-token",
      [Cl.principal(treasuryPrincipal)],
      deployer,
    );
    expect(r.result).toBeErr(Cl.uint(410));
  });
});

describe("New guard: wrong token rejected (u412)", () => {
  beforeEach(() => {
    wire();
    faucet(wallet1);
  });

  it("deposit with a WRONG token principal => u412", () => {
    // The WRONG token is a real contract (the treasury itself) that is not the
    // wired sBTC token; the treasury asserts the trait's contract principal.
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
    expect(
      simnet.callReadOnlyFn(GOV, "get-total-staked", [], deployer).result,
    ).toBeUint(0);
  });

  it("conclude (withdraw) with a WRONG token principal => u412, no transfer", () => {
    // Stake with the real token so a passing proposal would otherwise transfer.
    expect(stake(wallet1, 1_000_000).result).toBeOk(Cl.bool(true));
    faucet(wallet2);
    expect(stake(wallet2, 1_000_000).result).toBeOk(Cl.bool(true));
    const startBal = balance();
    expect(propose(wallet1, "wrong-token", wallet3, 100_000).result).toBeOk(
      Cl.uint(1),
    );
    enterVotingWindow();
    expect(vote(wallet1, 1, true).result).toBeOk(Cl.bool(true));
    expect(vote(wallet2, 1, true).result).toBeOk(Cl.bool(true));
    enterExecWindow();
    // Concluding a PASSING proposal but with the wrong token aborts the tx at the
    // treasury's token assert (u412); nothing is concluded or transferred.
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
