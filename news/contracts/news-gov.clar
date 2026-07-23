;; news-gov
;; Stake-weighted governance for the aibtc.news Legion.
;;
;; ONE PROPOSAL TYPE, ONE QUESTION: was this week's reporting worth paying for?
;;
;; A proposal names the week's first brief date, the ordinal inscriptions the
;; week's briefs were written to, and one entry per correspondent carrying how
;; many of their signals appeared across them. There is no
;; free-form recipient field anywhere in this contract -- no proposal can express
;; "send N sats to my address." The only reachable outcome of a passing vote is
;; that the correspondents named in the week's inscribed briefs split a fixed
;; percentage of the pool, pro rata to how many signals each of them landed.
;;
;; WHY PER-CORRESPONDENT, NOT PER-SIGNAL. A week carries roughly 84 signals at
;; current volume. Settling those individually would mean 84 sBTC transfers in
;; one transaction -- over the list cap and a real block-cost risk. Collapsing to
;; one entry per correspondent with a signal count gives identical arithmetic
;; (every signal is still worth exactly the same) in ~13 transfers.
;;
;; NO ORACLE. Clarity cannot read a Bitcoin inscription, so this contract does
;; not try. The proposer submits the entries; the entries are stored in full and
;; readable via `get-brief-entries`. Voters are agents -- they check the list
;; against aibtc.news themselves before voting. A tampered list gets voted down
;; and costs the proposer their bond. Voting without checking is the voter's
;; problem, not the contract's.
;;
;; THREE OUTCOMES, and the distinction between the last two matters:
;;   SETTLED  -- quorum met, threshold met. Entries are paid. Bond released.
;;   REJECTED -- quorum met, threshold missed. Voters looked and said no.
;;              Bond slashed into the pool.
;;   EXPIRED  -- quorum never met. Nobody looked. Bond returned IN FULL.
;;
;; Slashing a proposer because other people failed to show up would end
;; proposing within a week. Apathy costs a delay, never a bond.

;; -------------------------------------------------------------------
;; Config -- normative parameters
;; -------------------------------------------------------------------
(define-constant SELF (as-contract tx-sender))

;; Voting window in BITCOIN blocks. ~1008 blocks = ~7 days: one settlement per
;; week, so the pool draws 1% per week rather than 1% per day. At a daily
;; cadence the same rate distributes ~97.5% of the pool in a year; weekly, ~41%,
;; which leaves the pool alive into a second year without continuous refilling.
(define-constant VOTE_WINDOW u1008)

;; Percentage of CAST weight that must be yes for a brief to pass.
(define-constant VOTING_THRESHOLD u66)

;; Percentage of ELIGIBLE staked weight that must participate. This is not zero
;; and must not be: with no quorum, a single member holding MIN_STAKE votes yes
;; alone, reaches 100% of cast weight, and unilaterally spends a slice of
;; everyone else's pool. Quorum is the only thing standing between the treasury
;; and one 10k-sat principal.
(define-constant VOTING_QUORUM u15)

;; Distinct voters required regardless of weight.
(define-constant MIN_PARTICIPANTS u2)

;; Membership floor.
(define-constant MIN_STAKE u10000)

