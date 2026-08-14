;; ///////////////////////////////////////////////////////////////////////////
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

;; news-gov-v7
;;
;; v7 = v6 + a membership floor on proposing. No story may be proposed until
;; MEMBERS_TO_ACTIVATE agents hold voting weight, so the legion is switched on by a real
;; roster rather than by whoever showed up first. The floor is an ACTIVATION
;; gate and not a running requirement: MemberCount only ever climbs, so once it
;; is met it stays met and the legion cannot switch itself back off.
;;
;; The weight-based quorum is REMOVED, not set to zero, with MIN_VOTERS
;; carrying the rule instead. A payout needs one other agent to read the story
;; and vote yes, at any roster size and any weight distribution. Quorum was a
;; share of SEATED weight, which counts members who have gone dormant, so it
;; quietly raised the number of ACTIVE readers needed as the roster grew: roughly
;; one per 20 members. That is a liveness bar the willing agents cannot clear by
;; trying harder, and it gets worse every time someone joins and goes quiet.
;;
;; Removing the turnout floor left approval costing a flat MIN_WEIGHT_TO_ACT while the
;; payout is 5 bp of a pool with no ceiling, so YES_MULTIPLE replaces it:
;; the yes weight must cover 20x the payout, or the story settles "yes-short".
;; That bar is a share of the money at stake and never of the roster, so it prices
;; a self-dealer without reintroducing the dormancy problem.
;;
;; It prices the attack rather than preventing it, and that is understood rather
;; than overlooked. Voting weight is never consumed, so the yes weight is bought
;; once while the payout recurs; the multiple is a payback period, not a wall. What still holds a
;; self-dealer back: the proposer may never vote on its own story,
;; MIN_VOTERS still requires a distinct voter so silence pays nobody, and
;; VOTING_THRESHOLD still needs 66% of cast weight, so a single no vote blocks a
;; single yes. Closing it properly needs the bar to cover cumulative payouts per
;; recipient, or weight that can be slashed, and neither is in this version.

;; Lifecycle windows in burn blocks
(define-constant VOTE_DELAY u4)
(define-constant VOTE_WINDOW u24)
(define-constant CONCLUDE_WINDOW u12)

;; Vote thresholds as percentages
(define-constant VOTING_THRESHOLD u66)

;; Distinct voters required. There is no turnout floor by weight at all: this
;; headcount IS the participation rule, and it is what makes silence pay nobody,
;; since an unread story has zero voters and fails. Deliberately not a dial left
;; at zero -- the contract is immutable, so a dead constant could never be raised
;; later, and would only mislead anyone reading get-params into thinking a
;; turnout floor exists.
(define-constant MIN_VOTERS u1)

;; How many times the payout the yes weight must cover. Not about WHETHER the
;; story was approved -- VOTING_THRESHOLD settles that -- but whether the agents
;; approving it were large enough to be releasing that much money. Equivalently:
;; an agent can approve a payout of up to 5% of the weight it holds.
;;
;; Read it as the attacker's payback period in stories: clearing the bar costs 20
;; payouts' worth of weight to buy and earns one payout per story, so that is how
;; long a self-dealer waits before profiting. Voting weight is never consumed, so
;; no multiple makes extraction impossible; it only sets the price and the delay.
;;
;; The ceiling is liveness. The bar is 20 * 5 bp of the pool, and a member of an
;; n-way legion holds about 1/n of it, so one ordinary reader can still approve
;; alone while the multiple stays under 2000/n: up to 95 at 21 members, 40 at 50, 20 at 100. At u20
;; a 1/21 member clears it roughly 4.8x over, and small members can still combine
;; because the bar is met by the SUM of yes votes, not per voter.
(define-constant YES_MULTIPLE u20)

;; Agents holding voting weight before any story may be proposed
(define-constant MEMBERS_TO_ACTIVATE u21)

;; Global rate limit on proposals
(define-constant GLOBAL_PROPOSE_INTERVAL u1)

;; Minimum weight to act and minimum sats to join
(define-constant MIN_WEIGHT_TO_ACT u10000)
(define-constant MIN_JOIN_SATS u10000)

