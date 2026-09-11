;; El Salvador's reserve P2SH scripts from bitcoin.gob.sv. Fixed at deploy.
(define-constant SUBJECT_SCRIPTS (list
  0xa9140b55e104bb614b309d85efac36703194ff2d830287
  0xa91499958175664828a0b123c060db855e7458d5410987
  0xa914473130e6cc8ddd0067695a7e56e18799edfeb19987
  0xa914c8c81eed882ff355522e33967b104ac4d30b7ff587
  0xa91485626ed16d8d4c7c2e1b4c1ce84a5d669b35cd3687
  0xa914160ebfc91b9ecd952ed2337ca54e8178b013ee3787
  0xa9144c05fd8bd452d02a24a9e0e90c5f274791c1b4ec87
  0xa9140764624356ff5fbee91507e574e60976237f069387
  0xa914da8fc56a4225ee57c4d3c4c105c07e1e8e152bc887
  0xa9144245cd5405a45447c5ef1061036a285a05fe938787
  0xa91424e3a015561a043e7b82ad60f1b65e779a3c4d6287
  0xa91456a915de90045ea6696d7aa26eb97033f6526fa487
  0xa914496fcda4c57ca03cdff77df9c24b9cfa6a44b15587
  0xa914c87bd49e4906ec21946e80a19bbd65d8862c007387
  0xa914fc5c54cbae62c9b24192f8ed5f9d4f50e178929a87
  0xa9149195edbf7cf4cad9cbcc6cdb974ccd6fba9a453a87
  0xa914f9f34ba4191c3d818b6d63cb234dd61419da3a0387
  0xa9145fbbb75b3b004653bfe38942a0b4624fe47dd6ec87
  0xa914c39c9802bb3fda0b59e57656c810972c9ecc509387
  0xa91425f5a35ef602a7cefbd8b16ab3a46b63d771aa8387
))

;; El Salvador's listed BTC addresses.
(define-constant RESERVE_ADDRESSES (list
  "32ixEdVJWo3kmvJGMTZq5jAQVZZeuwnqzo"
  "3Fh6QjPzfu2LWYxVYqRZ45QPTja1PrFmNC"
  "38BSq1sUaGFxDVdqhCraRMg1Kgh4wpTbfG"
  "3KzeoYiSFaRxPktmdoehuXRNmE1hZQM2Cp"
  "3DrHiHzfAKnne3zn8pqJdxJQhRFtW1jnMG"
  "33heTZ5DNKVeCDrknBvZnk95f7rzVYC6X4"
  "38czTLv6ufGFjqLgiRdaQpDduErqszgfDX"
  "32N6ugHCwxQ7esqSY6dwmanDx2onLHCdyp"
  "3McfTktodPWHwigfg7e9pQti4wXYKP47LW"
  "37jS98twXbuDHMVDvZCEaAyqBngD2XmKTr"
  "3544w8kqR1SFKwysmidDz4LHrLJv58rP4o"
  "39bEbJWGAYjpRvoJfDUEY4cQaFtJgDgdvH"
  "38PKBmzVrmuiGnSMzSsLGXUXP61LCf1t9T"
  "3Ky5QojgyfdfaQ7hoPQfio4BCLtavsPqsB"
  "3QhNpAuMJjN6WJNWmHuZQHyBcTxrrWpS5g"
  "3ExoWb4ZwU5F8rRHGfQdeqLtK2AgP4jjwt"
  "3QUddmvT36K4edS9AsKGHydygM8MavXSbc"
  "3ARCzX8kjALXjfnAhEbyfqXLiRUpNJJfa3"
  "3KXKHH5hhiYkx9nfJdUxZL3ivrVSnQNfKz"
  "359jBt2XuTdgk6YEz1WwhwMwrzTd7Qb3Gw"
))

(define-read-only (get-reserve-addresses) RESERVE_ADDRESSES)

(define-read-only (get-bond-indices) BOND_INDICES)


(define-constant FIRST_INDEX  u2)
(define-constant LAST_INDEX   u7)
(define-constant BOND_INDICES (list u2 u3 u4 u5 u6 u7))
(define-constant CLOSE_HEIGHT u16274)

(define-constant MIN_WINDOW_BLOCKS u144)

(define-constant STATUS_OPEN   u0)
(define-constant STATUS_BONDED u1)
(define-constant STATUS_IDLE   u2)

(define-constant SIDE_IDLE   u0)
(define-constant SIDE_BONDED u1)

