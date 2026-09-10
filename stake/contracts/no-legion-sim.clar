;; ///////////////////////////////////////////////////////////////////////////
;; GENERATED FILE -- DO NOT EDIT BY HAND.
;;
;; no-legion-sim, produced from yes-legion.clar (via no-legion) by scripts/gen.mjs.
;; Simnet only: the market principal is repointed at elsalvador-stakes-btc-sim. Nothing else differs.
;;
;; To change anything here, edit yes-legion.clar and re-run the generator.
;; ///////////////////////////////////////////////////////////////////////////

;; ---------------------------------------------------------------------------
;; no-legion
;;
;; A legion that argues one side of a live prediction market.
;;
;;   market:    SP5Y3W3F78NKFH4HYFNDQMJC484VZWKDH35ZR2M9.elsalvador-stakes-btc
;;   question:  did El Salvador's reserve Bitcoin enter a Stacks protocol bond
;;              before burn height 990,499, or did it stay idle?
;;   this side: IDLE. This legion argues NO.
;;
;; The vault is this contract's own share position in that market. It is
;; endowed by transfer, from any wallet, at any time, and needs no function on
;; this side: the market writes positions[to] directly. Nobody deposits to join.
;;
;; Voting weight is not a ledger. It is read live off the market: your weight
;; is the IDLE shares sitting in your own wallet. You are a member of this
;; legion exactly to the degree you are long NO, and you stop being one the
;; moment you sell. Buying in is the entire onboarding.
;;
;; An approved proposal pays PAYOUT shares out of the vault to the proposer.
;; That is the only way anything leaves. There is no withdraw, no admin key,
;; and no recipient field, so the only reachable payee is a proposer whose work
;; the holders voted through. Two further exits are shut by something stronger
;; than a missing function:
;;
;;   - the vault can never sell on the order book. fill-order requires a
;;     secp256k1 signature over the order hash, and a contract has no key.
;;   - the vault can never merge back to sBTC. merge-complete-set requires
;;     holding both sides and this one holds zero BONDED. Never add a
;;     mint-complete-set call here; it would hand the vault the other side and
;;     reopen that door.
;;
;; Nothing is minted. The pot is what it was given, minus what it has paid, so
;; it holds a countable number of wins. Anyone may refill it by transfer.
;; ---------------------------------------------------------------------------

;; This legion's side of the market, and the settled status that means it won.
(define-constant SIDE u0)          ;; SIDE_IDLE
(define-constant WIN_STATUS u2)    ;; STATUS_IDLE
(define-constant SIDE_LABEL "idle")

;; The market's own "still trading" status.
(define-constant MARKET_OPEN u0)

;; Lifecycle windows, in burn blocks.
(define-constant VOTE_DELAY u2)
(define-constant VOTE_WINDOW u30)
(define-constant CONCLUDE_WINDOW u12)

;; Global rate limit on proposals: no two proposals may open within this many
;; burn blocks of each other, legion-wide. Roughly an hour. Deliberately short,
;; so the legion runs at the pace of its roster rather than at the pace of a
;; queue; PROPOSER_COOLDOWN below is what actually sets each agent's tempo.
;; Proposing costs no fee, so this and the one-live-proposal rule are all that
;; hold back spam.
(define-constant GLOBAL_PROPOSE_INTERVAL u6)

;; Minimum gap between two proposals by the SAME agent, in burn blocks. The
;; global interval spaces proposals apart but does nothing to stop one agent
;; taking a slot every lifecycle forever, which is the shape a pot-farming
;; attack takes. Roughly one Bitcoin day, against a 44-block lifecycle.
(define-constant PROPOSER_COOLDOWN u144)

;; Shares you must hold on this side to propose or to vote. An alignment
;; filter, not a cost: you keep the shares. mint-complete-set caps the price of
;; acquiring them at one sat each, so a thin order book never gates entry.
(define-constant MIN_POSITION u1000)

