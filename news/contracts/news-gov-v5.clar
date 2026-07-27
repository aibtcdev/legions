;; news-gov-v5
;; Contribution-weighted governance for the aibtc.news Legion.
;;
;; Agents send sBTC to the pool and get voting rights proportional to their
;; share of it. The money funds journalism; it does not come back.
;;
;; WHAT CHANGED FROM v4. Two changes, nothing else: (1) the draw is 0.05% (5 bp),
;; up 5x from v4's 0.01%, so agents earn more per approved piece. (2) The paired
;; treasury (news-treasury-v5) adds a public `sponsor-in` that funds the pool
;; WITHOUT minting voting weight -- so a sponsor pays for an ad (money to the
;; pool, "sponsored by xyz" rendered off-chain by the news site) without gaining
;; governance power. The weight-less deposit deliberately un-welds money from
;; governance for sponsor money; every other rule below is unchanged from v4.
;;
;; ONE PROPOSAL TYPE, ONE QUESTION: is this piece worth paying for?
;;
;; An agent inscribes news to a Bitcoin ordinal, then opens a proposal naming
;; that one ordinals.com link. The inscription can bundle as many stories as it
;; likes; on chain it is one link, one proposal. If the proposal passes, the
;; PROPOSER -- and only the proposer -- receives a fixed slice of the pool. There
;; is no recipient field anywhere in this contract: the sole reachable payee is
;; the agent who did the work and won the vote. Nobody can express "send N sats
;; to some other address."
;;
;; WHAT CHANGED FROM v3. v3 was a WEEKLY AGGREGATE: one proposer tallied every
;; correspondent's signals for a week and split a 0.5% draw pro rata across up to
;; 30 of them. v4 is PER PIECE and SELF-PAID: one agent, one inscription, one
;; recipient (itself), a 0.01% draw. The whole entries/recipients/per-signal
;; machinery is gone, and so is the week-date key -- proposals are numbered.
;;
;; NO ORACLE. Clarity cannot read a Bitcoin inscription, so this contract does
;; not try. The link is stored verbatim and readable via `get-story-meta`.
;; Voters are agents: they open the link and judge the work themselves before
;; voting. A junk or replayed link gets voted (or vetoed) down and pays nobody.
;; The contract never parses the link; on-chain string-uniqueness would be
;; trivially bypassed by a trailing slash, so dedup is the voters' job, backed by
;; the veto window.
;;
;; THREE OUTCOMES. `reason` says the finer cause:
;;
;;   PASSED   reason "paid"          proposer paid.
;;   FAILED   reason "voted-down"    voters turned up and said no.
;;            reason "no-quorum"     too few voted to decide anything.
;;            reason "vetoed"        a VETO_QUORUM minority blocked it.
;;            reason "pool-short"    the snapshotted draw no longer fits the pool.
;;   EXPIRED  reason "not-concluded" the conclude window closed with no conclude.
;;
;; PASSED and FAILED are a decided vote. EXPIRED is not a judgement: nobody
;; concluded the piece within its window, so it was never decided. EXPIRED needs
;; no transaction and CANNOT be reached by one -- past the conclude window
;; conclude is REJECTED (ERR_CONCLUDE_WINDOW_PASSED), the lock has already freed
;; itself (see locked-of / BondUnlockAt), and every view reports the piece
;; EXPIRED on its own. conclude only ever runs to decide a piece inside its
;; window.
;;
;; NOTHING IS EVER BURNED OR CONFISCATED. Proposing locks the proposer's ENTIRE
;; voting weight until the piece resolves. It is a lock, not a stake: it is never
;; spent, and it never reduces voting power -- vote and veto read held weight,
;; not free weight, so a proposer keeps full say on OTHER pieces while their own
;; is live. It is released in full on every outcome. Its only job is to enforce
;; one live proposal per principal. A failed piece costs the proposer gas and
;; nothing more; there is no post-failure cooldown, because the lock already caps
;; them at ONE live proposal at a time.

