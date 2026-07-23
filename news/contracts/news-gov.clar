;; news-gov (optimistic settlement)
;; Contribution-weighted governance for the aibtc.news Legion.
;;
;; Agents send sBTC to the pool and get voting rights proportional to their
;; share of it. The money funds journalism; it does not come back.
;;
;; OPTIMISTIC SETTLEMENT. A week is paid out by DEFAULT. There is no vote in the
;; normal case:
;;
;;   propose -> challenge window passes with no objection -> anyone settles -> paid
;;
;; Only a challenge triggers a vote, and then contributors decide who was right
;; and the loser's bond transfers to the winner.
;;
;; WHY. The affirmative-voting version failed CLOSED: no votes meant no quorum
;; meant nobody got paid, week after week, and the most likely thing to go wrong
;; in practice is simply that people are busy. Optimistic settlement fails OPEN.
;; Silence is assent, because the common case is an honest proposer submitting a
;; correct list, and that case should not require organising a quorum.
;;
;; It also fixes who is paid to care. Under affirmative voting, a contributor
;; who carefully checked a week got nothing for it. Here, catching a bad list
;; wins the proposer's bond, so verification is paid work rather than unpaid
;; civic duty.
;;
;; The trade: a wrong list nobody notices gets paid. The defence is economic,
;; not procedural. Make the bond worth catching and fraud stops being worth
;; attempting.
;;
;; A proposal names the week's first brief date, the ordinal inscriptions the
;; week's briefs were written to, and one entry per correspondent carrying how
;; many of their signals appeared across them. There is no free-form recipient
;; field anywhere in this contract, so no proposal can express "send N sats to
;; my address."

;; -------------------------------------------------------------------
;; Config, normative parameters
;; -------------------------------------------------------------------
(define-constant SELF (as-contract tx-sender))

;; ///////////////////////////////////////////////////////////////////////////
;; TEST TIMING. THIS BUILD IS NOT MAINNET-READY.
;;
;; Counting is on STACKS blocks, not burn (Bitcoin) blocks, and the windows are
;; short, so an unchallenged week completes in about 90 minutes on testnet
;; instead of a week, and a challenged one in about three hours.
;;
;; PRODUCTION: set CHALLENGE_WINDOW to u1008 and DISPUTE_WINDOW to u1008, and
;; switch every height reference in this contract back to `burn-block-height`.
;; One settlement per week is what the 0.5% draw is sized against.
;;
;; `get-timing-mode` returns "TEST-STACKS-BLOCKS" so a deployed instance can be
;; queried for which build it is. A production build must return "PROD-BURN".
;; ///////////////////////////////////////////////////////////////////////////

;; How long anyone has to object before a week can be settled. Nothing happens
;; during this window in the normal case; it is dead time by design.
(define-constant CHALLENGE_WINDOW u144)

;; If a week is challenged, how long contributors have to vote on the dispute.
(define-constant DISPUTE_WINDOW u144)

;; Percentage of CAST weight needed to OVERTURN a challenged proposal. The
;; proposal stands by default, so the challenger carries the burden: a simple
;; majority is not enough to reverse a submission that the rest of the network
;; had a full window to object to and did not.
(define-constant OVERTURN_THRESHOLD u66)

;; Percentage of ELIGIBLE weight that must vote for a dispute to be decided by
;; the voters at all. Below this the proposal stands and the challenger loses
;; their bond, which is what stops a cheap challenge from freezing a week that
;; nobody actually disputes.
(define-constant DISPUTE_QUORUM u15)

;; Distinct voters required in a dispute, regardless of weight.
(define-constant MIN_PARTICIPANTS u2)

;; GLOBAL rate limit on proposals: the whole contract accepts one every
;; PROPOSE_INTERVAL blocks, whoever sends it.
;;
;; Without this, nothing bounded how many weeks could be open at once. Week keys
;; are just strings that pass a shape check, so "2027-01-01" is proposable today,
;; and the only cost was a bond of 5 bps of total weight. A proposer holding a
;; third of the weight could carry several hundred concurrent proposals.
;;
;; That mattered two ways. Each open week is a slot nobody else can propose, so
;; bulk-proposing pre-empts legitimate submissions for a full window each. And
;; every week that settles draws another 0.5%, so hundreds settling together
;; would take a large fraction of the pool inside a single window rather than
;; the 0.5% per week the economics are sized against.
;;
;; A per-principal cap would not have closed it: an attacker rotates accounts.
;; A global interval does, and it costs legitimate use nothing, because weeks
;; arrive once a week and this permits one proposal per day.
(define-constant PROPOSE_INTERVAL u144)

