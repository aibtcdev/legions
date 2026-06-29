;; legion-providers
;; Provider guild for a Provider Legion: inference operators register, post a
;; refundable sBTC bond (quality collateral + routing weight), advertise a model
;; + endpoint, and accrue a soft reputation (jobs ok/fail).
;;
;; Earnings are NOT handled here. Inference payments settle DIRECT per-call via
;; legion-fees.route (92% to the serving provider, 8% to the guild treasury) -
;; non-custodial. This contract only ever holds BONDS (slashable collateral),
;; never earnings.
;;
;; v1 trust model: an Admin principal attests job outcomes and may slash a bond.
;; This is the placeholder for a later proof mechanism (challenge market / oracle);
;; on-chain slashing is intentionally admin-gated until that exists.

(use-trait sip010-trait 'STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait)

(define-constant DEPLOYER tx-sender)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_ALREADY_WIRED (err u403))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_ALREADY_REGISTERED (err u406))
(define-constant ERR_BELOW_MIN_BOND (err u405))
(define-constant ERR_SLASH_EXCEEDS (err u407))
(define-constant ERR_ZERO_AMOUNT (err u409))
(define-constant ERR_INVALID_PRINCIPAL (err u410))
(define-constant ERR_WRONG_TOKEN (err u412))
(define-constant ERR_EMPTY (err u400))

;; -------------------------------------------------------------------
;; Config
;; -------------------------------------------------------------------
(define-constant MIN_BOND u1000000) ;; minimum bond, sBTC base units

;; -------------------------------------------------------------------
;; State
;; -------------------------------------------------------------------
(define-data-var Admin principal DEPLOYER)        ;; attests jobs / slashes (v1)
(define-data-var Token (optional principal) none) ;; wired sBTC token
(define-data-var SlashSink principal DEPLOYER)    ;; where slashed bond is sent

(define-map Providers
  principal
  {
    model: (string-ascii 64),
    endpoint: (string-ascii 256),
    bond: uint,
    active: bool,
    jobs-ok: uint,
    jobs-fail: uint,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-provider (who principal)) (map-get? Providers who))
(define-read-only (get-admin) (var-get Admin))
(define-read-only (get-token) (var-get Token))
(define-read-only (get-slash-sink) (var-get SlashSink))
(define-read-only (get-min-bond) MIN_BOND)
(define-read-only (is-active (who principal))
  (match (map-get? Providers who) p (get active p) false)
)

