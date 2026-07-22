;; news-gov
;; Stake-weighted governance for the aibtc.news Legion.
;;
;; ONE PROPOSAL TYPE, ONE QUESTION: was this brief worth paying for?
;;
;; A proposal names a brief date, the ordinal inscription that brief was written
;; to, and the list of (signal-id, recipient) entries in it. There is no
;; free-form recipient field anywhere in this contract -- no proposal can express
;; "send N sats to my address." The only reachable outcome of a passing vote is
;; that the correspondents named in an inscribed brief split a fixed percentage
;; of the pool.
;;
;; NO ORACLE. Clarity cannot read a Bitcoin inscription, so this contract does
;; not try. The proposer submits the entries, the contract stores a canonical
;; digest of them, and verifiers recompute that digest from the named
;; inscription off-chain. A tampered list fails the comparison, gets voted down,
;; and costs the proposer their bond. Fraud detection is a hash comparison
;; anyone can run, not a judgement call and not a trusted feed.
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

;; Voting window in BITCOIN blocks. ~144 blocks = ~24h, so a daily brief's vote
;; closes before the next day's brief is inscribed.
(define-constant VOTE_WINDOW u144)

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

;; Draw per approved brief, in basis points of the POOL (contributed sBTC only,
;; never members' stake). 100 bps = 1%.
(define-constant DRAW_BPS u100)

;; Proposal bond, in basis points of the pending draw. Scales with the pool, so
;; it stays meaningful as TVL grows and never needs a governance vote.
(define-constant BOND_BPS u1000)

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
(define-constant ERR_NOT_SORTED (err u412)) ;; entries must ascend by signal-id
(define-constant ERR_INSUFFICIENT_BOND (err u413)) ;; free stake cannot cover the bond
(define-constant ERR_BELOW_MIN_STAKE (err u414)) ;; stake/remainder below the floor
(define-constant ERR_STAKE_LOCKED (err u415)) ;; unstake before the lock expires
(define-constant ERR_INSUFFICIENT_STAKE (err u416)) ;; unstake exceeds free stake
(define-constant ERR_PAYOUT_FAILED (err u417)) ;; a treasury payout errored; whole tx reverts
(define-constant ERR_EMPTY_POOL (err u418)) ;; nothing to draw against
(define-constant ERR_DUST_DRAW (err u419)) ;; per-entry share would round to zero
(define-constant ERR_BAD_DATE (err u420)) ;; brief-date must be exactly YYYY-MM-DD
(define-constant ERR_BAD_INSCRIPTION (err u421)) ;; inscription id must be non-empty
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

;; One brief per date. REJECTED and EXPIRED clear the way for a re-proposal;
;; SETTLED is terminal.
(define-map Briefs
  (string-ascii 10)
  {
    proposer: principal,
    inscriptionId: (buff 64),
    digest: (buff 32),
    entryCount: uint,
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

(define-map BriefEntries
  (string-ascii 10)
  (list 30 {
    signalId: (buff 16),
    recipient: principal,
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
    (briefDate (string-ascii 10))
    (signalId (buff 16))
    (recipient principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    d: briefDate,
    s: signalId,
    r: recipient,
  })))
)

;; -------------------------------------------------------------------
;; Private helpers
;; -------------------------------------------------------------------
;; Entries must ascend strictly by signal-id. Enforcing a canonical order is
;; what makes the stored digest reproducible: two proposers building the same
;; brief produce byte-identical entry lists, so verifiers compare one hash
;; rather than diffing an arbitrarily ordered list.
(define-private (check-sorted
    (entry {
      signalId: (buff 16),
      recipient: principal,
    })
    (acc {
      prev: (buff 16),
      ok: bool,
      first: bool,
    })
  )
  (if (not (get ok acc))
    acc
    {
      prev: (get signalId entry),
      ok: (or (get first acc) (> (get signalId entry) (get prev acc))),
      first: false,
    }
  )
)

(define-private (collect-recipient
    (entry {
      signalId: (buff 16),
      recipient: principal,
    })
    (acc (list 30 principal))
  )
  (unwrap-panic (as-max-len? (append acc (get recipient entry)) u30))
)

;; Pays one entry. Threaded through `fold`, so it cannot use `try!` -- it carries
;; an `ok` flag instead, which `settle` asserts on afterwards. A false flag
;; aborts the whole transaction, reverting any transfers already made.
(define-private (pay-entry
    (entry {
      signalId: (buff 16),
      recipient: principal,
    })
    (acc {
      briefDate: (string-ascii 10),
      amount: uint,
      ok: bool,
    })
  )
  (if (not (get ok acc))
    acc
    (merge acc { ok: (is-ok (contract-call? .news-treasury execute-payout
      (get recipient entry)
      (get amount acc)
      (payout-ref (get briefDate acc) (get signalId entry) (get recipient entry))
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
    (inscriptionId (buff 64))
    (entries (list 30 {
      signalId: (buff 16),
      recipient: principal,
    }))
  )
  (let (
      (existing (map-get? Briefs briefDate))
      (pool (contract-call? .news-treasury get-pool))
      (draw (/ (* pool DRAW_BPS) u10000))
      (bond (/ (* draw BOND_BPS) u10000))
      (proposerStake (get-stake tx-sender))
      (alreadyLocked (locked-of tx-sender))
      (snapshot (var-get TotalStaked))
      (voteEnd (+ burn-block-height VOTE_WINDOW))
      (sortCheck (fold check-sorted entries {
        prev: 0x,
        ok: true,
        first: true,
      }))
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
    ;; Sanitize the map key: a brief date is exactly "YYYY-MM-DD".
    (asserts! (is-eq (len briefDate) u10) ERR_BAD_DATE)
    (asserts! (> (len inscriptionId) u0) ERR_BAD_INSCRIPTION)
    (asserts! (> (len entries) u0) ERR_EMPTY_ENTRIES)
    (asserts! (get ok sortCheck) ERR_NOT_SORTED)
    (asserts! (> pool u0) ERR_EMPTY_POOL)
    ;; Only a member may propose, and their free stake must cover the bond.
    (asserts! (>= proposerStake MIN_STAKE) ERR_INELIGIBLE)
    (asserts! (>= proposerStake (+ alreadyLocked bond)) ERR_INSUFFICIENT_BOND)

    (map-set LockedStake tx-sender (+ alreadyLocked bond))
    (extend-lock tx-sender voteEnd)
    (map-set BriefEntries briefDate entries)
    (map-set BriefRecipients briefDate (fold collect-recipient entries (list)))
    (map-set Briefs briefDate {
      proposer: tx-sender,
      inscriptionId: inscriptionId,
      digest: (sha256 (unwrap-panic (to-consensus-buff? entries))),
      entryCount: (len entries),
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
      inscriptionId: inscriptionId,
      digest: (sha256 (unwrap-panic (to-consensus-buff? entries))),
      entryCount: (len entries),
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
      (perEntry (/ distributable (get entryCount brief)))
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
        (map-set Briefs briefDate (merge brief { status: STATUS_EXPIRED }))
        (print {
          event: "settle",
          briefDate: briefDate,
          outcome: "expired",
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
          (map-set Briefs briefDate (merge brief { status: STATUS_REJECTED }))
          (print {
            event: "settle",
            briefDate: briefDate,
            outcome: "rejected",
            yesWeight: (get yesWeight brief),
            noWeight: (get noWeight brief),
            bondSlashed: bond,
          })
          (ok STATUS_REJECTED)
        )
        ;; SETTLED -- pay every entry, then the proposer's fee.
        (begin
          (asserts! (> perEntry u0) ERR_DUST_DRAW)
          ;; Mark terminal BEFORE paying: effects before interaction, and the
          ;; date can never be re-proposed or re-settled.
          (map-set Briefs briefDate (merge brief { status: STATUS_SETTLED }))
          (asserts!
            (get ok (fold pay-entry entries {
              briefDate: briefDate,
              amount: perEntry,
              ok: true,
            }))
            ERR_PAYOUT_FAILED
          )
          ;; Proposer fee, keyed on a reserved all-zero signal id so it can never
          ;; collide with a real entry's payout ref.
          (and (> fee u0)
            (unwrap!
              (contract-call? .news-treasury execute-payout proposer fee
                (payout-ref briefDate 0x00000000000000000000000000000000 proposer)
              )
              ERR_PAYOUT_FAILED
            ))
          (print {
            event: "settle",
            briefDate: briefDate,
            outcome: "settled",
            draw: draw,
            proposerFee: fee,
            perEntry: perEntry,
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
