import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const w1 = accounts.get("wallet_1")!;
const w2 = accounts.get("wallet_2")!;

const REG = "legion-registry";

// Convenience: register a Legion and return the new id (uint).
function register(
  who: string,
  kind: string,
  treasury: string,
  model: string,
  uri = "ipfs://x",
  gov: any = Cl.none(),
  fees: any = Cl.none(),
) {
  return simnet.callPublicFn(
    REG,
    "register",
    [Cl.stringAscii(kind), Cl.principal(treasury), gov, fees, Cl.stringAscii(model), Cl.stringAscii(uri)],
    who,
  );
}

describe("legion-registry", () => {
  it("registers a Legion, assigns sequential ids, and stores the entry", () => {
    expect(register(w1, "provider", w1, "qwen2.5-7b").result).toBeOk(Cl.uint(1));
    expect(register(w2, "demand", w2, "bitcoin-macro").result).toBeOk(Cl.uint(2));
    expect(simnet.callReadOnlyFn(REG, "get-count", [], deployer).result).toBeUint(2);

    const e = simnet.callReadOnlyFn(REG, "get-legion", [Cl.uint(1)], deployer).result as any;
    expect(e.value.data.owner).toStrictEqual(Cl.principal(w1));
    expect(e.value.data.kind).toStrictEqual(Cl.stringAscii("provider"));
    expect(e.value.data.model).toStrictEqual(Cl.stringAscii("qwen2.5-7b"));
    expect(e.value.data.active).toStrictEqual(Cl.bool(true));
  });

  it("rejects empty required fields (u400)", () => {
    expect(register(w1, "", w1, "m").result).toBeErr(Cl.uint(400));
    expect(register(w1, "provider", w1, "").result).toBeErr(Cl.uint(400));
  });

  it("only the owner can edit; others get u401; missing id u404", () => {
    expect(register(w1, "provider", w1, "qwen2.5-7b").result).toBeOk(Cl.uint(1));
    // non-owner cannot set uri
    expect(simnet.callPublicFn(REG, "set-uri", [Cl.uint(1), Cl.stringAscii("ipfs://y")], w2).result)
      .toBeErr(Cl.uint(401));
    // owner can
    expect(simnet.callPublicFn(REG, "set-uri", [Cl.uint(1), Cl.stringAscii("ipfs://y")], w1).result)
      .toBeOk(Cl.bool(true));
    // missing id
    expect(simnet.callPublicFn(REG, "set-uri", [Cl.uint(99), Cl.stringAscii("z")], w1).result)
      .toBeErr(Cl.uint(404));
  });

  it("admin (deployer) can deactivate any entry; owner can too", () => {
    expect(register(w1, "provider", w1, "qwen2.5-7b").result).toBeOk(Cl.uint(1));
    // admin deactivates someone else's entry (curation backstop)
    expect(simnet.callPublicFn(REG, "set-active", [Cl.uint(1), Cl.bool(false)], deployer).result)
      .toBeOk(Cl.bool(true));
    const e = simnet.callReadOnlyFn(REG, "get-legion", [Cl.uint(1)], deployer).result as any;
    expect(e.value.data.active).toStrictEqual(Cl.bool(false));
    // a random non-owner non-admin cannot
    expect(simnet.callPublicFn(REG, "set-active", [Cl.uint(1), Cl.bool(true)], w2).result)
      .toBeErr(Cl.uint(401));
  });

  it("ownership transfers, then only the new owner can edit", () => {
    expect(register(w1, "provider", w1, "qwen2.5-7b").result).toBeOk(Cl.uint(1));
    expect(simnet.callPublicFn(REG, "transfer-entry", [Cl.uint(1), Cl.principal(w2)], w1).result)
      .toBeOk(Cl.bool(true));
    expect(simnet.callPublicFn(REG, "set-uri", [Cl.uint(1), Cl.stringAscii("z")], w1).result)
      .toBeErr(Cl.uint(401)); // old owner locked out
    expect(simnet.callPublicFn(REG, "set-uri", [Cl.uint(1), Cl.stringAscii("z")], w2).result)
      .toBeOk(Cl.bool(true));
  });
});
