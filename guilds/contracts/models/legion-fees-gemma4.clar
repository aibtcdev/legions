;; legion-fees
;; Protocol fee collector (v3.0 section 11a) - the inflow that makes the treasury a
;; positive-margin pass-through instead of a faucet.
;;
;; `route` skims FEE_BPS (8%) of a routed sBTC payment into the legion-treasury
;; and forwards the remainder to the intended recipient, in a single atomic call.
;; The fee is sent via the treasury's permissionless `deposit`, so it is tracked
;; in the treasury's internal pool-accounted Balance and inherits the treasury's
;; wired-token validation (a wrong `ft` reverts inside deposit with u412).
;;
;; This is the common inflow primitive needed by BOTH the grants and business
;; paths, so it ships in Phase 1. Demand-gated bounty payout (which consumes this
;; inflow) is a later phase.

;; -------------------------------------------------------------------
;; Traits
;; -------------------------------------------------------------------
(use-trait sip010-trait 'STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_DUST (err u430)) ;; routed amount too small to skim a non-zero fee
(define-constant ERR_SELF_ROUTE (err u431)) ;; recipient is the treasury itself

;; -------------------------------------------------------------------
;; Config
;; -------------------------------------------------------------------
(define-constant TREASURY .legion-treasury-gemma4)
(define-constant FEE_BPS u800) ;; 8%

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-fee-bps)
  FEE_BPS
)

;; The fee that would be skimmed from `amount`.
(define-read-only (quote-fee (amount uint))
  (/ (* amount FEE_BPS) u10000)
)

;; -------------------------------------------------------------------
;; Public: route
;; -------------------------------------------------------------------
;; Pull `amount` sBTC from tx-sender: FEE_BPS to the treasury, the rest to `to`.
(define-public (route
    (ft <sip010-trait>)
    (amount uint)
    (to principal)
  )
  (let ((fee (/ (* amount FEE_BPS) u10000)))
    ;; reject amounts so small the fee rounds to zero (no free routing)
    (asserts! (> fee u0) ERR_DUST)
    ;; never route the principal portion back into the treasury itself
    (asserts! (not (is-eq to TREASURY)) ERR_SELF_ROUTE)
    ;; fee -> treasury (deposit validates the token + tracks Balance)
    (try! (contract-call? .legion-treasury-gemma4 deposit ft fee))
    ;; remainder -> intended recipient
    (try! (contract-call? ft transfer (- amount fee) tx-sender to none))
    (print {
      event: "route",
      payer: tx-sender,
      amount: amount,
      fee: fee,
      to: to,
    })
    (ok fee)
  )
)