;; Weight floor to propose, challenge or vote.
(define-constant MIN_WEIGHT u10000)

;; Draw per approved week, in basis points of the pool. 50 bps = 0.5%.
(define-constant DRAW_BPS u50)

;; Bond, in basis points of TOTAL WEIGHT, posted by the proposer and matched by
;; any challenger. The bond is WEIGHT, not sats: the loser permanently transfers
;; that much say to the winner. No sats move, because there is nowhere for them
;; to go.
;;
;; Matched bonds are what make this work. The proposer risks something by
;; submitting, the challenger risks something by objecting, and the winner is
;; paid out of the loser's stake, so checking a week is compensated.
(define-constant BOND_BPS u5)

;; Absolute floor under the bond. The percentage bond is economically nothing
;; while the pool is small, which is exactly when the legion can least absorb
;; spam or frivolous challenges.
(define-constant MIN_BOND u10000)

;; Paid to the proposer out of the draw, on success only.
(define-constant PROPOSER_FEE_BPS u100)

;; -- Week lifecycle states --
(define-constant STATUS_OPEN u0)
(define-constant STATUS_SETTLED u1) ;; paid: unchallenged, or the challenge failed
(define-constant STATUS_OVERTURNED u2) ;; challenge succeeded: nobody paid, week reopens

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; below the weight floor
(define-constant ERR_BRIEF_ALREADY_OPEN (err u403)) ;; a week is already live
(define-constant ERR_NO_BRIEF (err u404)) ;; no proposal for this week
(define-constant ERR_ALREADY_VOTED (err u405)) ;; one vote per principal per dispute
(define-constant ERR_RECIPIENT_CANNOT_VOTE (err u406)) ;; named in the week under dispute
(define-constant ERR_VOTE_CLOSED (err u407)) ;; dispute voting has closed
(define-constant ERR_TOO_EARLY (err u408)) ;; settle before the relevant window closes
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; contribution must be > 0
(define-constant ERR_BRIEF_SETTLED (err u410)) ;; terminal; can never be re-proposed
(define-constant ERR_EMPTY_ENTRIES (err u411)) ;; a week must name at least one entry
(define-constant ERR_BAD_ENTRIES (err u412)) ;; duplicate correspondent, or zero signals
(define-constant ERR_INSUFFICIENT_BOND (err u413)) ;; free weight cannot cover the bond
(define-constant ERR_PAYOUT_FAILED (err u417)) ;; a treasury payout errored; tx reverts
(define-constant ERR_EMPTY_POOL (err u418)) ;; nothing to draw against
(define-constant ERR_DUST_DRAW (err u419)) ;; per-signal share would round to zero
(define-constant ERR_BAD_DATE (err u420)) ;; week must be exactly YYYY-MM-DD
(define-constant ERR_BAD_INSCRIPTION (err u421)) ;; inscription list must be non-empty
(define-constant ERR_PROPOSE_COOLDOWN (err u422)) ;; proposer barred after losing a dispute
(define-constant ERR_PARTY_CANNOT_VOTE (err u423)) ;; proposer or challenger voting on own dispute
(define-constant ERR_DUST_CONTRIBUTION (err u426)) ;; too small to mint any weight
(define-constant ERR_ALREADY_CHALLENGED (err u427)) ;; one challenge per week
(define-constant ERR_CHALLENGE_CLOSED (err u428)) ;; challenge after the window
(define-constant ERR_NOT_CHALLENGED (err u429)) ;; voting with no dispute open
(define-constant ERR_SELF_CHALLENGE (err u430)) ;; proposer challenging their own week
(define-constant ERR_EMPTY_REASON (err u431)) ;; a challenge must say what is wrong
(define-constant ERR_PROPOSE_TOO_SOON (err u432)) ;; another proposal is too recent

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

;; Sum of a principal's OPEN bonds, as proposer or challenger.
(define-map LockedWeight
  principal
  uint
)

;; Earliest height at which a principal may propose again, set when a week they
;; proposed is overturned. The bar is on the PRINCIPAL, not the week: anyone
;; else may propose the reopened week in the next block, so an honest loss costs
;; the newsroom nothing.
(define-map ProposeCooldownUntil
  principal
  uint
)

