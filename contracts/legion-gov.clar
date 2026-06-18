;; legion-gov
;; Proposals + STAKE-WEIGHTED voting for the AIBTC Legion.
;;
;; This contract mirrors the production AIBTC action-proposal-voting extension
;; (aibtc-action-proposal-voting.clar) governance model, adapted to our simpler
;; stake-weighted design:
;;
;;   - There is NO DAO governance token. A voter's weight is exactly the amount of
;;     sBTC they have staked through this contract's `stake` function (which is
;;     forwarded into legion-treasury via `deposit`).
;;   - The full burn-block proposal lifecycle (delay -> vote -> exec) is matched.
;;   - Quorum / threshold / veto math matches the reference exactly.
;;
;; Timing uses stacks-block-height (like the reference), NOT stacks-block-height.
;;
;; Funds are denominated in sBTC: `stake` forwards a `<sip010-trait>` token into
;; the treasury and `conclude-proposal` forwards the same trait reference into the
;; treasury's execute-transfer. The treasury validates the token principal.

;; -------------------------------------------------------------------
;; Traits
;; -------------------------------------------------------------------
(use-trait sip010-trait 'STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; zero-stake / ineligible voter
(define-constant ERR_NO_PROPOSAL (err u404)) ;; no such proposal
(define-constant ERR_DOUBLE_VOTE (err u405)) ;; principal already voted (same direction)
(define-constant ERR_SELF_TARGET (err u407)) ;; recipient is gov/treasury itself
(define-constant ERR_ZERO_SNAPSHOT (err u410)) ;; no stake exists at proposal creation
(define-constant ERR_VOTE_TOO_SOON (err u411)) ;; before voteStart
(define-constant ERR_VOTE_TOO_LATE (err u412)) ;; at/after voteEnd
(define-constant ERR_ALREADY_CONCLUDED (err u413)) ;; proposal already concluded
(define-constant ERR_VETO_WINDOW (err u414)) ;; not in [voteEnd, execStart)
(define-constant ERR_ALREADY_VETOED (err u415)) ;; principal already vetoed
(define-constant ERR_NOT_IN_EXEC_WINDOW (err u416)) ;; conclude outside [execStart, execEnd)
(define-constant ERR_ZERO_AMOUNT (err u417)) ;; stake/propose amount must be > 0
(define-constant ERR_EMPTY_DESC (err u418)) ;; proposal description must be non-empty

;; -------------------------------------------------------------------
;; Config (matches the reference parameter values)
;; -------------------------------------------------------------------
(define-constant TREASURY .legion-treasury)
(define-constant SELF (as-contract tx-sender))

(define-constant VOTING_QUORUM u15) ;; 15% turnout (of total staked) required
(define-constant VOTING_THRESHOLD u66) ;; 66% of cast votes must be yes
;; TEST TIMING: short windows + Stacks-block (not burn-block) counting so a full
;; lifecycle runs in ~10-15 min on testnet. For production, revert to
;; burn-block-height with VOTING_DELAY u12 / VOTING_PERIOD u24 (AIBTC-matched).
(define-constant VOTING_DELAY u1) ;; stacks blocks between creation and vote start
(define-constant VOTING_PERIOD u15) ;; stacks-block voting window length

;; Our extra guard on top of the AIBTC model: require at least this many distinct
;; voters before a proposal can execute.
(define-constant MIN_PARTICIPANTS u2)

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
;; Stake per principal = voting weight.
(define-map Stakes
  principal
  uint
)

;; Running total of all staked STX. Used as the quorum/veto denominator snapshot.
(define-data-var TotalStaked uint u0)

(define-data-var ProposalNonce uint u0)

(define-map Proposals
  uint
  {
    proposer: principal,
    desc: (string-ascii 256),
    recipient: principal,
    amount: uint,
    ;; burn-block lifecycle anchor
    createdBtc: uint,
    ;; DEVIATION FROM REFERENCE:
    ;; The reference snapshots each VOTER's token balance at the proposal's
    ;; creation Stacks block via `at-block`, and uses liquid token supply as the
    ;; quorum denominator. We instead snapshot the TOTAL staked amount into the
    ;; proposal at creation time (`totalStakedSnapshot`) as the quorum/veto
    ;; denominator, and read per-voter weight as CURRENT stake at vote time.
    ;; This is safe here because staked STX is locked inside legion-treasury and
    ;; cannot be withdrawn, so mid-proposal vote-buying is not a cheap attack and
    ;; per-voter weight cannot be inflated then unwound.
    totalStakedSnapshot: uint,
    yesWeight: uint,
    noWeight: uint,
    vetoWeight: uint,
    voterCount: uint,
    concluded: bool,
    executed: bool,
  }
)

;; one vote RECORD per principal per proposal: stores their chosen direction and
;; the weighted amount applied, so a voter can change their vote in-window.
(define-map Votes
  {
    proposalId: uint,
    voter: principal,
  }
  {
    vote: bool,
    amount: uint,
  }
)

;; one veto per principal per proposal
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
(define-read-only (get-stake (who principal))
  (default-to u0 (map-get? Stakes who))
)

(define-read-only (get-total-staked)
  (var-get TotalStaked)
)

(define-read-only (get-proposal (id uint))
  (map-get? Proposals id)
)

(define-read-only (get-proposal-count)
  (var-get ProposalNonce)
)

(define-read-only (has-voted
    (id uint)
    (who principal)
  )
  (is-some (map-get? Votes {
    proposalId: id,
    voter: who,
  }))
)

(define-read-only (get-vote-record
    (id uint)
    (who principal)
  )
  (map-get? Votes {
    proposalId: id,
    voter: who,
  })
)

;; Mirrors the reference getter: returns computed lifecycle windows plus the
;; current met-quorum / met-threshold / veto evaluation for a proposal.
(define-read-only (get-proposal-status (id uint))
  (match (map-get? Proposals id)
    prop (let (
        (createdBtc (get createdBtc prop))
        (voteStart (+ createdBtc VOTING_DELAY))
        (voteEnd (+ voteStart VOTING_PERIOD))
        (execStart (+ voteEnd VOTING_DELAY))
        (execEnd (+ execStart VOTING_PERIOD))
        (yesWeight (get yesWeight prop))
        (noWeight (get noWeight prop))
        (vetoWeight (get vetoWeight prop))
        (snapshot (get totalStakedSnapshot prop))
        (castTotal (+ yesWeight noWeight))
        (hasVotes (> castTotal u0))
        (metQuorum (and
          (> snapshot u0)
          hasVotes
          (>= (/ (* castTotal u100) snapshot) VOTING_QUORUM)
        ))
        (metThreshold (and
          hasVotes
          (>= (/ (* yesWeight u100) castTotal) VOTING_THRESHOLD)
        ))
        (vetoMetQuorum (and
          (> snapshot u0)
          (> vetoWeight u0)
          (>= (/ (* vetoWeight u100) snapshot) VOTING_QUORUM)
        ))
        (vetoActivated (and vetoMetQuorum (> vetoWeight yesWeight)))
      )
      (some {
        createdBtc: createdBtc,
        voteStart: voteStart,
        voteEnd: voteEnd,
        execStart: execStart,
        execEnd: execEnd,
        yesWeight: yesWeight,
        noWeight: noWeight,
        vetoWeight: vetoWeight,
        totalStakedSnapshot: snapshot,
        voterCount: (get voterCount prop),
        metQuorum: metQuorum,
        metThreshold: metThreshold,
        vetoMetQuorum: vetoMetQuorum,
        vetoActivated: vetoActivated,
        concluded: (get concluded prop),
        executed: (get executed prop),
      })
    )
    none
  )
)

;; -------------------------------------------------------------------
;; Public: stake
;; -------------------------------------------------------------------
;; Forwards `amount` sBTC into the treasury and credits the caller's voting
;; weight. tx-sender is preserved into the treasury call, so the staker is the
;; one debited. The `ft` trait reference is forwarded to the treasury, which
;; asserts it matches the wired sBTC token.
(define-public (stake
    (ft <sip010-trait>)
    (amount uint)
  )
  (begin
    ;; Reject zero-value stakes up front (defense in depth; treasury also checks).
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    ;; treasury.deposit asserts amount > u0, validates the token, and transfers.
    (try! (contract-call? .legion-treasury deposit ft amount))
    (map-set Stakes tx-sender (+ (get-stake tx-sender) amount))
    (var-set TotalStaked (+ (var-get TotalStaked) amount))
    (print {
      event: "stake",
      staker: tx-sender,
      amount: amount,
      total: (get-stake tx-sender),
      totalStaked: (var-get TotalStaked),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: propose
;; -------------------------------------------------------------------
;; Snapshots the total staked weight and anchors the burn-block lifecycle.
(define-public (propose
    (desc (string-ascii 256))
    (recipient principal)
    (amount uint)
  )
  (let (
      (id (+ (var-get ProposalNonce) u1))
      (snapshot (var-get TotalStaked))
      (createdBtc stacks-block-height)
    )
    ;; No self-targeting: cannot route funds to gov or treasury contracts.
    (asserts! (and (not (is-eq recipient SELF)) (not (is-eq recipient TREASURY)))
      ERR_SELF_TARGET
    )
    ;; A meaningful quorum denominator must exist.
    (asserts! (> snapshot u0) ERR_ZERO_SNAPSHOT)
    ;; Proposed payout must be a positive amount.
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    ;; Reject blank descriptions; this also sanitizes `desc` before it is stored.
    (asserts! (> (len desc) u0) ERR_EMPTY_DESC)
    (map-set Proposals id {
      proposer: tx-sender,
      desc: desc,
      recipient: recipient,
      amount: amount,
      createdBtc: createdBtc,
      totalStakedSnapshot: snapshot,
      yesWeight: u0,
      noWeight: u0,
      vetoWeight: u0,
      voterCount: u0,
      concluded: false,
      executed: false,
    })
    (var-set ProposalNonce id)
    (print {
      event: "propose",
      id: id,
      proposer: tx-sender,
      recipient: recipient,
      amount: amount,
      createdBtc: createdBtc,
      voteStart: (+ createdBtc VOTING_DELAY),
      voteEnd: (+ (+ createdBtc VOTING_DELAY) VOTING_PERIOD),
      totalStakedSnapshot: snapshot,
    })
    (ok id)
  )
)

;; -------------------------------------------------------------------
;; Public: vote
;; -------------------------------------------------------------------
;; Allowed only in [voteStart, voteEnd). A voter may change their vote within
;; the window: the previous weighted vote is subtracted and the new one added.
(define-public (vote
    (proposal-id uint)
    (support bool)
  )
  (let (
      (prop (unwrap! (map-get? Proposals proposal-id) ERR_NO_PROPOSAL))
      (createdBtc (get createdBtc prop))
      (voteStart (+ createdBtc VOTING_DELAY))
      (voteEnd (+ voteStart VOTING_PERIOD))
      (weight (get-stake tx-sender))
      (prior (map-get? Votes {
        proposalId: proposal-id,
        voter: tx-sender,
      }))
    )
    ;; voter must hold non-zero stake
    (asserts! (> weight u0) ERR_INELIGIBLE)
    ;; proposal not concluded
    (asserts! (not (get concluded prop)) ERR_ALREADY_CONCLUDED)
    ;; voting window: [voteStart, voteEnd)
    (asserts! (>= stacks-block-height voteStart) ERR_VOTE_TOO_SOON)
    (asserts! (< stacks-block-height voteEnd) ERR_VOTE_TOO_LATE)
    ;; if a prior vote exists, the new vote must be a CHANGE of direction
    (and
      (is-some prior)
      (asserts! (not (is-eq (get vote (unwrap-panic prior)) support))
        ERR_DOUBLE_VOTE
      )
    )
    ;; remove the previous weighted vote (if any)
    (let (
        (priorYes (match prior
          r (if (get vote r)
            (get amount r)
            u0
          )
          u0
        ))
        (priorNo (match prior
          r (if (get vote r)
            u0
            (get amount r)
          )
          u0
        ))
        (baseYes (- (get yesWeight prop) priorYes))
        (baseNo (- (get noWeight prop) priorNo))
        (newVoterCount (if (is-some prior)
          (get voterCount prop)
          (+ (get voterCount prop) u1)
        ))
      )
      (map-set Votes {
        proposalId: proposal-id,
        voter: tx-sender,
      } {
        vote: support,
        amount: weight,
      })
      (map-set Proposals proposal-id
        (merge prop {
          yesWeight: (if support
            (+ baseYes weight)
            baseYes
          ),
          noWeight: (if support
            baseNo
            (+ baseNo weight)
          ),
          voterCount: newVoterCount,
        })
      )
      (print {
        event: "vote",
        id: proposal-id,
        voter: tx-sender,
        support: support,
        weight: weight,
        changed: (is-some prior),
      })
      (ok true)
    )
  )
)

;; -------------------------------------------------------------------
;; Public: veto
;; -------------------------------------------------------------------
;; Callable in [voteEnd, execStart) by any staker. One veto per principal.
(define-public (veto (proposal-id uint))
  (let (
      (prop (unwrap! (map-get? Proposals proposal-id) ERR_NO_PROPOSAL))
      (createdBtc (get createdBtc prop))
      (voteEnd (+ (+ createdBtc VOTING_DELAY) VOTING_PERIOD))
      (execStart (+ voteEnd VOTING_DELAY))
      (weight (get-stake tx-sender))
    )
    (asserts! (> weight u0) ERR_INELIGIBLE)
    (asserts! (not (get concluded prop)) ERR_ALREADY_CONCLUDED)
    ;; veto window: [voteEnd, execStart)
    (asserts! (>= stacks-block-height voteEnd) ERR_VETO_WINDOW)
    (asserts! (< stacks-block-height execStart) ERR_VETO_WINDOW)
    (asserts!
      (is-none (map-get? Vetoes {
        proposalId: proposal-id,
        voter: tx-sender,
      }))
      ERR_ALREADY_VETOED
    )
    (map-set Vetoes {
      proposalId: proposal-id,
      voter: tx-sender,
    }
      weight
    )
    (map-set Proposals proposal-id
      (merge prop { vetoWeight: (+ (get vetoWeight prop) weight) })
    )
    (print {
      event: "veto",
      id: proposal-id,
      voter: tx-sender,
      weight: weight,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: conclude-proposal
;; -------------------------------------------------------------------
;; Replaces the old `tally-and-execute`. Callable only in [execStart, execEnd)
;; and only once. Marks the proposal concluded BEFORE any external call
;; (effects-before-interaction). Executes the treasury transfer ONLY IF the
;; proposal met quorum AND threshold AND has >= MIN_PARTICIPANTS voters AND was
;; not veto-activated. Otherwise it concludes as a FAILED proposal (no transfer)
;; but the tx still succeeds, matching the reference's "always concludable after
;; the window" behavior.
(define-public (conclude-proposal
    (proposal-id uint)
    (ft <sip010-trait>)
  )
  (let (
      (prop (unwrap! (map-get? Proposals proposal-id) ERR_NO_PROPOSAL))
      (createdBtc (get createdBtc prop))
      (voteEnd (+ (+ createdBtc VOTING_DELAY) VOTING_PERIOD))
      (execStart (+ voteEnd VOTING_DELAY))
      (execEnd (+ execStart VOTING_PERIOD))
      (yesWeight (get yesWeight prop))
      (noWeight (get noWeight prop))
      (vetoWeight (get vetoWeight prop))
      (snapshot (get totalStakedSnapshot prop))
      (castTotal (+ yesWeight noWeight))
      (hasVotes (> castTotal u0))
      ;; quorum: total cast vs snapshot. Guard against zero snapshot / no votes.
      (metQuorum (and
        (> snapshot u0)
        hasVotes
        (>= (/ (* castTotal u100) snapshot) VOTING_QUORUM)
      ))
      ;; threshold: yes vs cast. Guard against div-by-zero (castTotal > 0).
      (metThreshold (and
        hasVotes
        (>= (/ (* yesWeight u100) castTotal) VOTING_THRESHOLD)
      ))
      (vetoMetQuorum (and
        (> snapshot u0)
        (> vetoWeight u0)
        (>= (/ (* vetoWeight u100) snapshot) VOTING_QUORUM)
      ))
      (vetoActivated (and vetoMetQuorum (> vetoWeight yesWeight)))
      (enoughParticipants (>= (get voterCount prop) MIN_PARTICIPANTS))
      (votePassed (and
        metQuorum
        metThreshold
        enoughParticipants
        (not vetoActivated)
      ))
    )
    ;; not already concluded
    (asserts! (not (get concluded prop)) ERR_ALREADY_CONCLUDED)
    ;; execution window: [execStart, execEnd)
    (asserts! (>= stacks-block-height execStart) ERR_NOT_IN_EXEC_WINDOW)
    (asserts! (< stacks-block-height execEnd) ERR_NOT_IN_EXEC_WINDOW)
    ;; EFFECTS BEFORE INTERACTION: mark concluded (and executed iff passing)
    ;; before the external treasury call.
    (map-set Proposals proposal-id
      (merge prop {
        concluded: true,
        executed: votePassed,
      })
    )
    (print {
      event: "conclude-proposal",
      id: proposal-id,
      recipient: (get recipient prop),
      amount: (get amount prop),
      yesWeight: yesWeight,
      noWeight: noWeight,
      vetoWeight: vetoWeight,
      metQuorum: metQuorum,
      metThreshold: metThreshold,
      vetoActivated: vetoActivated,
      enoughParticipants: enoughParticipants,
      passed: votePassed,
    })
    (if votePassed
      (try! (contract-call? .legion-treasury execute-transfer ft (get recipient prop)
        (get amount prop)
      ))
      true
    )
    (ok votePassed)
  )
)
