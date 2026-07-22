// Type declarations for the clarinet-sdk custom vitest matchers
// (toBeOk / toBeErr / toBeSome / toBeUint / ...).
//
// The matchers are registered at runtime by vitest-environment-clarinet, so the
// tests pass. But the augmentation shipped inside @hirosystems/clarinet-sdk is
// compiled against the copy of `vitest` bundled *inside* that package, so it
// augments a different `vitest` module than the one our tests import. Declaring
// the augmentation here — in the project's own compilation context — targets the
// project's `vitest`, so the editor/tsc recognize the matchers too.

import type { ClarityValue, ClarityType } from "@stacks/transactions";
import type { ExpectStatic } from "vitest";

interface ClarityValuesMatchers<R = unknown> {
  toHaveClarityType(expectedType: ClarityType): R;
  toBeOk(expected: ExpectStatic | ClarityValue): R;
  toBeErr(expected: ExpectStatic | ClarityValue): R;
  toBeSome(expected: ExpectStatic | ClarityValue): R;
  toBeNone(): R;
  toBeBool(expected: boolean): R;
  toBeInt(expected: number | bigint): R;
  toBeUint(expected: number | bigint): R;
  toBeAscii(expected: string): R;
  toBeUtf8(expected: string): R;
  toBePrincipal(expected: string): R;
  toBeBuff(expected: Uint8Array): R;
  toBeList(expected: ExpectStatic[] | ClarityValue[]): R;
  toBeTuple(expected: Record<string, ExpectStatic | ClarityValue>): R;
}

declare module "vitest" {
  interface Assertion<T = any> extends ClarityValuesMatchers<T> {}
  interface AsymmetricMatchersContaining
    extends ClarityValuesMatchers<ExpectStatic> {}
}