(define-constant ERR_NOT_OPEN           (err u102))
(define-constant ERR_NOT_YET_OPEN       (err u105))
(define-constant ERR_ALREADY_OPEN       (err u100))
(define-constant ERR_WINDOW_CLOSED      (err u103))
(define-constant ERR_WINDOW_OPEN        (err u104))
(define-constant ERR_ZERO               (err u106))
(define-constant ERR_NO_POSITION        (err u107))
(define-constant ERR_UNRESOLVED         (err u108))
(define-constant ERR_BAD_SIDE           (err u109))
(define-constant ERR_SELF_TRANSFER      (err u110))
(define-constant ERR_BAD_SIG            (err u113))
(define-constant ERR_ORDER_EXPIRED      (err u114))
(define-constant ERR_ORDER_FILLED       (err u115))
(define-constant ERR_ORDER_CANCELLED    (err u116))
(define-constant ERR_FILL_TOO_SMALL     (err u117))
(define-constant ERR_FILL_TOO_LARGE     (err u118))
(define-constant ERR_WINDOW_TOO_SHORT   (err u119))
(define-constant ERR_FLOOR_NOT_FORWARD  (err u120))
(define-constant ERR_WINDOW_TOO_LONG    (err u121))
(define-constant ERR_BID_EXISTS         (err u129))
(define-constant ERR_NO_BID             (err u130))
(define-constant ERR_BIDS_TOO_LOW       (err u131))
(define-constant ERR_SAME_BUYER         (err u132))
(define-constant ERR_BID_ABOVE_PAR      (err u133))
(define-constant ERR_BAD_HEADER         (err u200))
(define-constant ERR_BAD_MERKLE         (err u201))
(define-constant ERR_NOT_SPENT          (err u205))
(define-constant ERR_NO_MEMBERSHIP      (err u206))
(define-constant ERR_NOT_L1             (err u207))
(define-constant ERR_LOCKUP_TOO_BIG     (err u209))
(define-constant ERR_BOND_TOO_EARLY     (err u210))
(define-constant ERR_NO_BOND            (err u211))
(define-constant ERR_UNLOCK_TOO_EARLY   (err u212))
(define-constant ERR_BOND_UNREACHABLE   (err u213))
(define-constant ERR_NOT_SUBJECT        (err u214))
(define-constant ERR_WRONG_PERIOD       (err u215))
(define-constant ERR_BAD_TERMS          (err u216))
(define-constant ERR_PARSE              (err u300))
(define-constant ERR_TOO_MANY           (err u302))
(define-constant ERR_NOT_A_LOCKUP       (err u313))

(define-constant MIN_FILL_BPS u100)

(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant POX5 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.pox5-sim)

;; The whole market is one row, so it is data-vars rather than a map.
(define-data-var status      uint STATUS_OPEN)
(define-data-var vault       uint u0)
(define-data-var idle-circ   uint u0)
(define-data-var bonded-circ uint u0)

;; Nothing trades until `open` has proven the baked parameters answerable.
(define-data-var opened bool false)

;; A lockup mined at or before this is a lookup, not a prediction.
(define-data-var created-at uint u0)

(define-map positions principal { idle: uint, bonded: uint })

(define-map filled-orders { hash: (buff 32) } { filled: uint })

(define-map order-floor { seller: principal } { min-nonce: uint })

;; A bid cannot be a signature the way an ask can, so the buyer escrows up front.
(define-map bids { buyer: principal, side: uint } { amount: uint, escrow: uint })

