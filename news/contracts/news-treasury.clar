;; news-treasury
;; The sBTC balance sheet for the aibtc.news Legion.
;;
;; Holds two logically separate balances under one contract principal:
;;
;;   Pool   -- contributed sBTC. This is what pays journalists. Nobody can
;;            withdraw it; it only leaves via `execute-payout` on a passed vote.
;;   Staked -- members' voting collateral. Refundable to the member who put it
;;            in, via `execute-unstake`. Never paid out to correspondents.
;;
;; Keeping these apart is load-bearing. The draw is a percentage of the POOL,
;; not of the contract's total holdings -- otherwise an approved brief would pay
;; correspondents out of the members' own stake, and staking would become a
;; slow donation.
;;
;; Every outflow is gated on `contract-caller` being the wired gov contract, so
;; no human can move funds directly. The deployer's only power is the one-time
;; wiring; it holds no key to the money.

;; -------------------------------------------------------------------
;; Config
;; -------------------------------------------------------------------
;; The sBTC token is a fixed, known contract, so it is referenced statically
;; rather than through a <sip010-trait> parameter. This is deliberate: settling
;; a brief folds over up to 30 entries, and Clarity cannot carry a trait
;; reference through a `fold` accumulator. A static reference also removes the
;; whole class of wrong-token bugs -- there is no token argument to get wrong.
(define-constant SBTC 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token)

(define-constant DEPLOYER tx-sender)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_UNAUTHORIZED (err u401)) ;; caller is not gov / not deployer
(define-constant ERR_INSUFFICIENT (err u402)) ;; amount exceeds the relevant balance
(define-constant ERR_ALREADY_WIRED (err u403)) ;; gov already set
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; amount must be > u0
(define-constant ERR_INVALID_PRINCIPAL (err u410)) ;; cannot wire gov to the treasury itself
(define-constant ERR_INVALID_RECIPIENT (err u411)) ;; treasury cannot pay itself
(define-constant ERR_ALREADY_PAID (err u416)) ;; this payout-ref has already been settled

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
(define-data-var Gov (optional principal) none)

;; Contributed sBTC available to pay journalists.
(define-data-var Pool uint u0)
;; Members' voting collateral, refundable.
(define-data-var Staked uint u0)

;; Settled payout references, keyed by sha256(brief-date | signal-id |
;; recipient). Anyone holding the brief inscription can recompute a ref and
;; check on-chain whether it was paid, and for how much.
(define-map Paid
  (buff 32)
  {
    recipient: principal,
    amount: uint,
    burnHeight: uint,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-pool)
  (var-get Pool)
)

(define-read-only (get-staked)
  (var-get Staked)
)

;; Total sBTC held under this contract principal.
(define-read-only (get-balance)
  (+ (var-get Pool) (var-get Staked))
)

(define-read-only (get-gov)
  (var-get Gov)
)

(define-read-only (get-token)
  SBTC
)

(define-read-only (get-payout (payout-ref (buff 32)))
  (map-get? Paid payout-ref)
)

(define-read-only (is-paid (payout-ref (buff 32)))
  (is-some (map-get? Paid payout-ref))
)

;; -------------------------------------------------------------------
;; Private auth helper
;; -------------------------------------------------------------------
;; Gov reaches us through an inter-contract call, so authorize on
;; contract-caller (the immediate caller), never tx-sender.
(define-private (is-gov (who principal))
  (is-eq (some who) (var-get Gov))
)

;; -------------------------------------------------------------------
;; Public: wiring (one-time, deployer only)
;; -------------------------------------------------------------------
(define-public (set-gov (gov principal))
  (begin
    (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (is-none (var-get Gov)) ERR_ALREADY_WIRED)
    (asserts! (not (is-eq gov (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (var-set Gov (some gov))
    (print {
      event: "set-gov",
      gov: gov,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: deposit (anyone)
;; -------------------------------------------------------------------
;; Fund the newsroom. Contributed sBTC goes to the Pool and is not refundable --
;; it exists to be paid to journalists.
(define-public (deposit (amount uint))
  (begin
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
    (var-set Pool (+ (var-get Pool) amount))
    (print {
      event: "deposit",
      from: tx-sender,
      amount: amount,
      pool: (var-get Pool),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: stake-in (gov only)
;; -------------------------------------------------------------------
;; Pulls a member's voting collateral in. tx-sender is preserved across the
;; inter-contract call from news-gov.stake, so the member is debited, not gov.
(define-public (stake-in (amount uint))
  (begin
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
    (var-set Staked (+ (var-get Staked) amount))
    (print {
      event: "stake-in",
      from: tx-sender,
      amount: amount,
      staked: (var-get Staked),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: execute-payout (gov only)
;; -------------------------------------------------------------------
;; Settles one entry of a passed brief, out of the Pool. The payout-ref is
;; claimed before the transfer, so a re-entrant call cannot double-settle the
;; same inscribed contribution.
(define-public (execute-payout
    (recipient principal)
    (amount uint)
    (payout-ref (buff 32))
  )
  (let ((pool (var-get Pool)))
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (not (is-eq recipient (as-contract tx-sender))) ERR_INVALID_RECIPIENT)
    (asserts! (is-none (map-get? Paid payout-ref)) ERR_ALREADY_PAID)
    (asserts! (<= amount pool) ERR_INSUFFICIENT)

    ;; --- effects ---
    (map-set Paid payout-ref {
      recipient: recipient,
      amount: amount,
      burnHeight: burn-block-height,
    })
    (var-set Pool (- pool amount))

    ;; --- interaction ---
    (try! (as-contract (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender recipient none)))

    (print {
      event: "execute-payout",
      recipient: recipient,
      amount: amount,
      payoutRef: payout-ref,
      pool: (var-get Pool),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: execute-unstake (gov only)
;; -------------------------------------------------------------------
;; Returns a member's own collateral. news-gov bounds `amount` to that member's
;; free (unlocked) stake before calling, and gov has no entrypoint that lets a
;; proposal name an arbitrary recipient -- so this cannot become a payout channel.
(define-public (execute-unstake
    (recipient principal)
    (amount uint)
  )
  (let ((staked (var-get Staked)))
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (<= amount staked) ERR_INSUFFICIENT)
    (asserts! (not (is-eq recipient (as-contract tx-sender))) ERR_INVALID_RECIPIENT)
    (var-set Staked (- staked amount))
    (try! (as-contract (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender recipient none)))
    (print {
      event: "execute-unstake",
      recipient: recipient,
      amount: amount,
      staked: (var-get Staked),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: slash (gov only)
;; -------------------------------------------------------------------
;; Moves a forfeited proposal bond from Staked into Pool. No tokens move -- the
;; sBTC is already held here; only the claim on it changes. The proposer's
;; per-principal stake ledger is decremented in news-gov in the same call.
(define-public (slash (amount uint))
  (let ((staked (var-get Staked)))
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (<= amount staked) ERR_INSUFFICIENT)
    (var-set Staked (- staked amount))
    (var-set Pool (+ (var-get Pool) amount))
    (print {
      event: "slash",
      amount: amount,
      pool: (var-get Pool),
      staked: (var-get Staked),
    })
    (ok true)
  )
)
