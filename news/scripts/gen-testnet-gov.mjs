// gen-testnet-gov.mjs
//
// Generates the TESTNET build of the news governance contract from the mainnet
// source, so the two never drift. The ONLY differences between the builds are:
//
//   1. the height clock  -- burn-block-height (mainnet) -> stacks-block-height
//      (testnet), because Bitcoin testnet blocks are ~10 min and erratic, while
//      Nakamoto stacks blocks are seconds-to-a-minute, so a full lifecycle can
//      be walked in ~30 min instead of ~8 hr;
//   2. the four window constants, shrunk to a ~30 min lifecycle;
//   3. the get-timing-mode label, so a deployed instance is unmistakable.
//
// Everything else -- every rule, guard, and payout path -- is copied verbatim.
// Edit news-gov-v4.clar, then re-run:  node scripts/gen-testnet-gov.mjs
//
// The testnet gov reuses the mainnet treasury (news-treasury-v4): the pool has
// no timing, so there is nothing to shrink and no second treasury to generate.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, "..", "contracts", "news-gov-v4.clar");
const OUT = join(here, "..", "contracts", "news-gov-v4-testnet.clar");

// Deliberately shorter than v3's 36/12/48, which TESTNET.md measured at a bit
// over 30 min. At the ~35-40s per stacks block those v3 runs implied, this is
// roughly ~19 min to settle and ~26 min full. Block counts are exact; wall-clock
// rides testnet's real cadence. If yours differs, change these four numbers and
// re-run; nothing else moves.
//   vote 24 + veto 6 (~19 min to settle) + conclude 12 = 42 blocks (~26 min full)
const TESTNET = {
  VOTING_DELAY: 4,
  VOTE_WINDOW: 24,
  VETO_WINDOW: 6,
  CONCLUDE_WINDOW: 12,
  PROPOSE_INTERVAL: 1,
};

const BANNER = `;; ///////////////////////////////////////////////////////////////////////////
;; GENERATED FILE -- DO NOT EDIT BY HAND.
;;
;; This is the TESTNET build, produced from news-gov-v4.clar by
;; scripts/gen-testnet-gov.mjs. It counts STACKS blocks (get-timing-mode returns
;; "TEST-STACKS-BLOCKS") with a short lifecycle (~20-30 min at observed testnet
;; cadence), for fast iteration. It is NOT
;; mainnet-safe: the tamper-resistant burn-block clock is deliberately traded for
;; speed. The prose comments below still describe the mainnet (burn-block) design;
;; only the four window constants, the height clock, and the timing label differ.
;;
;; To change anything, edit news-gov-v4.clar and re-run the generator.
;; ///////////////////////////////////////////////////////////////////////////

`;

let src = readFileSync(SRC, "utf8");

// A small helper that requires each substitution to actually land, so a rename
// in the source can never silently produce a stale or half-transformed build.
function sub(text, pattern, replacement, label) {
  // Check the pattern MATCHES, not that the text changed: an unchanged value
  // (e.g. PROPOSE_INTERVAL staying u1) is a legitimate no-op, not a miss.
  if (!pattern.test(text)) {
    throw new Error(`gen-testnet: substitution "${label}" matched nothing; the source contract may have changed shape.`);
  }
  return text.replace(pattern, replacement);
}

// 1. The height clock, everywhere it is read.
if (!src.includes("burn-block-height")) {
  throw new Error("gen-testnet: source has no burn-block-height; nothing to convert.");
}
src = src.replaceAll("burn-block-height", "stacks-block-height");

// 2. The four window constants.
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

writeFileSync(OUT, BANNER + src);
console.log(
  `Wrote ${OUT}\n  windows: delay ${TESTNET.VOTING_DELAY} / vote ${TESTNET.VOTE_WINDOW} / veto ${TESTNET.VETO_WINDOW} / conclude ${TESTNET.CONCLUDE_WINDOW} / interval ${TESTNET.PROPOSE_INTERVAL} (stacks blocks)`,
);