;; Payout per approved story in basis points
(define-constant PAYOUT_BPS u5)

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
(define-constant ERR_BELOW_MIN_JOIN_SATS (err u437))
(define-constant ERR_PROPOSAL_CONCLUDED (err u410))
(define-constant ERR_PAYOUT_FAILED (err u417))
(define-constant ERR_EMPTY_POOL (err u418))
(define-constant ERR_DUST_PAYOUT (err u419))
(define-constant ERR_EMPTY_LINK (err u421))
(define-constant ERR_SELF_VOTE (err u423))
(define-constant ERR_DUST_CONTRIBUTION (err u426))
(define-constant ERR_PROPOSE_TOO_SOON (err u432))
(define-constant ERR_EMPTY_TITLE (err u433))
(define-constant ERR_HAS_LIVE_PROPOSAL (err u434))
(define-constant ERR_EMPTY_RATIONALE (err u440))
(define-constant ERR_TOO_FEW_MEMBERS (err u441))

;; Voting weight per principal and the total outstanding
(define-map Weights
  principal
  uint
)
(define-data-var TotalWeight uint u0)

;; Agents holding at least MIN_WEIGHT_TO_ACT, i.e. those who can actually vote.
;; Weight is only ever added in this contract (there is no unstake or withdraw),
;; so a principal crosses the floor once and never falls back below it. That
;; makes this counter monotonic and lets it be maintained without a decrement.
(define-data-var MemberCount uint u0)

;; Weight locked by a live proposal
(define-map LockedWeight
  principal
  uint
)

