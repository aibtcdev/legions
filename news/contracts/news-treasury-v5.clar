;; news-treasury-v5
;; The sBTC pool for the aibtc.news Legion (v5).
;;
;; ONE POOL. Agents send sBTC in and receive voting rights over how it is spent.
;; The money funds journalism; it does not come back. There is no staking, no
;; withdrawal, and no second balance.
;;
;; TWO WAYS IN. `contribute-in` (gov-only) adds sBTC AND mints the caller voting
;; weight -- the people paying are the people deciding. `sponsor-in` (public, new
;; in v5) adds sBTC and mints NO weight: a sponsor funds the pool for an ad
;; without gaining governance power. That weight-less path deliberately un-welds
;; money from governance, but only for sponsor money; contribute-in is unchanged.
;; A sponsor names itself on-chain (see `sponsor-in`) and buys nothing but the
;; attribution; the pool spends its money exactly as it spends everyone else's.
;;
;; Weight comes from the same sats that get paid out, so every yes vote spends
;; the voter's own money in proportion to their say. Because nothing is
;; withdrawable, this pool can never be short: payouts simply shrink it, and
;; every holder's claim shrinks together.
;;
;; Every OUTFLOW is still gated on `contract-caller` being the wired gov contract,
;; so no human can move funds out directly. The deployer's only power is the
;; one-time wiring; it holds no key to the money.