;; Height of the most recent proposal, by anyone. Enforces PROPOSE_INTERVAL.
(define-data-var LastProposeAt uint u0)

;; One week per date. OVERTURNED clears the way for a re-proposal; SETTLED is
;; terminal.
(define-map Briefs
  (string-ascii 10)
  {
    proposer: principal,
    inscriptions: (list 7 (buff 64)),
    digest: (buff 32),
    entryCount: uint,
    totalSignals: uint,
    bond: uint,
    createdAt: uint,
    challengeEnd: uint,
    challenger: (optional principal),
    disputeEnd: uint,
    eligibleSnapshot: uint,
    upholdWeight: uint,
    overturnWeight: uint,
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

;; Recipient principals for the open week, for the "a recipient may not vote on
;; their own week" check.
(define-map BriefRecipients
  (string-ascii 10)
  (list 30 principal)
)

;; What a challenger says is wrong, recorded alongside the challenge.
;;
;; The contract never reads this: it is for the voters. A challenge with no
;; stated reason forces every voter to independently work out what the objection
;; even was, which is far more work than checking a specific claim, and turns a
;; dispute into a guessing game. Naming the defect ("agent-07 shows 30 signals,
;; the briefs show 12") makes the vote a verification task instead.
;;
;; 256 ASCII is enough for a concrete claim or a URL to a longer writeup.
(define-map ChallengeReason
  (string-ascii 10)
  {
    challenger: principal,
    reason: (string-ascii 256),
    at: uint,
  }
)

(define-map Votes
  {
    briefDate: (string-ascii 10),
    voter: principal,
  }
  {
    overturn: bool,
    weight: uint,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-timing-mode)
  "TEST-STACKS-BLOCKS"
)

(define-read-only (get-weight (who principal))
  (default-to u0 (map-get? Weights who))
)

(define-read-only (get-total-weight)
  (var-get TotalWeight)
)

(define-read-only (locked-of (who principal))
  (default-to u0 (map-get? LockedWeight who))
)

;; Weight not earmarked by an open bond.
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
;; anyone. Lets an agent wait rather than burn a transaction on ERR_PROPOSE_TOO_SOON.
(define-read-only (get-next-propose-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0 ;; nothing proposed yet, the contract is open
    (+ (var-get LastProposeAt) PROPOSE_INTERVAL)
  )
)

(define-read-only (get-propose-cooldown (who principal))
  (default-to u0 (map-get? ProposeCooldownUntil who))
)

(define-read-only (get-brief (briefDate (string-ascii 10)))
  (map-get? Briefs briefDate)
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
    brief (some (get status brief))
    none
  )
)

;; Is this week under dispute right now?
(define-read-only (is-challenged (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (is-some (get challenger brief))
    false
  )
)

;; Can `settle` be called yet, and would it pay out? Lets an agent decide
;; whether it is worth sending the transaction.
(define-read-only (can-settle (briefDate (string-ascii 10)))
  (match (map-get? Briefs briefDate)
    brief (if (not (is-eq (get status brief) STATUS_OPEN))
      false
      (if (is-some (get challenger brief))
        (>= stacks-block-height (get disputeEnd brief))
        (>= stacks-block-height (get challengeEnd brief))
      )
    )
    false
  )
)

;; The challenger, their stated objection, and when it was raised. This is what
;; a voter should read before deciding a dispute.
(define-read-only (get-challenge (briefDate (string-ascii 10)))
  (map-get? ChallengeReason briefDate)
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

(define-read-only (quote-draw)
  (/ (* (contract-call? .news-treasury get-balance) DRAW_BPS) u10000)
)

;; Bond a proposer or challenger would post right now, in weight.
(define-read-only (quote-bond)
  (let ((raw (/ (* (var-get TotalWeight) BOND_BPS) u10000)))
    (if (> raw MIN_BOND)
      raw
      MIN_BOND
    )
  )
)

;; Weight a contribution of `amount` would mint right now.
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

;; The payout reference for one correspondent's week.
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
;; ({f,r} vs {d,r}). Consensus serialization encodes tuple field names, so the
;; two shapes can never produce the same bytes and therefore never the same ref.
;; Keying the fee off `payout-ref` with a "reserved" sentinel would not be safe:
;; nothing stops an entry from carrying that exact value and paying the
;; proposer, which would make the week permanently unsettleable.
(define-read-only (fee-ref
    (weekStart (string-ascii 10))
    (proposer principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    f: weekStart,
    r: proposer,
  })))
)

;; -------------------------------------------------------------------
;; Private helpers
;; -------------------------------------------------------------------
;; Rejects a duplicate correspondent or a zero signal count.
;;
;; This is about settlement liveness, not convenience: `payout-ref` is keyed on
;; (week, recipient), so two rows for one principal produce the same ref, the
;; treasury rejects the second as ERR_ALREADY_PAID, and the entire settlement
;; reverts. A week that survives its challenge window must always be payable.
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

(define-private (sum-signals
    (entry {
      recipient: principal,
      signals: uint,
    })
    (acc uint)
  )
  (+ acc (get signals entry))
)

;; Pays one correspondent. Threaded through `fold`, so it cannot use `try!`. It
;; carries an `ok` flag instead, which `settle` asserts on afterwards; a false
;; flag aborts the whole transaction, reverting any transfers already made.
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

;; Release a principal's bond earmark.
(define-private (release-bond
    (who principal)
    (amount uint)
  )
  (map-set LockedWeight who
    (if (> (locked-of who) amount)
      (- (locked-of who) amount)
      u0
    ))
)

;; Move `amount` of weight from the loser of a dispute to the winner. Total
;; weight is unchanged: this is a transfer, not a burn, so the winner is paid
;; for their attention out of the loser's say.
(define-private (transfer-bond
    (from principal)
    (to principal)
    (amount uint)
  )
  (let ((fromWeight (get-weight from)))
    (map-set Weights from
      (if (> fromWeight amount)
        (- fromWeight amount)
        u0
      ))
    (map-set Weights to (+ (get-weight to)
      (if (> fromWeight amount)
        amount
        fromWeight
      )))
    true
  )
)

;; -------------------------------------------------------------------
;; Public: contribute
;; -------------------------------------------------------------------
;; Send sBTC to the pool and receive voting rights over how it is spent. This is
;; the only way in and the only way to get weight. The money is not refundable:
;; it funds journalism.
;;
;; SHARE-OF-BALANCE MINTING:
;;
;;   minted = amount * TotalWeight / BalanceBefore      (first contributor: amount)
;;
;; A contribution is measured against the money that is actually there, not
;; against everything ever contributed. If the pool has taken in 100k, paid out
;; 50k and now holds 50k, someone adding 50k funded half of what is in it and
;; receives half the say. Counting cumulatively would give them a third, leaving
;; earlier funders steering on the strength of sats already spent. It also means
;; voting rights dilute naturally as the pool is spent and refilled by others,
;; so no expiry rule is needed.
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
;; Submit a week and open the challenge window. If nobody objects, this is the
;; only governance transaction the week ever needs.
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
      (pool (contract-call? .news-treasury get-balance))
      (bond (quote-bond))
      (proposerWeight (get-weight tx-sender))
      (alreadyLocked (locked-of tx-sender))
      (snapshot (var-get TotalWeight))
      (challengeEnd (+ stacks-block-height CHALLENGE_WINDOW))
      (entryCheck (fold check-entry entries {
        seen: (list),
        ok: true,
      }))
      (totalSignals (fold sum-signals entries u0))
    )
    (match existing
      prev (begin
        (asserts! (not (is-eq (get status prev) STATUS_OPEN)) ERR_BRIEF_ALREADY_OPEN)
        (asserts! (not (is-eq (get status prev) STATUS_SETTLED)) ERR_BRIEF_SETTLED)
        true
      )
      true
    )
    ;; Sanitize the map key: a week is exactly "YYYY-MM-DD". The separators
    ;; matter because the date IS the key that gates settlement; length alone
    ;; would let "2026-07-20" and "20-07-2026" be two settleable slots for the
    ;; same week.
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
    (asserts!
      (>= stacks-block-height (get-propose-cooldown tx-sender))
      ERR_PROPOSE_COOLDOWN
    )
    ;; One proposal at a time, contract-wide.
    (asserts!
      (>= stacks-block-height (get-next-propose-height))
      ERR_PROPOSE_TOO_SOON
    )
    (asserts! (>= proposerWeight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts! (>= proposerWeight (+ alreadyLocked bond)) ERR_INSUFFICIENT_BOND)

    (var-set LastProposeAt stacks-block-height)
    (map-set LockedWeight tx-sender (+ alreadyLocked bond))
    (map-set BriefEntries briefDate entries)
    (map-set BriefRecipients briefDate (get seen entryCheck))
    (map-set Briefs briefDate {
      proposer: tx-sender,
      inscriptions: inscriptions,
      digest: (sha256 (unwrap-panic (to-consensus-buff? entries))),
      entryCount: (len entries),
      totalSignals: totalSignals,
      bond: bond,
      createdAt: stacks-block-height,
      challengeEnd: challengeEnd,
      challenger: none,
      disputeEnd: u0,
      ;; Dispute quorum denominator excludes the proposer, who cannot vote on
      ;; their own week.
      eligibleSnapshot: (- snapshot proposerWeight),
      upholdWeight: u0,
      overturnWeight: u0,
      voterCount: u0,
      status: STATUS_OPEN,
    })
    (print {
      event: "propose-brief",
      briefDate: briefDate,
      proposer: tx-sender,
      inscriptions: inscriptions,
      entryCount: (len entries),
      totalSignals: totalSignals,
      bond: bond,
      drawPreview: (/ (* pool DRAW_BPS) u10000),
      challengeEnd: challengeEnd,
    })
    (ok briefDate)
  )
)

