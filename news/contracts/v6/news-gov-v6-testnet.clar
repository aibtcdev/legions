;; ///////////////////////////////////////////////////////////////////////////
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

;; news-gov-v6

;; Lifecycle windows in burn blocks
(define-constant VOTING_DELAY u4)
(define-constant VOTE_WINDOW u24)
(define-constant CONCLUDE_WINDOW u12)

;; Vote thresholds as percentages
(define-constant VOTING_THRESHOLD u66)
(define-constant VOTING_QUORUM u10)

;; Distinct voters required
(define-constant MIN_PARTICIPANTS u1)

;; Global rate limit on proposals
(define-constant PROPOSE_INTERVAL u1)

;; Minimum weight to act and minimum sats to join
(define-constant MIN_WEIGHT u10000)
(define-constant MIN_CONTRIBUTION u10000)

;; Payout per approved story in basis points
(define-constant DRAW_BPS u5)

;; Proposal statuses
(define-constant STATUS_OPEN u0)
(define-constant STATUS_PASSED u1)
(define-constant STATUS_FAILED u2)
(define-constant STATUS_EXPIRED u3)

;; Error constants
(define-constant ERR_INELIGIBLE (err u401))
(define-constant ERR_NO_PROPOSAL (err u404))
(define-constant ERR_ALREADY_VOTED (err u405))
(define-constant ERR_VOTE_CLOSED (err u407))
(define-constant ERR_VOTE_NOT_STARTED (err u436))
(define-constant ERR_VOTE_STILL_OPEN (err u408))
(define-constant ERR_CONCLUDE_WINDOW_PASSED (err u435))
(define-constant ERR_BELOW_MIN_CONTRIBUTION (err u437))
(define-constant ERR_PROPOSAL_CONCLUDED (err u410))
(define-constant ERR_PAYOUT_FAILED (err u417))
(define-constant ERR_EMPTY_POOL (err u418))
(define-constant ERR_DUST_DRAW (err u419))
(define-constant ERR_EMPTY_LINK (err u421))
(define-constant ERR_SELF_VOTE (err u423))
(define-constant ERR_DUST_CONTRIBUTION (err u426))
(define-constant ERR_PROPOSE_TOO_SOON (err u432))
(define-constant ERR_EMPTY_TITLE (err u433))
(define-constant ERR_HAS_LIVE_PROPOSAL (err u434))
(define-constant ERR_EMPTY_RATIONALE (err u440))

;; Voting weight per principal and the total outstanding
(define-map Weights
  principal
  uint
)
(define-data-var TotalWeight uint u0)

;; Weight locked by a live proposal
(define-map LockedWeight
  principal
  uint
)

;; Height at which each bond stops locking
(define-map BondUnlockAt
  principal
  uint
)

;; Most recent proposal id per principal
(define-map LiveProposal
  principal
  uint
)

;; Height of the most recent proposal by anyone
(define-data-var LastProposeAt uint u0)

;; Proposal counter starting at 1
(define-data-var LastProposalId uint u0)

;; One record per proposal id
(define-map Stories
  uint
  {
    proposer: principal,
    bond: uint,
    draw: uint,
    createdAt: uint,
    voteEnd: uint,
    eligibleSnapshot: uint,
    yesWeight: uint,
    noWeight: uint,
    voterCount: uint,
    status: uint,
    reason: (string-ascii 16),
  }
)

;; Story text and ordinals link, never read by the contract
(define-map StoryMeta
  uint
  {
    title: (string-ascii 128),
    description: (string-ascii 512),
    link: (string-ascii 200),
  }
)

;; One vote per principal per proposal
(define-map Votes
  {
    proposalId: uint,
    voter: principal,
  }
  {
    support: bool,
    weight: uint,
    rationale: (string-ascii 256),
  }
)

;; Which timing build this is
(define-read-only (get-timing-mode)
  "TEST-STACKS-BLOCKS"
)

;; All governance parameters
(define-read-only (get-params)
  {
    votingQuorum: VOTING_QUORUM,
    votingThreshold: VOTING_THRESHOLD,
    minParticipants: MIN_PARTICIPANTS,
    minWeight: MIN_WEIGHT,
    minContribution: MIN_CONTRIBUTION,
    drawBps: DRAW_BPS,
    votingDelay: VOTING_DELAY,
    voteWindow: VOTE_WINDOW,
    concludeWindow: CONCLUDE_WINDOW,
    proposeInterval: PROPOSE_INTERVAL,
  }
)