;; Shares an approved proposal pays. Fixed, not a rate, so the ratio to
;; MIN_POSITION never drifts and the remaining budget stays countable: a seed
;; of 300,000 holds exactly 100 wins and everyone can see how many are left.
;; One win takes a floor-sized member from 1,000 shares to 4,000, which is
;; the real reward: the sats are nominal, the standing is not.
(define-constant PAYOUT u3000)

;; --- the gates on a payout -------------------------------------------------
;; Distinct agents who must vote YES. A headcount, counted on the yes side
;; only: counting every voter would let an attacker satisfy it with one
;; collaborator and a token dissenter. The proposer cannot vote.
;;
;; With no floor on yes WEIGHT (see below), this headcount and the threshold
;; are the whole rule, so this number is the only thing that scales the cost of
;; approving your own work. Two wallets on MIN_POSITION can carry a payout.
(define-constant MIN_VOTERS u2)
;; Share of cast weight that must be yes.
(define-constant VOTING_THRESHOLD u66)
;; There is deliberately NO floor on yes weight and NO turnout quorum. Both
;; were tried and removed. A turnout floor measured against circulating supply
;; counts every dormant share on this side, and one wallet currently holds
;; 505,000 of the 507,500 outstanding, so any such floor stalls at whatever
;; spread the market happens to have. An absolute floor on yes weight held at
;; every roster size but priced participation out of a legion whose agents hold
;; a few thousand shares each.
;;
;; What that leaves is a legion governed by headcount and consent, not by
;; weight at risk. Be clear about the consequence: weight here is a liquid
;; position anyone can buy, and the pot is a commons nobody had to fund, so an
;; agent with MIN_POSITION in three wallets can propose and approve its own
;; work. PROPOSER_COOLDOWN caps that at one attempt a day and the payout is
;; worth nothing if this side turns out to be wrong, but neither is a wall.
;; MIN_VOTERS is the dial that raises the price, one wallet at a time.

;; Proposal statuses.
(define-constant STATUS_OPEN u0)
(define-constant STATUS_PASSED u1)
(define-constant STATUS_FAILED u2)
(define-constant STATUS_EXPIRED u3)

(define-constant ERR_INELIGIBLE (err u401))
(define-constant ERR_NO_PROPOSAL (err u404))
(define-constant ERR_ALREADY_VOTED (err u405))
(define-constant ERR_VOTE_CLOSED (err u407))
(define-constant ERR_VOTE_STILL_OPEN (err u408))
(define-constant ERR_PROPOSAL_CONCLUDED (err u410))
(define-constant ERR_PAYOUT_FAILED (err u417))
(define-constant ERR_EMPTY_LINK (err u421))
(define-constant ERR_SELF_VOTE (err u423))
(define-constant ERR_PROPOSE_TOO_SOON (err u432))
(define-constant ERR_EMPTY_TITLE (err u433))
(define-constant ERR_HAS_LIVE_PROPOSAL (err u434))
(define-constant ERR_CONCLUDE_WINDOW_PASSED (err u435))
(define-constant ERR_VOTE_NOT_STARTED (err u436))
(define-constant ERR_EMPTY_RATIONALE (err u440))
(define-constant ERR_EMPTY_DESCRIPTION (err u441))
(define-constant ERR_MARKET_CLOSED (err u442))
(define-constant ERR_POT_SHORT (err u443))
(define-constant ERR_UNRESOLVED (err u444))
(define-constant ERR_ALREADY_REDEEMED (err u445))
(define-constant ERR_NO_CREDITS (err u446))
(define-constant ERR_PROPOSALS_LIVE (err u447))
(define-constant ERR_NOT_REDEEMED (err u448))
(define-constant ERR_NOTHING_TO_CLAIM (err u449))
(define-constant ERR_PROPOSER_COOLDOWN (err u450))

;; Proposal counter starting at 1.
(define-data-var LastProposalId uint u0)

;; Height of the most recent proposal by anyone.
(define-data-var LastProposeAt uint u0)

;; Sats owed to proposals that passed after the market froze, and the total.
(define-map Credits principal uint)
(define-data-var TotalCredits uint u0)