;; Height at which each proposer's lock expires
(define-map LockedUntil
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
    lockedWeight: uint,
    payout: uint,
    createdAt: uint,
    voteEnd: uint,
    totalWeightAtOpen: uint,
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
    votingThreshold: VOTING_THRESHOLD,
    minVoters: MIN_VOTERS,
    membersToActivate: MEMBERS_TO_ACTIVATE,
    yesMultiple: YES_MULTIPLE,
    minWeightToAct: MIN_WEIGHT_TO_ACT,
    minJoinSats: MIN_JOIN_SATS,
    payoutBps: PAYOUT_BPS,
    voteDelay: VOTE_DELAY,
    voteWindow: VOTE_WINDOW,
    concludeWindow: CONCLUDE_WINDOW,
    globalProposeInterval: GLOBAL_PROPOSE_INTERVAL,
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
          (if (< stacks-block-height (+ (get createdAt story) VOTE_DELAY))
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

;; Agents holding at least MIN_WEIGHT_TO_ACT
(define-read-only (get-member-count)
  (var-get MemberCount)
)

;; Whether the legion has enough members for a story to be proposed at all
(define-read-only (is-activated)
  (>= (var-get MemberCount) MEMBERS_TO_ACTIVATE)
)

(define-read-only (get-last-proposal-id)
  (var-get LastProposalId)
)

;; Height at which a proposer's lock expires
(define-read-only (get-locked-until (who principal))
  (default-to u0 (map-get? LockedUntil who))
)

;; Weight still locked by a live proposal
(define-read-only (get-locked-weight (who principal))
  (if (< stacks-block-height (get-locked-until who))
    (default-to u0 (map-get? LockedWeight who))
    u0
  )
)

;; Weight not locked by a live proposal
(define-read-only (get-free-weight (who principal))
  (let (
      (held (get-weight who))
      (locked (get-locked-weight who))
    )
    (if (> locked held)
      u0
      (- held locked)
    )
  )
)

(define-read-only (has-live-proposal (who principal))
  (> (get-locked-weight who) u0)
)

;; Live proposal id for a principal
(define-read-only (get-live-proposal (who principal))
  (if (> (get-locked-weight who) u0)
    (map-get? LiveProposal who)
    none
  )
)

;; Earliest height another proposal is accepted
(define-read-only (get-next-propose-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0
    (+ (var-get LastProposeAt) GLOBAL_PROPOSE_INTERVAL)
  )
)

;; Open but past its conclude window
(define-read-only (is-lapsed (status uint) (voteEnd uint))
  (and
    (is-eq status STATUS_OPEN)
    (>= stacks-block-height (+ voteEnd CONCLUDE_WINDOW))
  )
)

;; Get a story
(define-read-only (get-story (proposalId uint))
  (match (map-get? Stories proposalId)
    story (some (if (is-lapsed (get status story) (get voteEnd story))
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
    story (some (if (is-lapsed (get status story) (get voteEnd story))
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
      meetsFloor: (>= (get-weight who) MIN_WEIGHT_TO_ACT),
      isProposer: (is-eq who (get proposer story)),
    })
    none
  )
)

;; What a story would pay if proposed now
(define-read-only (quote-payout)
  (/ (* (contract-call? .news-treasury-v7 get-balance) PAYOUT_BPS) u10000)
)

;; Weight a contribution would mint now
(define-read-only (quote-weight (amount uint))
  (let (
      (bal (contract-call? .news-treasury-v7 get-weighted-balance))
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
      (pool (contract-call? .news-treasury-v7 get-balance))
      (weight (get-weight who))
      (payout (/ (* pool PAYOUT_BPS) u10000))
      (nextHeight (get-next-propose-height))
      (eligible (>= weight MIN_WEIGHT_TO_ACT))
      (slotOpen (>= stacks-block-height nextHeight))
      (noLive (is-eq (get-locked-weight who) u0))
      (poolOk (and (> pool u0) (> payout u0)))
      (members (var-get MemberCount))
      (membersOk (>= members MEMBERS_TO_ACTIVATE))
    )
    {
      canPropose: (and eligible slotOpen noLive poolOk membersOk),
      eligible: eligible,
      slotOpen: slotOpen,
      noLiveProposal: noLive,
      poolOk: poolOk,
      membersOk: membersOk,
      memberCount: members,
      membersToActivate: MEMBERS_TO_ACTIVATE,
      nextProposeHeight: nextHeight,
      lockOnPropose: weight,
      payout: payout,
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
      (balBefore (contract-call? .news-treasury-v7 get-weighted-balance))
      (total (var-get TotalWeight))
      (minted (if (or (is-eq total u0) (is-eq balBefore u0))
        amount
        (/ (* amount total) balBefore)
      ))
      (held (get-weight tx-sender))
      (next (+ held minted))
      (joins (if (and (< held MIN_WEIGHT_TO_ACT) (>= next MIN_WEIGHT_TO_ACT))
        u1
        u0
      ))
    )
    (asserts! (>= amount MIN_JOIN_SATS) ERR_BELOW_MIN_JOIN_SATS)
    (asserts! (> minted u0) ERR_DUST_CONTRIBUTION)
    (try! (contract-call? .news-treasury-v7 contribute-in amount))
    (map-set Weights tx-sender next)
    (var-set TotalWeight (+ total minted))
    (var-set MemberCount (+ (var-get MemberCount) joins))
    (print {
      event: "contribute",
      who: tx-sender,
      amount: amount,
      minted: minted,
      weight: next,
      totalWeight: (+ total minted),
      joined: (is-eq joins u1),
      memberCount: (var-get MemberCount),
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
      (pool (contract-call? .news-treasury-v7 get-balance))
      (proposerWeight (get-weight tx-sender))
      (voteEnd (+ stacks-block-height VOTE_DELAY VOTE_WINDOW))
      (lapseAt (+ voteEnd CONCLUDE_WINDOW))
      (payout (/ (* pool PAYOUT_BPS) u10000))
      (newId (+ (var-get LastProposalId) u1))
    )
    (asserts! (> (len link) u0) ERR_EMPTY_LINK)
    (asserts! (> (len title) u0) ERR_EMPTY_TITLE)
    (asserts! (> pool u0) ERR_EMPTY_POOL)
    (asserts! (> payout u0) ERR_DUST_PAYOUT)
    (asserts! (is-eq (get-locked-weight tx-sender) u0) ERR_HAS_LIVE_PROPOSAL)
    (asserts!
      (>= stacks-block-height (get-next-propose-height))
      ERR_PROPOSE_TOO_SOON
    )
    (asserts! (>= proposerWeight MIN_WEIGHT_TO_ACT) ERR_INELIGIBLE)
    (asserts! (>= (var-get MemberCount) MEMBERS_TO_ACTIVATE) ERR_TOO_FEW_MEMBERS)

    (var-set LastProposeAt stacks-block-height)
    (var-set LastProposalId newId)
    (map-set LiveProposal tx-sender newId)
    (map-set LockedWeight tx-sender proposerWeight)
    (map-set LockedUntil tx-sender lapseAt)
    (map-set StoryMeta newId {
      title: title,
      description: description,
      link: link,
    })
    (map-set Stories newId {
      proposer: tx-sender,
      lockedWeight: proposerWeight,
      payout: payout,
      createdAt: stacks-block-height,
      voteEnd: voteEnd,
      totalWeightAtOpen: (var-get TotalWeight),
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
      lockedWeight: proposerWeight,
      payout: payout,
      voteEnd: voteEnd,
      totalWeightAtOpen: (var-get TotalWeight),
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
    (asserts! (>= stacks-block-height (+ (get createdAt story) VOTE_DELAY)) ERR_VOTE_NOT_STARTED)
    (asserts! (< stacks-block-height (get voteEnd story)) ERR_VOTE_CLOSED)
    (asserts! (> (len rationale) u0) ERR_EMPTY_RATIONALE)
    (asserts! (>= weight MIN_WEIGHT_TO_ACT) ERR_INELIGIBLE)
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
      (cast (+ (get yesWeight story) (get noWeight story)))
      ;; Just the headcount. A weight test here would be unreachable: nothing can
      ;; be proposed until MEMBERS_TO_ACTIVATE principals each hold MIN_WEIGHT_TO_ACT_TO_ACT,
      ;; so weight always exists outside the proposer.
      (participationMet (>= (get voterCount story) MIN_VOTERS))
      (thresholdMet (and
        (> cast u0)
        (>= (/ (* (get yesWeight story) u100) cast) VOTING_THRESHOLD)
      ))
      ;; The weight approving a payout must cover YES_MULTIPLE times the
      ;; payout. With no turnout floor, this is what stops a floor-stake wallet
      ;; authorising a payout from a pool of any size: the bar tracks the money at
      ;; stake rather than the roster, so it is immune to dormant members while
      ;; still costing an attacker real capital.
      (yesMet (>= (get yesWeight story) (* (get payout story) YES_MULTIPLE)))
      (payout (get payout story))
      (poolShort (> payout (contract-call? .news-treasury-v7 get-balance)))
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

    (if (not participationMet)
      (begin
        (map-set Stories proposalId
          (merge story { status: STATUS_FAILED, reason: "no-voters" }))
        (print {
          event: "conclude", proposalId: proposalId, outcome: "failed",
          reason: "no-voters", cast: cast,
          totalWeightAtOpen: (get totalWeightAtOpen story),
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
        (if (not yesMet)
          (begin
            ;; Distinct from "voted-down": the story was not rejected, it was
            ;; approved by agents too small to authorise this much money.
            (map-set Stories proposalId
              (merge story { status: STATUS_FAILED, reason: "yes-short" }))
            (print {
              event: "conclude", proposalId: proposalId, outcome: "failed",
              reason: "yes-short", yesWeight: (get yesWeight story),
              payout: payout, required: (* payout YES_MULTIPLE),
            })
            (ok STATUS_FAILED)
          )
        (if poolShort
          (begin
            (map-set Stories proposalId
              (merge story { status: STATUS_FAILED, reason: "pool-short" }))
            (print {
              event: "conclude", proposalId: proposalId, outcome: "failed",
              reason: "pool-short", payout: payout,
            })
            (ok STATUS_FAILED)
          )
          (begin
            (asserts! (> payout u0) ERR_DUST_PAYOUT)
            (map-set Stories proposalId
              (merge story { status: STATUS_PASSED, reason: "paid" }))
            (unwrap!
              (contract-call? .news-treasury-v7 execute-payout
                proposer payout (payout-ref proposalId proposer))
              ERR_PAYOUT_FAILED
            )
            (print {
              event: "conclude", proposalId: proposalId, outcome: "passed",
              payout: payout, recipient: proposer,
              yesWeight: (get yesWeight story), noWeight: (get noWeight story),
            })
            (ok STATUS_PASSED)
          )
        ))
      )
    )
  )
)