;; Draw per approved week, in basis points of the POOL (contributed sBTC only,
;; never members' stake). 50 bps = 0.5%.
;;
;; Cadence sets pool longevity; pool size sets correspondent income. At 0.5%
;; weekly the pool distributes ~23% per year and half-lives in ~2.6 years, so it
;; survives long enough to prove the mechanism without continuous refilling.
;; Stretching the PERIOD instead (monthly) would buy the same longevity at the
;; cost of making both the payout and the oversight too thin to function: ~30
;; briefs is more than a voter will actually recompute against the inscriptions,
;; and the no-oracle design depends on them doing exactly that.
(define-constant DRAW_BPS u50)

;; Proposal bond, in basis points of the pending draw. Scales with the pool, so
;; it stays meaningful as TVL grows and never needs a governance vote.
(define-constant BOND_BPS u1000)

;; Absolute floor under the bond. The percentage bond works out to pool/200000,
;; which is economically nothing while the pool is small -- 500 sats at 0.01 BTC
;; -- exactly when the legion is least able to absorb spam. The floor makes
;; proposing cost a real membership stake from day one.
(define-constant MIN_BOND u10000)

;; Paid to the proposer out of the draw, on success only. Assembling and
;; verifying an entry list is real work that nobody is otherwise paid for.
;; There is deliberately no settler fee: every recipient in a passed brief
;; already wants to call `settle`, since that call is how they get paid.
(define-constant PROPOSER_FEE_BPS u100)

;; -- Brief lifecycle states --
(define-constant STATUS_OPEN u0)
(define-constant STATUS_SETTLED u1)
(define-constant STATUS_REJECTED u2)
(define-constant STATUS_EXPIRED u3)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; zero-stake voter or proposer
(define-constant ERR_BRIEF_ALREADY_OPEN (err u403)) ;; a vote is already live for this date
(define-constant ERR_NO_BRIEF (err u404)) ;; no proposal for this date
(define-constant ERR_ALREADY_VOTED (err u405)) ;; one vote per principal per brief
(define-constant ERR_RECIPIENT_CANNOT_VOTE (err u406)) ;; named in the brief under vote
(define-constant ERR_VOTE_CLOSED (err u407)) ;; at/after voteEnd
(define-constant ERR_VOTE_STILL_OPEN (err u408)) ;; settle before voteEnd
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; stake/unstake must be > 0
(define-constant ERR_BRIEF_SETTLED (err u410)) ;; terminal; can never be re-proposed
(define-constant ERR_EMPTY_ENTRIES (err u411)) ;; a brief must name at least one entry
(define-constant ERR_BAD_ENTRIES (err u412)) ;; duplicate correspondent, or a zero signal count
(define-constant ERR_INSUFFICIENT_BOND (err u413)) ;; free stake cannot cover the bond
(define-constant ERR_BELOW_MIN_STAKE (err u414)) ;; stake/remainder below the floor
(define-constant ERR_STAKE_LOCKED (err u415)) ;; unstake before the lock expires
(define-constant ERR_INSUFFICIENT_STAKE (err u416)) ;; unstake exceeds free stake
(define-constant ERR_PAYOUT_FAILED (err u417)) ;; a treasury payout errored; whole tx reverts
(define-constant ERR_EMPTY_POOL (err u418)) ;; nothing to draw against
(define-constant ERR_DUST_DRAW (err u419)) ;; per-entry share would round to zero
(define-constant ERR_BAD_DATE (err u420)) ;; brief-date must be exactly YYYY-MM-DD
(define-constant ERR_BAD_INSCRIPTION (err u421)) ;; inscription id must be non-empty
(define-constant ERR_PROPOSE_COOLDOWN (err u422)) ;; proposer barred after a failed brief
(define-constant ERR_SELF_VOTE (err u423)) ;; proposer voting on own brief

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
;; Stake per principal = voting weight.
(define-map Stakes
  principal
  uint
)
(define-data-var TotalStaked uint u0)

;; Sum of a principal's OPEN (unreleased) proposal bonds.
(define-map LockedStake
  principal
  uint
)

;; Earliest burn height at which a principal may unstake. Set on propose and on
;; vote to that brief's voteEnd, kept monotonic. Blocks vote-then-flee.
(define-map UnlockAt
  principal
  uint
)

;; Earliest burn height at which a principal may propose again, set whenever a
;; brief they proposed fails (EXPIRED or REJECTED).
;;
;; This closes a free denial-of-service. Returning the bond in full on EXPIRED
;; protects honest proposers from other people's apathy -- but combined with
;; "one live proposal per week" and an unrestricted reopen, it let a single
;; MIN_STAKE holder propose garbage, watch it expire, get the bond back, and
;; immediately re-propose. Forever, at zero cost, blocking the legitimate
;; proposer from ever taking the slot. It worked best when turnout was low,
;; which is precisely when the legion is most fragile.
;;
;; The cooldown is on the PROPOSER, not the week: anyone else may propose the
;; reopened week in the very next block, so an honest failure costs the newsroom
;; nothing, while sustaining the attack now costs MIN_STAKE per account per
;; cycle instead of nothing.
(define-map ProposeCooldownUntil
  principal
  uint
)

;; One brief per date. REJECTED and EXPIRED clear the way for a re-proposal;
;; SETTLED is terminal.
(define-map Briefs
  (string-ascii 10)
  {
    proposer: principal,
    inscriptions: (list 7 (buff 64)),
    digest: (buff 32),
    entryCount: uint,
    totalSignals: uint,
    bond: uint,
    createdBurn: uint,
    voteEnd: uint,
    eligibleSnapshot: uint,
    yesWeight: uint,
    noWeight: uint,
    voterCount: uint,
    status: uint,
  }
)

;; One entry per correspondent: how many of their signals appeared in the
;; week's briefs. Every signal is worth the same; the count is the weight.
(define-map BriefEntries
  (string-ascii 10)
  (list 30 {
    recipient: principal,
    signals: uint,
  })
)

;; Recipient principals for the open brief, for the "a recipient may not vote on
;; their own brief" check.
(define-map BriefRecipients
  (string-ascii 10)
  (list 30 principal)
)

(define-map Votes
  {
    briefDate: (string-ascii 10),
    voter: principal,
  }
  {
    support: bool,
    weight: uint,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-stake (who principal))
  (default-to u0 (map-get? Stakes who))
)

(define-read-only (get-total-staked)
  (var-get TotalStaked)
)

(define-read-only (locked-of (who principal))
  (default-to u0 (map-get? LockedStake who))
)

(define-read-only (get-unlock-at (who principal))
  (default-to u0 (map-get? UnlockAt who))
)

;; Earliest burn height at which `who` may propose again (u0 = no cooldown).
(define-read-only (get-propose-cooldown (who principal))
  (default-to u0 (map-get? ProposeCooldownUntil who))
)

;; Stake not earmarked by an open proposal bond.
(define-read-only (get-free-stake (who principal))
  (let (
      (staked (get-stake who))
      (locked (locked-of who))
    )
    (if (> locked staked)
      u0
      (- staked locked)
    )
  )
)

(define-read-only (get-brief (briefDate (string-ascii 10)))
  (map-get? Briefs briefDate)
)

(define-read-only (get-brief-entries (briefDate (string-ascii 10)))
  (map-get? BriefEntries briefDate)
)

;; The canonical digest a verifier recomputes from the inscription.
(define-read-only (get-entry-digest (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (some (get digest brief))
    none
  )
)

(define-read-only (get-brief-status (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (some (get status brief))
    none
  )
)

(define-read-only (get-vote-record
    (briefDate (string-ascii 10))
    (voter principal)
  )
  (map-get? Votes {
    briefDate: briefDate,
    voter: voter,
  })
)

;; Current draw against the pool, before any brief is proposed.
(define-read-only (quote-draw)
  (/ (* (contract-call? .news-treasury get-pool) DRAW_BPS) u10000)
)

;; Bond a proposer would post right now.
(define-read-only (quote-bond)
  (/ (* (quote-draw) BOND_BPS) u10000)
)

;; The payout reference for one entry. Deterministic and reproducible off-chain
;; from the same tuple shape, so anyone can ask the treasury whether a given
;; signal has been paid.
(define-read-only (payout-ref
    (weekStart (string-ascii 10))
    (recipient principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    d: weekStart,
    r: recipient,
  })))
)

;; The payout reference for the proposer's success fee.
;;
;; This deliberately hashes a tuple with DIFFERENT FIELD NAMES from `payout-ref`
;; ({f,r} vs {d,s,r}). Consensus serialization encodes tuple field names, so the
;; two shapes can never produce the same bytes and therefore never the same ref.
;;
;; An earlier version keyed the fee off `payout-ref` with a "reserved" sentinel
;; value, which was not safe: nothing stopped an entry from carrying that exact
;; value and paying the proposer. The refs would collide, the treasury would
;; reject the second payout as ERR_ALREADY_PAID, and settling that week would
;; revert forever. Distinct shapes remove the failure mode by construction
;; instead of documenting around it.
(define-read-only (fee-ref
    (briefDate (string-ascii 10))
    (proposer principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    f: briefDate,
    r: proposer,
  })))
)

