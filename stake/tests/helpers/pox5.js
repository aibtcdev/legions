// Driving the REAL pox-5 in simnet.
//
// contracts/pox5-sim.clar is the deployed PoX-5 contract, generated from
// vendor/pox-5.testnet.clar and deployed under our own address so that we hold
// bond-admin. Nothing here fakes membership: every row these helpers produce is
// written by pox-5 itself, through grant-signer-key -> register-signer ->
// setup-bond -> register-for-bond.
import { Cl, serializeCV, signMessageHashRsv, privateKeyToPublic, publicKeyToHex } from "@stacks/transactions";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

export const POX = "pox5-sim";
export const SIGNER_MANAGER = "test-signer-manager";

const hex = (h) => Buffer.from(String(h).replace(/^0x/, ""), "hex");

// pox-5 bonds start every BOND_GAP_CYCLES (2) reward cycles of 1050 burn
// blocks, so bond `i` starts at burn height i * 2100. setup-bond is only
// accepted inside the two-cycle window before that start, which leaves exactly
// one usable index at any height.
export const BOND_SPACING = 2100;
export const currentBondIndex = () =>
  Math.floor(simnet.burnBlockHeight / BOND_SPACING) + 1;

function devnetKey(account) {
  const txt = readFileSync("settings/Devnet.toml", "utf8");
  let name = null;
  for (const line of txt.split("\n")) {
    const a = line.match(/^\[accounts\.([a-z0-9_]+)\]/);
    if (a) name = a[1];
    const k = line.match(/secret_key:\s*([0-9a-f]+)/);
    if (k && name === account) return k[1];
  }
  throw new Error(`no secret_key for ${account} in settings/Devnet.toml`);
}

// pox-5 will only accept a signer that holds a signed key grant, and insists
// both calls originate from the signer contract itself.
export function registerSigner(deployer, authId = 1) {
  const mgr = `${deployer}.${SIGNER_MANAGER}`;
  const priv = devnetKey("deployer");
  const pubkey = hex(publicKeyToHex(privateKeyToPublic(priv)));
  const messageHash = simnet.callReadOnlyFn(POX, "get-signer-grant-message-hash",
    [Cl.principal(mgr), Cl.uint(authId)], deployer).result.value;
  const sig = signMessageHashRsv({ messageHash, privateKey: priv });
  simnet.callPublicFn(SIGNER_MANAGER, "grant-key",
    [Cl.buffer(pubkey), Cl.uint(authId), Cl.buffer(hex(sig))], deployer);
  simnet.callPublicFn(SIGNER_MANAGER, "register",
    [Cl.contractPrincipal(deployer, SIGNER_MANAGER), Cl.buffer(pubkey)], deployer);
  return mgr;
}

export const EARLY_UNLOCK_BYTES = Buffer.from([0x51]); // OP_1
export const STAKER_UNLOCK_BYTES = Buffer.from([0x51]);

export function setupBond(deployer, bondIndex, stakers, maxSats = 30_000_000_000) {
  return simnet.callPublicFn(POX, "setup-bond", [
    Cl.uint(bondIndex), Cl.uint(500), Cl.uint(100), Cl.uint(1),
    Cl.buffer(EARLY_UNLOCK_BYTES),
    Cl.list(stakers.map((s) => Cl.tuple({ staker: Cl.principal(s), "max-sats": Cl.uint(maxSats) }))),
  ], deployer);
}

// The earliest L1 unlock height pox-5 will accept for this bond.
export const minUnlockHeight = (deployer, bondIndex) =>
  Number(simnet.callReadOnlyFn(POX, "get-bond-l1-unlock-height", [Cl.uint(bondIndex)], deployer).result.value);

// pox-5's own lockup script for a staker. This is the template At Stake's
// check 4 has to recognise, so tests pay the real thing rather than a lookalike.
// sha256d(to-consensus-buff? staker) -- the commitment pox-5 embeds in the
// lockup script. Computed here rather than read from a contract, so a test can
// assert the script really binds the staker it names.
export function stakerCommitment(staker) {
  const b = Buffer.from(serializeCV(Cl.principal(staker)), "hex");
  return createHash("sha256").update(
    createHash("sha256").update(b).digest()).digest();
}

export function lockupScriptFor(deployer, staker, unlockHeight) {
  const witness = simnet.callReadOnlyFn(POX, "construct-lockup-script",
    [Cl.principal(staker), Cl.uint(unlockHeight), Cl.buffer(STAKER_UNLOCK_BYTES),
     Cl.buffer(EARLY_UNLOCK_BYTES)], deployer).result.value.value;
  const spk = simnet.callReadOnlyFn(POX, "construct-lockup-output-script",
    [Cl.principal(staker), Cl.uint(unlockHeight), Cl.buffer(STAKER_UNLOCK_BYTES),
     Cl.buffer(EARLY_UNLOCK_BYTES)], deployer).result.value.value;
  const w = hex(witness);
  return { witness: w, spk: hex(spk) };
}

// Register an L1 (native BTC timelock) bond. `proof` is a single-transaction
// block: its merkle root IS the txid, which is a legitimate proof for a block
// of one transaction, and is what both pox-5 and at-stake verify.
export function registerL1Bond(staker, mgrDeployer, bondIndex, { tx, header, amount, unlockHeight }) {
  return simnet.callPublicFn(POX, "register-for-bond", [
    Cl.uint(bondIndex), Cl.contractPrincipal(mgrDeployer, SIGNER_MANAGER),
    Cl.uint(100_000_000_000),
    Cl.ok(Cl.tuple({
      outputs: Cl.list([Cl.tuple({
        height: Cl.uint(1), tx: Cl.buffer(tx), "output-index": Cl.uint(0),
        header: Cl.buffer(header), "leaf-hashes": Cl.list([]),
        "tx-count": Cl.uint(1), "tx-index": Cl.uint(0),
        amount: Cl.uint(amount), "unlock-burn-height": Cl.uint(unlockHeight),
      })]),
      "staker-unlock-bytes": Cl.buffer(STAKER_UNLOCK_BYTES),
    })),
    Cl.none(),
  ], staker);
}

// Register an sBTC-locked bond. pox-5 records is-l1-lock: false for these,
// which is the case At Stake resolves NO.
export function registerSbtcBond(staker, mgrDeployer, bondIndex, sats) {
  return simnet.callPublicFn(POX, "register-for-bond", [
    Cl.uint(bondIndex), Cl.contractPrincipal(mgrDeployer, SIGNER_MANAGER),
    Cl.uint(100_000_000_000), Cl.error(Cl.uint(sats)), Cl.none(),
  ], staker);
}

export const membershipOf = (deployer, staker) =>
  simnet.callReadOnlyFn(POX, "get-bond-membership", [Cl.principal(staker)], deployer).result;
