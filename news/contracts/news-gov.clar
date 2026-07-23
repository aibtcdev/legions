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
;; voting. A tampered list gets voted down and costs the proposer their bond.
;; Voting without checking is the voter's problem, not the contract's.
;;
;; FOUR OUTCOMES:
;;   SETTLED  = quorum + threshold met, not vetoed. Entries paid, bond released.
;;   VETOED   = objections reached VETO_QUORUM of eligible weight. Bond returned.
;;   REJECTED = quorum met, threshold missed. Voters looked and said no. The
;;              bond is burned, so the proposer permanently loses that much say.
;;   EXPIRED  = quorum never met. Nobody looked. Bond released in full.
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
;; short, so a full propose -> vote -> veto -> settle lifecycle completes in
;; about 30 minutes on testnet instead of eight days, and the whole runbook
;; (settle, veto, reject) in about 90 minutes. That makes it possible to iterate
;; several times in a day rather than proving it once.
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
;; PROPOSE_INTERVAL blocks, whoever sends it. Set to a full week lifecycle so
;; weeks are strictly serialized -- one resolves completely before the next can
;; be opened.
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
;; (propose, expire, re-propose); it does not stop bulk pre-emption up front.
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
;; The bond is WEIGHT, not sats. Losing it means permanently losing that much
;; say. The sats stay in the pool either way, because there is nowhere else for
;; them to go.
(define-constant BOND_BPS u5)

;; Absolute floor under the bond. The percentage bond is economically nothing
;; while the pool is small, which is exactly when the legion can least absorb
;; spam.
(define-constant MIN_BOND u10000)

;; Paid to the proposer out of the draw, on success only. Assembling and
;; verifying an entry list is real work that nobody is otherwise paid for.
;; There is deliberately no settler fee: every recipient in a passed week
;; already wants to call `settle`, since that call is how they get paid.
(define-constant PROPOSER_FEE_BPS u100)

;; -- Week lifecycle states --
(define-constant STATUS_OPEN u0)
(define-constant STATUS_SETTLED u1)
(define-constant STATUS_REJECTED u2)
(define-constant STATUS_EXPIRED u3)
(define-constant STATUS_VETOED u4)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; below the weight floor
(define-constant ERR_BRIEF_ALREADY_OPEN (err u403)) ;; a vote is already live for this week
(define-constant ERR_NO_BRIEF (err u404)) ;; no proposal for this week
(define-constant ERR_ALREADY_VOTED (err u405)) ;; one vote per principal per week
(define-constant ERR_RECIPIENT_CANNOT_VOTE (err u406)) ;; named in the week under vote
(define-constant ERR_VOTE_CLOSED (err u407)) ;; at/after voteEnd
(define-constant ERR_VOTE_STILL_OPEN (err u408)) ;; settle before vetoEnd
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; contribution must be > 0
(define-constant ERR_BRIEF_SETTLED (err u410)) ;; terminal; can never be re-proposed
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

;; Sum of a principal's OPEN (unreleased) proposal bonds, in weight.
(define-map LockedWeight
  principal
  uint
)

;; Earliest height at which a principal may propose again, set whenever a week
;; they proposed fails (EXPIRED, REJECTED or VETOED).
;;
;; This closes a free denial-of-service. Returning the bond on EXPIRED protects
;; honest proposers from other people's apathy, but combined with "one live
;; proposal per week" and an unrestricted reopen, it let a single MIN_WEIGHT
;; holder propose garbage, watch it expire, get the bond back, and immediately
;; re-propose. Forever, at zero cost, blocking the legitimate proposer.
;;
;; The bar is on the PRINCIPAL, not the week: anyone else may propose the
;; reopened week in the very next block, so an honest failure costs the newsroom
;; nothing, while sustaining the attack costs a real contribution per account
;; per cycle.
(define-map ProposeCooldownUntil
  principal
  uint
)

;; Height of the most recent proposal, by anyone. Enforces PROPOSE_INTERVAL.
(define-data-var LastProposeAt uint u0)