;; -------------------------------------------------------------------
;; Config
;; -------------------------------------------------------------------
;; The sBTC token is a fixed, known contract, referenced statically rather than
;; through a <sip010-trait> parameter. It removes the whole class of wrong-token
;; bugs -- there is no token argument to get wrong.
;;
;; NOTE: `contract-call?` requires a LITERAL contract identifier, so the token is
;; written out at each call site below rather than referenced through SBTC.
;;
;; DEPLOY NOTE: this is the simnet/testnet sBTC principal, matching the rest of
;; this repo's test setup. A MAINNET deploy MUST swap every occurrence for the
;; mainnet sBTC contract ('SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token).
(define-constant SBTC 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token)

(define-constant DEPLOYER tx-sender)

;; Floor on a single `sponsor-in` deposit, in sats. A sponsorship buys attribution
;; off-chain, so a dust deposit would claim the same billing as a real one. There
;; is deliberately NO ceiling: a large deposit is a good customer, not an error,
;; and the contract cannot tell a fat-finger from a whale.
(define-constant MIN_SPONSOR u100000)

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
(define-constant ERR_BELOW_MIN (err u450)) ;; sponsor deposit under MIN_SPONSOR
(define-constant ERR_EMPTY_NAME (err u451)) ;; a sponsor must say who it is

;; -------------------------------------------------------------------
;; Data
;; -------------------------------------------------------------------
(define-data-var Gov (optional principal) none)

;; The pool. Everything in here is spendable on journalism and nothing else.
(define-data-var Balance uint u0)

;; The CONTRIBUTED share of the pool: sats that arrived through `contribute-in`
;; and therefore minted voting weight. Sponsor sats are in Balance but NOT here.
;;
;; This exists because gov prices new weight as a share of the pool, and a
;; weight-less inflow would otherwise move that price. Two failures follow from
;; pricing against raw Balance: a sponsorship landing before the first
;; contributor leaves weight at zero over a large pool (the first contributor
;; then mints a flat `amount` and owns everything, at a price no later joiner can
;; match), and every later sponsorship raises the sats cost of the same weight,
;; so successful sponsorship progressively closes the legion. Both invert the
;; point of the weight-less path.
;;
;; Pricing against WeightedBalance instead keeps the exchange rate a function of
;; contributed money only. Sponsor sats still enlarge every payout, because the
;; draw is a fraction of the WHOLE pool; they simply buy no governance and move
;; no one else's price. The consequence, deliberate: as sponsorship grows,
;; governance is cheap relative to the money it governs, since only contributors
;; hold weight and their claim is priced off their own sats.
;;
;; Payouts shrink it pro-rata, so it stays a true fraction of Balance.
(define-data-var WeightedBalance uint u0)

;; Settled payout references, keyed by sha256 of {id: proposalId, r: recipient}.
;; Anyone can recompute a ref and check on-chain whether that proposal was paid,
;; and how much. The uniqueness of proposalId makes each ref settleable once.
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

;; The contributed share of the pool. Gov prices new weight against THIS, never
;; against get-balance, so sponsor money never moves the exchange rate.
(define-read-only (get-weighted-balance)
  (var-get WeightedBalance)
)

(define-read-only (get-gov)
  (var-get Gov)
)

(define-read-only (get-token)
  SBTC
)

;; The sponsorship floor, readable so a caller never has to hardcode it.
(define-read-only (get-min-sponsor)
  MIN_SPONSOR
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
;; The WEIGHT-MINTING way sBTC enters. Called by news-gov-v5.contribute, which
;; mints the corresponding voting weight in the same transaction. tx-sender is
;; preserved across the inter-contract call, so the contributor is debited, not
;; gov. (The weight-less path is `sponsor-in` below.)
(define-public (contribute-in (amount uint))
  (begin
    (asserts! (is-gov contract-caller) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
    (var-set Balance (+ (var-get Balance) amount))
    ;; Weight-minting money, so it counts toward the price of future weight.
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

;; -------------------------------------------------------------------
;; Public: sponsor-in (public, weight-less) -- NEW IN v5
;; -------------------------------------------------------------------
;; A weight-less deposit into the pool. Unlike contribute-in, this mints NO
;; voting weight: a sponsor (or an agent depositing on a sponsor's behalf) funds
;; journalism without gaining a governance vote. It is the one thing v4
;; deliberately forbade -- a direct, weightless inflow -- reintroduced on purpose
;; for sponsor money only. Opt-in: anyone who wants a say still uses contribute;
;; only money that should NOT carry a vote comes in here.
;;
;; The sponsor's identity is STRUCTURED, not packed into one blob. `name` is the
;; sponsor as it should be attributed, `link` is an optional site, and `memo` is
;; free-form text the sponsor puts on the record. Splitting them means no reader
;; has to parse a separator convention back apart: the event prints three
;; distinct fields and any indexer reads `name` directly. The contract never
;; reads any of them.
;;
;; `name` is an UNVERIFIED claim -- anyone can pass any string, so a display
;; MUST treat the sender principal as the authoritative identity and `name` as
;; the label that principal asserted. The txid is the sponsor's proof of payment.
;;
;; Nothing about the sponsorship's DURATION or display lives here. The chain
;; records who paid, how much, and what they called themselves; how long a badge
;; shows and which sponsor wins a contested slot are off-chain rules anyone can
;; recompute from these events.
;;
;; A deposit is FINAL. There is no refund path and cannot be one without handing
;; someone a key to the money (see the outflow note in the header), so a repeat
;; or oversized deposit simply funds more journalism. The floor is the only
;; guard, and it is deliberately one-sided.
(define-public (sponsor-in
    (amount uint)
    (name (string-ascii 40))
    (link (optional (string-ascii 96)))
    (memo (string-ascii 128))
  )
  (begin
    ;; Refuse money the pool could never spend. Every outflow is gov-gated, so
    ;; before wiring there is no path out at all: if the deployer key is lost
    ;; between deploy and set-gov, an unguarded sponsor-in would keep accepting
    ;; deposits into a treasury that can never pay anything. This is the only
    ;; entry point not already gov-gated, so it is the only one that needs it.
    (asserts! (is-some (var-get Gov)) ERR_UNAUTHORIZED)
    ;; MIN_SPONSOR is > u0, so this subsumes the zero check the other inflows do.
    (asserts! (>= amount MIN_SPONSOR) ERR_BELOW_MIN)
    (asserts! (> (len name) u0) ERR_EMPTY_NAME)
    (try! (contract-call? 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
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

;; -------------------------------------------------------------------
;; Public: execute-payout (gov only)
;; -------------------------------------------------------------------
;; The ONLY way sBTC leaves. Settles one passed proposal to its proposer. The
;; payout-ref is claimed before the transfer, so a re-entrant call cannot
;; double-settle the same proposal.
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
    ;; Shrink the contributed share by the SAME FRACTION the pool shrank, so it
    ;; stays a true proportion of Balance and weight keeps diluting as the pool
    ;; is spent. `bal` is > u0 here: amount is > u0 and <= bal, so no divide by
    ;; zero. Integer division rounds this down, leaving WeightedBalance a hair
    ;; high, which prices new weight very slightly in existing holders' favour.
    (var-set WeightedBalance (- weighted (/ (* weighted amount) bal)))

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