;; The only hand-rolled Bitcoin code: there is no get-bitcoin-tx-input?. Add no more.
(define-constant MAX_INPUTS u450)
(define-constant IDX (list
  u0   u1   u2   u3   u4   u5   u6   u7   u8   u9   u10  u11  u12
  u13  u14  u15  u16  u17  u18  u19  u20  u21  u22  u23  u24  u25
  u26  u27  u28  u29  u30  u31  u32  u33  u34  u35  u36  u37  u38
  u39  u40  u41  u42  u43  u44  u45  u46  u47  u48  u49  u50  u51
  u52  u53  u54  u55  u56  u57  u58  u59  u60  u61  u62  u63  u64
  u65  u66  u67  u68  u69  u70  u71  u72  u73  u74  u75  u76  u77
  u78  u79  u80  u81  u82  u83  u84  u85  u86  u87  u88  u89  u90
  u91  u92  u93  u94  u95  u96  u97  u98  u99  u100 u101 u102 u103
  u104 u105 u106 u107 u108 u109 u110 u111 u112 u113 u114 u115 u116
  u117 u118 u119 u120 u121 u122 u123 u124 u125 u126 u127 u128 u129
  u130 u131 u132 u133 u134 u135 u136 u137 u138 u139 u140 u141 u142
  u143 u144 u145 u146 u147 u148 u149 u150 u151 u152 u153 u154 u155
  u156 u157 u158 u159 u160 u161 u162 u163 u164 u165 u166 u167 u168
  u169 u170 u171 u172 u173 u174 u175 u176 u177 u178 u179 u180 u181
  u182 u183 u184 u185 u186 u187 u188 u189 u190 u191 u192 u193 u194
  u195 u196 u197 u198 u199 u200 u201 u202 u203 u204 u205 u206 u207
  u208 u209 u210 u211 u212 u213 u214 u215 u216 u217 u218 u219 u220
  u221 u222 u223 u224 u225 u226 u227 u228 u229 u230 u231 u232 u233
  u234 u235 u236 u237 u238 u239 u240 u241 u242 u243 u244 u245 u246
  u247 u248 u249 u250 u251 u252 u253 u254 u255 u256 u257 u258 u259
  u260 u261 u262 u263 u264 u265 u266 u267 u268 u269 u270 u271 u272
  u273 u274 u275 u276 u277 u278 u279 u280 u281 u282 u283 u284 u285
  u286 u287 u288 u289 u290 u291 u292 u293 u294 u295 u296 u297 u298
  u299 u300 u301 u302 u303 u304 u305 u306 u307 u308 u309 u310 u311
  u312 u313 u314 u315 u316 u317 u318 u319 u320 u321 u322 u323 u324
  u325 u326 u327 u328 u329 u330 u331 u332 u333 u334 u335 u336 u337
  u338 u339 u340 u341 u342 u343 u344 u345 u346 u347 u348 u349 u350
  u351 u352 u353 u354 u355 u356 u357 u358 u359 u360 u361 u362 u363
  u364 u365 u366 u367 u368 u369 u370 u371 u372 u373 u374 u375 u376
  u377 u378 u379 u380 u381 u382 u383 u384 u385 u386 u387 u388 u389
  u390 u391 u392 u393 u394 u395 u396 u397 u398 u399 u400 u401 u402
  u403 u404 u405 u406 u407 u408 u409 u410 u411 u412 u413 u414 u415
  u416 u417 u418 u419 u420 u421 u422 u423 u424 u425 u426 u427 u428
  u429 u430 u431 u432 u433 u434 u435 u436 u437 u438 u439 u440 u441
  u442 u443 u444 u445 u446 u447 u448 u449))

(define-read-only (read-u8 (tx (buff 32768)) (pos uint))
  (match (element-at? tx pos)
    b (some (buff-to-uint-be b))
    none))

(define-read-only (read-u32-le (tx (buff 32768)) (pos uint))
  (match (slice? tx pos (+ pos u4))
    b (match (as-max-len? b u16) bb (some (buff-to-uint-le bb)) none)
    none))

;; Bitcoin compact-size integer: the value, and how many bytes it used.
(define-read-only (read-varint (tx (buff 32768)) (pos uint))
  (match (read-u8 tx pos)
    first
      (if (< first u253)
          (some { val: first, size: u1 })
          (if (is-eq first u253)
              (match (slice? tx (+ pos u1) (+ pos u3))
                b (match (as-max-len? b u16) bb (some { val: (buff-to-uint-le bb), size: u3 }) none)
                none)
              (if (is-eq first u254)
                  (match (slice? tx (+ pos u1) (+ pos u5))
                    b (match (as-max-len? b u16) bb (some { val: (buff-to-uint-le bb), size: u5 }) none)
                    none)
                  (match (slice? tx (+ pos u1) (+ pos u9))
                    b (match (as-max-len? b u16) bb (some { val: (buff-to-uint-le bb), size: u9 }) none)
                    none))))
    none))

;; Walk one input: txid(32) vout(4) varint scriptlen, script, sequence(4).
(define-private (skip-input
                  (i uint)
                  (acc { tx: (buff 32768), pos: uint, n: uint, ok: bool,
                         hits: uint, want-txid: (buff 32), want-vout: uint }))
  (if (or (not (get ok acc)) (>= i (get n acc)))
      acc
      (let ((tx (get tx acc))
            (p  (get pos acc)))
        (match (slice? tx p (+ p u32))
          prev-raw
            (match (read-u32-le tx (+ p u32))
              vout
                (match (read-varint tx (+ p u36))
                  vi
                    (let ((next (+ p u36 (get size vi) (get val vi) u4))
                          (matched (and (is-eq (unwrap-panic (as-max-len? prev-raw u32))
                                               (get want-txid acc))
                                        (is-eq vout (get want-vout acc)))))
                      (merge acc { pos: next,
                                   hits: (if matched (+ (get hits acc) u1) (get hits acc)) }))
                  (merge acc { ok: false }))
              (merge acc { ok: false }))
          (merge acc { ok: false })))))

