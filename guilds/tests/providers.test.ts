import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!; // also the Admin
const prov = accounts.get("wallet_1")!;     // a provider
const other = accounts.get("wallet_2")!;

const P = "legion-providers";
const SBTC = "STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token";
const MIN_BOND = 1_000_000;

function faucet(who: string, times = 1) {
  for (let i = 0; i < times; i++) {
    expect(simnet.callPublicFn(SBTC, "faucet", [], who).result).toBeOk(Cl.bool(true));
  }
}
function sbtcOf(who: string): bigint {
  const r = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return (r.result as any).value.value as bigint;
}
function wireToken() {
  expect(simnet.callPublicFn(P, "set-token", [Cl.principal(SBTC)], deployer).result).toBeOk(Cl.bool(true));
}
function register(who: string, bond: number, model = "qwen2.5-7b", endpoint = "https://x/v1") {
  return simnet.callPublicFn(P, "register",
    [Cl.principal(SBTC), Cl.stringAscii(model), Cl.stringAscii(endpoint), Cl.uint(bond)], who);
}

describe("legion-providers", () => {
  beforeEach(() => { wireToken(); faucet(prov, 1); });

  it("rejects a bond below MIN_BOND (u405) and registers at/above it", () => {
    expect(register(prov, MIN_BOND - 1).result).toBeErr(Cl.uint(405));
    expect(register(prov, MIN_BOND).result).toBeOk(Cl.bool(true));
    expect(simnet.callReadOnlyFn(P, "is-active", [Cl.principal(prov)], deployer).result).toBeBool(true);
  });

  it("holds the bond in-contract and refunds it on deregister", () => {
    const before = sbtcOf(prov);
    expect(register(prov, MIN_BOND).result).toBeOk(Cl.bool(true));
    expect(before - sbtcOf(prov)).toBe(BigInt(MIN_BOND)); // bond left the provider
    expect(simnet.callPublicFn(P, "deregister", [Cl.principal(SBTC)], prov).result).toBeOk(Cl.uint(MIN_BOND));
    expect(sbtcOf(prov)).toBe(before); // fully refunded
    expect(simnet.callReadOnlyFn(P, "is-active", [Cl.principal(prov)], deployer).result).toBeBool(false);
  });

  it("blocks double registration (u406)", () => {
    expect(register(prov, MIN_BOND).result).toBeOk(Cl.bool(true));
    faucet(prov, 1);
    expect(register(prov, MIN_BOND).result).toBeErr(Cl.uint(406));
  });

  it("only admin records jobs + slashes; slash moves bond and can deactivate", () => {
    faucet(prov, 1); // 2x faucet so bond can exceed MIN comfortably
    expect(register(prov, 2 * MIN_BOND).result).toBeOk(Cl.bool(true));
    // non-admin cannot record/slash
    expect(simnet.callPublicFn(P, "record-success", [Cl.principal(prov)], other).result).toBeErr(Cl.uint(401));
    expect(simnet.callPublicFn(P, "slash", [Cl.principal(SBTC), Cl.principal(prov), Cl.uint(MIN_BOND)], other).result).toBeErr(Cl.uint(401));
    // admin records a success
    expect(simnet.callPublicFn(P, "record-success", [Cl.principal(prov)], deployer).result).toBeOk(Cl.bool(true));
    // admin slashes half the bond -> remaining returned, still active
    expect(simnet.callPublicFn(P, "slash", [Cl.principal(SBTC), Cl.principal(prov), Cl.uint(MIN_BOND)], deployer).result).toBeOk(Cl.uint(MIN_BOND));
    // slash the rest -> deactivated
    expect(simnet.callPublicFn(P, "slash", [Cl.principal(SBTC), Cl.principal(prov), Cl.uint(MIN_BOND)], deployer).result).toBeOk(Cl.uint(0));
    expect(simnet.callReadOnlyFn(P, "is-active", [Cl.principal(prov)], deployer).result).toBeBool(false);
  });
});
