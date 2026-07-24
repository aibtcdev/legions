;; news-treasury
;; The sBTC pool for the aibtc.news Legion.
;;
;; ONE POOL. Agents send sBTC in and receive voting rights over how it is spent.
;; The money funds journalism; it does not come back. There is no staking, no
;; withdrawal, and no second balance.
;;
;; An earlier version held two balances -- a Pool that paid correspondents and a
;; separate Staked balance that bought votes and was never spent. That detached
;; the two things governance has to weld together: the people deciding were not
;; the people paying, so approving a bad week cost a voter nothing. Weight now
;; comes from the same sats that get paid out, so every yes vote spends the
;; voter's own money in proportion to their say.
;;
;; Because nothing is withdrawable, this pool can never be short. Payouts simply
;; shrink it, and every holder's claim shrinks together.
;;
;; Every outflow is gated on `contract-caller` being the wired gov contract, so
;; no human can move funds directly. The deployer's only power is the one-time
;; wiring; it holds no key to the money.

;; -------------------------------------------------------------------
;; Config
;; -------------------------------------------------------------------
;; The sBTC token is a fixed, known contract, referenced statically rather than
;; through a <sip010-trait> parameter: settling a week folds over up to 30
;; entries, and Clarity cannot carry a trait reference through a `fold`
;; accumulator. It also removes the whole class of wrong-token bugs -- there is
;; no token argument to get wrong.
;;
;; NOTE: `contract-call?` requires a LITERAL contract identifier. A constant
;; bound to a contract principal passes `clarinet check` and then fails at
;; runtime with ContractCallExpectName, so the token is written out at each call
;; site below rather than referenced through SBTC.
(define-constant SBTC 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token)

(define-constant DEPLOYER tx-sender)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_UNAUTHORIZED (err u401)) ;; caller is not gov / not deployer
(define-constant ERR_INSUFFICIENT (err u402)) ;; amount exceeds the pool
(define-constant ERR_ALREADY_WIRED (err u403)) ;; gov already set
(define-constant ERR_ZERO_AMOUNT (err u409)) ;; amount must be > u0
(define-constant ERR_INVALID_PRINCIPAL (err u410)) ;; cannot wire gov to the treasury itself
(define-constant ERR_INVALID_RECIPIENT (err u411)) ;; treasury cannot pay itself
(define-constant ERR_ALREADY_PAID (err u416)) ;; this payout-ref has already been settled

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
(define-data-var Gov (optional principal) none)

;; The pool. Everything in here is spendable on journalism and nothing else.
(define-data-var Balance uint u0)

;; Settled payout references, keyed by sha256 of {d: week, r: recipient}.
;; Anyone can recompute a ref and check on-chain whether that correspondent was
;; paid for that week, and how much.
(define-map Paid
  (buff 32)
  {
    recipient: principal,
    amount: uint,
    height: uint,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-balance)
  (var-get Balance)
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
;; Public: contribute-in (gov only)
;; -------------------------------------------------------------------
;; The only way sBTC enters. Called by news-gov.contribute, which mints the
;; corresponding voting weight in the same transaction. tx-sender is preserved
;; across the inter-contract call, so the contributor is debited, not gov.
;;
;; Deliberately gov-only: a direct deposit path would let someone fund the pool
;; without receiving the say that funding is supposed to buy, which is the exact
;; split this design exists to remove.
(define-public (contribute-in (amount uint))
  (begin
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
    (var-set Balance (+ (var-get Balance) amount))
    (print {
      event: "contribute-in",
      from: tx-sender,
      amount: amount,
      balance: (var-get Balance),
    })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: execute-payout (gov only)
;; -------------------------------------------------------------------
;; The ONLY way sBTC leaves. Settles one correspondent from a passed week. The
;; payout-ref is claimed before the transfer, so a re-entrant call cannot
;; double-settle the same correspondent.
(define-public (execute-payout
    (recipient principal)
    (amount uint)
    (payout-ref (buff 32))
  )
  (let ((bal (var-get Balance)))
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (not (is-eq recipient (as-contract tx-sender))) ERR_INVALID_RECIPIENT)
    (asserts! (is-none (map-get? Paid payout-ref)) ERR_ALREADY_PAID)
    (asserts! (<= amount bal) ERR_INSUFFICIENT)

    ;; --- effects ---
    (map-set Paid payout-ref {
      recipient: recipient,
      amount: amount,
      height: stacks-block-height,
    })
    (var-set Balance (- bal amount))

    ;; --- interaction ---
    (try! (as-contract (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender recipient none)))

    (print {
      event: "execute-payout",
      recipient: recipient,
      amount: amount,
      payoutRef: payout-ref,
      balance: (var-get Balance),
    })
    (ok true)
  )
)