(define-read-only (tx-spends-outpoint
                    (tx (buff 32768))
                    (prev-txid (buff 32))
                    (prev-vout uint))
  (match (read-varint tx u4)
    vin-count
      (if (> (get val vin-count) MAX_INPUTS)
          ERR_TOO_MANY
          (let ((r (fold skip-input IDX
                     { tx: tx, pos: (+ u4 (get size vin-count)),
                       n: (get val vin-count), ok: true, hits: u0,
                       want-txid: prev-txid, want-vout: prev-vout })))
            (if (get ok r) (ok (> (get hits r) u0)) ERR_PARSE)))
    ERR_PARSE))

;; Is this txid in a block Bitcoin actually mined?
(define-private (tx-was-mined
                    (burn-height uint)
                    (header (buff 80))
                    (reversed-txid (buff 32))
                    (tx-index uint)
                    (tx-count uint)
                    (hashes (list 24 (buff 32))))
  (let ((block (unwrap! (contract-call? POX5 parse-block-header header) ERR_BAD_HEADER)))
    (asserts! (contract-call? POX5 verify-block-header header burn-height) ERR_BAD_HEADER)
    (asserts! (or
                ;; sole transaction in the block
                (is-eq (get merkle-root block)
                       (contract-call? POX5 reverse-buff32 reversed-txid))
                (verify-merkle-proof reversed-txid
                  (contract-call? POX5 reverse-buff32 (get merkle-root block))
                  tx-index tx-count hashes))
              ERR_BAD_MERKLE)
    (ok true)))

(define-private (script-hit (candidate (buff 34))
                            (acc { want: (buff 1024), hit: bool }))
  (if (get hit acc)
      acc
      (merge acc { hit: (is-eq candidate (get want acc)) })))

;; One address is as good as another: the question is whether the reserve bonded.
(define-read-only (is-subject-script (script (buff 1024)))
  (get hit (fold script-hit SUBJECT_SCRIPTS { want: script, hit: false })))

(define-read-only (get-subject-scripts) SUBJECT_SCRIPTS)

;; The deadline is not in the sentence; a page reads it from close-height.
(define-read-only (get-title)
  "Will El Salvador stake any of their Bitcoin in Stacks' PoX5 Bitcoin Protocol Bond?")

(define-read-only (get-market)
  { title:        (get-title),
    opened:       (var-get opened),
    bond-indices: BOND_INDICES,
    close-height: CLOSE_HEIGHT,
    created-at:   (var-get created-at),
    status:       (var-get status),
    vault:        (var-get vault),
    idle-circ:    (var-get idle-circ),
    bonded-circ:  (var-get bonded-circ) })

(define-read-only (get-position (who principal))
  (default-to { idle: u0, bonded: u0 } (map-get? positions who)))

(define-read-only (get-status) (var-get status))

;; Runs once, on `open` or the first trade, not at publish.
(define-private (ensure-open)
  (if (var-get opened)
    (ok false)
    (begin
      (asserts! (>= CLOSE_HEIGHT (+ burn-block-height MIN_WINDOW_BLOCKS))
                ERR_WINDOW_TOO_SHORT)
      ;; six deep and no deeper. Period LAST+1 enrols past the deadline.
      (asserts! (is-eq LAST_INDEX (+ FIRST_INDEX u5)) ERR_BAD_TERMS)
      ;; one block below the anchor's L1 unlock, so the rollover window,
      ;; where a bond may move outside this set, stays out of the market
      (asserts! (is-eq CLOSE_HEIGHT
                       (- (contract-call? POX5 get-bond-l1-unlock-height FIRST_INDEX) u1))
                ERR_WINDOW_TOO_LONG)
      ;; every one of the six stops enrolling inside the window
      (asserts! (< (contract-call? POX5 bond-period-to-burn-height LAST_INDEX) CLOSE_HEIGHT)
                ERR_BAD_TERMS)
      ;; a Yes stays reachable while any period in the set still enrols. Once
      ;; the last one starts, the answer is fixed and opening would sell a Yes
      ;; that cannot happen. Whether pox-5 has configured them yet is not the
      ;; question: that is the uncertainty the market prices.
      (asserts! (< burn-block-height (contract-call? POX5 bond-period-to-burn-height LAST_INDEX))
                ERR_BOND_UNREACHABLE)
      (var-set opened true)
      (var-set created-at burn-block-height)
      (print { event: "open", title: (get-title), bond-indices: BOND_INDICES,
               close-height: CLOSE_HEIGHT, created-at: burn-block-height,
               subject-scripts: SUBJECT_SCRIPTS })
      (ok true))))