;; -------------------------------------------------------------------
;; Private helpers
;; -------------------------------------------------------------------
;; Validates the entry list in one pass: every correspondent appears at most
;; once, and every signal count is positive.
;;
;; The duplicate check is the load-bearing half. `payout-ref` is keyed on
;; (week, recipient), so a correspondent listed twice would produce the same ref
;; for both entries -- the treasury would reject the second as ERR_ALREADY_PAID
;; and the entire settlement would revert. Rejecting duplicates at propose time
;; means a week that passes its vote can always be paid.
;; Rejects a duplicate correspondent or a zero signal count.
;;
;; This is NOT about making verification convenient -- agents verify against
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

;; Total signals across the week -- the denominator for the per-signal share.
(define-private (sum-signals
    (entry {
      recipient: principal,
      signals: uint,
    })
    (acc uint)
  )
  (+ acc (get signals entry))
)

;; Pays one entry. Threaded through `fold`, so it cannot use `try!` -- it carries
;; an `ok` flag instead, which `settle` asserts on afterwards. A false flag
;; aborts the whole transaction, reverting any transfers already made.
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

;; Extend a principal's unstake lock, never shorten it.
(define-private (extend-lock
    (who principal)
    (until uint)
  )
  (if (> until (get-unlock-at who))
    (map-set UnlockAt who until)
    true
  )
)

