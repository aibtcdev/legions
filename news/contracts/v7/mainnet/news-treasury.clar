;; news-treasury

;; sBTC token
(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)

(define-constant DEPLOYER tx-sender)

;; Floor on a single sponsorship
(define-constant MIN_SPONSOR u100000)

;; Error constants
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_INSUFFICIENT (err u402))
(define-constant ERR_ALREADY_WIRED (err u403))
(define-constant ERR_ZERO_AMOUNT (err u409))
(define-constant ERR_INVALID_PRINCIPAL (err u410))
(define-constant ERR_INVALID_RECIPIENT (err u411))
(define-constant ERR_ALREADY_PAID (err u416))
(define-constant ERR_BELOW_MIN (err u450))
(define-constant ERR_EMPTY_NAME (err u451))
(define-constant ERR_NOT_WIRED (err u452))

;; The wired gov contract, set once and never changed
(define-data-var Gov (optional principal) none)

;; Every sat in the pool
(define-data-var Balance uint u0)

;; The contributed share of the pool, excluding sponsor sats
;; Must never reach u0 while weight exists
(define-data-var WeightedBalance uint u0)

;; Settled payouts keyed by payout reference
(define-map Paid
  (buff 32)
  {
    recipient: principal,
    amount: uint,
    height: uint,
  }
)

(define-read-only (get-balance)
  (var-get Balance)
)

(define-read-only (get-weighted-balance)
  (var-get WeightedBalance)
)

(define-read-only (get-gov)
  (var-get Gov)
)

(define-read-only (get-token)
  SBTC
)

(define-read-only (get-min-sponsor)
  MIN_SPONSOR
)

(define-read-only (get-payout (payout-ref (buff 32)))
  (map-get? Paid payout-ref)
)

(define-read-only (is-paid (payout-ref (buff 32)))
  (is-some (map-get? Paid payout-ref))
)

;; Authorize on contract-caller, never tx-sender
(define-private (is-gov (who principal))
  (is-eq (some who) (var-get Gov))
)

;; Wire the gov contract once, deployer only
(define-public (set-gov (gov principal))
  (begin
    (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (is-none (var-get Gov)) ERR_ALREADY_WIRED)
    (asserts! (not (is-eq gov current-contract)) ERR_INVALID_PRINCIPAL)
    (var-set Gov (some gov))
    (print {
      event: "set-gov",
      gov: gov,
    })
    (ok true)
  )
)

;; Weight-minting inflow, gov only
(define-public (contribute-in (amount uint))
  (begin
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer amount tx-sender current-contract none))
    (var-set Balance (+ (var-get Balance) amount))
    (var-set WeightedBalance (+ (var-get WeightedBalance) amount))
    (print {
      event: "contribute-in",
      from: tx-sender,
      amount: amount,
      balance: (var-get Balance),
    })
    (ok true)
  )
)

;; Weight-less inflow, public. Identity fields are unverified
(define-public (sponsor-in
    (amount uint)
    (name (string-ascii 40))
    (link (optional (string-ascii 96)))
    (memo (string-ascii 128))
  )
  (begin
    (asserts! (is-some (var-get Gov)) ERR_NOT_WIRED)
    (asserts! (>= amount MIN_SPONSOR) ERR_BELOW_MIN)
    (asserts! (> (len name) u0) ERR_EMPTY_NAME)
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer amount tx-sender current-contract none))
    (var-set Balance (+ (var-get Balance) amount))
    (print {
      event: "sponsor-in",
      from: tx-sender,
      amount: amount,
      name: name,
      link: link,
      memo: memo,
      balance: (var-get Balance),
    })
    (ok true)
  )
)

;; The only way sBTC leaves, gov only
(define-public (execute-payout
    (recipient principal)
    (amount uint)
    (payout-ref (buff 32))
  )
  (let (
      (bal (var-get Balance))
      (weighted (var-get WeightedBalance))
    )
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (not (is-eq recipient current-contract)) ERR_INVALID_RECIPIENT)
    (asserts! (is-none (map-get? Paid payout-ref)) ERR_ALREADY_PAID)
    (asserts! (<= amount bal) ERR_INSUFFICIENT)

    (map-set Paid payout-ref {
      recipient: recipient,
      amount: amount,
      height: stacks-block-height,
    })
    (var-set Balance (- bal amount))
    (var-set WeightedBalance (- weighted (/ (* weighted amount) bal)))

    (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" amount))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer amount tx-sender recipient none))))

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