;; Pins created-at at deploy rather than at the first trade.
(define-public (open)
  (begin
    (asserts! (try! (ensure-open)) ERR_ALREADY_OPEN)
    (ok true)))

(define-private (assert-tradeable)
  (begin
    (try! (ensure-open))
    (asserts! (is-eq (var-get status) STATUS_OPEN) ERR_NOT_OPEN)
    ;; trading stops at the deadline, not merely at resolution
    (asserts! (<= burn-block-height CLOSE_HEIGHT) ERR_WINDOW_CLOSED)
    (ok true)))

(define-public (mint-complete-set (sats uint))
  (let ((pos (get-position contract-caller)))
    (asserts! (> sats u0) ERR_ZERO)
    (try! (assert-tradeable))
    ;; write state before the transfer
    (map-set positions contract-caller
             { idle: (+ (get idle pos) sats), bonded: (+ (get bonded pos) sats) })
    (var-set vault       (+ (var-get vault) sats))
    (var-set idle-circ   (+ (var-get idle-circ) sats))
    (var-set bonded-circ (+ (var-get bonded-circ) sats))
    (try! (contract-call? SBTC transfer sats contract-caller current-contract none))
    (print { event: "mint", sats: sats, who: contract-caller })
    (ok sats)))

(define-public (merge-complete-set (sats uint))
  (let ((pos (get-position contract-caller))
        (who contract-caller))
    (asserts! (> sats u0) ERR_ZERO)
    (asserts! (var-get opened) ERR_NOT_YET_OPEN)
    (asserts! (is-eq (var-get status) STATUS_OPEN) ERR_NOT_OPEN)
    (asserts! (and (>= (get idle pos) sats) (>= (get bonded pos) sats)) ERR_NO_POSITION)
    (map-set positions who
             { idle: (- (get idle pos) sats), bonded: (- (get bonded pos) sats) })
    (var-set vault       (- (var-get vault) sats))
    (var-set idle-circ   (- (var-get idle-circ) sats))
    (var-set bonded-circ (- (var-get bonded-circ) sats))
    (try! (as-contract?
            ((with-ft SBTC "sbtc-token" sats))
            (try! (contract-call? SBTC transfer sats current-contract who none))))
    (print { event: "merge", sats: sats, who: who })
    (ok sats)))

(define-public (transfer-shares (side uint) (amount uint) (to principal))
  (let ((from contract-caller)
        (src  (get-position contract-caller))
        (dst  (get-position to)))
    (asserts! (> amount u0) ERR_ZERO)
    (asserts! (not (is-eq to from)) ERR_SELF_TRANSFER)
    (asserts! (or (is-eq side SIDE_IDLE) (is-eq side SIDE_BONDED)) ERR_BAD_SIDE)
    (try! (assert-tradeable))
    (if (is-eq side SIDE_IDLE)
        (begin
          (asserts! (>= (get idle src) amount) ERR_NO_POSITION)
          (map-set positions from (merge src { idle: (- (get idle src) amount) }))
          (map-set positions to   (merge dst { idle: (+ (get idle dst) amount) })))
        (begin
          (asserts! (>= (get bonded src) amount) ERR_NO_POSITION)
          (map-set positions from (merge src { bonded: (- (get bonded src) amount) }))
          (map-set positions to   (merge dst { bonded: (+ (get bonded dst) amount) }))))
    (print { event: "transfer", side: side, amount: amount, from: from, to: to })
    (ok amount)))

;; SIP-018 so browser wallets can sign. The hash covers the seller and this contract.
(define-constant SIP018_PREFIX 0x534950303138)
(define-constant SIP018_DOMAIN (sha256 (unwrap-panic (to-consensus-buff?
  { name: "At Stake", version: "1", chain-id: u1 }))))

(define-read-only (order-hash
                    (seller principal) (side uint) (amount uint)
                    (price-sats uint) (nonce uint) (expiry uint))
  (sha256 (concat SIP018_PREFIX (concat SIP018_DOMAIN
    (sha256 (unwrap-panic (to-consensus-buff?
      { contract: current-contract, seller: seller, side: side,
        amount: amount, price: price-sats, nonce: nonce, expiry: expiry })))))))

(define-read-only (get-order-floor (seller principal))
  (default-to u0 (get min-nonce (map-get? order-floor { seller: seller }))))