;; -------------------------------------------------------------------
;; Wiring (deployer / admin)
;; -------------------------------------------------------------------
(define-public (set-token (token principal))
  (begin
    (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (is-none (var-get Token)) ERR_ALREADY_WIRED)
    (asserts! (not (is-eq token (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (var-set Token (some token))
    (ok true)
  )
)

(define-public (set-admin (who principal))
  (begin
    (asserts! (is-eq contract-caller (var-get Admin)) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq who (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (var-set Admin who)
    (ok true)
  )
)

(define-public (set-slash-sink (who principal))
  (begin
    (asserts! (is-eq contract-caller (var-get Admin)) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq who (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (var-set SlashSink who)
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Provider lifecycle
;; -------------------------------------------------------------------
;; Register with an initial bond (pulls sBTC from the provider into this contract).
(define-public (register
    (ft <sip010-trait>)
    (model (string-ascii 64))
    (endpoint (string-ascii 256))
    (bond uint)
  )
  (begin
    (asserts! (is-eq (contract-of ft) (unwrap! (var-get Token) ERR_WRONG_TOKEN)) ERR_WRONG_TOKEN)
    (asserts! (is-none (map-get? Providers tx-sender)) ERR_ALREADY_REGISTERED)
    (asserts! (> (len model) u0) ERR_EMPTY)
    (asserts! (> (len endpoint) u0) ERR_EMPTY)
    (asserts! (>= bond MIN_BOND) ERR_BELOW_MIN_BOND)
    (try! (contract-call? ft transfer bond tx-sender (as-contract tx-sender) none))
    (map-set Providers tx-sender {
      model: model,
      endpoint: endpoint,
      bond: bond,
      active: true,
      jobs-ok: u0,
      jobs-fail: u0,
    })
    (print { event: "register", provider: tx-sender, model: model, bond: bond })
    (ok true)
  )
)

;; Top up an existing bond.
(define-public (add-bond
    (ft <sip010-trait>)
    (amount uint)
  )
  (let ((p (unwrap! (map-get? Providers tx-sender) ERR_NOT_FOUND)))
    (asserts! (is-eq (contract-of ft) (unwrap! (var-get Token) ERR_WRONG_TOKEN)) ERR_WRONG_TOKEN)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? ft transfer amount tx-sender (as-contract tx-sender) none))
    (map-set Providers tx-sender (merge p { bond: (+ (get bond p) amount), active: true }))
    (ok true)
  )
)

;; Update advertised model / endpoint.
(define-public (set-listing
    (model (string-ascii 64))
    (endpoint (string-ascii 256))
  )
  (let ((p (unwrap! (map-get? Providers tx-sender) ERR_NOT_FOUND)))
    (map-set Providers tx-sender (merge p { model: model, endpoint: endpoint }))
    (ok true)
  )
)

;; Leave the guild: return the full remaining bond and delete the entry.
(define-public (deregister (ft <sip010-trait>))
  (let (
      (p (unwrap! (map-get? Providers tx-sender) ERR_NOT_FOUND))
      (bond (get bond p))
      (who tx-sender)
    )
    (asserts! (is-eq (contract-of ft) (unwrap! (var-get Token) ERR_WRONG_TOKEN)) ERR_WRONG_TOKEN)
    (asserts! (> bond u0) ERR_ZERO_AMOUNT)
    (try! (as-contract (contract-call? ft transfer bond tx-sender who none)))
    (map-delete Providers who)
    (print { event: "deregister", provider: who, returned: bond })
    (ok bond)
  )
)

;; -------------------------------------------------------------------
;; Reputation + slashing (admin-gated v1; proof mechanism comes later)
;; -------------------------------------------------------------------
(define-public (record-success (provider principal))
  (let ((p (unwrap! (map-get? Providers provider) ERR_NOT_FOUND)))
    (asserts! (is-eq contract-caller (var-get Admin)) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq provider (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (map-set Providers provider (merge p { jobs-ok: (+ (get jobs-ok p) u1) }))
    (ok true)
  )
)

(define-public (record-fail (provider principal))
  (let ((p (unwrap! (map-get? Providers provider) ERR_NOT_FOUND)))
    (asserts! (is-eq contract-caller (var-get Admin)) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq provider (as-contract tx-sender))) ERR_INVALID_PRINCIPAL)
    (map-set Providers provider (merge p { jobs-fail: (+ (get jobs-fail p) u1) }))
    (ok true)
  )
)

;; Slash part of a bond to the slash sink. Deactivates the provider if the bond
;; is fully consumed.
(define-public (slash
    (ft <sip010-trait>)
    (provider principal)
    (amount uint)
  )
  (let (
      (p (unwrap! (map-get? Providers provider) ERR_NOT_FOUND))
      (sink (var-get SlashSink))
      (remaining (- (get bond p) amount))
    )
    (asserts! (is-eq contract-caller (var-get Admin)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (contract-of ft) (unwrap! (var-get Token) ERR_WRONG_TOKEN)) ERR_WRONG_TOKEN)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (<= amount (get bond p)) ERR_SLASH_EXCEEDS)
    (try! (as-contract (contract-call? ft transfer amount tx-sender sink none)))
    (map-set Providers provider (merge p { bond: remaining, active: (> remaining u0) }))
    (print { event: "slash", provider: provider, amount: amount, sink: sink })
    (ok remaining)
  )
)
