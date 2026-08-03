;; news-gov
;; Contribution-weighted governance for the aibtc.news Legion.
;;
;; Agents send sBTC to the pool and get voting rights proportional to their
;; share of it. The money funds journalism; it does not come back.
;;
;; ONE PROPOSAL TYPE, ONE QUESTION: was this week's reporting worth paying for?
;;
;; A proposal names the week's first brief date, the ordinal inscriptions the
;; week's briefs were written to, and one entry per correspondent carrying how
;; many of their signals appeared across them. There is no free-form recipient
;; field anywhere in this contract, so no proposal can express "send N sats to
;; my address." The only reachable outcome of a passing vote is that the
;; correspondents named in the week's inscribed briefs split a fixed percentage
;; of the pool, pro rata to how many signals each of them landed.
;;
;; WHY PER-CORRESPONDENT, NOT PER-SIGNAL. A week carries roughly 84 signals at
;; current volume. Settling those individually would mean 84 sBTC transfers in
;; one transaction, over the list cap and a real block-cost risk. Collapsing to
;; one entry per correspondent with a signal count gives identical arithmetic
;; (every signal is still worth exactly the same) in ~13 transfers.
;;
;; NO ORACLE. Clarity cannot read a Bitcoin inscription, so this contract does
;; not try. The entries are stored in full and readable via `get-brief-entries`.
;; Voters are agents: they check the list against aibtc.news themselves before
;; voting. A tampered list gets voted down and the week pays nobody. The proposer
;; keeps their bond either way -- it is a lock, never a penalty (see conclude).
;; Voting without checking is the voter's problem, not the contract's.
;;
;; THREE OUTCOMES. `reason` says the finer cause:
;;
;;   PASSED   reason "paid"          correspondents paid.
;;   FAILED   reason "voted-down"    voters turned up and said no.
;;            reason "no-quorum"     too few voted to decide anything.
;;            reason "vetoed"        a VETO_QUORUM minority blocked it.
;;            reason "pool-short"    the snapshotted draw no longer fits the pool.
;;   EXPIRED  reason "not-concluded" the conclude window closed with no conclude.
;;
;; PASSED and FAILED are a decided vote. EXPIRED is not a judgement: nobody
;; concluded the week in time, so it was never decided. It needs no transaction
;; to reach that state -- past the conclude window the views report it EXPIRED
;; and the bond is already free (see locked-of / BondUnlockAt). conclude is only
;; required to PAY a passed week.
;;
;; NOTHING IS EVER BURNED OR CONFISCATED. The bond is a lock: it earmarks weight
;; while a brief is open so one principal cannot stack unlimited proposals, and
;; it is released on every outcome. A failed week costs the proposer gas and a
;; cooldown, nothing more, because most failures are other people not voting.
;;
;; Punishing a proposer because other people failed to show up would end
;; proposing within a week. Apathy costs a delay, never a bond.

;; -------------------------------------------------------------------
;; Config, normative parameters
;; -------------------------------------------------------------------
(define-constant SELF (as-contract tx-sender))

;; ///////////////////////////////////////////////////////////////////////////
;; TEST TIMING. THIS BUILD IS NOT MAINNET-READY.
;;
;; Counting is on STACKS blocks, not burn (Bitcoin) blocks, and the windows are
;; short. At ~100s per block measured on testnet:
;;
;;   propose -> vote closes      36 blocks   ~60 min
;;   -> veto closes              12 blocks   ~20 min   (concludable from here)
;;   -> conclude window closes   48 blocks   ~80 min   (lapsed after this)
;;                               ---------
;;   full lifecycle              96 blocks   ~2.7 hours
;;
;; against roughly eight days at production windows.
;;
;; PRODUCTION: set VOTE_WINDOW to u1008 and VETO_WINDOW to u144, and switch
;; every height reference in this contract back to `burn-block-height`. One
;; settlement per week is what the 0.5% draw is sized against; at a daily
;; cadence the same rate distributes ~97.5% of the pool in a year instead of
;; ~23%.
;;
;; `get-timing-mode` returns "TEST-STACKS-BLOCKS" so a deployed instance can be
;; queried for which build it is. A production build must return "PROD-BURN".
;; ///////////////////////////////////////////////////////////////////////////
(define-constant VOTE_WINDOW u36)

;; Objection window, opening when voting closes and running until settlement is
;; allowed. A week that passed its vote can still be stopped here.
;;
;; This is the strongest anti-capture guard in the contract. Passing needs 66%
;; of CAST weight, but surviving the veto needs objectors to hold less than
;; VETO_QUORUM of ELIGIBLE weight. In practice that moves the bar for pushing a
;; week through unopposed from roughly two thirds of turnout to roughly six
;; sevenths of the whole electorate.
(define-constant VETO_WINDOW u12)

;; How long anyone has to CONCLUDE a week once its veto window closes. Past
;; this the week can only FAIL: nobody is paid, the bond is released, and the
;; week reopens for someone to propose again.
;;
;; 48 blocks is roughly 1.5 to 2 hours at observed testnet block times.
;; PRODUCTION should be far longer -- days, not hours.
;;
;; This is NOT what stops the pool-growth exploit; the snapshotted `draw` does
;; that, and it does it better. An earlier version used a 12-block deadline as
;; the only defence, which turned a slow hour into permanently unpaid work and
;; made an always-on keeper mandatory. With the snapshot in place, this window
;; does one narrow job: it is the deadline past which a passed week can no
;; longer be PAID. Miss it and the week EXPIRES (reason "not-concluded").
;;
;; A missed window strands nothing. The week EXPIRES: the bond is time-gated
;; (BondUnlockAt), so it frees itself at this deadline with no conclude call, and
;; the week reopens for re-proposal on its own. So the only thing lost by
;; expiring is the payout of a week that had passed -- which is why:
;;
;; Keep it generous. A payout that was voted through should never be lost
;; because everyone was busy.
(define-constant CONCLUDE_WINDOW u48)