(define-public (cancel-orders-below (min-nonce uint))
  (begin
    (asserts! (> min-nonce (get-order-floor contract-caller)) ERR_FLOOR_NOT_FORWARD)
    (map-set order-floor { seller: contract-caller } { min-nonce: min-nonce })
    (print { event: "cancel", seller: contract-caller, min-nonce: min-nonce })
    (ok min-nonce)))

(define-read-only (order-filled (hash (buff 32)))
  (default-to u0 (get filled (map-get? filled-orders { hash: hash }))))

;; Rounded up, so a seller cannot be drained a share at a time.
(define-read-only (fill-price (price-sats uint) (amount uint) (fill-amount uint))
  (if (is-eq amount u0)
      u0
      (/ (+ (* price-sats fill-amount) (- amount u1)) amount)))

;; Rounded down, against what is LEFT of the bid, or every partial is dearer.
(define-read-only (bid-cost (escrow uint) (amount uint) (fill-amount uint))
  (if (is-eq amount u0) u0 (/ (* escrow fill-amount) amount)))

(define-read-only (min-fill-for (amount uint))
  (let ((floor-amt (/ (* amount MIN_FILL_BPS) u10000)))
    (if (> floor-amt u0) floor-amt u1)))

(define-public (fill-order
                 (side uint) (amount uint) (price-sats uint)
                 (nonce uint) (expiry uint)
                 (seller principal) (signature (buff 65))
                 (fill-amount uint))
  (let ((hash      (order-hash seller side amount price-sats nonce expiry))
        (buyer     contract-caller)
        (src       (get-position seller))
        (dst       (get-position contract-caller))
        (already   (order-filled hash))
        (remaining (- amount (order-filled hash)))
        (cost      (fill-price price-sats amount fill-amount)))
    (asserts! (> amount u0) ERR_ZERO)
    (asserts! (> fill-amount u0) ERR_ZERO)
    (asserts! (< already amount) ERR_ORDER_FILLED)
    (asserts! (<= fill-amount remaining) ERR_FILL_TOO_LARGE)
    ;; at least the minimum slice, or whatever is left
    (asserts! (or (>= fill-amount (min-fill-for amount))
                  (is-eq fill-amount remaining))
              ERR_FILL_TOO_SMALL)
    (asserts! (not (is-eq seller buyer)) ERR_SELF_TRANSFER)
    (asserts! (or (is-eq side SIDE_IDLE) (is-eq side SIDE_BONDED)) ERR_BAD_SIDE)
    (try! (assert-tradeable))
    (asserts! (<= burn-block-height expiry) ERR_ORDER_EXPIRED)
    (asserts! (>= nonce (get-order-floor seller)) ERR_ORDER_CANCELLED)
    ;; the seller must have signed it
    (asserts! (is-eq (unwrap! (principal-of? (unwrap! (secp256k1-recover? hash signature)
                                                      ERR_BAD_SIG))
                              ERR_BAD_SIG)
                     seller)
              ERR_BAD_SIG)
    (map-set filled-orders { hash: hash } { filled: (+ already fill-amount) })
    (if (is-eq side SIDE_IDLE)
        (begin
          (asserts! (>= (get idle src) fill-amount) ERR_NO_POSITION)
          (map-set positions seller (merge src { idle: (- (get idle src) fill-amount) }))
          (map-set positions buyer  (merge dst { idle: (+ (get idle dst) fill-amount) })))
        (begin
          (asserts! (>= (get bonded src) fill-amount) ERR_NO_POSITION)
          (map-set positions seller (merge src { bonded: (- (get bonded src) fill-amount) }))
          (map-set positions buyer  (merge dst { bonded: (+ (get bonded dst) fill-amount) }))))
    (try! (contract-call? SBTC transfer cost buyer seller none))
    (print { event: "fill", side: side, order-amount: amount,
             fill-amount: fill-amount, cost: cost, filled-total: (+ already fill-amount),
             price-sats: price-sats, seller: seller, buyer: buyer, hash: hash })
    (ok fill-amount)))

;; `total-sats` buys the WHOLE `amount`: 100 shares at 30c is u100 and u30.
(define-public (place-bid (side uint) (amount uint) (total-sats uint))
  (let ((who contract-caller))
    (asserts! (> amount u0) ERR_ZERO)
    (asserts! (> total-sats u0) ERR_ZERO)
    ;; a share pays at most one sat, so bidding above par is always a mistake
    (asserts! (<= total-sats amount) ERR_BID_ABOVE_PAR)
    (asserts! (or (is-eq side SIDE_IDLE) (is-eq side SIDE_BONDED)) ERR_BAD_SIDE)
    (try! (assert-tradeable))
    (asserts! (is-none (map-get? bids { buyer: who, side: side })) ERR_BID_EXISTS)
    (map-set bids { buyer: who, side: side } { amount: amount, escrow: total-sats })
    (try! (contract-call? SBTC transfer total-sats who current-contract none))
    (print { event: "bid", side: side, amount: amount,
             total-sats: total-sats, buyer: who })
    (ok amount)))

