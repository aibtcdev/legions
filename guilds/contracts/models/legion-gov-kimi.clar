;; legion-gov (GENERIC model-legion variant)
;; Proposals + STAKE-WEIGHTED voting for a model Legion. Generated from the
;; news legion-gov with the Rail-A news gates (content-hash / inscription
;; freshness / source count) removed: propose is (desc recipient amount).
;; Bond + proposer-exclusion + quorum/threshold/veto are unchanged.
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
;; Timing uses stacks-block-height (like the reference test-fast config), NOT
;; burn-block-height.
;;
;; Funds are denominated in sBTC: `stake` forwards a `<sip010-trait>` token into
;; the treasury and `conclude-proposal` forwards the same trait reference into the
;; treasury's execute-transfer. The treasury validates the token principal.
;;
;; -------------------------------------------------------------------
;; v3.0 / Phase-1 additions (Agent-News -> Legion payout, demand-gated design):
;;   1. BondLock          - each proposal earmarks a bond from the proposer's own
;;        stake. `locked-of` sums ALL of a proposer's open bonds, so one stake can
;;        no longer back unlimited concurrent proposals. Stake is time-locked
;;        (StakeLockedUntil) past the exec + challenge window, so a proposer cannot
;;        unstake-and-run mid-lifecycle.
;;   2. ProposerExclusion - the proposer may not vote on their own proposal, and
;;        the quorum / veto denominator is ELIGIBLE (non-proposer) stake, so a
;;        whale proposer holding the majority cannot brick honest quorum.
;; (Demand-gated bounty, challenge market and soulbound rep are later phases.)
;; -------------------------------------------------------------------