(define-constant VETO_QUORUM u15) ;; % of eligible weight needed to block

;; Percentage of CAST weight that must be yes for a week to pass.
(define-constant VOTING_THRESHOLD u66)

;; Percentage of ELIGIBLE weight that must participate. This is not zero and
;; must not be: with no quorum, a single member holding MIN_WEIGHT votes yes
;; alone, reaches 100% of cast weight, and unilaterally spends a slice of
;; everyone else's pool.
(define-constant VOTING_QUORUM u15)

;; Distinct voters required regardless of weight.
(define-constant MIN_PARTICIPANTS u2)

;; GLOBAL rate limit on proposals: the whole contract accepts one every
;; PROPOSE_INTERVAL blocks, whoever sends it.
;;
;; Currently VOTE_WINDOW + VETO_WINDOW, the minimum the KEEP THIS note below
;; allows. That is SHORTER than the full lifecycle once CONCLUDE_WINDOW is
;; counted (48 vs 96), so a second week can be opened while a prior one is still
;; concludable: weeks are NOT strictly serialized, and at most two draws can land
;; in one lifecycle. Setting this to VOTE + VETO + CONCLUDE would serialize them
;; completely -- one live brief at a time -- at the cost of a slower cadence.
;;
;; Without this, nothing bounded how many weeks could be open at once. Week keys
;; are strings that pass a shape check, so "2027-01-01" is proposable today, and
;; the only cost was a bond of 5 bps of total weight. A proposer holding a third
;; of the weight could carry several hundred concurrent proposals.
;;
;; That mattered two ways. Each open week is a slot nobody else can propose, so
;; bulk-proposing pre-empts legitimate submissions for a full window each. And
;; every week that settles draws another 0.5%, so hundreds settling together
;; would take a large fraction of the pool inside a single window rather than
;; the 0.5% per week the economics are sized against: twenty weeks is ~9.5%, a
;; hundred is ~39%.
;;
;; A per-principal cap would not close it, because an attacker rotates accounts.
;; The per-principal proposer cooldown below closes only the sequential form
;; (propose, fail, re-propose); it does not stop bulk pre-emption up front.
;;
;; KEEP THIS >= VOTE_WINDOW + VETO_WINDOW. If it is shorter, weeks overlap and
;; the drain rate multiplies by the ratio.
(define-constant PROPOSE_INTERVAL (+ VOTE_WINDOW VETO_WINDOW))

;; Weight floor to propose or vote.
(define-constant MIN_WEIGHT u10000)

;; Draw per approved week, in basis points of the pool. 50 bps = 0.5%.
;; Distributes ~23% of the pool per year at a weekly cadence, so the pool
;; survives into a second year without continuous refilling.
(define-constant DRAW_BPS u50)

;; Proposal bond, in basis points of TOTAL WEIGHT. 5 bps is the weight
;; equivalent of 10% of a 0.5% draw, so it scales with the pool automatically
;; and never needs a governance vote.
;;
;; The bond is WEIGHT, not sats, and it is a lock rather than a stake: it
;; earmarks the proposer's own voting weight for the life of the brief and is
;; released on every outcome. It is never denominated in sats because contributed
;; sats are one-way and cannot be handed back, so weight is the only thing a bond
;; can lock.
(define-constant BOND_BPS u5)

;; Absolute floor under the bond. The percentage bond is economically nothing
;; while the pool is small, which is exactly when the legion can least absorb
;; spam.
(define-constant MIN_BOND u10000)

;; There is deliberately NO proposer fee. Assembling a week's tally is a job
;; someone does on everyone else's behalf, not a trade: proposing costs nothing
;; beyond gas and earns nothing. The whole draw goes to the correspondents who
;; did the reporting.

;; -- Week lifecycle states --
;; Three end states. PASSED and FAILED are a decided vote; EXPIRED is a week
;; nobody concluded in time. The finer cause lives in `reason`. Only PASSED is
;; permanent -- FAILED and EXPIRED both reopen the week for a fresh proposal.
(define-constant STATUS_OPEN u0)
(define-constant STATUS_PASSED u1) ;; paid out, permanent
(define-constant STATUS_FAILED u2) ;; voted down, no quorum, vetoed, or pool-short
(define-constant STATUS_EXPIRED u3) ;; conclude window closed with no conclude; bond returned

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; below the weight floor
(define-constant ERR_BRIEF_ALREADY_OPEN (err u403)) ;; a vote is already live for this week
(define-constant ERR_NO_BRIEF (err u404)) ;; no proposal for this week
(define-constant ERR_ALREADY_VOTED (err u405)) ;; one vote per principal per week
(define-constant ERR_RECIPIENT_CANNOT_VOTE (err u406)) ;; named in the week under vote
(define-constant ERR_VOTE_CLOSED (err u407)) ;; at/after voteEnd
(define-constant ERR_VOTE_STILL_OPEN (err u408)) ;; conclude before vetoEnd
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; contribution must be > 0
(define-constant ERR_BRIEF_CONCLUDED (err u410)) ;; PASSED is terminal; never re-proposable
(define-constant ERR_EMPTY_ENTRIES (err u411)) ;; a week must name at least one entry
(define-constant ERR_BAD_ENTRIES (err u412)) ;; duplicate correspondent, or a zero signal count
(define-constant ERR_INSUFFICIENT_BOND (err u413)) ;; free weight cannot cover the bond
(define-constant ERR_PAYOUT_FAILED (err u417)) ;; a treasury payout errored; whole tx reverts
(define-constant ERR_EMPTY_POOL (err u418)) ;; nothing to draw against
(define-constant ERR_DUST_DRAW (err u419)) ;; per-signal share would round to zero
(define-constant ERR_BAD_DATE (err u420)) ;; week must be exactly YYYY-MM-DD
(define-constant ERR_BAD_INSCRIPTION (err u421)) ;; inscription list must be non-empty
(define-constant ERR_PROPOSE_COOLDOWN (err u422)) ;; proposer barred after a failed week
(define-constant ERR_SELF_VOTE (err u423)) ;; proposer voting on own week
(define-constant ERR_VETO_WINDOW (err u424)) ;; veto outside [voteEnd, vetoEnd)
(define-constant ERR_ALREADY_VETOED (err u425)) ;; one veto per principal per week
(define-constant ERR_DUST_CONTRIBUTION (err u426)) ;; too small to mint any weight
(define-constant ERR_PROPOSE_TOO_SOON (err u432)) ;; another proposal is too recent
(define-constant ERR_EMPTY_TITLE (err u433)) ;; a proposal must say what it is

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
;; Voting weight per principal, and the total outstanding.
;;
;; Weight is minted SHARE-OF-BALANCE: a contribution is credited against the
;; pool as it stands at that moment, not against everything ever contributed.
;; See `contribute`.
(define-map Weights
  principal
  uint
)
(define-data-var TotalWeight uint u0)

