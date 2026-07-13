;; legion-treasury
;; Holds pooled funds for the AIBTC Legion and moves them only on authorized instruction.
;;
;; The pool is denominated in sBTC (a SIP-010 fungible token). Funds are moved via
;; the SIP-010 `transfer` entrypoint on a `<sip010-trait>` token passed in by the
;; caller. The token principal is wired once via `set-token`, and every fund-moving
;; entrypoint asserts the supplied trait reference matches the wired token. The
;; authorization model (gov wiring) is identical to the prior STX version.

;; -------------------------------------------------------------------
;; Traits
;; -------------------------------------------------------------------
(use-trait sip010-trait 'STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_UNAUTHORIZED (err u401)) ;; caller is not gov
(define-constant ERR_INSUFFICIENT (err u402)) ;; amount > balance
(define-constant ERR_ALREADY_WIRED (err u403)) ;; gov/token already set
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; amount must be > u0
(define-constant ERR_INVALID_PRINCIPAL (err u410)) ;; cannot wire gov/token to the treasury itself
(define-constant ERR_INVALID_RECIPIENT (err u411)) ;; treasury cannot transfer to itself
(define-constant ERR_WRONG_TOKEN (err u412)) ;; supplied ft does not match the wired sBTC token

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
;; The deployer is the only principal allowed to perform the one-time wiring.
(define-constant DEPLOYER tx-sender)

(define-data-var Gov (optional principal) none)
;; The wired sBTC token principal. Set once by the deployer via `set-token`.
(define-data-var Token (optional principal) none)

;; Internal accounting of pool-accounted sBTC. Incremented on `deposit`, decremented
;; on `execute-transfer`. Tracked as a uint so gov can read the pool cheaply
;; via `get-balance` without needing a trait reference. This reflects funds that
;; flowed through this contract's accounted entrypoints, not a raw token balance.
(define-data-var Balance uint u0)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
;; Returns the internal pool-accounted balance (uint). NOTE: this is the
;; pool-accounted total tracked by deposit/execute-transfer, deliberately exposed
;; without a trait param so gov can read the pool cheaply.
(define-read-only (get-balance)
  (var-get Balance)
)

(define-read-only (get-gov)
  (var-get Gov)
)

(define-read-only (get-token)
  (var-get Token)
)

;; -------------------------------------------------------------------
;; Private auth helper
;; -------------------------------------------------------------------
;; Funds may only be moved by the wired gov contract. Because gov invokes us
;; through inter-contract calls, we authorize on contract-caller (the immediate
;; caller), not tx-sender (the human who triggered the chain).
(define-private (is-authorized-mover (who principal))
  (is-eq (some who) (var-get Gov))
)

;; -------------------------------------------------------------------
;; Public: wiring (one-time each, deployer only)
;; -------------------------------------------------------------------
(define-public (set-gov (gov principal))
  (begin
    (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (is-none (var-get Gov)) ERR_ALREADY_WIRED)
    ;; gov must be an external contract, never the treasury itself.
    (asserts! (not (is-eq gov (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (var-set Gov (some gov))
    (print {
      event: "set-gov",
      gov: gov,
    })
    (ok true)
  )
)

;; Wire the sBTC token principal. One-time, deployer only, never the treasury
;; itself. After this, every fund-moving entrypoint requires the supplied trait
;; reference to equal this principal.
(define-public (set-token (token principal))
  (begin
    (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (is-none (var-get Token)) ERR_ALREADY_WIRED)
    ;; token must be an external contract, never the treasury itself.
    (asserts! (not (is-eq token (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (var-set Token (some token))
    (print {
      event: "set-token",
      token: token,
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: deposit
;; -------------------------------------------------------------------
;; Pulls `amount` sBTC from tx-sender into this contract via the SIP-010 token.
;; tx-sender is preserved across inter-contract calls (gov.stake forwards here),
;; so the original staker is debited even when called via gov. The token-match
;; assert sanitizes `ft` (it must equal the wired token) before it is used, and
;; the amount assert sanitizes `amount`.
(define-public (deposit
    (ft <sip010-trait>)
    (amount uint)
  )
  (begin
    (asserts! (is-eq (contract-of ft) (unwrap! (var-get Token) ERR_WRONG_TOKEN))
      ERR_WRONG_TOKEN
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? ft transfer amount tx-sender (as-contract tx-sender) none))
    (var-set Balance (+ (var-get Balance) amount))
    (print {
      event: "deposit",
      from: tx-sender,
      amount: amount,
      balance: (var-get Balance),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: execute-transfer (gov only)
;; -------------------------------------------------------------------
;; Sends `amount` sBTC out of the treasury to `recipient` via the SIP-010 token.
(define-public (execute-transfer
    (ft <sip010-trait>)
    (recipient principal)
    (amount uint)
  )
  (let ((bal (var-get Balance)))
    (asserts! (is-authorized-mover contract-caller) ERR_UNAUTHORIZED)
    ;; the supplied token must match the wired sBTC token; sanitizes `ft`.
    (asserts! (is-eq (contract-of ft) (unwrap! (var-get Token) ERR_WRONG_TOKEN))
      ERR_WRONG_TOKEN
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (<= amount bal) ERR_INSUFFICIENT)
    ;; The treasury must never pay itself (would be a self-transfer no-op that
    ;; masks a misrouted payout). Validates `recipient` before the transfer.
    (asserts! (not (is-eq recipient (as-contract tx-sender))) ERR_INVALID_RECIPIENT)
    ;; Move out of the contract's own balance.
    (try! (as-contract (contract-call? ft transfer amount tx-sender recipient none)))
    (var-set Balance (- bal amount))
    (print {
      event: "execute-transfer",
      caller: contract-caller,
      recipient: recipient,
      amount: amount,
      balance: (var-get Balance),
    })
    (ok true)
  )
)