;; One week per date. REJECTED, EXPIRED and VETOED clear the way for a
;; re-proposal; SETTLED is terminal.
(define-map Briefs
  (string-ascii 10)
  {
    proposer: principal,
    inscriptions: (list 7 (buff 80)),
    digest: (buff 32),
    entryCount: uint,
    totalSignals: uint,
    bond: uint,
    createdAt: uint,
    voteEnd: uint,
    eligibleSnapshot: uint,
    yesWeight: uint,
    noWeight: uint,
    vetoWeight: uint,
    voterCount: uint,
    status: uint,
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

;; One veto per principal per week.
(define-map Vetoes
  {
    briefDate: (string-ascii 10),
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

(define-read-only (get-weight (who principal))
  (default-to u0 (map-get? Weights who))
)

(define-read-only (get-total-weight)
  (var-get TotalWeight)
)

(define-read-only (locked-of (who principal))
  (default-to u0 (map-get? LockedWeight who))
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

(define-read-only (get-brief (briefDate (string-ascii 10)))
  (map-get? Briefs briefDate)
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

(define-read-only (get-veto-record
    (briefDate (string-ascii 10))
    (voter principal)
  )
  (map-get? Vetoes {
    briefDate: briefDate,
    voter: voter,
  })
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

;; The payout reference for the proposer's success fee.
;;
;; This deliberately hashes a tuple with DIFFERENT FIELD NAMES from `payout-ref`
;; ({f,r} vs {d,r}). Consensus serialization encodes tuple field names, so the
;; two shapes can never produce the same bytes and therefore never the same ref.
;; An earlier version keyed the fee off `payout-ref` with a "reserved" sentinel
;; value, which was not safe: nothing stopped an entry from carrying that exact
;; value and paying the proposer. The refs would collide, the treasury would
;; reject the second payout as ERR_ALREADY_PAID, and settling that week would
;; revert forever.
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
;; It carries an `ok` flag instead, which `settle` asserts on afterwards. A
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
;; Open the vote on one week. The caller locks a bond scaled to total weight,
;; which they forfeit only if voters reject the week on its merits.
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
      (entryCheck (fold check-entry entries {
        seen: (list),
        ok: true,
      }))
      (totalSignals (fold sum-signals entries u0))
    )
    ;; A live vote blocks a second proposal; a settled week is terminal.
    (match existing
      prev (begin
        (asserts! (not (is-eq (get status prev) STATUS_OPEN)) ERR_BRIEF_ALREADY_OPEN)
        (asserts! (not (is-eq (get status prev) STATUS_SETTLED)) ERR_BRIEF_SETTLED)
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
      voteEnd: voteEnd,
      ;; Quorum denominator excludes the proposer, who cannot vote on their own
      ;; week. Otherwise a large proposer would make quorum unreachable.
      eligibleSnapshot: (- snapshot proposerWeight),
      yesWeight: u0,
      noWeight: u0,
      vetoWeight: u0,
      voterCount: u0,
      status: STATUS_OPEN,
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
      drawPreview: (/ (* pool DRAW_BPS) u10000),
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
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_VOTE_CLOSED)
    (asserts! (< stacks-block-height (get voteEnd brief)) ERR_VOTE_CLOSED)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    ;; The proposer has a bond at stake and cannot also vote their own week up.
    (asserts! (not (is-eq tx-sender (get proposer brief))) ERR_SELF_VOTE)
    ;; Producers do not vote themselves a paycheque. A correspondent named in
    ;; this week is excluded from this week only; they may vote on any other.
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
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_SETTLED)
    (asserts! (>= stacks-block-height voteEnd) ERR_VETO_WINDOW)
    (asserts! (< stacks-block-height vetoEnd) ERR_VETO_WINDOW)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts!
      (is-none (map-get? Vetoes {
        briefDate: briefDate,
        voter: tx-sender,
      }))
      ERR_ALREADY_VETOED
    )
    (map-set Vetoes {
      briefDate: briefDate,
      voter: tx-sender,
    } weight)
    (map-set Briefs briefDate
      (merge brief { vetoWeight: (+ (get vetoWeight brief) weight) })
    )
    (print {
      event: "veto",
      briefDate: briefDate,
      voter: tx-sender,
      weight: weight,
      vetoWeight: (+ (get vetoWeight brief) weight),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: settle (permissionless)
;; -------------------------------------------------------------------
;; Concludes the week and, if it passed, pays every correspondent, in one call,
;; by anyone. Nobody has to be online, trusted, or available for correspondents
;; to get paid.
;;
;; The draw is read at settle time, not at propose time, so a contribution that
;; lands mid-vote raises that week's payout.
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
      (vetoed (and
        (> eligible u0)
        (>= (/ (* (get vetoWeight brief) u100) eligible) VETO_QUORUM)
      ))
      (pool (contract-call? .news-treasury get-balance))
      (draw (/ (* pool DRAW_BPS) u10000))
      (fee (/ (* draw PROPOSER_FEE_BPS) u10000))
      (distributable (- draw fee))
      (perSignal (/ distributable (get totalSignals brief)))
    )
    (asserts! (is-eq (get status brief) STATUS_OPEN) ERR_BRIEF_SETTLED)
    (asserts! (>= stacks-block-height (+ (get voteEnd brief) VETO_WINDOW)) ERR_VOTE_STILL_OPEN)

    ;; Release the proposer's bond lock in every outcome. Whether the bond is
    ;; also burned is decided below.
    (map-set LockedWeight proposer
      (if (> (locked-of proposer) bond)
        (- (locked-of proposer) bond)
        u0
      ))

    (if vetoed
      ;; VETOED. A VETO_QUORUM minority blocked it. The proposer cleared the bar
      ;; they were asked to clear, so the bond comes back. The cooldown still
      ;; applies so a contested week is not immediately re-submitted by the same
      ;; principal.
      (begin
        (map-set ProposeCooldownUntil proposer (+ stacks-block-height VOTE_WINDOW))
        (map-set Briefs briefDate (merge brief { status: STATUS_VETOED }))
        (print {
          event: "settle",
          briefDate: briefDate,
          outcome: "vetoed",
          vetoWeight: (get vetoWeight brief),
          eligible: eligible,
          bondReturned: bond,
        })
        (ok STATUS_VETOED)
      )
    (if (not quorumMet)
      ;; EXPIRED. Nobody showed up. The proposer did nothing wrong, so the bond
      ;; is released and the week reopens.
      (begin
        (map-set ProposeCooldownUntil proposer (+ stacks-block-height VOTE_WINDOW))
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
        ;; REJECTED. Voters looked and said no. The bond is BURNED, so the
        ;; proposer permanently loses that much say. The sats stay in the pool
        ;; either way, because there is nowhere else for them to go, so the
        ;; penalty is influence rather than principal.
        (begin
          (map-set Weights proposer
            (if (> (get-weight proposer) bond)
              (- (get-weight proposer) bond)
              u0
            ))
          (var-set TotalWeight
            (if (> (var-get TotalWeight) bond)
              (- (var-get TotalWeight) bond)
              u0
            ))
          (map-set ProposeCooldownUntil proposer (+ stacks-block-height VOTE_WINDOW))
          (map-set Briefs briefDate (merge brief { status: STATUS_REJECTED }))
          (print {
            event: "settle",
            briefDate: briefDate,
            outcome: "rejected",
            yesWeight: (get yesWeight brief),
            noWeight: (get noWeight brief),
            bondBurned: bond,
          })
          (ok STATUS_REJECTED)
        )
        ;; SETTLED. Pay every correspondent, then the proposer's fee.
        (begin
          (asserts! (> perSignal u0) ERR_DUST_DRAW)
          ;; Mark terminal BEFORE paying: effects before interaction, and the
          ;; week can never be re-proposed or re-settled.
          (map-set Briefs briefDate (merge brief { status: STATUS_SETTLED }))
          (asserts!
            (get ok (fold pay-entry entries {
              briefDate: briefDate,
              perSignal: perSignal,
              ok: true,
            }))
            ERR_PAYOUT_FAILED
          )
          ;; Proposer fee, keyed with `fee-ref`, whose tuple shape differs from
          ;; an entry's so collision is structurally impossible.
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
)