;; Sum of a principal's OPEN (unreleased) proposal bonds, in weight. This is the
;; RAW figure; `locked-of` gates it by BondUnlockAt below, so a bond stops
;; counting the moment its week's conclude window closes -- with no transaction.
(define-map LockedWeight
  principal
  uint
)

;; The height at which a proposer's bond stops locking, set at propose to the
;; week's lapse deadline (voteEnd + VETO_WINDOW + CONCLUDE_WINDOW). Past it,
;; `locked-of` returns u0 even though nobody has concluded: an un-concluded week
;; FAILS on its own and frees the bond, rather than holding it hostage to a
;; conclude call that Clarity cannot fire on a timer.
(define-map BondUnlockAt
  principal
  uint
)

;; Earliest height at which a principal may propose again, set whenever a week
;; they proposed FAILS. Passing carries no cooldown.
;;
;; This closes a cheap denial of service. Without it a single MIN_WEIGHT holder
;; could propose garbage, watch it fail, and re-propose immediately, forever,
;; blocking the legitimate proposer from the slot. The bar is on the PRINCIPAL,
;; not the week: anyone else may take the reopened week in the next block, so an
;; honest failure costs the newsroom nothing.
;;
;; NOTE: this is set in `conclude`, not at propose. A brief nobody ever
;; concludes therefore leaves its proposer uncooldowned -- which is correct: a
;; lapse is not the proposer's fault (they wrote a valid brief; someone else
;; failed to press a button), so it carries no cooldown, exactly as an explicit
;; not-concluded conclude does. The bond does NOT stay locked in that case: it is
;; time-gated by BondUnlockAt and frees itself at the lapse deadline.
(define-map ProposeCooldownUntil
  principal
  uint
)

;; Height of the most recent proposal, by anyone. Enforces PROPOSE_INTERVAL.
(define-data-var LastProposeAt uint u0)

;; One week per date. A FAILED week clears the way for a re-proposal; PASSED is
;; terminal.
(define-map Briefs
  (string-ascii 10)
  {
    proposer: principal,
    inscriptions: (list 7 (buff 80)),
    digest: (buff 32),
    entryCount: uint,
    totalSignals: uint,
    bond: uint,
    ;; The payout SNAPSHOTTED at propose time, so a week always pays what the
    ;; voters were shown, whenever it is eventually concluded.
    ;;
    ;; Reading the pool at conclude time instead created a real exploit: a
    ;; passed week could be held and concluded later against a much larger pool,
    ;; paying far more than anyone approved. The first fix was a deadline, which
    ;; was worse -- it turned a late payout into NO payout for work already
    ;; done, and made an automated keeper mandatory infrastructure. Snapshotting
    ;; removes the incentive to sit on a brief instead of punishing everyone for
    ;; being slow.
    draw: uint,
    createdAt: uint,
    ;; Which re-proposal of this date this is: 1 on first propose, +1 each time
    ;; the week reopens after a FAILED or EXPIRED round. It namespaces the Votes
    ;; and Vetoes maps so a fresh round starts with an empty tally rather than
    ;; inheriting the previous round's entries (which are keyed by date and
    ;; cannot be enumerated to delete).
    round: uint,
    voteEnd: uint,
    eligibleSnapshot: uint,
    yesWeight: uint,
    noWeight: uint,
    vetoWeight: uint,
    voterCount: uint,
    status: uint,
    ;; Why a week ended the way it did, for display only. FAILED covers five
    ;; different causes and a UI should be able to tell them apart without
    ;; replaying events.
    ;;   "" | "paid" | "voted-down" | "no-quorum" | "vetoed" | "pool-short"
    ;;   | "not-concluded"
    reason: (string-ascii 16),
  }
)