(define-read-only (get-bid (buyer principal) (side uint))
  (map-get? bids { buyer: buyer, side: side }))

(define-public (cancel-bid (side uint))
  (let ((who contract-caller)
        (b (unwrap! (map-get? bids { buyer: contract-caller, side: side }) ERR_NO_BID)))
    (map-delete bids { buyer: who, side: side })
    (print { event: "bid-cancel", side: side, buyer: who, refund: (get escrow b) })
    (if (> (get escrow b) u0)
        (try! (as-contract?
                ((with-ft SBTC "sbtc-token" (get escrow b)))
                (try! (contract-call? SBTC transfer (get escrow b) current-contract who none))))
        true)
    (ok (get escrow b))))

;; Two opposing bids mint the sets between them; the matcher keeps the spread.
(define-public (match-bids (yes-buyer principal) (no-buyer principal)
                           (fill-amount uint))
  (let ((yb   (unwrap! (map-get? bids { buyer: yes-buyer, side: SIDE_BONDED }) ERR_NO_BID))
        (nb   (unwrap! (map-get? bids { buyer: no-buyer,  side: SIDE_IDLE })  ERR_NO_BID))
        (ypos (get-position yes-buyer))
        (npos (get-position no-buyer)))
    (asserts! (> fill-amount u0) ERR_ZERO)
    (asserts! (not (is-eq yes-buyer no-buyer)) ERR_SAME_BUYER)
    (try! (assert-tradeable))
    (asserts! (<= fill-amount (get amount yb)) ERR_FILL_TOO_LARGE)
    (asserts! (<= fill-amount (get amount nb)) ERR_FILL_TOO_LARGE)
    (let ((ycost (bid-cost (get escrow yb) (get amount yb) fill-amount))
          (ncost (bid-cost (get escrow nb) (get amount nb) fill-amount)))
      ;; a complete set costs one sat, so the two sides must cover par together
      (asserts! (>= (+ ycost ncost) fill-amount) ERR_BIDS_TOO_LOW)
      (map-set bids { buyer: yes-buyer, side: SIDE_BONDED }
               { amount: (- (get amount yb) fill-amount),
                 escrow: (- (get escrow yb) ycost) })
      (map-set bids { buyer: no-buyer, side: SIDE_IDLE }
               { amount: (- (get amount nb) fill-amount),
                 escrow: (- (get escrow nb) ncost) })
      (map-set positions yes-buyer (merge ypos { bonded: (+ (get bonded ypos) fill-amount) }))
      (map-set positions no-buyer  (merge npos { idle:   (+ (get idle npos) fill-amount) }))
      (var-set vault       (+ (var-get vault) fill-amount))
      (var-set idle-circ   (+ (var-get idle-circ) fill-amount))
      (var-set bonded-circ (+ (var-get bonded-circ) fill-amount))
      (print { event: "match", fill-amount: fill-amount,
               yes-buyer: yes-buyer, no-buyer: no-buyer,
               yes-cost: ycost, no-cost: ncost,
               keeper: contract-caller, spread: (- (+ ycost ncost) fill-amount) })
      ;; the spread above par pays whoever bothered to match them
      (if (> (+ ycost ncost) fill-amount)
          (let ((spread (- (+ ycost ncost) fill-amount))
                (keeper contract-caller))
            (try! (as-contract?
                    ((with-ft SBTC "sbtc-token" spread))
                    (try! (contract-call? SBTC transfer spread current-contract keeper none)))))
          true)
      (ok fill-amount))))