;; -------------------------------------------------------------------
;; Public: challenge
;; -------------------------------------------------------------------
;; Object to a submitted week. Freezes settlement and opens a dispute vote.
;;
;; The challenger matches the proposer's bond, so objecting is not free, and the
;; winner takes the loser's bond. That is what turns checking a week from unpaid
;; civic duty into paid work.
;;
;; One challenge per week: the first objection is enough to force the question,
;; and a second adds nothing but another bond at risk.
;;
;; `reason` states what is wrong, in the challenger's own words. The contract
;; never reads it; it exists so voters can verify a specific claim rather than
;; reverse-engineer the objection from scratch.
(define-public (challenge
    (briefDate (string-ascii 10))
    (reason (string-ascii 256))
  )
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (bond (get bond brief))
      (weight (get-weight tx-sender))
      (alreadyLocked (locked-of tx-sender))
      (disputeEnd (+ stacks-block-height DISPUTE_WINDOW))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_SETTLED)
    (asserts! (is-none (get challenger brief)) ERR_ALREADY_CHALLENGED)
    (asserts! (< stacks-block-height (get challengeEnd brief)) ERR_CHALLENGE_CLOSED)
    (asserts! (not (is-eq tx-sender (get proposer brief))) ERR_SELF_CHALLENGE)
    ;; Say what is wrong. Voters cannot verify an unstated claim.
    (asserts! (> (len reason) u0) ERR_EMPTY_REASON)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts! (>= weight (+ alreadyLocked bond)) ERR_INSUFFICIENT_BOND)

    (map-set LockedWeight tx-sender (+ alreadyLocked bond))
    (map-set ChallengeReason briefDate {
      challenger: tx-sender,
      reason: reason,
      at: stacks-block-height,
    })
    (map-set Briefs briefDate
      (merge brief {
        challenger: (some tx-sender),
        disputeEnd: disputeEnd,
      }))
    (print {
      event: "challenge",
      briefDate: briefDate,
      challenger: tx-sender,
      reason: reason,
      bond: bond,
      disputeEnd: disputeEnd,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: vote (disputes only)
;; -------------------------------------------------------------------
;; Only callable while a challenge is live. `overturn` true means the challenger
;; is right and the week should not be paid; false means the proposal stands.
;;
;; Both parties to the dispute are barred: each has a bond riding on the
;; outcome, so neither votes on their own case.
(define-public (vote
    (briefDate (string-ascii 10))
    (overturn bool)
  )
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (recipients (default-to (list) (map-get? BriefRecipients briefDate)))
      (weight (get-weight tx-sender))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_SETTLED)
    (asserts! (is-some (get challenger brief)) ERR_NOT_CHALLENGED)
    (asserts! (< stacks-block-height (get disputeEnd brief)) ERR_VOTE_CLOSED)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts! (not (is-eq tx-sender (get proposer brief))) ERR_PARTY_CANNOT_VOTE)
    (asserts!
      (not (is-eq (some tx-sender) (get challenger brief)))
      ERR_PARTY_CANNOT_VOTE
    )
    ;; Producers do not vote themselves a paycheque.
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
      overturn: overturn,
      weight: weight,
    })
    (map-set Briefs briefDate
      (merge brief {
        overturnWeight: (if overturn
          (+ (get overturnWeight brief) weight)
          (get overturnWeight brief)
        ),
        upholdWeight: (if overturn
          (get upholdWeight brief)
          (+ (get upholdWeight brief) weight)
        ),
        voterCount: (+ (get voterCount brief) u1),
      }))
    (print {
      event: "vote",
      briefDate: briefDate,
      voter: tx-sender,
      overturn: overturn,
      weight: weight,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: settle (permissionless)
;; -------------------------------------------------------------------
;; The normal path: challenge window passed, nobody objected, pay everyone.
;; Nobody voted and nobody had to.
;;
;; The dispute path: the vote decides. The proposal STANDS unless the challenger
;; reaches OVERTURN_THRESHOLD of cast weight with DISPUTE_QUORUM turnout and
;; MIN_PARTICIPANTS voters. A challenge nobody backs therefore fails, and the
;; challenger loses their bond, which is what stops a cheap objection from
;; freezing a week that nobody actually disputes.
;;
;; The draw is read at settle time, so a contribution that lands mid-window
;; raises that week's payout.
(define-public (settle (briefDate (string-ascii 10)))
  (let (
      (brief (unwrap! (map-get? Briefs briefDate) ERR_NO_BRIEF))
      (entries (default-to (list) (map-get? BriefEntries briefDate)))
      (proposer (get proposer brief))
      (bond (get bond brief))
      (eligible (get eligibleSnapshot brief))
      (cast (+ (get upholdWeight brief) (get overturnWeight brief)))
      (overturned (and
        (> eligible u0)
        (> cast u0)
        (>= (get voterCount brief) MIN_PARTICIPANTS)
        (>= (/ (* cast u100) eligible) DISPUTE_QUORUM)
        (>= (/ (* (get overturnWeight brief) u100) cast) OVERTURN_THRESHOLD)
      ))
      (pool (contract-call? .news-treasury get-balance))
      (draw (/ (* pool DRAW_BPS) u10000))
      (fee (/ (* draw PROPOSER_FEE_BPS) u10000))
      (distributable (- draw fee))
      (perSignal (/ distributable (get totalSignals brief)))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_SETTLED)
    ;; An unchallenged week waits out the challenge window; a challenged one
    ;; waits out the dispute window.
    (asserts!
      (if (is-some (get challenger brief))
        (>= stacks-block-height (get disputeEnd brief))
        (>= stacks-block-height (get challengeEnd brief))
      )
      ERR_TOO_EARLY
    )

    (release-bond proposer bond)
    (match (get challenger brief)
      c (release-bond c bond)
      true
    )

    (if overturned
      ;; OVERTURNED. The challenger was right. Nobody is paid, the proposer's
      ;; bond transfers to the challenger, and the week reopens for someone
      ;; else to submit correctly.
      (begin
        (match (get challenger brief)
          c (transfer-bond proposer c bond)
          true
        )
        (map-set ProposeCooldownUntil proposer (+ stacks-block-height CHALLENGE_WINDOW))
        (map-set Briefs briefDate (merge brief { status: STATUS_OVERTURNED }))
        (print {
          event: "settle",
          briefDate: briefDate,
          outcome: "overturned",
          challenger: (get challenger brief),
          overturnWeight: (get overturnWeight brief),
          upholdWeight: (get upholdWeight brief),
          bondTransferred: bond,
        })
        (ok STATUS_OVERTURNED)
      )
      ;; SETTLED. Either nobody objected, or the challenge failed. Pay every
      ;; correspondent, then the proposer's fee. If there was a failed
      ;; challenge, the challenger's bond transfers to the proposer.
      (begin
        (asserts! (> perSignal u0) ERR_DUST_DRAW)
        (match (get challenger brief)
          c (transfer-bond c proposer bond)
          true
        )
        ;; Mark terminal BEFORE paying: effects before interaction, and the week
        ;; can never be re-proposed or re-settled.
        (map-set Briefs briefDate (merge brief { status: STATUS_SETTLED }))
        (asserts!
          (get ok (fold pay-entry entries {
            briefDate: briefDate,
            perSignal: perSignal,
            ok: true,
          }))
          ERR_PAYOUT_FAILED
        )
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
          challenged: (is-some (get challenger brief)),
          draw: draw,
          proposerFee: fee,
          perSignal: perSignal,
          totalSignals: (get totalSignals brief),
          entryCount: (get entryCount brief),
        })
        (ok STATUS_SETTLED)
      )
    )
  )
)
