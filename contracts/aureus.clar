;; Aureus Shield Protocol (ASP)
;; Parametric insurance for Bitcoin miners against difficulty adjustments and energy price spikes

;; Constants
(define-constant PROTOCOL-ADMIN tx-sender)
(define-constant ERR-ADMIN-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-BALANCE (err u103))
(define-constant ERR-COVERAGE-EXPIRED (err u104))
(define-constant ERR-PAYOUT-ALREADY-PROCESSED (err u105))
(define-constant ERR-TRIGGER-NOT-MET (err u106))
(define-constant ERR-DATA-SOURCE-NOT-AUTHORIZED (err u107))
(define-constant ERR-INVALID-PARAMETERS (err u108))

;; Data Variables
(define-data-var primary-data-source principal PROTOCOL-ADMIN)
(define-data-var platform-fee-basis-points uint u250) ;; 2.5% in basis points
(define-data-var total-shields-issued uint u0)
(define-data-var platform-reserve uint u0)

;; Valid data types for oracle submissions - Fixed string length
(define-constant VALID-METRIC-TYPES (list "difficulty" "energy-price"))

;; Validation helper - Fixed parameter type to match list elements
(define-private (is-metric-type-valid (metric-type (string-ascii 12)))
  (is-some (index-of VALID-METRIC-TYPES metric-type))
)

