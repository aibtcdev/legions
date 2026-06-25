;; legion-registry
;; Discovery directory for Legions - both demand guilds (treasury + stake-weighted
;; governance) and provider guilds (inference operators who stake a bond and earn
;; by serving). Maps a numeric legion-id to its on-chain pieces + metadata.
;;
;; Holds NO funds. It is a pure coordination/discovery layer: agents use it to
;; find Legions, and the inference gateway uses it to know which treasury a
;; payment should skim into. Registration is permissionless; each entry is owned
;; by its registrant, who alone may edit it. A deployer-held admin may deactivate
;; abusive entries (a curation backstop, not custody).

(define-constant DEPLOYER tx-sender)

;; -------------------------------------------------------------------
;; Errors
;; -------------------------------------------------------------------
(define-constant ERR_BAD_INPUT (err u400)) ;; empty required field
(define-constant ERR_NOT_OWNER (err u401)) ;; caller is not the entry owner / admin
(define-constant ERR_NOT_FOUND (err u404)) ;; no such legion-id

;; -------------------------------------------------------------------
;; State
;; -------------------------------------------------------------------
(define-data-var Admin principal DEPLOYER)
(define-data-var LastId uint u0)

(define-map Legions
  uint
  {
    owner: principal,
    kind: (string-ascii 16),   ;; "demand" | "provider" | ...
    treasury: principal,       ;; where this Legion's fee skim lands
    gov: (optional principal), ;; governance contract, if any
    fees: (optional principal),;; legion-fees instance, if any
    model: (string-ascii 64),  ;; model / capability label (e.g. "qwen2.5-7b")
    uri: (string-ascii 256),   ;; off-chain metadata JSON
    active: bool,
  }
)

;; -------------------------------------------------------------------
;; Read-only views
;; -------------------------------------------------------------------
(define-read-only (get-count) (var-get LastId))
(define-read-only (get-admin) (var-get Admin))
(define-read-only (get-legion (id uint)) (map-get? Legions id))
(define-read-only (get-owner (id uint))
  (match (map-get? Legions id) e (some (get owner e)) none)
)

;; -------------------------------------------------------------------
;; Public: register a Legion (permissionless; owner = tx-sender)
;; -------------------------------------------------------------------
(define-public (register
    (kind (string-ascii 16))
    (treasury principal)
    (gov (optional principal))
    (fees (optional principal))
    (model (string-ascii 64))
    (uri (string-ascii 256))
  )
  (let ((id (+ (var-get LastId) u1)))
    (asserts! (> (len kind) u0) ERR_BAD_INPUT)
    (asserts! (> (len model) u0) ERR_BAD_INPUT)
    (map-set Legions id {
      owner: tx-sender,
      kind: kind,
      treasury: treasury,
      gov: gov,
      fees: fees,
      model: model,
      uri: uri,
      active: true,
    })
    (var-set LastId id)
    (print {
      event: "register",
      id: id,
      owner: tx-sender,
      kind: kind,
      treasury: treasury,
      model: model,
    })
    (ok id)
  )
)

;; -------------------------------------------------------------------
;; Public: owner-scoped edits
;; -------------------------------------------------------------------
(define-public (set-uri
    (id uint)
    (uri (string-ascii 256))
  )
  (let ((e (unwrap! (map-get? Legions id) ERR_NOT_FOUND)))
    (asserts! (is-eq (get owner e) tx-sender) ERR_NOT_OWNER)
    (map-set Legions id (merge e { uri: uri }))
    (ok true)
  )
)

(define-public (transfer-entry
    (id uint)
    (new-owner principal)
  )
  (let ((e (unwrap! (map-get? Legions id) ERR_NOT_FOUND)))
    (asserts! (is-eq (get owner e) tx-sender) ERR_NOT_OWNER)
    (map-set Legions id (merge e { owner: new-owner }))
    (ok true)
  )
)

;; owner OR admin may flip active (admin = curation backstop).
(define-public (set-active
    (id uint)
    (active bool)
  )
  (let ((e (unwrap! (map-get? Legions id) ERR_NOT_FOUND)))
    (asserts!
      (or (is-eq (get owner e) tx-sender) (is-eq (var-get Admin) tx-sender))
      ERR_NOT_OWNER
    )
    (map-set Legions id (merge e { active: active }))
    (print { event: "set-active", id: id, active: active, by: tx-sender })
    (ok true)
  )
)

;; -------------------------------------------------------------------
;; Public: admin handoff
;; -------------------------------------------------------------------
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-eq (var-get Admin) tx-sender) ERR_NOT_OWNER)
    (var-set Admin new-admin)
    (ok true)
  )
)