;; -------------------------------------------------------------------
;; Public: stake / unstake
;; -------------------------------------------------------------------
;; Contributing voting collateral is the same action as joining. Stake is held
;; in the treasury's Staked balance and is never paid out to correspondents.
(define-public (stake (amount uint))
  (let (
      (current (get-stake tx-sender))
      (next (+ current amount))
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (>= next MIN_STAKE) ERR_BELOW_MIN_STAKE)
    (try! (contract-call? .news-treasury stake-in amount))
    (map-set Stakes tx-sender next)
    (var-set TotalStaked (+ (var-get TotalStaked) amount))
    (print {
      event: "stake",
      who: tx-sender,
      amount: amount,
      stake: next,
      totalStaked: (var-get TotalStaked),
    })
    (ok next)
  )
)

;; Withdraw free stake. Blocked while any brief the caller proposed or voted on
;; is still open.
(define-public (unstake (amount uint))
  (let (
      (current (get-stake tx-sender))
      (free (get-free-stake tx-sender))
      (remaining (- current amount))
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (>= burn-block-height (get-unlock-at tx-sender)) ERR_STAKE_LOCKED)
    (asserts! (<= amount free) ERR_INSUFFICIENT_STAKE)
    ;; Leaving entirely is fine; leaving a dust position below the floor is not.
    (asserts! (or (is-eq remaining u0) (>= remaining MIN_STAKE)) ERR_BELOW_MIN_STAKE)
    (map-set Stakes tx-sender remaining)
    (var-set TotalStaked (- (var-get TotalStaked) amount))
    (try! (contract-call? .news-treasury execute-unstake tx-sender amount))
    (print {
      event: "unstake",
      who: tx-sender,
      amount: amount,
      stake: remaining,
      totalStaked: (var-get TotalStaked),
    })
    (ok remaining)
  )
)