;; Valid principals check
(define-private (is-valid-principal (addr principal))
  (not (is-eq addr 'SP000000000000000000002Q6VF78))
)

;; Shield Structure
(define-map protection-shields
  { shield-id: uint }
  {
    protected-miner: principal,
    premium-amount: uint,
    protection-value: uint,
    difficulty-trigger: uint,
    energy-price-trigger: uint,
    activation-block: uint,
    expiry-block: uint,
    payout-processed: bool,
    shield-active: bool
  }
)

;; Oracle Data - Updated to use consistent string length
(define-map market-metrics
  { metric-type: (string-ascii 12), submission-block: uint }
  {
    metric-value: uint,
    timestamp: uint,
    data-source: principal
  }
)

;; Authorized Data Sources
(define-map authorized-data-sources
  { data-source: principal }
  { is-authorized: bool }
)

;; Miner Protection Profiles
(define-map miner-protection-profiles
  { protected-miner: principal }
  {
    total-shields: uint,
    total-payouts: uint,
    total-premiums-paid: uint
  }
)

;; Shield Events - Updated to use consistent string length
(define-map shield-events
  { shield-id: uint, event-type: (string-ascii 20) }
  {
    event-block: uint,
    timestamp: uint,
    event-data: uint
  }
)

;; Read-only functions

(define-read-only (get-protection-shield (shield-id uint))
  (map-get? protection-shields { shield-id: shield-id })
)

(define-read-only (get-market-metric (metric-type (string-ascii 12)) (submission-block uint))
  (map-get? market-metrics { metric-type: metric-type, submission-block: submission-block })
)

(define-read-only (get-miner-protection-profile (protected-miner principal))
  (default-to 
    { total-shields: u0, total-payouts: u0, total-premiums-paid: u0 }
    (map-get? miner-protection-profiles { protected-miner: protected-miner })
  )
)

(define-read-only (is-data-source-authorized (data-source principal))
  (default-to false (get is-authorized (map-get? authorized-data-sources { data-source: data-source })))
)

(define-read-only (calculate-shield-premium (protection-value uint) (risk-factor uint))
  (let ((base-premium (/ (* protection-value u500) u10000))) ;; 5% base rate
    (/ (* base-premium risk-factor) u100)
  )
)

(define-read-only (get-platform-statistics)
  {
    total-shields: (var-get total-shields-issued),
    platform-reserve: (var-get platform-reserve),
    primary-data-source: (var-get primary-data-source),
    platform-fee-basis-points: (var-get platform-fee-basis-points)
  }
)

;; Administrative functions

(define-public (set-primary-data-source (new-data-source principal))
  (begin
    (asserts! (is-eq tx-sender PROTOCOL-ADMIN) ERR-ADMIN-ONLY)
    (asserts! (is-valid-principal new-data-source) ERR-INVALID-PARAMETERS)
    (var-set primary-data-source new-data-source)
    (ok true)
  )
)

(define-public (authorize-data-source (source-addr principal))
  (begin
    (asserts! (is-eq tx-sender PROTOCOL-ADMIN) ERR-ADMIN-ONLY)
    (asserts! (is-valid-principal source-addr) ERR-INVALID-PARAMETERS)
    (map-set authorized-data-sources { data-source: source-addr } { is-authorized: true })
    (ok true)
  )
)

(define-public (revoke-data-source (source-addr principal))
  (begin
    (asserts! (is-eq tx-sender PROTOCOL-ADMIN) ERR-ADMIN-ONLY)
    (asserts! (is-valid-principal source-addr) ERR-INVALID-PARAMETERS)
    (map-set authorized-data-sources { data-source: source-addr } { is-authorized: false })
    (ok true)
  )
)

(define-public (update-platform-fee (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender PROTOCOL-ADMIN) ERR-ADMIN-ONLY)
    (asserts! (<= new-rate u1000) ERR-INVALID-PARAMETERS) ;; Max 10%
    (var-set platform-fee-basis-points new-rate)
    (ok true)
  )
)

;; Data Source functions - Updated parameter type

(define-public (submit-market-metric (metric-type (string-ascii 12)) (metric-value uint))
  (let ((current-block block-height))
    (asserts! (is-data-source-authorized tx-sender) ERR-DATA-SOURCE-NOT-AUTHORIZED)
    (asserts! (is-metric-type-valid metric-type) ERR-INVALID-PARAMETERS)
    (map-set market-metrics 
      { metric-type: metric-type, submission-block: current-block }
      { metric-value: metric-value, timestamp: (unwrap-panic (get-block-info? time current-block)), data-source: tx-sender }
    )
    (ok true)
  )
)

;; Core insurance functions

(define-public (create-protection-shield 
  (protection-value uint)
  (difficulty-trigger uint)
  (energy-price-trigger uint)
  (shield-duration-blocks uint)
  (risk-factor uint)
)
  (let (
    (shield-id (+ (var-get total-shields-issued) u1))
    (premium (calculate-shield-premium protection-value risk-factor))
    (platform-fee (/ (* premium (var-get platform-fee-basis-points)) u10000))
    (total-cost (+ premium platform-fee))
    (current-block block-height)
    (expiry-block (+ current-block shield-duration-blocks))
    (current-profile (get-miner-protection-profile tx-sender))
  )
    (asserts! (> protection-value u0) ERR-INVALID-PARAMETERS)
    (asserts! (> difficulty-trigger u0) ERR-INVALID-PARAMETERS)
    (asserts! (> energy-price-trigger u0) ERR-INVALID-PARAMETERS)
    (asserts! (> shield-duration-blocks u0) ERR-INVALID-PARAMETERS)
    (asserts! (>= (stx-get-balance tx-sender) total-cost) ERR-INSUFFICIENT-BALANCE)
    
    ;; Transfer premium and fee
    (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
    
    ;; Create protection shield
    (map-set protection-shields 
      { shield-id: shield-id }
      {
        protected-miner: tx-sender,
        premium-amount: premium,
        protection-value: protection-value,
        difficulty-trigger: difficulty-trigger,
        energy-price-trigger: energy-price-trigger,
        activation-block: current-block,
        expiry-block: expiry-block,
        payout-processed: false,
        shield-active: true
      }
    )
    
    ;; Update miner profile
    (map-set miner-protection-profiles 
      { protected-miner: tx-sender }
      {
        total-shields: (+ (get total-shields current-profile) u1),
        total-payouts: (get total-payouts current-profile),
        total-premiums-paid: (+ (get total-premiums-paid current-profile) premium)
      }
    )
    
    ;; Update platform state
    (var-set total-shields-issued shield-id)
    (var-set platform-reserve (+ (var-get platform-reserve) platform-fee))
    
    (ok shield-id)
  )
)

(define-public (process-protection-payout (shield-id uint))
  (let (
    (shield (unwrap! (get-protection-shield shield-id) ERR-NOT-FOUND))
    (current-block block-height)
    (difficulty-metric (get-market-metric "difficulty" current-block))
    (energy-metric (get-market-metric "energy-price" current-block))
    (current-profile (get-miner-protection-profile (get protected-miner shield)))
  )
    (asserts! (is-eq tx-sender (get protected-miner shield)) ERR-ADMIN-ONLY)
    (asserts! (get shield-active shield) ERR-NOT-FOUND)
    (asserts! (not (get payout-processed shield)) ERR-PAYOUT-ALREADY-PROCESSED)
    (asserts! (<= current-block (get expiry-block shield)) ERR-COVERAGE-EXPIRED)
    
    ;; Check if triggers are met
    (let (
      (difficulty-triggered 
        (match difficulty-metric
          metric-entry (>= (get metric-value metric-entry) (get difficulty-trigger shield))
          false
        )
      )
      (energy-triggered 
        (match energy-metric
          metric-entry (>= (get metric-value metric-entry) (get energy-price-trigger shield))
          false
        )
      )
    )
      (asserts! (or difficulty-triggered energy-triggered) ERR-TRIGGER-NOT-MET)
      
      ;; Calculate payout
      (let ((payout-amount (get protection-value shield)))
        ;; Transfer payout
        (try! (as-contract (stx-transfer? payout-amount tx-sender (get protected-miner shield))))
        
        ;; Update shield
        (map-set protection-shields 
          { shield-id: shield-id }
          (merge shield { payout-processed: true, shield-active: false })
        )
        
        ;; Update miner profile
        (map-set miner-protection-profiles 
          { protected-miner: (get protected-miner shield) }
          (merge current-profile { total-payouts: (+ (get total-payouts current-profile) u1) })
        )
        
        ;; Record event
        (map-set shield-events
          { shield-id: shield-id, event-type: "payout-processed" }
          { event-block: current-block, timestamp: (unwrap-panic (get-block-info? time current-block)), event-data: payout-amount }
        )
        
        (ok payout-amount)
      )
    )
  )
)

(define-public (cancel-protection-shield (shield-id uint))
  (let (
    (shield (unwrap! (get-protection-shield shield-id) ERR-NOT-FOUND))
    (current-block block-height)
  )
    (asserts! (is-eq tx-sender (get protected-miner shield)) ERR-ADMIN-ONLY)
    (asserts! (get shield-active shield) ERR-NOT-FOUND)
    (asserts! (not (get payout-processed shield)) ERR-PAYOUT-ALREADY-PROCESSED)
    (asserts! (< current-block (get activation-block shield)) ERR-COVERAGE-EXPIRED)
    
    ;; Refund premium (minus platform fee)
    (let ((refund-amount (get premium-amount shield)))
      (try! (as-contract (stx-transfer? refund-amount tx-sender (get protected-miner shield))))
      
      ;; Deactivate shield
      (map-set protection-shields 
        { shield-id: shield-id }
        (merge shield { shield-active: false })
      )
      
      (ok refund-amount)
    )
  )
)

;; Treasury management

(define-public (withdraw-platform-reserve (amount uint))
  (begin
    (asserts! (is-eq tx-sender PROTOCOL-ADMIN) ERR-ADMIN-ONLY)
    (asserts! (<= amount (var-get platform-reserve)) ERR-INSUFFICIENT-BALANCE)
    (try! (as-contract (stx-transfer? amount tx-sender PROTOCOL-ADMIN)))
    (var-set platform-reserve (- (var-get platform-reserve) amount))
    (ok amount)
  )
)

;; Initialize contract
(begin
  (map-set authorized-data-sources { data-source: PROTOCOL-ADMIN } { is-authorized: true })
)