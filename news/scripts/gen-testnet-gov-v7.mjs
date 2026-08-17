// gen-testnet-gov-v7.mjs
//
// Generates the TESTNET build of the v7 governance contract from the mainnet
// source, so the two never drift. The ONLY differences between the builds are:
//
//   1. the height clock  -- burn-block-height (mainnet) -> stacks-block-height
//      (testnet), because Bitcoin testnet blocks are ~10 min and erratic, while
//      Nakamoto stacks blocks are seconds-to-a-minute, so a full lifecycle can
//      be walked in ~25 min instead of ~7 hr;
//   2. the three window constants, shrunk to a ~25 min lifecycle;
//   3. the get-timing-mode label, so a deployed instance is unmistakable.
//
// Everything else -- every rule, guard, and payout path -- is copied verbatim.
// Edit news-gov-v7.clar, then re-run:  node scripts/gen-testnet-gov-v7.mjs
//
// SEPARATE FROM gen-testnet-gov-v6.mjs (which targets v6) because each version
// is generated from its own source: that generator requires a VETO_WINDOW constant to substitute and would
// throw against this source. The versions are generated independently on
// purpose, so editing one can never silently reshape another's build.
//
// The testnet gov reuses the mainnet treasury (news-treasury-v7): the pool has
// no timing, so there is nothing to shrink and no second treasury to generate.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, "..", "contracts", "v7", "news-gov-v7.clar");
const OUT = join(here, "..", "contracts", "v7", "news-gov-v7-testnet.clar");
const TRE_SRC = join(here, "..", "contracts", "v7", "news-treasury-v7.clar");
const TRE_OUT = join(here, "..", "contracts", "v7", "news-treasury-v7-testnet.clar");
const MAINNET_SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const TESTNET_SBTC = "ST2VN1G6EBXPMMAJKCSY1HR50YQCVFSK68KKP9SKW.sbtc-token";
const MAIN_GOV_OUT = join(here, "..", "contracts", "v7", "mainnet", "news-gov.clar");
const MAIN_TRE_OUT = join(here, "..", "contracts", "v7", "mainnet", "news-treasury.clar");

// Identical to the v6 testnet windows, so a v6/v7 testnet comparison is
// like-for-like and only the membership floor differs. At the ~35-40s per stacks block the
// earlier runs implied, this is roughly ~17 min to settle and ~24 min full.
// Block counts are exact; wall-clock rides testnet's real cadence. If yours
// differs, change these three numbers and re-run; nothing else moves.
//   delay 4 + vote 24 (~17 min to settle) + conclude 12 = 40 blocks (~24 min full)
const TESTNET = {
  VOTE_DELAY: 4,
  VOTE_WINDOW: 24,
  CONCLUDE_WINDOW: 12,
  GLOBAL_PROPOSE_INTERVAL: 1,
};

const BANNER = `;; ///////////////////////////////////////////////////////////////////////////
;; GENERATED FILE -- DO NOT EDIT BY HAND.
;;
;; This is the TESTNET build, produced from news-gov-v7.clar by
;; scripts/gen-testnet-gov-v7.mjs. It counts STACKS blocks (get-timing-mode
;; returns "TEST-STACKS-BLOCKS") with a short lifecycle (~25 min at observed
;; testnet cadence), for fast iteration. It is NOT mainnet-safe: the
;; tamper-resistant burn-block clock is deliberately traded for speed. The prose
;; comments below still describe the mainnet (burn-block) design; only the three
;; window constants, the height clock, and the timing label differ.
;;
;; To change anything, edit news-gov-v7.clar and re-run the generator.
;; ///////////////////////////////////////////////////////////////////////////

`;

let src = readFileSync(SRC, "utf8");