;; -------------------------------------------------------------------
;; Public: propose-brief
;; -------------------------------------------------------------------
;; Open the vote on one brief. The caller stakes a bond scaled to the pending
;; draw, which they forfeit only if voters reject the brief on its merits.
(define-public (propose-brief
    (briefDate (string-ascii 10))
    (inscriptions (list 7 (buff 64)))
    (entries (list 30 {
      recipient: principal,
      signals: uint,
    }))
  )
  (let (
      (existing (map-get? Briefs briefDate))
      (pool (contract-call? .news-treasury get-pool))
      (draw (/ (* pool DRAW_BPS) u10000))
      (rawBond (/ (* draw BOND_BPS) u10000))
      (bond (if (> rawBond MIN_BOND)
        rawBond
        MIN_BOND
      ))
      (proposerStake (get-stake tx-sender))
      (alreadyLocked (locked-of tx-sender))
      (snapshot (var-get TotalStaked))
      (voteEnd (+ burn-block-height VOTE_WINDOW))
      (entryCheck (fold check-entry entries {
        seen: (list),
        ok: true,
      }))
      (totalSignals (fold sum-signals entries u0))
    )
    ;; A live vote blocks a second proposal; a settled date is terminal.
    (match existing
      prev (begin
        (asserts! (not (is-eq (get status prev) STATUS_OPEN)) ERR_BRIEF_ALREADY_OPEN)
        (asserts! (not (is-eq (get status prev) STATUS_SETTLED)) ERR_BRIEF_SETTLED)
        true
      )
      true
    )
    ;; Sanitize the map key: a brief date is exactly "YYYY-MM-DD". Checking the
    ;; separators as well as the length matters because the date IS the map key
    ;; that gates settlement -- without it, "2026-07-21" and "21-07-2026" are two
    ;; independently settleable slots for the same brief.
    (asserts!
      (and
        (is-eq (len briefDate) u10)
        (is-eq (slice? briefDate u4 u5) (some "-"))
        (is-eq (slice? briefDate u7 u8) (some "-"))
      )
      ERR_BAD_DATE
    )
    (asserts! (> (len inscriptions) u0) ERR_BAD_INSCRIPTION)
    (asserts! (> (len entries) u0) ERR_EMPTY_ENTRIES)
    (asserts! (get ok entryCheck) ERR_BAD_ENTRIES)
    (asserts! (> pool u0) ERR_EMPTY_POOL)
    ;; A proposer whose last brief failed sits out one window. Anyone else may
    ;; take this week immediately -- the bar is on the principal, not the slot.
    (asserts!
      (>= burn-block-height (get-propose-cooldown tx-sender))
      ERR_PROPOSE_COOLDOWN
    )
    ;; Only a member may propose, and their free stake must cover the bond.
    (asserts! (>= proposerStake MIN_STAKE) ERR_INELIGIBLE)
    (asserts! (>= proposerStake (+ alreadyLocked bond)) ERR_INSUFFICIENT_BOND)

    (map-set LockedStake tx-sender (+ alreadyLocked bond))
    (extend-lock tx-sender voteEnd)
    (map-set BriefEntries briefDate entries)
    (map-set BriefRecipients briefDate (get seen entryCheck))
    (map-set Briefs briefDate {
      proposer: tx-sender,
      inscriptions: inscriptions,
      digest: (sha256 (unwrap-panic (to-consensus-buff? entries))),
      entryCount: (len entries),
      totalSignals: totalSignals,
      bond: bond,
      createdBurn: burn-block-height,
      voteEnd: voteEnd,
      ;; Quorum denominator excludes the proposer, who cannot vote on their own
      ;; brief. Otherwise a large proposer would make quorum unreachable.
      eligibleSnapshot: (- snapshot proposerStake),
      yesWeight: u0,
      noWeight: u0,
      voterCount: u0,
      status: STATUS_OPEN,
    })
    (print {
      event: "propose-brief",
      briefDate: briefDate,
      proposer: tx-sender,
      inscriptions: inscriptions,
      digest: (sha256 (unwrap-panic (to-consensus-buff? entries))),
      entryCount: (len entries),
      totalSignals: totalSignals,
      bond: bond,
      drawPreview: draw,
      voteEnd: voteEnd,
      eligibleSnapshot: (- snapshot proposerStake),
    })
    (ok briefDate)
  )
)

