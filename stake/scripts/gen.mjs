// gen.mjs
//
// yes-legion.clar is the single source of record. Every other legion contract
// is generated from it, so the two sides can never drift apart in their rules:
//
//   yes-legion.clar        hand-written, MAINNET, argues BONDED
//     -> no-legion.clar          the same rules, arguing IDLE
//     -> yes-legion-sim.clar     simnet only: market principal repointed
//     -> no-legion-sim.clar      both transforms
//
// The -sim builds change exactly one thing: the market they read. There is no
// separate clock, no shrunken window and no mock, so the contract the tests
// exercise is otherwise byte for byte the one that deploys to mainnet, talking
// to the real market source and the real mainnet sBTC.
//
// contracts/elsalvador-stakes-btc-sim.clar is vendored from the stacksbet repo
// and is that market's own simnet build: pox-5 swapped for pox5-sim, which is
// the same pox-5 published under an address the tests hold admin on, and the
// deadline moved inside pox5-sim's bond period 1.
//
// Edit yes-legion.clar, then run:  node scripts/gen.mjs
//
// Every substitution is required to land. A rename in the source that leaves
// one unmatched throws here rather than silently shipping a half-transformed
// build.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const C = (f) => join(here, "..", "contracts", f);

const MARKET = "'SP5Y3W3F78NKFH4HYFNDQMJC484VZWKDH35ZR2M9.elsalvador-stakes-btc";

// Replace every occurrence, and fail loudly if there were none.
function subAll(src, from, to, label) {
  const parts = src.split(from);
  if (parts.length < 2) {
    throw new Error(`gen.mjs: "${label}" matched nothing. Did yes-legion.clar change?`);
  }
  return parts.join(to);
}

// Replace exactly one occurrence, and fail if it is not exactly one.
function subOne(src, from, to, label) {
  const parts = src.split(from);
  if (parts.length !== 2) {
    throw new Error(`gen.mjs: "${label}" matched ${parts.length - 1} times, expected 1.`);
  }
  return parts.join(to);
}

function banner(name, from, what) {
  return `;; ///////////////////////////////////////////////////////////////////////////
;; GENERATED FILE -- DO NOT EDIT BY HAND.
;;
;; ${name}, produced from ${from} by scripts/gen.mjs.
;; ${what}
;;
;; To change anything here, edit yes-legion.clar and re-run the generator.
;; ///////////////////////////////////////////////////////////////////////////

`;
}

// --- yes -> no --------------------------------------------------------------
// The rules are identical. Only the side this legion argues, the settled status
// that means it won, and the field it reads weight out of move.
function toNo(src) {
  let s = src;
  s = subOne(s, ";; yes-legion\n", ";; no-legion\n", "header name");
  s = subOne(s,
    ";;   this side: BONDED. This legion argues YES.",
    ";;   this side: IDLE. This legion argues NO.",
    "header side");
  s = subOne(s,
    ";; is the BONDED shares sitting in your own wallet. You are a member of this\n;; legion exactly to the degree you are long YES, and you stop being one the",
    ";; is the IDLE shares sitting in your own wallet. You are a member of this\n;; legion exactly to the degree you are long NO, and you stop being one the",
    "header weight prose");
  s = subOne(s,
    ";;     holding both sides and this one holds zero IDLE. Never add a",
    ";;     holding both sides and this one holds zero BONDED. Never add a",
    "header merge prose");
  s = subOne(s,
    "(define-constant SIDE u1)          ;; SIDE_BONDED",
    "(define-constant SIDE u0)          ;; SIDE_IDLE", "SIDE");
  s = subOne(s,
    "(define-constant WIN_STATUS u1)    ;; STATUS_BONDED",
    "(define-constant WIN_STATUS u2)    ;; STATUS_IDLE", "WIN_STATUS");
  s = subOne(s,
    '(define-constant SIDE_LABEL "bonded")',
    '(define-constant SIDE_LABEL "idle")', "SIDE_LABEL");
  s = subOne(s,
    "(define-read-only (get-weight (who principal))\n  (get bonded",
    "(define-read-only (get-weight (who principal))\n  (get idle", "get-weight field");
  s = subOne(s,
    "(circ (get bonded-circ (market-snapshot)))",
    "(circ (get idle-circ (market-snapshot)))", "circulating field");
  return s;
}

// --- mainnet -> simnet ------------------------------------------------------
// One substitution: the market is not on chain in simnet, so the reads point at
// its vendored simnet build. Nothing else moves, sBTC included.
function toSim(src) {
  return subAll(src, MARKET, ".elsalvador-stakes-btc-sim", "market principal");
}

const yes = readFileSync(C("yes-legion.clar"), "utf8");
if (yes.includes("GENERATED FILE")) {
  throw new Error("gen.mjs: yes-legion.clar looks generated. It is the source of record.");
}
const no = toNo(yes);

const SIM_NOTE = "Simnet only: the market principal is repointed at elsalvador-stakes-btc-sim. Nothing else differs.";

writeFileSync(C("no-legion.clar"),
  banner("no-legion", "yes-legion.clar", "The same rules, arguing the other side: IDLE, the coins stayed put.") + no);
writeFileSync(C("yes-legion-sim.clar"),
  banner("yes-legion-sim", "yes-legion.clar", SIM_NOTE) + toSim(yes));
writeFileSync(C("no-legion-sim.clar"),
  banner("no-legion-sim", "yes-legion.clar (via no-legion)", SIM_NOTE) + toSim(no));

console.log("generated: no-legion.clar, yes-legion-sim.clar, no-legion-sim.clar");