// A small helper that requires each substitution to actually land, so a rename
// in the source can never silently produce a stale or half-transformed build.
function sub(text, pattern, replacement, label) {
  // Check the pattern MATCHES, not that the text changed: an unchanged value
  // (e.g. PROPOSE_INTERVAL staying u1) is a legitimate no-op, not a miss.
  if (!pattern.test(text)) {
    throw new Error(`gen-testnet-v7: substitution "${label}" matched nothing; the source contract may have changed shape.`);
  }
  return text.replace(pattern, replacement);
}

// 0. The veto must be gone. If a VETO_ constant ever reappears in the source,
// this generator's window list is incomplete and the build would be wrong.
if (/\(define-constant VETO_/.test(src)) {
  throw new Error("gen-testnet-v7: source declares a VETO_ constant; v6 removed the veto and v7 kept it removed, so this generator no longer matches it.");
}

// 1. The height clock.
if (!src.includes("burn-block-height")) {
  throw new Error("gen-testnet-v7: source has no burn-block-height; nothing to convert.");
}
src = src.replaceAll("burn-block-height", "stacks-block-height");

// 2. The three window constants (plus the propose interval).
for (const [name, value] of Object.entries(TESTNET)) {
  src = sub(
    src,
    new RegExp(`\\(define-constant ${name} u\\d+\\)`),
    `(define-constant ${name} u${value})`,
    name,
  );
}

// 3. The timing-mode label. Target the FUNCTION BODY specifically, not the
// first "PROD-BURN" in the file (which is a comment). The comments deliberately
// name both modes, so they read correctly in either build and are left as-is.
src = sub(
  src,
  /(\(define-read-only \(get-timing-mode\)\s*\n\s*)"PROD-BURN"/,
  '$1"TEST-STACKS-BLOCKS"',
  "timing-mode",
);

// 4. The testnet gov calls the testnet treasury.
src = src.replaceAll(".news-treasury-v7", ".news-treasury-v7-testnet");

writeFileSync(OUT, BANNER + src);

// The testnet treasury: the mainnet source with the mock sBTC swapped in.
let tre = readFileSync(TRE_SRC, "utf8");
if (!tre.includes(MAINNET_SBTC)) {
  throw new Error("gen-testnet-v7: treasury source has no mainnet sBTC; nothing to swap.");
}
tre = tre.replaceAll(MAINNET_SBTC, TESTNET_SBTC)
  .replace(";; news-treasury-v7", ";; news-treasury-v7-testnet")
  .replace(";; Mainnet sBTC. The -testnet build swaps this for the mock token.",
           ";; Mock sBTC on testnet. Generated from news-treasury-v7.clar.");
writeFileSync(TRE_OUT, tre);
console.log(`Wrote ${TRE_OUT}`);

// The clean-named mainnet build: same real-sBTC sources, deployed as news-gov /
// news-treasury. Only the gov's treasury reference is rewritten to match.
const mainGov = readFileSync(SRC, "utf8").replaceAll(".news-treasury-v7", ".news-treasury");
const mainTre = readFileSync(TRE_SRC, "utf8")
  .replace(/;; news-treasury-v7\n;;\n;; Behaviour is byte-for-byte v6's\. It is redeployed only because `set-gov` is\n;; one-time, so a new gov contract needs a new treasury to wire itself into\.\n/, ";; news-treasury\n")
  .replace(";; Mainnet sBTC. The -testnet build swaps this for the mock token.", ";; sBTC token");
writeFileSync(MAIN_GOV_OUT, mainGov);
writeFileSync(MAIN_TRE_OUT, mainTre);
console.log(`Wrote ${MAIN_GOV_OUT}\n       ${MAIN_TRE_OUT}`);
console.log(
  `Wrote ${OUT}\n  windows: delay ${TESTNET.VOTE_DELAY} / vote ${TESTNET.VOTE_WINDOW} / conclude ${TESTNET.CONCLUDE_WINDOW} / interval ${TESTNET.GLOBAL_PROPOSE_INTERVAL} (stacks blocks)`,
);