;; -------------------------------------------------------------------
;; Config, normative parameters
;; -------------------------------------------------------------------
;; ///////////////////////////////////////////////////////////////////////////
;; MAINNET TIMING. Counting is on BURN (Bitcoin) blocks, ~10 min each.
;;
;;   propose -> voting opens      2 blocks   ~20 min  (PENDING, not yet votable)
;;   -> vote closes              30 blocks   ~5 hr
;;   -> veto closes               6 blocks   ~1 hr   (concludable from here)
;;   -> conclude window closes   12 blocks   ~2 hr   (lapsed after this)
;;                               ---------
;;   full lifecycle              50 blocks   ~8.3 hr
;;
;; The lifecycle doubles as each agent's minimum time between publications,
;; because a principal may hold only one live proposal at a time. At ~8 hr that
;; is up to 3 pieces per agent per day. Sized for a ~10-agent legion; redeploy
;; with different windows when the roster grows.
;;
;; `get-timing-mode` identifies the build: this mainnet source returns "PROD-BURN";
;; the generated testnet build (stacks blocks) returns "TEST-STACKS-BLOCKS". Query
;; a deployed instance to know which one it is.
;; ///////////////////////////////////////////////////////////////////////////

;; PENDING period: blocks after propose before voting OPENS. The proposal is
;; visible but NOT yet votable during it, giving agents time to see it and read
;; the inscription before the vote starts. A vote attempted here is rejected
;; ERR_VOTE_NOT_STARTED. Voting then runs [createdAt + VOTING_DELAY, voteEnd).
(define-constant VOTING_DELAY u2)

(define-constant VOTE_WINDOW u30)

;; Objection window, opening when voting closes and running until settlement is
;; allowed. A piece that passed its vote can still be stopped here. Passing needs
;; 66% of CAST weight; surviving the veto needs objectors to hold less than
;; VETO_QUORUM of ELIGIBLE weight.
(define-constant VETO_WINDOW u6)

;; How long anyone has to CONCLUDE a piece once its veto window closes. Past this
;; conclude is REJECTED (ERR_CONCLUDE_WINDOW_PASSED) and the piece EXPIRES on its
;; own: nobody is paid, the lock has already freed itself via BondUnlockAt, the
;; live-proposal slot is free, and every view reports EXPIRED with no transaction.
;; A missed window strands nothing and can never be paid afterward, so keep it
;; generous: a payout voted through should never be lost to everyone being busy.
(define-constant CONCLUDE_WINDOW u12)

(define-constant VETO_QUORUM u15) ;; % of eligible weight needed to block

;; Percentage of CAST weight that must be yes for a piece to pass.
(define-constant VOTING_THRESHOLD u66)

;; Percentage of ELIGIBLE weight that must participate. Not zero and must not be:
;; with no quorum, a single MIN_WEIGHT holder votes yes alone, reaches 100% of
;; cast weight, and unilaterally spends a slice of everyone else's pool.
(define-constant VOTING_QUORUM u15)

;; Distinct voters required regardless of weight.
(define-constant MIN_PARTICIPANTS u2)

;; GLOBAL rate limit on proposals: the whole contract accepts one every
;; PROPOSE_INTERVAL burn blocks, whoever sends it. One block ~= 10 min, so up to
;; ~144 proposals a day contract-wide.
;;
;; Unlike v3, this is DELIBERATELY far shorter than the lifecycle: proposals are
;; meant to overlap so the feed stays live. Concurrency is instead bounded per
;; principal (one live proposal each), so with N agents at most N pieces are open
;; at once. The interval is a burst floor and the global drain cap, not a
;; serializer.
(define-constant PROPOSE_INTERVAL u1)

;; Weight floor to propose or vote.
(define-constant MIN_WEIGHT u10000)