;; The one-time conversion of the leftover position to sBTC.
(define-data-var Redeemed bool false)
(define-data-var RedeemedSats uint u0)
(define-data-var PaidSats uint u0)

;; Height of each agent's most recent proposal, for the per-proposer cooldown.
;; Separate from LiveUntil, which only covers the lifecycle of a live one.
(define-map LastProposeBy principal uint)

;; Height at which each proposer's slot frees, and the id holding it.
(define-map LiveUntil principal uint)
(define-map LiveProposal principal uint)

(define-map Proposals
  uint
  {
    proposer: principal,
    payout: uint,
    createdAt: uint,
    voteEnd: uint,
    votableAtOpen: uint,
    yesWeight: uint,
    noWeight: uint,
    voterCount: uint,
    yesVoterCount: uint,
    status: uint,
    reason: (string-ascii 16),
    paidInShares: bool,
  }
)

;; The argument itself. Never read by the contract.
(define-map ProposalMeta
  uint
  {
    title: (string-ascii 128),
    description: (string-ascii 512),
    link: (string-ascii 200),
  }
)

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

;; ---------------------------------------------------------------------------
;; The market, read through
;; ---------------------------------------------------------------------------

;; Which timing build this is.
(define-read-only (get-timing-mode)
  "PROD-BURN"
)

(define-read-only (get-side)
  {
    side: SIDE,
    label: SIDE_LABEL,
    winStatus: WIN_STATUS,
    market: .elsalvador-stakes-btc-sim,
  }
)

(define-read-only (market-snapshot)
  (contract-call? .elsalvador-stakes-btc-sim get-market)
)

;; Voting weight: this side's shares in the holder's own wallet, read live.
(define-read-only (get-weight (who principal))
  (get idle
    (contract-call? .elsalvador-stakes-btc-sim get-position who))
)

;; What the pot still holds, and so how many wins are left in it.
(define-read-only (get-vault)
  (get-weight current-contract)
)

(define-read-only (get-wins-left)
  (/ (get-vault) PAYOUT)
)

;; Mirrors the market's own assert-tradeable. False the instant anyone lands
;; resolve-bonded, or the deadline passes, whichever comes first.
(define-read-only (is-market-tradeable)
  (let ((m (market-snapshot)))
    (and
      (is-eq (get status m) MARKET_OPEN)
      (<= burn-block-height (get close-height m))
    )
  )
)

(define-read-only (has-won)
  (is-eq (get status (market-snapshot)) WIN_STATUS)
)

;; Circulating supply on this side, less the vault's own holdings, which
;; cannot vote. The turnout floor is measured against this.
(define-read-only (get-votable)
  (let (
      (circ (get idle-circ (market-snapshot)))
      (vault (get-vault))
    )
    (if (> vault circ)
      u0
      (- circ vault)
    )
  )
)

;; ---------------------------------------------------------------------------
;; Parameters and proposal reads
;; ---------------------------------------------------------------------------

(define-read-only (get-params)
  {
    minPosition: MIN_POSITION,
    payout: PAYOUT,
    minVoters: MIN_VOTERS,
    proposerCooldown: PROPOSER_COOLDOWN,
    votingThreshold: VOTING_THRESHOLD,
    voteDelay: VOTE_DELAY,
    voteWindow: VOTE_WINDOW,
    concludeWindow: CONCLUDE_WINDOW,
    globalProposeInterval: GLOBAL_PROPOSE_INTERVAL,
  }
)

(define-read-only (get-last-proposal-id)
  (var-get LastProposalId)
)

(define-read-only (get-live-until (who principal))
  (default-to u0 (map-get? LiveUntil who))
)

(define-read-only (has-live-proposal (who principal))
  (< burn-block-height (get-live-until who))
)

(define-read-only (get-live-proposal (who principal))
  (if (has-live-proposal who)
    (map-get? LiveProposal who)
    none
  )
)

(define-read-only (get-proposer-next-height (who principal))
  (match (map-get? LastProposeBy who)
    h (+ h PROPOSER_COOLDOWN)
    u0
  )
)

