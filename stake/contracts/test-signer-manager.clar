;; SIMNET ONLY. Minimal signer-manager-trait implementation.
;;
;; pox-5 requires a signer-manager contract for register-for-bond, and insists
;; that signer setup calls originate from the signer contract itself
;; (contract-caller must equal the signer principal). So those two calls are
;; wrapped here rather than made from a test account. The trait reference is
;; passed in because a contract cannot name itself as a trait implementation.
;;
;; validate-stake! accepts everything: what the At Stake tests exercise is
;; pox-5's bond bookkeeping, not signer policy.

(use-trait signer-manager-trait .pox5-sim.signer-manager-trait)

(define-public (validate-stake!
                 (staker principal)
                 (first-index uint)
                 (num-indexes uint)
                 (amount-ustx uint)
                 (amount-sats uint)
                 (is-bond bool)
                 (signer-calldata (optional (buff 500))))
  (ok true))

;; pox-5: "Only the signer contract itself can call this function to grant a
;; signer key" -- so it has to originate here.
(define-public (grant-key (signer-key (buff 33)) (auth-id uint) (signer-sig (buff 65)))
  (contract-call? .pox5-sim grant-signer-key
                  signer-key current-contract auth-id signer-sig))

;; pox-5: "Only the signer contract itself can register itself".
(define-public (register (mgr <signer-manager-trait>) (signer-key (buff 33)))
  (contract-call? .pox5-sim register-signer mgr signer-key))
