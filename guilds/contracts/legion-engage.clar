;; legion-engage
;; Providers STAKE sBTC to join a legion and unlock benefits (ranking weight,
;; treasury share, governance). This is OPTIONAL engagement, NOT a requirement to
;; earn: earning is free at the gateway. The stake only buys you "more".
;;
;; There is NO admin and NO slash. Nothing in this contract can seize a member's
;; stake. A member's stake is fully refundable on `leave`, MINUS a fixed exit fee
;; that is routed into the legion treasury (so leaving leaves a little for the
;; commons). The wired sBTC token is a compile-time constant, so there is not even
;; a wiring admin.

(use-trait sip010-trait 'STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait)

;; The only sBTC this contract accepts (the Faktory sBTC the Legion is wired to).
(define-constant SBTC 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token)
;; Exit fees route into `.legion-treasury` (same guild bundle); contract-call?
;; requires the literal contract principal, so it is referenced inline below.

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_ALREADY_MEMBER (err u406))
(define-constant ERR_BELOW_MIN_STAKE (err u405))
(define-constant ERR_ZERO_AMOUNT (err u409))
(define-constant ERR_WRONG_TOKEN (err u412))

;; -------------------------------------------------------------------
;; Config
;; -------------------------------------------------------------------
(define-constant MIN_STAKE u10000)   ;; 10k sats minimum to join
(define-constant EXIT_FEE_BPS u1000) ;; 10% exit fee, in basis points

;; -------------------------------------------------------------------
;; State
;; -------------------------------------------------------------------
(define-data-var TotalStaked uint u0)

(define-map Members
  principal
  {
    stake: uint,
    joined-at: uint,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-member (who principal)) (map-get? Members who))
(define-read-only (is-member (who principal)) (is-some (map-get? Members who)))
(define-read-only (get-stake (who principal))
  (match (map-get? Members who) m (get stake m) u0)
)
(define-read-only (get-total-staked) (var-get TotalStaked))
(define-read-only (get-min-stake) MIN_STAKE)
(define-read-only (get-exit-fee-bps) EXIT_FEE_BPS)
(define-read-only (get-token) SBTC)

;; What a member would get back if they left now: { stake, fee, refund }.
(define-read-only (quote-exit (who principal))
  (match (map-get? Members who)
    m (let (
        (s (get stake m))
        (fee (/ (* (get stake m) EXIT_FEE_BPS) u10000))
      )
      (some {
        stake: s,
        fee: fee,
        refund: (- s fee),
      }))
    none
  )
)

;; -------------------------------------------------------------------
;; Join: lock sBTC and become a member.
;; -------------------------------------------------------------------
(define-public (join
    (ft <sip010-trait>)
    (amount uint)
  )
  (begin
    (asserts! (is-eq (contract-of ft) SBTC) ERR_WRONG_TOKEN)
    (asserts! (is-none (map-get? Members tx-sender)) ERR_ALREADY_MEMBER)
    (asserts! (>= amount MIN_STAKE) ERR_BELOW_MIN_STAKE)
    (try! (contract-call? ft transfer amount tx-sender (as-contract tx-sender) none))
    (map-set Members tx-sender {
      stake: amount,
      joined-at: stacks-block-height,
    })
    (var-set TotalStaked (+ (var-get TotalStaked) amount))
    (print { event: "join", member: tx-sender, stake: amount })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Top up an existing stake.
;; -------------------------------------------------------------------
(define-public (add-stake
    (ft <sip010-trait>)
    (amount uint)
  )
  (let ((m (unwrap! (map-get? Members tx-sender) ERR_NOT_FOUND)))
    (asserts! (is-eq (contract-of ft) SBTC) ERR_WRONG_TOKEN)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? ft transfer amount tx-sender (as-contract tx-sender) none))
    (map-set Members tx-sender (merge m { stake: (+ (get stake m) amount) }))
    (var-set TotalStaked (+ (var-get TotalStaked) amount))
    (print { event: "add-stake", member: tx-sender, added: amount, stake: (+ (get stake m) amount) })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Leave: refund stake minus the exit fee. Fee -> treasury, refund -> member.
;; Effects-before-interaction: state is cleared before any token movement.
;; -------------------------------------------------------------------
(define-public (leave (ft <sip010-trait>))
  (let (
      (m (unwrap! (map-get? Members tx-sender) ERR_NOT_FOUND))
      (who tx-sender)
      (s (get stake m))
      (fee (/ (* (get stake m) EXIT_FEE_BPS) u10000))
      (refund (- (get stake m) (/ (* (get stake m) EXIT_FEE_BPS) u10000)))
    )
    (asserts! (is-eq (contract-of ft) SBTC) ERR_WRONG_TOKEN)
    (map-delete Members who)
    (var-set TotalStaked (- (var-get TotalStaked) s))
    ;; refund the member (stake minus fee)
    (try! (as-contract (contract-call? ft transfer refund tx-sender who none)))
    ;; route the exit fee into the treasury's accounted balance (governable)
    (if (> fee u0)
      (try! (as-contract (contract-call? .legion-treasury deposit ft fee)))
      true
    )
    (print { event: "leave", member: who, refund: refund, fee: fee })
    (ok { refund: refund, fee: fee })
  )
)
