import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

// Boundary verification for the attack-cost formulas in ECONOMICS.md section 6.
// Each case runs a clean legion twice: one unit BELOW the predicted threshold
// (must fail) and one unit AT it (must pay). A formula that is off by a single
// sat fails here.
//
// v6 has no veto, so there are two cases rather than three: the attacker beats
// an honest no-vote, or nobody defends and only turnout binds.

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const honest = accounts.get("wallet_1")!;
const attackProposer = accounts.get("wallet_2")!;
const attackVoter = accounts.get("wallet_3")!;
const anyone = accounts.get("wallet_5")!;

const TREASURY = "news-treasury-v6";
const GOV = "news-gov-v6";
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";

const VOTING_DELAY = 2;
const VOTE_WINDOW = 30;
const MIN_WEIGHT = 10_000;
const PASSED = 1n;
const FAILED = 2n;

const LINK = "https://ordinals.com/inscription/deadbeefi0";

function faucet(who: string, times = 1) {
  for (let i = 0; i < times; i++) simnet.callPublicFn(SBTC, "faucet", [], who);
}

function contribute(who: string, amount: number) {
  faucet(who);
  const r = simnet.callPublicFn(GOV, "contribute", [Cl.uint(amount)], who);
  expect(r.result).toBeOk(Cl.uint(amount)); // 1:1 while no payout has happened
}

/**
 * Run one attack scenario end to end on a fresh chain.
 *   honestWeight  - honest stake, votes no only if `honestDefends`
 *   attackerVote  - weight the attacker votes yes with (X - p)
 * Returns the concluded status.
 */
function runAttack(
  honestWeight: number,
  attackerVote: number,
  honestDefends: boolean,
): bigint {
  simnet.callPublicFn(
    TREASURY, "set-gov", [Cl.principal(`${deployer}.${GOV}`)], deployer,
  );
  contribute(honest, honestWeight);
  contribute(attackProposer, MIN_WEIGHT); // p, minimised
  contribute(attackVoter, attackerVote);

  expect(
    simnet.callPublicFn(GOV, "propose-story", [
      Cl.stringAscii(LINK), Cl.stringAscii("t"), Cl.stringAscii(""),
    ], attackProposer).result,
  ).toBeOk(Cl.uint(1));

  simnet.mineEmptyBurnBlocks(VOTING_DELAY);
  simnet.callPublicFn(GOV, "vote",
    [Cl.uint(1), Cl.bool(true), Cl.stringAscii("yes")], attackVoter);
  if (honestDefends) {
    simnet.callPublicFn(GOV, "vote",
      [Cl.uint(1), Cl.bool(false), Cl.stringAscii("no")], honest);
  }

  simnet.mineEmptyBurnBlocks(VOTE_WINDOW);
  simnet.callPublicFn(GOV, "conclude", [Cl.uint(1)], anyone);
  const r = simnet.callReadOnlyFn(GOV, "get-story-status", [Cl.uint(1)], deployer);
  return (r.result as any).value.value as bigint;
}

describe("ECONOMICS.md s6: attacker beats an honest no-vote", () => {
  // yes >= 66% of cast, floored:  X - p >= 33A/17
  it("A=1,000,000 fails at 1,941,176 and pays at 1,941,177", () => {
    expect(runAttack(1_000_000, 1_941_176, true)).toBe(FAILED);
  });
  it("A=1,000,000 pays at the boundary", () => {
    expect(runAttack(1_000_000, 1_941_177, true)).toBe(PASSED);
  });
  it("A=100,000 fails at 194,117 and pays at 194,118", () => {
    expect(runAttack(100_000, 194_117, true)).toBe(FAILED);
  });
  it("A=100,000 pays at the boundary", () => {
    expect(runAttack(100_000, 194_118, true)).toBe(PASSED);
  });
});

describe("ECONOMICS.md s6: nobody defends, only turnout binds", () => {
  // cast >= 10% of eligible, floored:  X - p >= A/9
  it("A=1,000,000 fails at 111,111 and pays at 111,112", () => {
    expect(runAttack(1_000_000, 111_111, false)).toBe(FAILED);
  });
  it("A=1,000,000 pays at the boundary", () => {
    expect(runAttack(1_000_000, 111_112, false)).toBe(PASSED);
  });
  it("A=100,000 fails at 11,111 and pays at 11,112", () => {
    expect(runAttack(100_000, 11_111, false)).toBe(FAILED);
  });
  it("A=100,000 pays at the boundary", () => {
    expect(runAttack(100_000, 11_112, false)).toBe(PASSED);
  });
});