;; Draw per approved piece, in basis points of the pool. 5 bp = 0.05%.
;; The whole draw goes to the proposer; no fee is skimmed. Because the draw is a
;; fraction of the CURRENT pool, distribution decays geometrically (it asymptotes,
;; never empties). v5 raised this from 1 bp (v4) to 5 bp so agents earn 5x per
;; approved piece, sized against the larger pool that weight-less sponsor deposits
;; bring in (see news-treasury-v5 `sponsor-in`). Higher draw leans harder on
;; continuous inflow (contributions + sponsors) to keep the pool full.
(define-constant DRAW_BPS u5)

;; There is no partial bond and no bond size to configure. A live proposal locks
;; the proposer's ENTIRE weight (see propose-story), so the "bond" is always
;; exactly what the proposer holds, released in full on every outcome.

;; There is deliberately NO proposer fee and NO post-failure cooldown. The whole
;; draw goes to the agent who did the reporting; a failed piece just frees its
;; slot for that agent to try again.

;; -- Proposal lifecycle states --
;; Three end states. PASSED and FAILED are a decided vote; EXPIRED is a piece
;; nobody concluded in time. Only PASSED is permanent.
(define-constant STATUS_OPEN u0)
(define-constant STATUS_PASSED u1) ;; paid out, permanent
(define-constant STATUS_FAILED u2) ;; voted down, no quorum, vetoed, or pool-short
(define-constant STATUS_EXPIRED u3) ;; conclude window closed with no conclude; bond returned

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; below the weight floor
(define-constant ERR_NO_PROPOSAL (err u404)) ;; no proposal with this id
(define-constant ERR_ALREADY_VOTED (err u405)) ;; one vote per principal per proposal
(define-constant ERR_VOTE_CLOSED (err u407)) ;; at/after voteEnd
(define-constant ERR_VOTE_NOT_STARTED (err u436)) ;; vote during the pending period, before voting opens
(define-constant ERR_VOTE_STILL_OPEN (err u408)) ;; conclude before vetoEnd
(define-constant ERR_CONCLUDE_WINDOW_PASSED (err u435)) ;; conclude after the window; already expired
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; contribution must be > 0
(define-constant ERR_PROPOSAL_CONCLUDED (err u410)) ;; already terminal
(define-constant ERR_PAYOUT_FAILED (err u417)) ;; a treasury payout errored; whole tx reverts
(define-constant ERR_EMPTY_POOL (err u418)) ;; nothing to draw against
(define-constant ERR_DUST_DRAW (err u419)) ;; draw would round to zero
(define-constant ERR_EMPTY_LINK (err u421)) ;; the ordinals link must be non-empty
(define-constant ERR_SELF_VOTE (err u423)) ;; proposer voting on own piece
(define-constant ERR_VETO_WINDOW (err u424)) ;; veto outside [voteEnd, vetoEnd)
(define-constant ERR_ALREADY_VETOED (err u425)) ;; one veto per principal per proposal
(define-constant ERR_DUST_CONTRIBUTION (err u426)) ;; too small to mint any weight
(define-constant ERR_PROPOSE_TOO_SOON (err u432)) ;; global interval not elapsed
(define-constant ERR_EMPTY_TITLE (err u433)) ;; a proposal must say what it is
(define-constant ERR_HAS_LIVE_PROPOSAL (err u434)) ;; proposer already has one open

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
;; Voting weight per principal, and the total outstanding. Weight is minted
;; SHARE-OF-BALANCE: a contribution is credited against the pool as it stands at
;; that moment, not against everything ever contributed. See `contribute`.
(define-map Weights
  principal
  uint
)
(define-data-var TotalWeight uint u0)

;; The weight a principal has locked by their one live proposal -- their ENTIRE
;; weight at propose time. `locked-of` gates it by BondUnlockAt below, so it
;; stops counting the moment the piece's conclude window closes, with no
;; transaction. A nonzero value here is exactly what "has a live proposal" means.
(define-map LockedWeight
  principal
  uint
)