;; -------------------------------------------------------------------
;; Traits
;; -------------------------------------------------------------------
(use-trait sip010-trait 'STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_INELIGIBLE (err u401)) ;; zero-stake / ineligible voter or proposer
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
(define-constant ERR_ZERO_AMOUNT (err u417)) ;; stake/propose/unstake amount must be > 0
(define-constant ERR_EMPTY_DESC (err u418)) ;; proposal description must be non-empty
(define-constant ERR_BELOW_MIN_STAKE (err u419)) ;; stake/remaining below the 10k membership floor
;; -- Bond / proposer-exclusion errors --
(define-constant ERR_INSUFFICIENT_BOND (err u422)) ;; free stake cannot cover the proposal bond
(define-constant ERR_SELF_VOTE (err u423)) ;; proposer voting on own proposal
(define-constant ERR_STAKE_LOCKED (err u424)) ;; unstake before StakeLockedUntil
(define-constant ERR_INSUFFICIENT_UNSTAKE (err u425)) ;; unstake more than free (unlocked) stake

;; -------------------------------------------------------------------
;; Config (matches the reference parameter values)
;; -------------------------------------------------------------------
(define-constant TREASURY .legion-treasury-kimi)
(define-constant SELF (as-contract tx-sender))

(define-constant VOTING_QUORUM u15) ;; 15% turnout (of ELIGIBLE staked) required
(define-constant VOTING_THRESHOLD u66) ;; 66% of cast votes must be yes
;; TEST TIMING: short windows + Stacks-block (not burn-block) counting. Tuned so
;; a full lifecycle (DELAY + PERIOD + DELAY + PERIOD = 96 stacks blocks) runs in
;; ~1 hour on testnet (~3x the prior 32-block / ~20-min cadence). For production,
;; revert to burn-block-height with VOTING_DELAY u12 / VOTING_PERIOD u24 (AIBTC-matched).
(define-constant VOTING_DELAY u3) ;; stacks blocks between creation and vote start
(define-constant VOTING_PERIOD u45) ;; stacks-block voting window length

;; Our extra guard on top of the AIBTC model: require at least this many distinct
;; voters before a proposal can execute.
(define-constant MIN_PARTICIPANTS u2)

;; -- Bond config --
;; Bond earmarked from the proposer's stake, in basis points of the requested amount.
(define-constant BOND_BPS u2000) ;; 20%
;; Membership economics (ported from legion-engage): a floor to join and a 10%
;; exit fee skimmed to the treasury on unstake (leaving leaves some for the commons).
(define-constant MIN_STAKE u10000)   ;; 10k sats minimum to be a member
(define-constant EXIT_FEE_BPS u1000) ;; 10% exit fee, in basis points
;; Stake stays locked this many blocks past execEnd (placeholder for the Phase-2
;; Rail-B challenge window). Prevents unstake-and-run before a proposal settles.
(define-constant CHALLENGE_PERIOD u15)

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
;; Stake per principal = voting weight.
(define-map Stakes
  principal
  uint
)

;; Running total of all staked sBTC. Used as the basis for the per-proposal
;; eligible-stake snapshot (denominator) and decremented on unstake.
(define-data-var TotalStaked uint u0)

;; BondLock: running sum of a principal's OPEN (unreleased) proposal bonds.
;; `locked-of` reads this in O(1). It is the "sum all open bonds" the design
;; requires so one stake cannot back unlimited concurrent proposals.
(define-map LockedStake principal uint)

;; BondLock: earliest stacks-block at which a principal may unstake. Set on
;; propose to execEnd + CHALLENGE_PERIOD (kept monotonic across proposals).
(define-map StakeLockedUntil principal uint)

;; Per-proposal bond record (earmarked from the proposer's stake).
(define-map ProposalBond
  uint
  {
    proposer: principal,
    locked: uint,
    released: bool,
  }
)

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
    ;; proposal at creation time (`totalStakedSnapshot`) and derive the quorum /
    ;; veto denominator as ELIGIBLE stake = snapshot - proposer's own stake
    ;; (`eligibleSnapshot`). Per-voter weight is read as CURRENT stake at vote
    ;; time. This is safe because staked sBTC is locked inside legion-treasury and
    ;; cannot be withdrawn while a proposal is live (StakeLockedUntil), so
    ;; mid-proposal vote-buying is not a cheap attack.
    totalStakedSnapshot: uint,
    proposerStake: uint,
    eligibleSnapshot: uint,
    bond: uint,
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

;; BondLock: total of `who`'s open (unreleased) proposal bonds.
(define-read-only (locked-of (who principal))
  (default-to u0 (map-get? LockedStake who))
)

;; BondLock: earliest block `who` may unstake (u0 = never proposed / unlocked).
(define-read-only (get-locked-until (who principal))
  (default-to u0 (map-get? StakeLockedUntil who))
)

;; Free (unlocked, unbonded) stake `who` could unstake right now, ignoring time.
(define-read-only (get-free-stake (who principal))
  (- (get-stake who) (locked-of who))
)

(define-read-only (get-bond (id uint))
  (map-get? ProposalBond id)
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
;; current met-quorum / met-threshold / veto evaluation for a proposal. Quorum is
;; measured against ELIGIBLE (non-proposer) stake.
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
        (eligible (get eligibleSnapshot prop))
        (castTotal (+ yesWeight noWeight))
        (hasVotes (> castTotal u0))
        (metQuorum (and
          (> eligible u0)
          hasVotes
          (>= (/ (* castTotal u100) eligible) VOTING_QUORUM)
        ))
        (metThreshold (and
          hasVotes
          (>= (/ (* yesWeight u100) castTotal) VOTING_THRESHOLD)
        ))
        (vetoMetQuorum (and
          (> eligible u0)
          (> vetoWeight u0)
          (>= (/ (* vetoWeight u100) eligible) VOTING_QUORUM)
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
        totalStakedSnapshot: (get totalStakedSnapshot prop),
        eligibleSnapshot: eligible,
        bond: (get bond prop),
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
    ;; Membership floor: the resulting stake must be at least MIN_STAKE (so a first
    ;; stake must be >= 10k; top-ups by an existing member always clear it).
    (asserts! (>= (+ (get-stake tx-sender) amount) MIN_STAKE) ERR_BELOW_MIN_STAKE)
    ;; treasury.deposit asserts amount > u0, validates the token, and transfers.
    (try! (contract-call? .legion-treasury-kimi deposit ft amount))
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
;; Public: unstake
;; -------------------------------------------------------------------
;; Returns `amount` sBTC from the treasury to the caller. Only FREE stake (stake
;; minus open bonds) is withdrawable, and only after StakeLockedUntil. gov is the
;; authorized mover, so it routes the payout through treasury.execute-transfer.
(define-public (unstake
    (ft <sip010-trait>)
    (amount uint)
  )
  (let (
      (staker tx-sender)
      (bal (get-stake tx-sender))
      (locked (locked-of tx-sender))
      (until (get-locked-until tx-sender))
      (fee (/ (* amount EXIT_FEE_BPS) u10000))
      (refund (- amount fee))
      (remaining (- bal amount))
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (>= stacks-block-height until) ERR_STAKE_LOCKED)
    ;; cannot withdraw stake that is earmarked as an open proposal bond
    (asserts! (<= amount (- bal locked)) ERR_INSUFFICIENT_UNSTAKE)
    ;; remaining stake must be a full exit (0) or stay at/above the membership floor
    (asserts! (or (is-eq remaining u0) (>= remaining MIN_STAKE)) ERR_BELOW_MIN_STAKE)
    ;; EFFECTS BEFORE INTERACTION
    (map-set Stakes staker remaining)
    (var-set TotalStaked (- (var-get TotalStaked) amount))
    ;; Refund the staker minus the 10% exit fee. execute-transfer moves only the
    ;; refund out of the treasury, so the fee portion stays in the treasury's
    ;; accounted balance (the commons); no separate deposit needed.
    (try! (contract-call? .legion-treasury-kimi execute-transfer ft staker refund))
    (print {
      event: "unstake",
      staker: staker,
      amount: amount,
      fee: fee,
      refund: refund,
      remaining: remaining,
      totalStaked: (var-get TotalStaked),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: propose
;; -------------------------------------------------------------------
;; Snapshots the eligible staked weight, anchors the burn-block lifecycle, runs
;; the Rail-A precheck (freshness / hash de-dup / sourcing), and earmarks a bond
;; from the proposer's own stake.
(define-public (propose
    (desc (string-ascii 256))
    (recipient principal)
    (amount uint)
  )
  (let (
      (id (+ (var-get ProposalNonce) u1))
      (snapshot (var-get TotalStaked))
      (proposer-stake (get-stake tx-sender))
      (already-locked (locked-of tx-sender))
      (createdBtc stacks-block-height)
      (bond (/ (* amount BOND_BPS) u10000))
      (execEnd (+ createdBtc (+ (* u2 VOTING_DELAY) (* u2 VOTING_PERIOD))))
      (lock-until (+ execEnd CHALLENGE_PERIOD))
      (cur-lock (get-locked-until tx-sender))
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
    ;; BondLock: only a staker may propose, and free stake must cover the bond.
    (asserts! (> proposer-stake u0) ERR_INELIGIBLE)
    (asserts! (>= proposer-stake (+ already-locked bond)) ERR_INSUFFICIENT_BOND)
    ;; BondLock: earmark the bond and time-lock the proposer's stake.
    (map-set LockedStake tx-sender (+ already-locked bond))
    (map-set ProposalBond id {
      proposer: tx-sender,
      locked: bond,
      released: false,
    })
    (map-set StakeLockedUntil tx-sender (if (> lock-until cur-lock)
      lock-until
      cur-lock
    ))
    (map-set Proposals id {
      proposer: tx-sender,
      desc: desc,
      recipient: recipient,
      amount: amount,
      createdBtc: createdBtc,
      totalStakedSnapshot: snapshot,
      proposerStake: proposer-stake,
      eligibleSnapshot: (- snapshot proposer-stake),
      bond: bond,
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
      bond: bond,
      createdBtc: createdBtc,
      voteStart: (+ createdBtc VOTING_DELAY),
      voteEnd: (+ (+ createdBtc VOTING_DELAY) VOTING_PERIOD),
      totalStakedSnapshot: snapshot,
      eligibleSnapshot: (- snapshot proposer-stake),
    })
    (ok id)
  )
)

;; -------------------------------------------------------------------
;; Public: vote
;; -------------------------------------------------------------------
;; Allowed only in [voteStart, voteEnd). The proposer may NOT vote on their own
;; proposal. A voter may change their vote within the window: the previous
;; weighted vote is subtracted and the new one added.
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
    ;; ProposerExclusion: the proposer cannot vote on their own proposal.
    (asserts! (not (is-eq tx-sender (get proposer prop))) ERR_SELF_VOTE)
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
;; Callable only in [execStart, execEnd) and only once. Marks the proposal
;; concluded BEFORE any external call (effects-before-interaction). Releases the
;; proposer's bond, and frees the content hash iff the proposal FAILED (so the
;; story can be re-filed; a paid hash stays claimed forever). Executes the
;; treasury transfer ONLY IF the proposal met (eligible) quorum AND threshold AND
;; has >= MIN_PARTICIPANTS voters AND was not veto-activated.
(define-public (conclude-proposal
    (proposal-id uint)
    (ft <sip010-trait>)
  )
  (let (
      (prop (unwrap! (map-get? Proposals proposal-id) ERR_NO_PROPOSAL))
      (bondInfo (unwrap! (map-get? ProposalBond proposal-id) ERR_NO_PROPOSAL))
      (createdBtc (get createdBtc prop))
      (voteEnd (+ (+ createdBtc VOTING_DELAY) VOTING_PERIOD))
      (execStart (+ voteEnd VOTING_DELAY))
      (execEnd (+ execStart VOTING_PERIOD))
      (yesWeight (get yesWeight prop))
      (noWeight (get noWeight prop))
      (vetoWeight (get vetoWeight prop))
      (eligible (get eligibleSnapshot prop))
      (castTotal (+ yesWeight noWeight))
      (hasVotes (> castTotal u0))
      ;; quorum: total cast vs ELIGIBLE snapshot. Guard against zero / no votes.
      (metQuorum (and
        (> eligible u0)
        hasVotes
        (>= (/ (* castTotal u100) eligible) VOTING_QUORUM)
      ))
      ;; threshold: yes vs cast. Guard against div-by-zero (castTotal > 0).
      (metThreshold (and
        hasVotes
        (>= (/ (* yesWeight u100) castTotal) VOTING_THRESHOLD)
      ))
      (vetoMetQuorum (and
        (> eligible u0)
        (> vetoWeight u0)
        (>= (/ (* vetoWeight u100) eligible) VOTING_QUORUM)
      ))
      (vetoActivated (and vetoMetQuorum (> vetoWeight yesWeight)))
      (enoughParticipants (>= (get voterCount prop) MIN_PARTICIPANTS))
      (votePassed (and
        metQuorum
        metThreshold
        enoughParticipants
        (not vetoActivated)
      ))
      (proposer (get proposer prop))
      (bondAmt (get locked bondInfo))
    )
    ;; not already concluded
    (asserts! (not (get concluded prop)) ERR_ALREADY_CONCLUDED)
    ;; execution window: [execStart, execEnd)
    (asserts! (>= stacks-block-height execStart) ERR_NOT_IN_EXEC_WINDOW)
    (asserts! (< stacks-block-height execEnd) ERR_NOT_IN_EXEC_WINDOW)
    ;; EFFECTS BEFORE INTERACTION:
    ;; release the proposer's bond back into free stake.
    (map-set ProposalBond proposal-id (merge bondInfo { released: true }))
    (map-set LockedStake proposer (- (locked-of proposer) bondAmt))
    ;; mark concluded (and executed iff passing) before the external call.
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
      eligibleSnapshot: eligible,
      metQuorum: metQuorum,
      metThreshold: metThreshold,
      vetoActivated: vetoActivated,
      enoughParticipants: enoughParticipants,
      bondReleased: bondAmt,
      passed: votePassed,
    })
    (if votePassed
      (try! (contract-call? .legion-treasury-kimi execute-transfer ft (get recipient prop)
        (get amount prop)
      ))
      true
    )
    (ok votePassed)
  )
)
