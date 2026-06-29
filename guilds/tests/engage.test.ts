import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const m1 = accounts.get("wallet_1")!;
const m2 = accounts.get("wallet_2")!;

const E = "legion-engage";
const T = "legion-treasury";
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";
const MIN_STAKE = 10_000;

function faucet(who: string, times = 1) {
  for (let i = 0; i < times; i++) {
    expect(simnet.callPublicFn(SBTC, "faucet", [], who).result).toBeOk(Cl.bool(true));
  }
}
function sbtcOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return (r.result as any).value.value as bigint;
}
// The treasury must have its token wired to accept the exit-fee deposit.
function wireTreasuryToken() {
  expect(simnet.callPublicFn(T, "set-token", [Cl.principal(SBTC)], deployer).result).toBeOk(Cl.bool(true));
}
function join(who: string, amount: number) {
  return simnet.callPublicFn(E, "join", [Cl.principal(SBTC), Cl.uint(amount)], who);
}
function getStake(who: string): bigint {
  const r = simnet.callReadOnlyFn(E, "get-stake", [Cl.principal(who)], deployer);
  return (r.result as any).value as bigint;
}
function treasuryBalance(): bigint {
  const r = simnet.callReadOnlyFn(T, "get-balance", [], deployer);
  return (r.result as any).value as bigint;
}

describe("legion-engage", () => {
  beforeEach(() => { wireTreasuryToken(); faucet(m1, 1); });

  it("rejects a stake below MIN_STAKE (u405) and joins at/above it", () => {
    expect(join(m1, MIN_STAKE - 1).result).toBeErr(Cl.uint(405));
    expect(join(m1, MIN_STAKE).result).toBeOk(Cl.bool(true));
    expect(simnet.callReadOnlyFn(E, "is-member", [Cl.principal(m1)], deployer).result).toBeBool(true);
    expect(getStake(m1)).toBe(BigInt(MIN_STAKE));
  });

  it("holds the stake in-contract on join", () => {
    const before = sbtcOf(m1);
    expect(join(m1, 100_000).result).toBeOk(Cl.bool(true));
    expect(before - sbtcOf(m1)).toBe(100_000n);
  });

  it("blocks a double join (u406)", () => {
    expect(join(m1, MIN_STAKE).result).toBeOk(Cl.bool(true));
    expect(join(m1, MIN_STAKE).result).toBeErr(Cl.uint(406));
  });

  it("add-stake increases the member's stake", () => {
    expect(join(m1, MIN_STAKE).result).toBeOk(Cl.bool(true));
    expect(simnet.callPublicFn(E, "add-stake", [Cl.principal(SBTC), Cl.uint(5_000)], m1).result).toBeOk(Cl.bool(true));
    expect(getStake(m1)).toBe(BigInt(MIN_STAKE + 5_000));
  });

  it("leave refunds 90% to the member and routes 10% to the treasury", () => {
    const before = sbtcOf(m1);
    expect(join(m1, 100_000).result).toBeOk(Cl.bool(true));
    const tBefore = treasuryBalance();
    const res = simnet.callPublicFn(E, "leave", [Cl.principal(SBTC)], m1);
    expect(res.result).toBeOk(Cl.tuple({ refund: Cl.uint(90_000), fee: Cl.uint(10_000) }));
    // member's net loss over the whole join+leave cycle is exactly the 10% fee
    expect(before - sbtcOf(m1)).toBe(10_000n);
    // the fee landed in the treasury's accounted (governable) balance
    expect(treasuryBalance() - tBefore).toBe(10_000n);
    // membership is cleared
    expect(simnet.callReadOnlyFn(E, "is-member", [Cl.principal(m1)], deployer).result).toBeBool(false);
    expect(getStake(m1)).toBe(0n);
  });

  it("quote-exit reports the 90/10 split for a member", () => {
    expect(join(m1, 100_000).result).toBeOk(Cl.bool(true));
    expect(simnet.callReadOnlyFn(E, "quote-exit", [Cl.principal(m1)], deployer).result)
      .toBeSome(Cl.tuple({ stake: Cl.uint(100_000), fee: Cl.uint(10_000), refund: Cl.uint(90_000) }));
  });

  it("rejects leave / add-stake when not a member (u404)", () => {
    expect(simnet.callPublicFn(E, "leave", [Cl.principal(SBTC)], m2).result).toBeErr(Cl.uint(404));
    expect(simnet.callPublicFn(E, "add-stake", [Cl.principal(SBTC), Cl.uint(5_000)], m2).result).toBeErr(Cl.uint(404));
  });
});
