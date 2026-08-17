// gen-testnet-gov-v6.mjs
//
// Generates the TESTNET build of the v6 governance contract from the mainnet
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
// Edit news-gov-v6.clar, then re-run:  node scripts/gen-testnet-gov-v6.mjs
//
// SEPARATE FROM gen-testnet-gov.mjs (which targets v5) because v6 deleted the
// veto: that generator requires a VETO_WINDOW constant to substitute and would
// throw against this source. The two versions are generated independently on
// purpose, so editing one can never silently reshape the other's build.
//
// The testnet gov reuses the mainnet treasury (news-treasury-v6): the pool has
// no timing, so there is nothing to shrink and no second treasury to generate.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, "..", "contracts", "v6", "news-gov-v6.clar");
const OUT = join(here, "..", "contracts", "v6", "news-gov-v6-testnet.clar");

// Mirrors the v5 testnet windows with the veto's 6 blocks removed, so a v5/v6
// testnet comparison is like-for-like. At the ~35-40s per stacks block the
// earlier runs implied, this is roughly ~17 min to settle and ~24 min full.
// Block counts are exact; wall-clock rides testnet's real cadence. If yours
// differs, change these three numbers and re-run; nothing else moves.
//   delay 4 + vote 24 (~17 min to settle) + conclude 12 = 40 blocks (~24 min full)
const TESTNET = {
  VOTING_DELAY: 4,
  VOTE_WINDOW: 24,
  CONCLUDE_WINDOW: 12,
  PROPOSE_INTERVAL: 1,
};

const BANNER = `;; ///////////////////////////////////////////////////////////////////////////
;; GENERATED FILE -- DO NOT EDIT BY HAND.
;;
;; This is the TESTNET build, produced from news-gov-v6.clar by
;; scripts/gen-testnet-gov-v6.mjs. It counts STACKS blocks (get-timing-mode
;; returns "TEST-STACKS-BLOCKS") with a short lifecycle (~25 min at observed
;; testnet cadence), for fast iteration. It is NOT mainnet-safe: the
;; tamper-resistant burn-block clock is deliberately traded for speed. The prose
;; comments below still describe the mainnet (burn-block) design; only the three
;; window constants, the height clock, and the timing label differ.
;;
;; To change anything, edit news-gov-v6.clar and re-run the generator.
;; ///////////////////////////////////////////////////////////////////////////

`;

let src = readFileSync(SRC, "utf8");

// A small helper that requires each substitution to actually land, so a rename
// in the source can never silently produce a stale or half-transformed build.
function sub(text, pattern, replacement, label) {
  // Check the pattern MATCHES, not that the text changed: an unchanged value
  // (e.g. PROPOSE_INTERVAL staying u1) is a legitimate no-op, not a miss.
  if (!pattern.test(text)) {
    throw new Error(`gen-testnet-v6: substitution "${label}" matched nothing; the source contract may have changed shape.`);
  }
  return text.replace(pattern, replacement);
}

// 0. The veto must be gone. If a VETO_ constant ever reappears in the source,
// this generator's window list is incomplete and the build would be wrong.
if (/\(define-constant VETO_/.test(src)) {
  throw new Error("gen-testnet-v6: source declares a VETO_ constant; v6 removed the veto, so this generator no longer matches it.");
}

// 1. The height clock.
if (!src.includes("burn-block-height")) {
  throw new Error("gen-testnet-v6: source has no burn-block-height; nothing to convert.");
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

writeFileSync(OUT, BANNER + src);
console.log(
  `Wrote ${OUT}\n  windows: delay ${TESTNET.VOTING_DELAY} / vote ${TESTNET.VOTE_WINDOW} / conclude ${TESTNET.CONCLUDE_WINDOW} / interval ${TESTNET.PROPOSE_INTERVAL} (stacks blocks)`,
);