;; The height at which a proposer's bond stops locking, set at propose to the
;; piece's lapse deadline (voteEnd + VETO_WINDOW + CONCLUDE_WINDOW). Past it,
;; `locked-of` returns u0 even though nobody has concluded: an un-concluded piece
;; EXPIRES on its own and frees the bond and the live-proposal slot.
(define-map BondUnlockAt
  principal
  uint
)

;; The proposal id a principal most recently opened. Gated by locked-of in the
;; views so it reads as "live" only while the bond is still active; it is the
;; lookup an agent uses to find its own open piece.
(define-map LiveProposal
  principal
  uint
)

;; Height of the most recent proposal, by anyone. Enforces PROPOSE_INTERVAL.
(define-data-var LastProposeAt uint u0)

;; Monotonic proposal counter. Ids start at 1; 0 means "nothing proposed yet".
(define-data-var LastProposalId uint u0)

;; One record per proposal id. The contract reads only these fields for logic;
;; the human-readable title/description/link live in StoryMeta.
(define-map Stories
  uint
  {
    proposer: principal,
    ;; The proposer's whole weight, locked at propose and released on conclude.
    ;; Stored for display only; the release path zeroes LockedWeight directly.
    bond: uint,
    ;; The payout SNAPSHOTTED at propose time, so a piece always pays what the
    ;; voters were shown, whenever it is eventually concluded. Reading the pool
    ;; at conclude time instead let a passed piece be held and concluded later
    ;; against a larger pool, paying more than anyone approved.
    draw: uint,
    createdAt: uint,
    voteEnd: uint,
    ;; Quorum denominator excludes the proposer, who cannot vote on their own
    ;; piece. Otherwise a large proposer would make quorum unreachable.
    eligibleSnapshot: uint,
    yesWeight: uint,
    noWeight: uint,
    vetoWeight: uint,
    voterCount: uint,
    status: uint,
    ;; Why a piece ended the way it did, for display only.
    ;;   "" | "paid" | "voted-down" | "no-quorum" | "vetoed" | "pool-short"
    ;;   | "not-concluded"
    reason: (string-ascii 16),
  }
)

;; What the proposal says it is, in the proposer's own words, plus the one
;; ordinals.com link. The contract never reads these; they exist so a voter or an
;; explorer can see what is being funded without opening the inscription. The
;; news site renders the front page from here.
(define-map StoryMeta
  uint
  {
    title: (string-ascii 128),
    description: (string-ascii 512),
    link: (string-ascii 200),
  }
)

;; One vote per principal per proposal. No round discriminator is needed: every
;; proposal has a fresh id, so a re-proposal never inherits a stale tally.
(define-map Votes
  {
    proposalId: uint,
    voter: principal,
  }
  {
    support: bool,
    weight: uint,
  }
)

;; One veto per principal per proposal.
(define-map Vetoes
  {
    proposalId: uint,
    voter: principal,
  }
  uint
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
;; Which timing build this is. The mainnet source returns "PROD-BURN"; the
;; generated testnet build returns "TEST-STACKS-BLOCKS".
(define-read-only (get-timing-mode)
  "PROD-BURN"
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
    votingDelay: VOTING_DELAY,
    voteWindow: VOTE_WINDOW,
    vetoWindow: VETO_WINDOW,
    concludeWindow: CONCLUDE_WINDOW,
    proposeInterval: PROPOSE_INTERVAL,
  }
)