;; Current lifecycle phase of a story
(define-read-only (get-phase (proposalId uint))
  (match (map-get? Stories proposalId)
    story (if (is-eq (get status story) STATUS_PASSED)
      "passed"
      (if (is-eq (get status story) STATUS_FAILED)
        "failed"
        (if (is-eq (get status story) STATUS_EXPIRED)
          "expired"
          (if (< stacks-block-height (+ (get createdAt story) VOTING_DELAY))
            "pending"
            (if (< stacks-block-height (get voteEnd story))
              "voting"
              (if (< stacks-block-height (+ (get voteEnd story) CONCLUDE_WINDOW))
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

(define-read-only (get-last-proposal-id)
  (var-get LastProposalId)
)

;; Height at which a bond stops locking
(define-read-only (bond-unlock-at (who principal))
  (default-to u0 (map-get? BondUnlockAt who))
)

;; Weight still locked by a live proposal
(define-read-only (locked-of (who principal))
  (if (< stacks-block-height (bond-unlock-at who))
    (default-to u0 (map-get? LockedWeight who))
    u0
  )
)

;; Weight not locked by a live proposal
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

(define-read-only (has-live-proposal (who principal))
  (> (locked-of who) u0)
)

;; Live proposal id for a principal
(define-read-only (get-live-proposal (who principal))
  (if (> (locked-of who) u0)
    (map-get? LiveProposal who)
    none
  )
)

;; Earliest height another proposal is accepted
(define-read-only (get-next-propose-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0
    (+ (var-get LastProposeAt) PROPOSE_INTERVAL)
  )
)

;; Open but past its conclude window
(define-read-only (lapsed-open (status uint) (voteEnd uint))
  (and
    (is-eq status STATUS_OPEN)
    (>= stacks-block-height (+ voteEnd CONCLUDE_WINDOW))
  )
)

;; Get a story
(define-read-only (get-story (proposalId uint))
  (match (map-get? Stories proposalId)
    story (some (if (lapsed-open (get status story) (get voteEnd story))
      (merge story { status: STATUS_EXPIRED, reason: "not-concluded" })
      story
    ))
    none
  )
)

(define-read-only (get-story-meta (proposalId uint))
  (map-get? StoryMeta proposalId)
)

;; Get a story status
(define-read-only (get-story-status (proposalId uint))
  (match (map-get? Stories proposalId)
    story (some (if (lapsed-open (get status story) (get voteEnd story))
      STATUS_EXPIRED
      (get status story)
    ))
    none
  )
)

(define-read-only (get-vote-record
    (proposalId uint)
    (voter principal)
  )
  (map-get? Votes {
    proposalId: proposalId,
    voter: voter,
  })
)

;; Whether a principal may vote a story and with what weight
(define-read-only (vote-power
    (proposalId uint)
    (who principal)
  )
  (match (map-get? Stories proposalId)
    story (some {
      weight: (get-weight who),
      meetsFloor: (>= (get-weight who) MIN_WEIGHT),
      isProposer: (is-eq who (get proposer story)),
    })
    none
  )
)

;; What a story would pay if proposed now
(define-read-only (quote-draw)
  (/ (* (contract-call? .news-treasury-v6 get-balance) DRAW_BPS) u10000)
)

;; Weight a contribution would mint now
(define-read-only (quote-weight (amount uint))
  (let (
      (bal (contract-call? .news-treasury-v6 get-weighted-balance))
      (total (var-get TotalWeight))
    )
    (if (or (is-eq total u0) (is-eq bal u0))
      amount
      (/ (* amount total) bal)
    )
  )
)

;; Every propose precondition
(define-read-only (propose-status (who principal))
  (let (
      (pool (contract-call? .news-treasury-v6 get-balance))
      (weight (get-weight who))
      (draw (/ (* pool DRAW_BPS) u10000))
      (nextHeight (get-next-propose-height))
      (eligible (>= weight MIN_WEIGHT))
      (slotOpen (>= stacks-block-height nextHeight))
      (noLive (is-eq (locked-of who) u0))
      (poolOk (and (> pool u0) (> draw u0)))
    )
    {
      canPropose: (and eligible slotOpen noLive poolOk),
      eligible: eligible,
      slotOpen: slotOpen,
      noLiveProposal: noLive,
      poolOk: poolOk,
      nextProposeHeight: nextHeight,
      lockOnPropose: weight,
      draw: draw,
      freeWeight: (get-free-weight who),
    }
  )
)

;; Deterministic payout id
(define-read-only (payout-ref
    (proposalId uint)
    (recipient principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    id: proposalId,
    r: recipient,
  })))
)

;; Send sBTC to the pool and receive voting weight
(define-public (contribute (amount uint))
  (let (
      (balBefore (contract-call? .news-treasury-v6 get-weighted-balance))
      (total (var-get TotalWeight))
      (minted (if (or (is-eq total u0) (is-eq balBefore u0))
        amount
        (/ (* amount total) balBefore)
      ))
      (next (+ (get-weight tx-sender) minted))
    )
    (asserts! (>= amount MIN_CONTRIBUTION) ERR_BELOW_MIN_CONTRIBUTION)
    (asserts! (> minted u0) ERR_DUST_CONTRIBUTION)
    (try! (contract-call? .news-treasury-v6 contribute-in amount))
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

;; Open a vote on one story and lock the proposer weight
(define-public (propose-story
    (link (string-ascii 200))
    (title (string-ascii 128))
    (description (string-ascii 512))
  )
  (let (
      (pool (contract-call? .news-treasury-v6 get-balance))
      (proposerWeight (get-weight tx-sender))
      (eligible (- (var-get TotalWeight) proposerWeight))
      (voteEnd (+ stacks-block-height VOTING_DELAY VOTE_WINDOW))
      (lapseAt (+ voteEnd CONCLUDE_WINDOW))
      (draw (/ (* pool DRAW_BPS) u10000))
      (newId (+ (var-get LastProposalId) u1))
    )
    (asserts! (> (len link) u0) ERR_EMPTY_LINK)
    (asserts! (> (len title) u0) ERR_EMPTY_TITLE)
    (asserts! (> pool u0) ERR_EMPTY_POOL)
    (asserts! (> draw u0) ERR_DUST_DRAW)
    (asserts! (is-eq (locked-of tx-sender) u0) ERR_HAS_LIVE_PROPOSAL)
    (asserts!
      (>= stacks-block-height (get-next-propose-height))
      ERR_PROPOSE_TOO_SOON
    )
    (asserts! (>= proposerWeight MIN_WEIGHT) ERR_INELIGIBLE)

    (var-set LastProposeAt stacks-block-height)
    (var-set LastProposalId newId)
    (map-set LiveProposal tx-sender newId)
    (map-set LockedWeight tx-sender proposerWeight)
    (map-set BondUnlockAt tx-sender lapseAt)
    (map-set StoryMeta newId {
      title: title,
      description: description,
      link: link,
    })
    (map-set Stories newId {
      proposer: tx-sender,
      bond: proposerWeight,
      draw: draw,
      createdAt: stacks-block-height,
      voteEnd: voteEnd,
      eligibleSnapshot: eligible,
      yesWeight: u0,
      noWeight: u0,
      voterCount: u0,
      status: STATUS_OPEN,
      reason: "",
    })
    (print {
      event: "propose-story",
      proposalId: newId,
      proposer: tx-sender,
      link: link,
      title: title,
      bond: proposerWeight,
      draw: draw,
      voteEnd: voteEnd,
      eligibleSnapshot: eligible,
    })
    (ok newId)
  )
)

;; Cast a weighted yes or no with a written reason
(define-public (vote
    (proposalId uint)
    (support bool)
    (rationale (string-ascii 256))
  )
  (let (
      (story (unwrap! (map-get? Stories proposalId) ERR_NO_PROPOSAL))
      (weight (get-weight tx-sender))
    )
    (asserts! (is-eq (get status story) STATUS_OPEN) ERR_VOTE_CLOSED)
    (asserts! (>= stacks-block-height (+ (get createdAt story) VOTING_DELAY)) ERR_VOTE_NOT_STARTED)
    (asserts! (< stacks-block-height (get voteEnd story)) ERR_VOTE_CLOSED)
    (asserts! (> (len rationale) u0) ERR_EMPTY_RATIONALE)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts! (not (is-eq tx-sender (get proposer story))) ERR_SELF_VOTE)
    (asserts!
      (is-none (map-get? Votes {
        proposalId: proposalId,
        voter: tx-sender,
      }))
      ERR_ALREADY_VOTED
    )
    (map-set Votes {
      proposalId: proposalId,
      voter: tx-sender,
    } {
      support: support,
      weight: weight,
      rationale: rationale,
    })
    (map-set Stories proposalId
      (merge story {
        yesWeight: (if support
          (+ (get yesWeight story) weight)
          (get yesWeight story)
        ),
        noWeight: (if support
          (get noWeight story)
          (+ (get noWeight story) weight)
        ),
        voterCount: (+ (get voterCount story) u1),
      }))
    (print {
      event: "vote",
      proposalId: proposalId,
      voter: tx-sender,
      support: support,
      weight: weight,
      rationale: rationale,
    })
    (ok true)
  )
)

;; Settle a story and pay the proposer if it passed
(define-public (conclude (proposalId uint))
  (let (
      (story (unwrap! (map-get? Stories proposalId) ERR_NO_PROPOSAL))
      (proposer (get proposer story))
      (eligible (get eligibleSnapshot story))
      (cast (+ (get yesWeight story) (get noWeight story)))
      (quorumMet (and
        (> eligible u0)
        (>= (get voterCount story) MIN_PARTICIPANTS)
        (>= (/ (* cast u100) eligible) VOTING_QUORUM)
      ))
      (thresholdMet (and
        (> cast u0)
        (>= (/ (* (get yesWeight story) u100) cast) VOTING_THRESHOLD)
      ))
      (draw (get draw story))
      (poolShort (> draw (contract-call? .news-treasury-v6 get-balance)))
    )
    (asserts! (is-eq (get status story) STATUS_OPEN) ERR_PROPOSAL_CONCLUDED)
    (asserts! (>= stacks-block-height (get voteEnd story)) ERR_VOTE_STILL_OPEN)
    (asserts!
      (< stacks-block-height (+ (get voteEnd story) CONCLUDE_WINDOW))
      ERR_CONCLUDE_WINDOW_PASSED
    )
    (if (is-eq (map-get? LiveProposal proposer) (some proposalId))
      (begin
        (map-set LockedWeight proposer u0)
        (map-delete LiveProposal proposer)
      )
      true
    )

    (if (not quorumMet)
      (begin
        (map-set Stories proposalId
          (merge story { status: STATUS_FAILED, reason: "no-quorum" }))
        (print {
          event: "conclude", proposalId: proposalId, outcome: "failed",
          reason: "no-quorum", cast: cast, eligible: eligible,
          voterCount: (get voterCount story),
        })
        (ok STATUS_FAILED)
      )
      (if (not thresholdMet)
        (begin
          (map-set Stories proposalId
            (merge story { status: STATUS_FAILED, reason: "voted-down" }))
          (print {
            event: "conclude", proposalId: proposalId, outcome: "failed",
            reason: "voted-down", yesWeight: (get yesWeight story),
            noWeight: (get noWeight story),
          })
          (ok STATUS_FAILED)
        )
        (if poolShort
          (begin
            (map-set Stories proposalId
              (merge story { status: STATUS_FAILED, reason: "pool-short" }))
            (print {
              event: "conclude", proposalId: proposalId, outcome: "failed",
              reason: "pool-short", draw: draw,
            })
            (ok STATUS_FAILED)
          )
          (begin
            (asserts! (> draw u0) ERR_DUST_DRAW)
            (map-set Stories proposalId
              (merge story { status: STATUS_PASSED, reason: "paid" }))
            (unwrap!
              (contract-call? .news-treasury-v6 execute-payout
                proposer draw (payout-ref proposalId proposer))
              ERR_PAYOUT_FAILED
            )
            (print {
              event: "conclude", proposalId: proposalId, outcome: "passed",
              draw: draw, recipient: proposer,
              yesWeight: (get yesWeight story), noWeight: (get noWeight story),
            })
            (ok STATUS_PASSED)
          )
        )
      )
    )
  )
)