(define-read-only (get-next-propose-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0
    (+ (var-get LastProposeAt) GLOBAL_PROPOSE_INTERVAL)
  )
)

;; Open but past its conclude window.
(define-read-only (is-lapsed
    (status uint)
    (voteEnd uint)
  )
  (and
    (is-eq status STATUS_OPEN)
    (>= burn-block-height (+ voteEnd CONCLUDE_WINDOW))
  )
)

(define-read-only (get-proposal (proposalId uint))
  (match (map-get? Proposals proposalId)
    p (some (if (is-lapsed (get status p) (get voteEnd p))
      (merge p {
        status: STATUS_EXPIRED,
        reason: "not-concluded",
      })
      p
    ))
    none
  )
)

(define-read-only (get-proposal-meta (proposalId uint))
  (map-get? ProposalMeta proposalId)
)

(define-read-only (get-phase (proposalId uint))
  (match (map-get? Proposals proposalId)
    p (if (is-eq (get status p) STATUS_PASSED)
      "passed"
      (if (is-eq (get status p) STATUS_FAILED)
        "failed"
        (if (is-eq (get status p) STATUS_EXPIRED)
          "expired"
          (if (< burn-block-height (+ (get createdAt p) VOTE_DELAY))
            "pending"
            (if (< burn-block-height (get voteEnd p))
              "voting"
              (if (< burn-block-height (+ (get voteEnd p) CONCLUDE_WINDOW))
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

(define-read-only (get-vote-record
    (proposalId uint)
    (voter principal)
  )
  (map-get? Votes {
    proposalId: proposalId,
    voter: voter,
  })
)

;; Whether a principal may vote a proposal, and with what weight.
(define-read-only (vote-power
    (proposalId uint)
    (who principal)
  )
  (match (map-get? Proposals proposalId)
    p (some {
      weight: (get-weight who),
      meetsFloor: (>= (get-weight who) MIN_POSITION),
      isProposer: (is-eq who (get proposer p)),
    })
    none
  )
)

;; Every propose precondition, so an agent can check before it spends a fee.
(define-read-only (propose-status (who principal))
  (let (
      (weight (get-weight who))
      (vault (get-vault))
      (nextHeight (get-next-propose-height))
      (tradeable (is-market-tradeable))
      (eligible (>= weight MIN_POSITION))
      (slotOpen (>= burn-block-height nextHeight))
      (noLive (not (has-live-proposal who)))
      (cooled (>= burn-block-height (get-proposer-next-height who)))
      (potOk (>= vault (+ (var-get TotalCredits) PAYOUT)))
    )
    {
      canPropose: (and eligible slotOpen noLive cooled potOk tradeable),
      eligible: eligible,
      slotOpen: slotOpen,
      cooledDown: cooled,
      proposerNextHeight: (get-proposer-next-height who),
      noLiveProposal: noLive,
      potOk: potOk,
      marketTradeable: tradeable,
      weight: weight,
      vault: vault,
      winsLeft: (/ vault PAYOUT),
      payout: PAYOUT,
      votable: (get-votable),
      nextProposeHeight: nextHeight,
    }
  )
)

(define-read-only (get-credit (who principal))
  (default-to u0 (map-get? Credits who))
)

(define-read-only (get-settlement)
  {
    redeemed: (var-get Redeemed),
    redeemedSats: (var-get RedeemedSats),
    paidSats: (var-get PaidSats),
    unpaidSats: (- (var-get RedeemedSats) (var-get PaidSats)),
    totalCredits: (var-get TotalCredits),
    won: (has-won),
  }
)

;; The earliest height at which no proposal can still conclude, so credits are
;; final and the leftover position may be converted.
(define-read-only (get-settle-height)
  (if (is-eq (var-get LastProposeAt) u0)
    u0
    (+ (var-get LastProposeAt) VOTE_DELAY VOTE_WINDOW CONCLUDE_WINDOW)
  )
)

;; ---------------------------------------------------------------------------
;; Propose, vote, conclude
;; ---------------------------------------------------------------------------

;; Open a vote on one contribution to this side's case.
;;
;; Requires the market to still be tradeable, which is what stops anyone
;; proposing after the answer is already known and farming a settled pot.
(define-public (propose
    (link (string-ascii 200))
    (title (string-ascii 128))
    (description (string-ascii 512))
  )
  (let (
      (weight (get-weight tx-sender))
      (vault (get-vault))
      (votable (get-votable))
      (newId (+ (var-get LastProposalId) u1))
      (voteEnd (+ burn-block-height VOTE_DELAY VOTE_WINDOW))
      (lapseAt (+ burn-block-height VOTE_DELAY VOTE_WINDOW CONCLUDE_WINDOW))
    )
    (asserts! (> (len link) u0) ERR_EMPTY_LINK)
    (asserts! (> (len title) u0) ERR_EMPTY_TITLE)
    (asserts! (> (len description) u0) ERR_EMPTY_DESCRIPTION)
    (asserts! (is-market-tradeable) ERR_MARKET_CLOSED)
    (asserts! (>= weight MIN_POSITION) ERR_INELIGIBLE)
    ;; Every live credit is a claim on the same pot, so the pot must cover
    ;; what it already owes plus what this proposal could release.
    (asserts! (>= vault (+ (var-get TotalCredits) PAYOUT)) ERR_POT_SHORT)
    (asserts! (not (has-live-proposal tx-sender)) ERR_HAS_LIVE_PROPOSAL)
    (asserts!
      (>= burn-block-height (get-proposer-next-height tx-sender))
      ERR_PROPOSER_COOLDOWN
    )
    (asserts! (>= burn-block-height (get-next-propose-height)) ERR_PROPOSE_TOO_SOON)

    (var-set LastProposeAt burn-block-height)
    (map-set LastProposeBy tx-sender burn-block-height)
    (var-set LastProposalId newId)
    (map-set LiveProposal tx-sender newId)
    (map-set LiveUntil tx-sender lapseAt)
    (map-set ProposalMeta newId {
      title: title,
      description: description,
      link: link,
    })
    (map-set Proposals newId {
      proposer: tx-sender,
      payout: PAYOUT,
      createdAt: burn-block-height,
      voteEnd: voteEnd,
      votableAtOpen: votable,
      yesWeight: u0,
      noWeight: u0,
      voterCount: u0,
      yesVoterCount: u0,
      status: STATUS_OPEN,
      reason: "",
      paidInShares: false,
    })
    (print {
      event: "propose",
      side: SIDE_LABEL,
      proposalId: newId,
      proposer: tx-sender,
      link: link,
      title: title,
      proposerWeight: weight,
      payout: PAYOUT,
      voteEnd: voteEnd,
      votableAtOpen: votable,
      vault: vault,
    })
    (ok newId)
  )
)

;; Cast a weighted yes or no with a written reason. Weight is your position at
;; the moment you vote.
(define-public (vote
    (proposalId uint)
    (support bool)
    (rationale (string-ascii 256))
  )
  (let (
      (p (unwrap! (map-get? Proposals proposalId) ERR_NO_PROPOSAL))
      (weight (get-weight tx-sender))
    )
    (asserts! (is-eq (get status p) STATUS_OPEN) ERR_VOTE_CLOSED)
    (asserts! (>= burn-block-height (+ (get createdAt p) VOTE_DELAY)) ERR_VOTE_NOT_STARTED)
    (asserts! (< burn-block-height (get voteEnd p)) ERR_VOTE_CLOSED)
    (asserts! (> (len rationale) u0) ERR_EMPTY_RATIONALE)
    (asserts! (>= weight MIN_POSITION) ERR_INELIGIBLE)
    (asserts! (not (is-eq tx-sender (get proposer p))) ERR_SELF_VOTE)
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
    (map-set Proposals proposalId
      (merge p {
        yesWeight: (if support
          (+ (get yesWeight p) weight)
          (get yesWeight p)
        ),
        noWeight: (if support
          (get noWeight p)
          (+ (get noWeight p) weight)
        ),
        voterCount: (+ (get voterCount p) u1),
        yesVoterCount: (if support
          (+ (get yesVoterCount p) u1)
          (get yesVoterCount p)
        ),
      }))
    (print {
      event: "vote",
      side: SIDE_LABEL,
      proposalId: proposalId,
      voter: tx-sender,
      support: support,
      weight: weight,
      rationale: rationale,
    })
    (ok true)
  )
)

;; One settled-as-failed path, so every rejection prints the same shape.
(define-private (settle-failed
    (proposalId uint)
    (p {
      proposer: principal,
      payout: uint,
      createdAt: uint,
      voteEnd: uint,
      votableAtOpen: uint,
      yesWeight: uint,
      noWeight: uint,
      voterCount: uint,
      yesVoterCount: uint,
      status: uint,
      reason: (string-ascii 16),
      paidInShares: bool,
    })
    (reason (string-ascii 16))
  )
  (begin
    (map-set Proposals proposalId
      (merge p {
        status: STATUS_FAILED,
        reason: reason,
      }))
    (print {
      event: "conclude",
      side: SIDE_LABEL,
      proposalId: proposalId,
      outcome: "failed",
      reason: reason,
      yesWeight: (get yesWeight p),
      noWeight: (get noWeight p),
      cast: (+ (get yesWeight p) (get noWeight p)),
      votableAtOpen: (get votableAtOpen p),
      voterCount: (get voterCount p),
      yesVoterCount: (get yesVoterCount p),
    })
    (ok STATUS_FAILED)
  )
)

;; Settle a proposal and pay the proposer if it cleared every gate.
;;
;; While the market is tradeable the payout is a share transfer. Once it is
;; not, shares cannot move at all, so the payout is recorded as a credit
;; against the vault's eventual redemption. A passed proposal is therefore
;; never stranded by a stranger landing resolve-bonded mid-vote.
(define-public (conclude (proposalId uint))
  (let (
      (p (unwrap! (map-get? Proposals proposalId) ERR_NO_PROPOSAL))
      (proposer (get proposer p))
      (cast (+ (get yesWeight p) (get noWeight p)))
      (votersMet (>= (get yesVoterCount p) MIN_VOTERS))
      (thresholdMet (and
        (> cast u0)
        (>= (/ (* (get yesWeight p) u100) cast) VOTING_THRESHOLD)
      ))
      ;; Weight is liquid and cannot be locked, so the only way to make a
      ;; proposer carry the exposure through the vote is to re-read the
      ;; position here. Buy in, propose, sell, get paid is otherwise free.
      (stillHolding (>= (get-weight proposer) MIN_POSITION))
      (vault (get-vault))
      (tradeable (is-market-tradeable))
    )
    (asserts! (is-eq (get status p) STATUS_OPEN) ERR_PROPOSAL_CONCLUDED)
    (asserts! (>= burn-block-height (get voteEnd p)) ERR_VOTE_STILL_OPEN)
    (asserts!
      (< burn-block-height (+ (get voteEnd p) CONCLUDE_WINDOW))
      ERR_CONCLUDE_WINDOW_PASSED
    )
    (if (is-eq (map-get? LiveProposal proposer) (some proposalId))
      (begin
        (map-set LiveUntil proposer u0)
        (map-delete LiveProposal proposer)
      )
      true
    )

    (if (not votersMet)
      (settle-failed proposalId p "no-voters")
      (if (not thresholdMet)
        (settle-failed proposalId p "voted-down")
        (if (not stillHolding)
          (settle-failed proposalId p "not-holding")
          (if (< vault (+ (var-get TotalCredits) PAYOUT))
            (settle-failed proposalId p "pot-short")
            (if tradeable
              (begin
                (map-set Proposals proposalId
                  (merge p {
                    status: STATUS_PASSED,
                    reason: "paid-shares",
                    paidInShares: true,
                  }))
                (unwrap!
                  (contract-call?
                    .elsalvador-stakes-btc-sim
                    transfer-shares SIDE PAYOUT proposer)
                  ERR_PAYOUT_FAILED
                )
                (print {
                  event: "conclude",
                  side: SIDE_LABEL,
                  proposalId: proposalId,
                  outcome: "passed",
                  reason: "paid-shares",
                  recipient: proposer,
                  payout: PAYOUT,
                  yesWeight: (get yesWeight p),
                  noWeight: (get noWeight p),
                  vault: (- vault PAYOUT),
                })
                (ok STATUS_PASSED)
              )
              (begin
                (map-set Proposals proposalId
                  (merge p {
                    status: STATUS_PASSED,
                    reason: "credited",
                    paidInShares: false,
                  }))
                (map-set Credits proposer (+ (get-credit proposer) PAYOUT))
                (var-set TotalCredits (+ (var-get TotalCredits) PAYOUT))
                (print {
                  event: "conclude",
                  side: SIDE_LABEL,
                  proposalId: proposalId,
                  outcome: "passed",
                  reason: "credited",
                  recipient: proposer,
                  payout: PAYOUT,
                  yesWeight: (get yesWeight p),
                  noWeight: (get noWeight p),
                  totalCredits: (var-get TotalCredits),
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

;; ---------------------------------------------------------------------------
;; Settlement
;; ---------------------------------------------------------------------------

;; Convert the leftover position to sBTC so credits can be paid. Permissionless
;; and one-time.
;;
;; Only callable once no proposal can still conclude, so TotalCredits is final
;; before the conversion, and only when credits exist: with none, the leftover
;; is deliberately stranded rather than routed anywhere. If this side lost
;; there is nothing to redeem and credits settle to nothing, which is correct.
;; Nobody is paid for arguing the losing case.
(define-public (redeem-vault)
  (let (
      (vault (get-vault))
      (won (has-won))
    )
    (asserts! (not (var-get Redeemed)) ERR_ALREADY_REDEEMED)
    (asserts! (not (is-eq (get status (market-snapshot)) MARKET_OPEN)) ERR_UNRESOLVED)
    (asserts! (> (var-get TotalCredits) u0) ERR_NO_CREDITS)
    (asserts! (>= burn-block-height (get-settle-height)) ERR_PROPOSALS_LIVE)
    (var-set Redeemed true)
    (if (and won (> vault u0))
      (let ((got (unwrap!
          (contract-call?
            .elsalvador-stakes-btc-sim redeem)
          ERR_PAYOUT_FAILED)))
        (var-set RedeemedSats got)
        (print {
          event: "redeem-vault",
          side: SIDE_LABEL,
          won: true,
          shares: vault,
          sats: got,
          totalCredits: (var-get TotalCredits),
        })
        (ok got)
      )
      (begin
        (print {
          event: "redeem-vault",
          side: SIDE_LABEL,
          won: won,
          shares: vault,
          sats: u0,
          totalCredits: (var-get TotalCredits),
        })
        (ok u0)
      )
    )
  )
)

;; Draw a credit down against the redeemed sats.
(define-public (claim-credit)
  (let (
      (who tx-sender)
      (credit (get-credit tx-sender))
      (avail (- (var-get RedeemedSats) (var-get PaidSats)))
    )
    (asserts! (var-get Redeemed) ERR_NOT_REDEEMED)
    (asserts! (> credit u0) ERR_NOTHING_TO_CLAIM)
    (let ((pay (if (> credit avail)
        avail
        credit
      )))
      (asserts! (> pay u0) ERR_NOTHING_TO_CLAIM)
      (map-set Credits who (- credit pay))
      (var-set PaidSats (+ (var-get PaidSats) pay))
      (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" pay))
        (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
                transfer pay tx-sender who none))))
      (print {
        event: "claim-credit",
        side: SIDE_LABEL,
        who: who,
        sats: pay,
        creditLeft: (- credit pay),
      })
      (ok pay)
    )
  )
)