;; -------------------------------------------------------------------
;; Public: vote
;; -------------------------------------------------------------------
;; Weight is the caller's current stake. Voting locks that stake until the
;; brief resolves, so weight cannot be cast and then withdrawn.
(define-public (vote
    (briefDate (string-ascii 10))
    (support bool)
  )
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (recipients (default-to (list) (map-get? BriefRecipients briefDate)))
      (weight (get-stake tx-sender))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_VOTE_CLOSED)
    (asserts! (< burn-block-height (get voteEnd brief)) ERR_VOTE_CLOSED)
    (asserts! (>= weight MIN_STAKE) ERR_INELIGIBLE)
    ;; The proposer has a bond at stake and cannot also vote their own brief up.
    (asserts! (not (is-eq tx-sender (get proposer brief))) ERR_SELF_VOTE)
    ;; Producers do not vote themselves a paycheque. A correspondent named in
    ;; this brief is excluded from this brief only -- they may vote on any other.
    (asserts! (is-none (index-of? recipients tx-sender)) ERR_RECIPIENT_CANNOT_VOTE)
    (asserts!
      (is-none (map-get? Votes {
        briefDate: briefDate,
        voter: tx-sender,
      }))
      ERR_ALREADY_VOTED
    )

    (map-set Votes {
      briefDate: briefDate,
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
    (extend-lock tx-sender (get voteEnd brief))
    (print {
      event: "vote",
      briefDate: briefDate,
      voter: tx-sender,
      support: support,
      weight: weight,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: settle (permissionless)
;; -------------------------------------------------------------------
;; Concludes the vote and, if it passed, pays every entry -- in one call, by
;; anyone. Nobody has to be online, trusted, or available for correspondents to
;; get paid.
;;
;; The draw is read at settle time, not at propose time, so a contribution that
;; lands mid-vote raises that brief's payout.
(define-public (settle (briefDate (string-ascii 10)))
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
      (pool (contract-call? .news-treasury get-pool))
      (draw (/ (* pool DRAW_BPS) u10000))
      (fee (/ (* draw PROPOSER_FEE_BPS) u10000))
      (distributable (- draw fee))
      (perSignal (/ distributable (get totalSignals brief)))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_SETTLED)
    (asserts! (>= burn-block-height (get voteEnd brief)) ERR_VOTE_STILL_OPEN)

    ;; Release the proposer's bond lock in every outcome. Whether the bond is
    ;; also confiscated is decided below.
    (map-set LockedStake proposer
      (if (> (locked-of proposer) bond)
        (- (locked-of proposer) bond)
        u0
      ))

    (if (not quorumMet)
      ;; EXPIRED -- nobody showed up. The proposer did nothing wrong, so the
      ;; bond is returned in full and the date reopens.
      (begin
        (map-set ProposeCooldownUntil proposer (+ burn-block-height VOTE_WINDOW))
        (map-set Briefs briefDate (merge brief { status: STATUS_EXPIRED }))
        (print {
          event: "settle",
          briefDate: briefDate,
          outcome: "expired",
          cooldownUntil: (+ burn-block-height VOTE_WINDOW),
          cast: cast,
          eligible: eligible,
          voterCount: (get voterCount brief),
          bondReturned: bond,
        })
        (ok STATUS_EXPIRED)
      )
      (if (not thresholdMet)
        ;; REJECTED -- voters looked and said no. Bond is confiscated into the
        ;; pool, which makes the next approved brief pay slightly more.
        (begin
          (map-set Stakes proposer
            (if (> (get-stake proposer) bond)
              (- (get-stake proposer) bond)
              u0
            ))
          (var-set TotalStaked
            (if (> (var-get TotalStaked) bond)
              (- (var-get TotalStaked) bond)
              u0
            ))
          (and (> bond u0) (unwrap! (contract-call? .news-treasury slash bond) ERR_PAYOUT_FAILED))
          (map-set ProposeCooldownUntil proposer (+ burn-block-height VOTE_WINDOW))
          (map-set Briefs briefDate (merge brief { status: STATUS_REJECTED }))
          (print {
            event: "settle",
            briefDate: briefDate,
            outcome: "rejected",
            cooldownUntil: (+ burn-block-height VOTE_WINDOW),
            yesWeight: (get yesWeight brief),
            noWeight: (get noWeight brief),
            bondSlashed: bond,
          })
          (ok STATUS_REJECTED)
        )
        ;; SETTLED -- pay every entry, then the proposer's fee.
        (begin
          (asserts! (> perSignal u0) ERR_DUST_DRAW)
          ;; Mark terminal BEFORE paying: effects before interaction, and the
          ;; date can never be re-proposed or re-settled.
          (map-set Briefs briefDate (merge brief { status: STATUS_SETTLED }))
          (asserts!
            (get ok (fold pay-entry entries {
              briefDate: briefDate,
              perSignal: perSignal,
              ok: true,
            }))
            ERR_PAYOUT_FAILED
          )
          ;; Proposer fee. Keyed with `fee-ref`, whose tuple SHAPE differs from an
          ;; entry's, so collision is structurally impossible -- see the note on
          ;; `fee-ref`.
          (and (> fee u0)
            (unwrap!
              (contract-call? .news-treasury execute-payout proposer fee
                (fee-ref briefDate proposer)
              )
              ERR_PAYOUT_FAILED
            ))
          (print {
            event: "settle",
            briefDate: briefDate,
            outcome: "settled",
            draw: draw,
            proposerFee: fee,
            perSignal: perSignal,
            totalSignals: (get totalSignals brief),
            entryCount: (get entryCount brief),
            yesWeight: (get yesWeight brief),
            noWeight: (get noWeight brief),
          })
          (ok STATUS_SETTLED)
        )
      )
    )
  )
)