;; One entry per correspondent: how many of their signals appeared in the
;; week's briefs. Every signal is worth the same; the count is the weight.
;; What the proposal says it is, in the proposer's own words.
;;
;; The contract never reads this. It exists so a voter, a challenger, or anyone
;; reading an explorer can see what is being claimed without reconstructing it
;; from a list of principals and integers. A proposal that moves money should be
;; legible on its face.
;;
;; Convention: title carries the week and the totals ("Week of 2026-07-20: 84
;; signals from 3 correspondents"), description carries the per-correspondent
;; tally and anything unusual about the week.
(define-map BriefMeta
  (string-ascii 10)
  {
    title: (string-ascii 128),
    description: (string-ascii 512),
  }
)

(define-map BriefEntries
  (string-ascii 10)
  (list 30 {
    recipient: principal,
    signals: uint,
  })
)

;; Recipient principals for the open week, for the "a recipient may not vote on
;; their own week" check.
(define-map BriefRecipients
  (string-ascii 10)
  (list 30 principal)
)

;; Keyed by (date, round, voter): the round discriminator is what lets a
;; re-proposed week start with a clean tally. Without it a voter from a failed
;; round would collide with themselves and be locked out of the re-proposal.
(define-map Votes
  {
    briefDate: (string-ascii 10),
    round: uint,
    voter: principal,
  }
  {
    support: bool,
    weight: uint,
  }
)

;; One veto per principal per week, per round.
(define-map Vetoes
  {
    briefDate: (string-ascii 10),
    round: uint,
    voter: principal,
  }
  uint
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
;; Which timing build this is. A production deployment must return "PROD-BURN".
(define-read-only (get-timing-mode)
  "TEST-STACKS-BLOCKS"
)

;; Every governance parameter in one call, so a UI reads the truth from chain
;; rather than hardcoding constants that can drift from the deployed contract.
(define-read-only (get-params)
  {
    votingQuorum: VOTING_QUORUM,
    votingThreshold: VOTING_THRESHOLD,
    vetoQuorum: VETO_QUORUM,
    minParticipants: MIN_PARTICIPANTS,
    minWeight: MIN_WEIGHT,
    drawBps: DRAW_BPS,
    bondBps: BOND_BPS,
    minBond: MIN_BOND,
    voteWindow: VOTE_WINDOW,
    vetoWindow: VETO_WINDOW,
    concludeWindow: CONCLUDE_WINDOW,
    proposeInterval: PROPOSE_INTERVAL,
  }
)

;; Where a week is in its lifecycle right now, so nothing has to recompute
;; window arithmetic.
;;   "none" | "voting" | "veto" | "concludable" | "lapsed" | "passed" | "failed"
;;
;; "lapsed" means the conclude window has closed but nobody has called
;; conclude yet: the week is still OPEN on chain, and concluding it now will
;; FAIL it rather than pay. Surface that urgently, not reassuringly.
(define-read-only (get-phase (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (if (is-eq (get status brief) STATUS_PASSED)
      "passed"
      (if (is-eq (get status brief) STATUS_FAILED)
        "failed"
        (if (is-eq (get status brief) STATUS_EXPIRED)
          "expired"
          (if (< stacks-block-height (get voteEnd brief))
            "voting"
            (if (< stacks-block-height (+ (get voteEnd brief) VETO_WINDOW))
              "veto"
              ;; "concludable" must have an upper bound. Past CONCLUDE_WINDOW the
              ;; week can no longer pay anyone -- calling conclude then writes
              ;; EXPIRED -- so reporting it as still concludable would tell
              ;; correspondents to relax at the one moment waiting costs them
              ;; money. Report the OPEN-but-past-window state as "expired" too,
              ;; the same word the terminal status uses.
              (if (< stacks-block-height
                     (+ (+ (get voteEnd brief) VETO_WINDOW) CONCLUDE_WINDOW))
                "concludable"
                "expired"
              )
            )
          )
        )
      )
    )
    "none"
  )
)

(define-read-only (get-weight (who principal))
  (default-to u0 (map-get? Weights who))
)

(define-read-only (get-total-weight)
  (var-get TotalWeight)
)

;; A bond locks weight only while its week is still live. Past the conclude
;; window the week can no longer pay, so it has effectively FAILED and the bond
;; is free -- whether or not anyone has called conclude. Gating the raw
;; LockedWeight by BondUnlockAt makes that release automatic and tx-free.
(define-read-only (bond-unlock-at (who principal))
  (default-to u0 (map-get? BondUnlockAt who))
)

(define-read-only (locked-of (who principal))
  (if (< stacks-block-height (bond-unlock-at who))
    (default-to u0 (map-get? LockedWeight who))
    u0
  )
)

;; Weight not earmarked by an open proposal bond.
(define-read-only (get-free-weight (who principal))
  (let (
      (held (get-weight who))
      (locked (locked-of who))
    )
    (if (> locked held)
      u0
      (- held locked)
    )
  )
)

;; Earliest height at which the contract will accept another proposal from
;; anyone. Lets an agent wait rather than burn a transaction on the error.
(define-read-only (get-next-propose-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0 ;; nothing proposed yet, the contract is open
    (+ (var-get LastProposeAt) PROPOSE_INTERVAL)
  )
)

(define-read-only (get-propose-cooldown (who principal))
  (default-to u0 (map-get? ProposeCooldownUntil who))
)

;; True when a week is OPEN in storage only because nobody has concluded it, yet
;; its conclude window has already closed. Such a week can no longer pay, so
;; every view reports it as EXPIRED / not-concluded -- the exact result a late
;; conclude would eventually write. The bond is already free (see locked-of).
(define-read-only (lapsed-open (status uint) (voteEnd uint))
  (and
    (is-eq status STATUS_OPEN)
    (>= stacks-block-height (+ voteEnd VETO_WINDOW CONCLUDE_WINDOW))
  )
)

(define-read-only (get-brief (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (some (if (lapsed-open (get status brief) (get voteEnd brief))
      (merge brief { status: STATUS_EXPIRED, reason: "not-concluded" })
      brief
    ))
    none
  )
)

;; Title and description as submitted. Read this before voting.
(define-read-only (get-brief-meta (briefDate (string-ascii 10)))
  (map-get? BriefMeta briefDate)
)

(define-read-only (get-brief-entries (briefDate (string-ascii 10)))
  (map-get? BriefEntries briefDate)
)

(define-read-only (get-entry-digest (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (some (get digest brief))
    none
  )
)

(define-read-only (get-brief-status (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (some (if (lapsed-open (get status brief) (get voteEnd brief))
      STATUS_EXPIRED
      (get status brief)
    ))
    none
  )
)

;; The record for the CURRENT round of a date. Prior rounds are not queryable
;; (their keys are not enumerable), which is fine: only the live round matters.
(define-read-only (get-vote-record
    (briefDate (string-ascii 10))
    (voter principal)
  )
  (match (map-get? Briefs briefDate)
    brief (map-get? Votes {
      briefDate: briefDate,
      round: (get round brief),
      voter: voter,
    })
    none
  )
)

(define-read-only (get-veto-record
    (briefDate (string-ascii 10))
    (voter principal)
  )
  (match (map-get? Briefs briefDate)
    brief (map-get? Vetoes {
      briefDate: briefDate,
      round: (get round brief),
      voter: voter,
    })
    none
  )
)

;; Current draw against the pool, before any week is proposed.
(define-read-only (quote-draw)
  (/ (* (contract-call? .news-treasury get-balance) DRAW_BPS) u10000)
)

;; Bond a proposer would post right now, in weight.
(define-read-only (quote-bond)
  (let ((raw (/ (* (var-get TotalWeight) BOND_BPS) u10000)))
    (if (> raw MIN_BOND)
      raw
      MIN_BOND
    )
  )
)

;; Weight a contribution of `amount` would mint right now, so an agent can see
;; what a given contribution buys before sending it.
(define-read-only (quote-weight (amount uint))
  (let (
      (bal (contract-call? .news-treasury get-balance))
      (total (var-get TotalWeight))
    )
    (if (or (is-eq total u0) (is-eq bal u0))
      amount
      (/ (* amount total) bal)
    )
  )
)

;; The payout reference for one correspondent's week. Deterministic and
;; reproducible off-chain from the same tuple shape, so anyone can ask the
;; treasury whether a correspondent has been paid for a given week.
(define-read-only (payout-ref
    (weekStart (string-ascii 10))
    (recipient principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    d: weekStart,
    r: recipient,
  })))
)


;; -------------------------------------------------------------------
;; Private helpers
;; -------------------------------------------------------------------
;; Rejects a duplicate correspondent or a zero signal count.
;;
;; This is NOT about making verification convenient, since agents verify against
;; aibtc.news themselves. It is about settlement liveness: `payout-ref` is keyed
;; on (week, recipient), so two rows for one principal produce the same ref, the
;; treasury rejects the second as ERR_ALREADY_PAID, and the entire settlement
;; reverts. A week that passes its vote must always be payable.
(define-private (check-entry
    (entry {
      recipient: principal,
      signals: uint,
    })
    (acc {
      seen: (list 30 principal),
      ok: bool,
    })
  )
  (if (not (get ok acc))
    acc
    {
      seen: (unwrap-panic (as-max-len? (append (get seen acc) (get recipient entry)) u30)),
      ok: (and
        (> (get signals entry) u0)
        (is-none (index-of? (get seen acc) (get recipient entry)))
      ),
    }
  )
)

;; Total signals across the week, the denominator for the per-signal share.
(define-private (sum-signals
    (entry {
      recipient: principal,
      signals: uint,
    })
    (acc uint)
  )
  (+ acc (get signals entry))
)

;; Pays one correspondent. Threaded through `fold`, so it cannot use `try!`.
;; It carries an `ok` flag instead, which `conclude` asserts on afterwards. A
;; false flag aborts the whole transaction, reverting any transfers already
;; made.
(define-private (pay-entry
    (entry {
      recipient: principal,
      signals: uint,
    })
    (acc {
      briefDate: (string-ascii 10),
      perSignal: uint,
      ok: bool,
    })
  )
  (if (not (get ok acc))
    acc
    (merge acc { ok: (is-ok (contract-call? .news-treasury execute-payout
      (get recipient entry)
      (* (get perSignal acc) (get signals entry))
      (payout-ref (get briefDate acc) (get recipient entry))
    )) })
  )
)

;; -------------------------------------------------------------------
;; Public: contribute
;; -------------------------------------------------------------------
;; Send sBTC to the pool and receive voting rights over how it is spent. This is
;; the only way in and the only way to get weight. The money is not refundable:
;; it funds journalism.
;;
;; SHARE-OF-BALANCE MINTING. Weight is credited against the pool as it stands at
;; this moment:
;;
;;   minted = amount * TotalWeight / BalanceBefore      (first contributor: amount)
;;
;; So a contribution is measured against the money that is actually there, not
;; against everything ever contributed. If the pool has taken in 100k, paid out
;; 50k, and now holds 50k, someone adding 50k funded half of what is in it and
;; receives half the say. Counting cumulatively would give them a third, leaving
;; earlier funders steering a pool on the strength of sats already spent.
;;
;; It also means voting rights dilute naturally as the pool is spent and
;; refilled by others, so no expiry rule is needed.
(define-public (contribute (amount uint))
  (let (
      (balBefore (contract-call? .news-treasury get-balance))
      (total (var-get TotalWeight))
      (minted (if (or (is-eq total u0) (is-eq balBefore u0))
        amount
        (/ (* amount total) balBefore)
      ))
      (next (+ (get-weight tx-sender) minted))
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    ;; A contribution so small it rounds to zero weight would be a silent
    ;; donation. Reject it rather than take the money for nothing.
    (asserts! (> minted u0) ERR_DUST_CONTRIBUTION)
    (try! (contract-call? .news-treasury contribute-in amount))
    (map-set Weights tx-sender next)
    (var-set TotalWeight (+ total minted))
    (print {
      event: "contribute",
      who: tx-sender,
      amount: amount,
      minted: minted,
      weight: next,
      totalWeight: (+ total minted),
    })
    (ok minted)
  )
)

;; -------------------------------------------------------------------
;; Public: propose-brief
;; -------------------------------------------------------------------
;; Open the vote on one week. The caller locks a bond scaled to total weight.
;; The bond is a lock on their own voting weight, released on every outcome; it
;; is never forfeited, whatever the vote decides (see conclude).
;; #[allow(unchecked_data)]
(define-public (propose-brief
    (briefDate (string-ascii 10))
    (title (string-ascii 128))
    (description (string-ascii 512))
    (inscriptions (list 7 (buff 80)))
    (entries (list 30 {
      recipient: principal,
      signals: uint,
    }))
  )
  (let (
      (existing (map-get? Briefs briefDate))
      (pool (contract-call? .news-treasury get-balance))
      (bond (quote-bond))
      (proposerWeight (get-weight tx-sender))
      (alreadyLocked (locked-of tx-sender))
      (snapshot (var-get TotalWeight))
      (voteEnd (+ stacks-block-height VOTE_WINDOW))
      ;; The height at which this week can no longer pay. Past it the bond frees
      ;; itself (see locked-of / BondUnlockAt). Always later than any prior brief
      ;; from this proposer, since createdAt only advances, so it is the max.
      (lapseAt (+ voteEnd VETO_WINDOW CONCLUDE_WINDOW))
      ;; A re-proposal of a failed/expired date bumps the round, giving the
      ;; Votes/Vetoes maps a fresh keyspace. First proposal of a date is round 1.
      (round (match existing prev (+ (get round prev) u1) u1))
      (draw (/ (* pool DRAW_BPS) u10000))
      (entryCheck (fold check-entry entries {
        seen: (list),
        ok: true,
      }))
      (totalSignals (fold sum-signals entries u0))
    )
    ;; A live vote blocks a second proposal; a PASSED week is terminal. A week
    ;; that LAPSED (OPEN but past its conclude window) has failed on its own and
    ;; is re-proposable immediately, with no conclude call required first -- so
    ;; the block is on a still-live week, not merely a stored-OPEN one.
    (match existing
      prev (let (
          (prevLapseAt (+ (get voteEnd prev) VETO_WINDOW CONCLUDE_WINDOW))
        )
        (asserts! (not (is-eq (get status prev) STATUS_PASSED)) ERR_BRIEF_CONCLUDED)
        (asserts!
          (not (and
            (is-eq (get status prev) STATUS_OPEN)
            (< stacks-block-height prevLapseAt)
          ))
          ERR_BRIEF_ALREADY_OPEN
        )
        true
      )
      true
    )
    ;; Sanitize the map key: a week is exactly "YYYY-MM-DD". Checking the
    ;; separators as well as the length matters because the date IS the map key
    ;; that gates settlement. Without it, "2026-07-20" and "20-07-2026" are two
    ;; independently settleable slots for the same week.
    (asserts!
      (and
        (is-eq (len briefDate) u10)
        (is-eq (slice? briefDate u4 u5) (some "-"))
        (is-eq (slice? briefDate u7 u8) (some "-"))
      )
      ERR_BAD_DATE
    )
    ;; Say what this is. A proposal that moves money should be legible without
    ;; decoding a list of principals and integers.
    (asserts! (> (len title) u0) ERR_EMPTY_TITLE)
    (asserts! (> (len inscriptions) u0) ERR_BAD_INSCRIPTION)
    (asserts! (> (len entries) u0) ERR_EMPTY_ENTRIES)
    (asserts! (get ok entryCheck) ERR_BAD_ENTRIES)
    (asserts! (> pool u0) ERR_EMPTY_POOL)
    ;; Reject a week whose draw cannot cover one sat per signal, here rather
    ;; than at conclude. Failing at conclude would let a week pass its vote and
    ;; then be unpayable.
    (asserts! (> (/ draw totalSignals) u0) ERR_DUST_DRAW)
    ;; A proposer whose last week failed sits out one window. Anyone else may
    ;; take this week immediately: the bar is on the principal, not the slot.
    (asserts!
      (>= stacks-block-height (get-propose-cooldown tx-sender))
      ERR_PROPOSE_COOLDOWN
    )
    ;; One proposal at a time, contract-wide.
    (asserts!
      (>= stacks-block-height (get-next-propose-height))
      ERR_PROPOSE_TOO_SOON
    )
    ;; Only a contributor may propose, and their free weight must cover the bond.
    (asserts! (>= proposerWeight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts! (>= proposerWeight (+ alreadyLocked bond)) ERR_INSUFFICIENT_BOND)

    (var-set LastProposeAt stacks-block-height)
    (map-set BriefMeta briefDate {
      title: title,
      description: description,
    })
    (map-set LockedWeight tx-sender (+ alreadyLocked bond))
    (map-set BondUnlockAt tx-sender lapseAt)
    (map-set BriefEntries briefDate entries)
    (map-set BriefRecipients briefDate (get seen entryCheck))
    (map-set Briefs briefDate {
      proposer: tx-sender,
      inscriptions: inscriptions,
      digest: (sha256 (unwrap-panic (to-consensus-buff? entries))),
      entryCount: (len entries),
      totalSignals: totalSignals,
      bond: bond,
      draw: draw,
      createdAt: stacks-block-height,
      round: round,
      voteEnd: voteEnd,
      ;; Quorum denominator excludes the proposer, who cannot vote on their own
      ;; week. Otherwise a large proposer would make quorum unreachable.
      eligibleSnapshot: (- snapshot proposerWeight),
      yesWeight: u0,
      noWeight: u0,
      vetoWeight: u0,
      voterCount: u0,
      status: STATUS_OPEN,
      reason: "",
    })
    (print {
      event: "propose-brief",
      briefDate: briefDate,
      title: title,
      proposer: tx-sender,
      inscriptions: inscriptions,
      entryCount: (len entries),
      totalSignals: totalSignals,
      bond: bond,
      draw: draw,
      voteEnd: voteEnd,
      eligibleSnapshot: (- snapshot proposerWeight),
    })
    (ok briefDate)
  )
)

;; -------------------------------------------------------------------
;; Public: vote
;; -------------------------------------------------------------------
;; Weight is the caller's current contribution weight. Because contributions
;; cannot be withdrawn, there is no vote-then-flee to guard against.
(define-public (vote
    (briefDate (string-ascii 10))
    (support bool)
  )
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (recipients (default-to (list) (map-get? BriefRecipients briefDate)))
      (weight (get-weight tx-sender))
      (round (get round brief))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_VOTE_CLOSED)
    (asserts! (< stacks-block-height (get voteEnd brief)) ERR_VOTE_CLOSED)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    ;; The proposer is excluded from voting their own week up: they are the one
    ;; party with a direct interest in it passing, and the quorum denominator
    ;; (eligibleSnapshot) already excludes their weight to match.
    (asserts! (not (is-eq tx-sender (get proposer brief))) ERR_SELF_VOTE)
    ;; Producers do not vote themselves a paycheque. A correspondent named in
    ;; this week is excluded from this week only; they may vote on any other.
    (asserts! (is-none (index-of? recipients tx-sender)) ERR_RECIPIENT_CANNOT_VOTE)
    (asserts!
      (is-none (map-get? Votes {
        briefDate: briefDate,
        round: round,
        voter: tx-sender,
      }))
      ERR_ALREADY_VOTED
    )

    (map-set Votes {
      briefDate: briefDate,
      round: round,
      voter: tx-sender,
    } {
      support: support,
      weight: weight,
    })
    (map-set Briefs briefDate
      (merge brief {
        yesWeight: (if support
          (+ (get yesWeight brief) weight)
          (get yesWeight brief)
        ),
        noWeight: (if support
          (get noWeight brief)
          (+ (get noWeight brief) weight)
        ),
        voterCount: (+ (get voterCount brief) u1),
      }))
    (print {
      event: "vote",
      briefDate: briefDate,
      round: round,
      voter: tx-sender,
      support: support,
      weight: weight,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: veto
;; -------------------------------------------------------------------
;; Open in [voteEnd, vetoEnd). Any contributor may object after seeing the
;; tally. If objections reach VETO_QUORUM of eligible weight, the week is
;; blocked no matter how the vote went.
;;
;; Unlike voting, recipients and the proposer are NOT barred here. A recipient
;; vetoing a week they are paid in is declining their own money, and a proposer
;; vetoing their own week is withdrawing it. Neither can be used to extract
;; anything, so there is nothing to guard against.
(define-public (veto (briefDate (string-ascii 10)))
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (voteEnd (get voteEnd brief))
      (vetoEnd (+ voteEnd VETO_WINDOW))
      (weight (get-weight tx-sender))
      (round (get round brief))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_CONCLUDED)
    (asserts! (>= stacks-block-height voteEnd) ERR_VETO_WINDOW)
    (asserts! (< stacks-block-height vetoEnd) ERR_VETO_WINDOW)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts!
      (is-none (map-get? Vetoes {
        briefDate: briefDate,
        round: round,
        voter: tx-sender,
      }))
      ERR_ALREADY_VETOED
    )
    (map-set Vetoes {
      briefDate: briefDate,
      round: round,
      voter: tx-sender,
    } weight)
    (map-set Briefs briefDate
      (merge brief { vetoWeight: (+ (get vetoWeight brief) weight) })
    )
    (print {
      event: "veto",
      briefDate: briefDate,
      round: round,
      voter: tx-sender,
      weight: weight,
      vetoWeight: (+ (get vetoWeight brief) weight),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: conclude (permissionless)
;; -------------------------------------------------------------------
;; Concludes the week and, if it passed, pays every correspondent, in one call,
;; by anyone. Nobody has to be online, trusted, or available for correspondents
;; to get paid.
;;
;; The draw is FIXED AT PROPOSE TIME and stored on the brief, so a contribution
;; landing mid-vote does not change this week's payout, and concluding late pays
;; exactly what concluding early would.
;;
;; It used to be read here, from the live pool. That was exploitable: a passed
;; week could be held and concluded later against a much larger pool, paying far
;; more than anyone approved, and waiting was simply better than not waiting.
;; Do not reintroduce it.
(define-public (conclude (briefDate (string-ascii 10)))
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (entries (default-to (list) (map-get? BriefEntries briefDate)))
      (proposer (get proposer brief))
      (bond (get bond brief))
      (eligible (get eligibleSnapshot brief))
      (cast (+ (get yesWeight brief) (get noWeight brief)))
      (quorumMet (and
        (> eligible u0)
        (>= (get voterCount brief) MIN_PARTICIPANTS)
        (>= (/ (* cast u100) eligible) VOTING_QUORUM)
      ))
      (thresholdMet (and
        (> cast u0)
        (>= (/ (* (get yesWeight brief) u100) cast) VOTING_THRESHOLD)
      ))
      (vetoed (and
        (> eligible u0)
        (>= (/ (* (get vetoWeight brief) u100) eligible) VETO_QUORUM)
      ))
      ;; The amount fixed at propose time, not today's pool. The entire draw
      ;; goes to correspondents; no fee is skimmed.
      (draw (get draw brief))
      (perSignal (/ draw (get totalSignals brief)))
      ;; Snapshotting traded a structural guarantee for a probabilistic one.
      ;; When the draw was a fraction of the CURRENT balance a shortfall was
      ;; impossible. Now it is fixed at propose, and because the cooldown only
      ;; lands at conclude, un-concluded briefs can accumulate claims at roughly
      ;; one per PROPOSE_INTERVAL. At 0.5% a draw you would need ~200 of them
      ;; outstanding, so this is remote -- but without handling it, a short pool
      ;; makes execute-payout fail, conclude revert, and the brief stick OPEN
      ;; forever with no way out. Failing the week instead keeps it recoverable:
      ;; it reopens and can be proposed again once the pool is healthy.
      ;; Compare the amount actually disbursed, not the draw. perSignal is
      ;; floored, so the real spend is up to totalSignals-1 sats below the draw,
      ;; and comparing the draw would fail a week the pool could in fact cover.
      ;; Past the conclude window: the week can only fail now.
      (lapsed (>= stacks-block-height
        (+ (+ (get voteEnd brief) VETO_WINDOW) CONCLUDE_WINDOW)
      ))
      (poolShort (> (* perSignal (get totalSignals brief))
        (contract-call? .news-treasury get-balance)
      ))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_CONCLUDED)
    (asserts! (>= stacks-block-height (+ (get voteEnd brief) VETO_WINDOW)) ERR_VOTE_STILL_OPEN)
    ;; Release the proposer's bond in EVERY outcome. The bond is a lock, not a
    ;; penalty: it earmarks weight so one principal cannot back several open
    ;; proposals at once, and that is all it does. Nothing is burned and nothing
    ;; is transferred anywhere.
    ;;
    ;; Confiscating it was considered and dropped. Spam is already impossible:
    ;; PROPOSE_INTERVAL allows one proposal at a time contract-wide, a failed
    ;; proposer sits out a cooldown, and MIN_WEIGHT can only be reached by a
    ;; contribution that is itself non-refundable. Entry already costs real
    ;; money, so charging again for a failure -- usually caused by other people
    ;; not voting -- would only deter people from proposing at all.
    (map-set LockedWeight proposer
      (if (> (locked-of proposer) bond)
        (- (locked-of proposer) bond)
        u0
      ))

        (if lapsed
      ;; EXPIRED because nobody concluded it in time. Not a failure of the vote:
      ;; the week was never decided. The bond is released and the week reopens,
      ;; so this is recoverable: propose it again. This branch only runs if
      ;; someone calls conclude late; if nobody ever does, the views report the
      ;; same EXPIRED state anyway (see lapsed-open) and the bond is already free.
      ;;
      ;; NO COOLDOWN. Like pool-short, this is not attributable to the proposer
      ;; -- they wrote a valid brief and someone else failed to press a button.
      (begin
        (map-set Briefs briefDate
          (merge brief { status: STATUS_EXPIRED, reason: "not-concluded" }))
        (print {
          event: "conclude", briefDate: briefDate, outcome: "expired",
          reason: "not-concluded", voteEnd: (get voteEnd brief),
        })
        (ok STATUS_EXPIRED)
      )
    (if vetoed
      ;; FAILED by veto. A VETO_QUORUM minority blocked a week that may well
      ;; have passed its vote.
      (begin
        (map-set ProposeCooldownUntil proposer (+ stacks-block-height VOTE_WINDOW))
        (map-set Briefs briefDate
          (merge brief { status: STATUS_FAILED, reason: "vetoed" }))
        (print {
          event: "conclude", briefDate: briefDate, outcome: "failed",
          reason: "vetoed", vetoWeight: (get vetoWeight brief), eligible: eligible,
        })
        (ok STATUS_FAILED)
      )
    (if (not quorumMet)
      ;; FAILED on turnout. Too few voted to decide anything either way.
      (begin
        (map-set ProposeCooldownUntil proposer (+ stacks-block-height VOTE_WINDOW))
        (map-set Briefs briefDate
          (merge brief { status: STATUS_FAILED, reason: "no-quorum" }))
        (print {
          event: "conclude", briefDate: briefDate, outcome: "failed",
          reason: "no-quorum", cast: cast, eligible: eligible,
          voterCount: (get voterCount brief),
        })
        (ok STATUS_FAILED)
      )
      (if (not thresholdMet)
        ;; FAILED on the vote. Voters turned up and said no.
        (begin
          (map-set ProposeCooldownUntil proposer (+ stacks-block-height VOTE_WINDOW))
          (map-set Briefs briefDate
            (merge brief { status: STATUS_FAILED, reason: "voted-down" }))
          (print {
            event: "conclude", briefDate: briefDate, outcome: "failed",
            reason: "voted-down", yesWeight: (get yesWeight brief),
            noWeight: (get noWeight brief),
          })
          (ok STATUS_FAILED)
        )
        (if poolShort
        ;; FAILED because the pool can no longer cover the snapshotted draw.
        ;; Recoverable: the week reopens and can be proposed again at today's
        ;; smaller draw.
        ;;
        ;; NO COOLDOWN here, unlike the other failures. This is the one cause
        ;; least attributable to the proposer -- they wrote a valid brief, won
        ;; the vote, and the pool shrank underneath them. Cooling them down
        ;; would block the person most motivated to re-propose it.
        (begin
          (map-set Briefs briefDate
            (merge brief { status: STATUS_FAILED, reason: "pool-short" }))
          (print {
            event: "conclude", briefDate: briefDate, outcome: "failed",
            reason: "pool-short", draw: draw,
          })
          (ok STATUS_FAILED)
        )
        ;; PASSED. Pay every correspondent. There is no proposer fee: the whole
        ;; draw goes to the people who did the reporting.
        (begin
          ;; Belt and braces. `propose-brief` already rejects a week whose draw
          ;; cannot cover one sat per signal, against these same snapshotted
          ;; values, so this cannot currently fire. It stays as a guard in case
          ;; that check is ever weakened.
          (asserts! (> perSignal u0) ERR_DUST_DRAW)
          ;; Mark terminal BEFORE paying: effects before interaction, and the
          ;; week can never be re-proposed or re-concluded.
          (map-set Briefs briefDate
            (merge brief { status: STATUS_PASSED, reason: "paid" }))
          (asserts!
            (get ok (fold pay-entry entries {
              briefDate: briefDate, perSignal: perSignal, ok: true,
            }))
            ERR_PAYOUT_FAILED
          )
          (print {
            event: "conclude", briefDate: briefDate, outcome: "passed",
            draw: draw, perSignal: perSignal,
            totalSignals: (get totalSignals brief),
            entryCount: (get entryCount brief),
            yesWeight: (get yesWeight brief), noWeight: (get noWeight brief),
          })
          (ok STATUS_PASSED)
        )
        )
      )
    )
    )
    )
  )
)