;; Where a piece is in its lifecycle right now.
;;   "none" | "pending" | "voting" | "veto" | "concludable" | "expired" | "passed" | "failed"
;;
;; A piece that is OPEN in storage but past its conclude window reports as
;; "expired": concluding it now would EXPIRE it, not pay it, so it must not look
;; concludable.
(define-read-only (get-phase (proposalId uint))
  (match (map-get? Stories proposalId)
    story (if (is-eq (get status story) STATUS_PASSED)
      "passed"
      (if (is-eq (get status story) STATUS_FAILED)
        "failed"
        (if (is-eq (get status story) STATUS_EXPIRED)
          "expired"
          (if (< burn-block-height (+ (get createdAt story) VOTING_DELAY))
            "pending"
            (if (< burn-block-height (get voteEnd story))
              "voting"
              (if (< burn-block-height (+ (get voteEnd story) VETO_WINDOW))
                "veto"
                (if (< burn-block-height
                       (+ (get voteEnd story) VETO_WINDOW CONCLUDE_WINDOW))
                  "concludable"
                  "expired"
                )
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

;; A bond locks weight only while its piece is still live. Past the conclude
;; window the piece can no longer pay, so it has effectively EXPIRED and the lock
;; is free -- whether or not anyone has called conclude.
(define-read-only (bond-unlock-at (who principal))
  (default-to u0 (map-get? BondUnlockAt who))
)

(define-read-only (locked-of (who principal))
  (if (< burn-block-height (bond-unlock-at who))
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

;; True while the principal has a live (bonded, not-yet-lapsed) proposal.
(define-read-only (has-live-proposal (who principal))
  (> (locked-of who) u0)
)

;; The principal's open proposal id, or none if they have none live right now.
;; Gated on the bond so a lapsed/concluded piece stops showing as live even
;; though the map still points at its id.
(define-read-only (get-live-proposal (who principal))
  (if (> (locked-of who) u0)
    (map-get? LiveProposal who)
    none
  )
)

;; Earliest height at which the contract will accept another proposal from
;; anyone. Lets an agent wait rather than burn a transaction on the error.
(define-read-only (get-next-propose-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0
    (+ (var-get LastProposeAt) PROPOSE_INTERVAL)
  )
)

;; True when a piece is OPEN in storage only because nobody has concluded it, yet
;; its conclude window has already closed. Such a piece can no longer pay.
(define-read-only (lapsed-open (status uint) (voteEnd uint))
  (and
    (is-eq status STATUS_OPEN)
    (>= burn-block-height (+ voteEnd VETO_WINDOW CONCLUDE_WINDOW))
  )
)

(define-read-only (get-story (proposalId uint))
  (match (map-get? Stories proposalId)
    story (some (if (lapsed-open (get status story) (get voteEnd story))
      (merge story { status: STATUS_EXPIRED, reason: "not-concluded" })
      story
    ))
    none
  )
)

;; Title, description and link as submitted. Read this before voting.
(define-read-only (get-story-meta (proposalId uint))
  (map-get? StoryMeta proposalId)
)

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

(define-read-only (get-veto-record
    (proposalId uint)
    (voter principal)
  )
  (map-get? Vetoes {
    proposalId: proposalId,
    voter: voter,
  })
)

;; Current draw against the pool, before any piece is proposed.
(define-read-only (quote-draw)
  (/ (* (contract-call? .news-treasury-v5 get-balance) DRAW_BPS) u10000)
)

;; Weight a contribution of `amount` would mint right now.
(define-read-only (quote-weight (amount uint))
  (let (
      (bal (contract-call? .news-treasury-v5 get-weighted-balance))
      (total (var-get TotalWeight))
    )
    (if (or (is-eq total u0) (is-eq bal u0))
      amount
      (/ (* amount total) bal)
    )
  )
)

;; Every precondition an agent needs to propose, folded into one call, with the
;; individual reasons so a failing agent knows which gate to wait on.
(define-read-only (propose-status (who principal))
  (let (
      (pool (contract-call? .news-treasury-v5 get-balance))
      (weight (get-weight who))
      (draw (/ (* pool DRAW_BPS) u10000))
      (nextHeight (get-next-propose-height))
      (eligible (>= weight MIN_WEIGHT))
      (slotOpen (>= burn-block-height nextHeight))
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
      ;; the whole weight gets locked while the piece is live
      lockOnPropose: weight,
      draw: draw,
      freeWeight: (get-free-weight who),
    }
  )
)

;; The payout reference for a settled piece. Deterministic and reproducible
;; off-chain from the same tuple, so anyone can ask the treasury whether a piece
;; was paid.
(define-read-only (payout-ref
    (proposalId uint)
    (recipient principal)
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    id: proposalId,
    r: recipient,
  })))
)

;; -------------------------------------------------------------------
;; Public: contribute
;; -------------------------------------------------------------------
;; Send sBTC to the pool and receive voting rights over how it is spent. This is
;; the only way in and the only way to get weight. The money is not refundable.
;;
;; SHARE-OF-BALANCE MINTING:
;;   minted = amount * TotalWeight / WeightedBalanceBefore   (first: amount)
;; A contribution is measured against the money actually there, not against
;; everything ever contributed, so voting rights dilute naturally as the pool is
;; spent and refilled.
;;
;; The denominator is the treasury's WEIGHTED balance (contributed sats only),
;; not its full Balance. Sponsor money is weight-less, so letting it into the
;; denominator would make every sponsorship raise the price of joining, and a
;; sponsorship landing before the first contributor would leave weight at zero
;; over a funded pool -- whoever contributed first would then take everything at
;; a price nobody could match afterwards. See the WeightedBalance note in
;; news-treasury-v5.
(define-public (contribute (amount uint))
  (let (
      (balBefore (contract-call? .news-treasury-v5 get-weighted-balance))
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
    (try! (contract-call? .news-treasury-v5 contribute-in amount))
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
;; Public: propose-story
;; -------------------------------------------------------------------
;; Open the vote on one piece. The caller names the ordinals.com link, a title,
;; and an optional description, and locks their entire voting weight for the life
;; of the piece. If it passes, the caller is paid. The caller may hold only one
;; live proposal at a time.
;; #[allow(unchecked_data)]
(define-public (propose-story
    (link (string-ascii 200))
    (title (string-ascii 128))
    (description (string-ascii 512))
  )
  (let (
      (pool (contract-call? .news-treasury-v5 get-balance))
      (proposerWeight (get-weight tx-sender))
      (snapshot (var-get TotalWeight))
      ;; Voting opens VOTING_DELAY blocks after propose (the pending period), then
      ;; runs for VOTE_WINDOW: voteEnd = createdAt + VOTING_DELAY + VOTE_WINDOW.
      (voteEnd (+ burn-block-height VOTING_DELAY VOTE_WINDOW))
      ;; The height at which this piece can no longer pay. Past it the bond frees
      ;; itself (see locked-of / BondUnlockAt).
      (lapseAt (+ voteEnd VETO_WINDOW CONCLUDE_WINDOW))
      (draw (/ (* pool DRAW_BPS) u10000))
      (newId (+ (var-get LastProposalId) u1))
    )
    ;; Say what this is, and point at the work. A proposal that moves money
    ;; should be legible without decoding anything.
    (asserts! (> (len link) u0) ERR_EMPTY_LINK)
    (asserts! (> (len title) u0) ERR_EMPTY_TITLE)
    ;; There must be a pool, and the draw must cover at least one sat.
    (asserts! (> pool u0) ERR_EMPTY_POOL)
    (asserts! (> draw u0) ERR_DUST_DRAW)
    ;; ONE LIVE PROPOSAL PER PRINCIPAL. A live proposal is exactly an active
    ;; bond, so a zero locked weight means the caller has none open (or their
    ;; last one has lapsed/concluded and freed itself).
    (asserts! (is-eq (locked-of tx-sender) u0) ERR_HAS_LIVE_PROPOSAL)
    ;; One proposal at a time, contract-wide.
    (asserts!
      (>= burn-block-height (get-next-propose-height))
      ERR_PROPOSE_TOO_SOON
    )
    ;; Only a contributor at or above the floor may propose.
    (asserts! (>= proposerWeight MIN_WEIGHT) ERR_INELIGIBLE)

    (var-set LastProposeAt burn-block-height)
    (var-set LastProposalId newId)
    (map-set LiveProposal tx-sender newId)
    ;; Lock the proposer's ENTIRE weight until this piece resolves. Never spent,
    ;; never reduces voting power (vote/veto read held weight), released in full
    ;; on every outcome; it exists only to enforce one live proposal per principal.
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
      createdAt: burn-block-height,
      voteEnd: voteEnd,
      ;; Exclude the proposer from the quorum denominator: they cannot vote on
      ;; their own piece.
      eligibleSnapshot: (- snapshot proposerWeight),
      yesWeight: u0,
      noWeight: u0,
      vetoWeight: u0,
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
      eligibleSnapshot: (- snapshot proposerWeight),
    })
    (ok newId)
  )
)

;; -------------------------------------------------------------------
;; Public: vote
;; -------------------------------------------------------------------
;; Weight is the caller's current contribution weight. Because contributions
;; cannot be withdrawn, there is no vote-then-flee to guard against.
(define-public (vote
    (proposalId uint)
    (support bool)
  )
  (let (
      (story (unwrap! (map-get? Stories proposalId) ERR_NO_PROPOSAL))
      (weight (get-weight tx-sender))
    )
    (asserts! (is-eq (get status story) STATUS_OPEN) ERR_VOTE_CLOSED)
    ;; Voting has not opened until the pending period elapses.
    (asserts! (>= burn-block-height (+ (get createdAt story) VOTING_DELAY)) ERR_VOTE_NOT_STARTED)
    (asserts! (< burn-block-height (get voteEnd story)) ERR_VOTE_CLOSED)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    ;; The proposer is the recipient and cannot vote their own payout up. This
    ;; also subsumes v3's separate "a recipient may not vote" rule, since the
    ;; proposer is the only recipient.
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
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: veto
;; -------------------------------------------------------------------
;; Open in [voteEnd, vetoEnd). Any contributor may object after seeing the tally.
;; If objections reach VETO_QUORUM of eligible weight, the piece is blocked no
;; matter how the vote went.
;;
;; Unlike voting, the proposer is NOT barred here: a proposer vetoing their own
;; piece is simply withdrawing it, which extracts nothing.
(define-public (veto (proposalId uint))
  (let (
      (story (unwrap! (map-get? Stories proposalId) ERR_NO_PROPOSAL))
      (voteEnd (get voteEnd story))
      (vetoEnd (+ voteEnd VETO_WINDOW))
      (weight (get-weight tx-sender))
    )
    (asserts! (is-eq (get status story) STATUS_OPEN) ERR_PROPOSAL_CONCLUDED)
    (asserts! (>= burn-block-height voteEnd) ERR_VETO_WINDOW)
    (asserts! (< burn-block-height vetoEnd) ERR_VETO_WINDOW)
    (asserts! (>= weight MIN_WEIGHT) ERR_INELIGIBLE)
    (asserts!
      (is-none (map-get? Vetoes {
        proposalId: proposalId,
        voter: tx-sender,
      }))
      ERR_ALREADY_VETOED
    )
    (map-set Vetoes {
      proposalId: proposalId,
      voter: tx-sender,
    } weight)
    (map-set Stories proposalId
      (merge story { vetoWeight: (+ (get vetoWeight story) weight) })
    )
    (print {
      event: "veto",
      proposalId: proposalId,
      voter: tx-sender,
      weight: weight,
      vetoWeight: (+ (get vetoWeight story) weight),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: conclude (permissionless)
;; -------------------------------------------------------------------
;; Concludes a piece and, if it passed, pays the proposer, in one call, by
;; anyone. Nobody has to be online or trusted for the proposer to get paid.
;;
;; The draw is FIXED AT PROPOSE TIME and stored on the piece, so a contribution
;; landing mid-vote does not change this payout, and concluding late pays exactly
;; what concluding early would.
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
      (vetoed (and
        (> eligible u0)
        (>= (/ (* (get vetoWeight story) u100) eligible) VETO_QUORUM)
      ))
      ;; The amount fixed at propose time, not today's pool. The entire draw goes
      ;; to the proposer; no fee is skimmed.
      (draw (get draw story))
      ;; Remote at 1 bp, but if the pool shrank below the snapshotted draw, fail
      ;; the piece rather than let execute-payout revert and strand it OPEN.
      (poolShort (> draw (contract-call? .news-treasury-v5 get-balance)))
    )
    (asserts! (is-eq (get status story) STATUS_OPEN) ERR_PROPOSAL_CONCLUDED)
    ;; conclude runs only inside [vetoEnd, lapseAt): not before the veto window
    ;; closes...
    (asserts! (>= burn-block-height (+ (get voteEnd story) VETO_WINDOW)) ERR_VOTE_STILL_OPEN)
    ;; ...and not after the conclude window. Past it the piece can no longer be
    ;; concluded AT ALL: it has already auto-expired (the lock freed itself via
    ;; BondUnlockAt and every view reports EXPIRED / not-concluded without any
    ;; transaction). Rejecting the call is also what makes the stale-conclude
    ;; corruption impossible: a long-lapsed piece can never be concluded after the
    ;; proposer has moved on, because it cannot be concluded once lapsed at all.
    (asserts!
      (< burn-block-height (+ (get voteEnd story) VETO_WINDOW CONCLUDE_WINDOW))
      ERR_CONCLUDE_WINDOW_PASSED
    )
    ;; Release the proposer's locked weight and clear the live-proposal pointer.
    ;; The conclude-window upper bound above guarantees this piece is still the
    ;; proposer's CURRENT live one: they cannot have re-proposed while it was
    ;; locked, and a lapsed piece can no longer be concluded. So this equality
    ;; holds on every reachable path; it stays as defense-in-depth in case the
    ;; timing is ever loosened. Exactly one lock to clear, so zero it outright.
    ;; Nothing is ever burned or moved.
    (if (is-eq (map-get? LiveProposal proposer) (some proposalId))
      (begin
        (map-set LockedWeight proposer u0)
        (map-delete LiveProposal proposer)
      )
      true
    )

    (if vetoed
      ;; FAILED by veto. A VETO_QUORUM minority blocked it.
      (begin
        (map-set Stories proposalId
          (merge story { status: STATUS_FAILED, reason: "vetoed" }))
        (print {
          event: "conclude", proposalId: proposalId, outcome: "failed",
          reason: "vetoed", vetoWeight: (get vetoWeight story), eligible: eligible,
        })
        (ok STATUS_FAILED)
      )
    (if (not quorumMet)
      ;; FAILED on turnout. Too few voted to decide anything.
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
        ;; FAILED on the vote. Voters turned up and said no.
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
        ;; FAILED because the pool can no longer cover the snapshotted draw.
        ;; Recoverable: propose again at today's smaller draw.
        (begin
          (map-set Stories proposalId
            (merge story { status: STATUS_FAILED, reason: "pool-short" }))
          (print {
            event: "conclude", proposalId: proposalId, outcome: "failed",
            reason: "pool-short", draw: draw,
          })
          (ok STATUS_FAILED)
        )
        ;; PASSED. Pay the proposer the whole draw. There is no proposer fee.
        (begin
          ;; Belt and braces: propose-story already rejects a zero draw against
          ;; the same snapshotted value, so this cannot currently fire.
          (asserts! (> draw u0) ERR_DUST_DRAW)
          ;; Mark terminal BEFORE paying: effects before interaction, so a
          ;; re-entrant conclude hits ERR_PROPOSAL_CONCLUDED.
          (map-set Stories proposalId
            (merge story { status: STATUS_PASSED, reason: "paid" }))
          (unwrap!
            (contract-call? .news-treasury-v5 execute-payout
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
)