;; Both resolvers are permissionless; the caller brings the proofs.
;; Settle YES. Six checks, every one with a rejection test. Keep it that way.
(define-public (resolve-bonded
                 (staker principal)
                 (unlock-burn-height uint)
                 (staker-unlock-bytes (buff 683))
                 (lockup-tx (buff 32768))
                 (lockup-vout uint)
                 (lockup-burn-height uint)
                 (lockup-header (buff 80))
                 (lockup-tx-index uint)
                 (lockup-tx-count uint)
                 (lockup-path (list 24 (buff 32)))
                 (funding-tx (buff 32768))
                 (funding-vout uint))
  (let ((lockup  (unwrap! (get-bitcoin-tx-output? lockup-tx lockup-vout) ERR_PARSE))
        (funding (unwrap! (get-bitcoin-tx-output? funding-tx funding-vout) ERR_PARSE)))
    ;; 1. open, and inside the window
    (asserts! (var-get opened) ERR_NOT_YET_OPEN)
    (asserts! (is-eq (var-get status) STATUS_OPEN) ERR_NOT_OPEN)
    (asserts! (<= burn-block-height CLOSE_HEIGHT) ERR_WINDOW_CLOSED)
    ;; 2. the lockup must postdate the market, or it is a lookup
    (asserts! (> lockup-burn-height (var-get created-at)) ERR_BOND_TOO_EARLY)
    ;; 3. the lockup is on Bitcoin
    (try! (tx-was-mined lockup-burn-height lockup-header (get txid lockup)
                        lockup-tx-index lockup-tx-count lockup-path))
    ;; 4. it spends a coin from a reserve address, one input is enough
    (asserts! (is-subject-script (get script funding)) ERR_NOT_SUBJECT)
    (asserts! (try! (tx-spends-outpoint lockup-tx (get txid funding) funding-vout))
              ERR_NOT_SPENT)
    ;; 5 and 6. The index comes off pox-5's membership, never from an
    ;; argument, so the caller cannot name a period at all.
    (let ((mem   (unwrap! (contract-call? POX5 get-bond-membership staker)
                          ERR_NO_MEMBERSHIP))
          (bidx  (get bond-index mem))
          (bond  (unwrap! (contract-call? POX5 get-protocol-bond bidx) ERR_NO_BOND))
          (floor (contract-call? POX5 get-bond-l1-unlock-height bidx)))
      (asserts! (is-some (index-of? BOND_INDICES bidx)) ERR_WRONG_PERIOD)
      ;; 5. pox-5's own lockup script, built by pox-5 not by the caller
      (asserts! (>= unlock-burn-height floor) ERR_UNLOCK_TOO_EARLY)
      (asserts! (is-eq (get script lockup)
                       (try! (contract-call? POX5 construct-lockup-output-script
                                staker unlock-burn-height staker-unlock-bytes
                                (get early-unlock-bytes bond))))
                ERR_NOT_A_LOCKUP)
      ;; 6. a live L1 membership, no smaller than the lockup
      (asserts! (get is-l1-lock mem) ERR_NOT_L1)
      ;; bounds a borrowed bond to its own size
      (asserts! (<= (get amount lockup) (get amount-sats mem)) ERR_LOCKUP_TOO_BIG)
      (var-set status STATUS_BONDED)
      (print { event: "resolve", outcome: "bonded", staker: staker,
               bond-index: bidx, sats: (get amount-sats mem),
               funding-txid: (get txid funding), funding-vout: funding-vout,
               lockup-burn-height: lockup-burn-height })
      (ok STATUS_BONDED))))

(define-public (resolve-idle)
  (begin
    (asserts! (var-get opened) ERR_NOT_YET_OPEN)
    (asserts! (is-eq (var-get status) STATUS_OPEN) ERR_NOT_OPEN)
    (asserts! (> burn-block-height CLOSE_HEIGHT) ERR_WINDOW_OPEN)
    (var-set status STATUS_IDLE)
    (print { event: "resolve", outcome: "idle" })
    (ok STATUS_IDLE)))

(define-public (redeem)
  (let ((pos (get-position contract-caller))
        (who contract-caller)
        (st  (var-get status)))
    (asserts! (not (is-eq st STATUS_OPEN)) ERR_UNRESOLVED)
    (let ((payout (if (is-eq st STATUS_BONDED) (get bonded pos) (get idle pos))))
      (asserts! (> payout u0) ERR_NO_POSITION)
      ;; both sides burn; the loser's shares pay nothing
      (map-set positions who { idle: u0, bonded: u0 })
      (var-set vault       (- (var-get vault) payout))
      (var-set idle-circ   (- (var-get idle-circ) (get idle pos)))
      (var-set bonded-circ (- (var-get bonded-circ) (get bonded pos)))
      (try! (as-contract?
              ((with-ft SBTC "sbtc-token" payout))
              (try! (contract-call? SBTC transfer payout current-contract who none))))
      (print { event: "redeem", who: who, payout: payout })
      (ok payout))))


;; ===== SIMNET ONLY. Not present in the deployed contract. =====
(define-public (test-set-bonded)
  (begin (var-set status STATUS_BONDED) (ok true)))

(define-read-only (test-tx-output (tx (buff 16384)) (index uint))
  (get-bitcoin-tx-output? tx index))
