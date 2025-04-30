;; aquachain-core
;; 
;; This contract serves as the central registry for water rights on the AquaChain platform.
;; It manages water allocation rights, tracks usage, and enables transparent trading of 
;; water rights between different stakeholders. The contract enforces usage limits, maintains
;; a verifiable history of water consumption, and supports different stakeholder types with
;; varying permissions and allocation rules.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ALREADY-REGISTERED (err u101))
(define-constant ERR-INVALID-STAKEHOLDER-TYPE (err u102))
(define-constant ERR-NOT-REGISTERED (err u103))
(define-constant ERR-INSUFFICIENT-ALLOCATION (err u104))
(define-constant ERR-INSUFFICIENT-RIGHTS (err u105))
(define-constant ERR-INVALID-AMOUNT (err u106))
(define-constant ERR-TRANSFER-TO-SELF (err u107))
(define-constant ERR-RECIPIENT-NOT-REGISTERED (err u108))
(define-constant ERR-EMERGENCY-ACTIVE (err u109))
(define-constant ERR-INVALID-MEASUREMENT (err u110))

;; Stakeholder types
(define-constant STAKEHOLDER-AGRICULTURAL u1)
(define-constant STAKEHOLDER-RESIDENTIAL u2)
(define-constant STAKEHOLDER-INDUSTRIAL u3)

;; Contract owner
(define-constant CONTRACT-OWNER tx-sender)

;; Data maps and variables

;; Tracks registered stakeholders and their type
(define-map stakeholders 
  { address: principal } 
  { stakeholder-type: uint, registered-at: uint }
)

;; Water rights allocations per stakeholder (in cubic meters)
(define-map water-rights
  { owner: principal }
  { annual-allocation: uint, current-balance: uint }
)

;; Historical water usage tracking
(define-map usage-history
  { owner: principal, year: uint }
  { total-usage: uint }
)

;; Water quality measurements
(define-map water-quality-measurements
  { measurement-id: uint }
  { 
    reporter: principal, 
    location: (string-ascii 64), 
    ph-level: uint, 
    turbidity: uint, 
    contaminants-level: uint,
    reported-at: uint
  }
)

;; Counter for measurement IDs
(define-data-var next-measurement-id uint u1)

;; Current emergency status
(define-data-var emergency-status bool false)

;; Reduction percentage during emergencies (1-100)
(define-data-var emergency-reduction-percent uint u0)

;; Current season modifier for allocations (percentage)
(define-data-var seasonal-modifier uint u100)

;; Function to check if caller is authorized as admin
(define-private (is-admin)
  (is-eq tx-sender CONTRACT-OWNER)
)

;; Function to check if an address is registered
(define-private (is-registered (address principal))
  (is-some (map-get? stakeholders { address: address }))
)

;; Function to get stakeholder type
(define-private (get-stakeholder-type (address principal))
  (default-to u0 (get stakeholder-type (map-get? stakeholders { address: address })))
)

;; Function to calculate adjusted allocation considering emergency status
(define-private (calculate-adjusted-allocation (original-allocation uint))
  (if (var-get emergency-status)
    (let ((reduction-factor (/ (* original-allocation (- u100 (var-get emergency-reduction-percent))) u100)))
      reduction-factor)
    original-allocation)
)

;; Function to calculate seasonal adjustment
(define-private (apply-seasonal-adjustment (allocation uint))
  (/ (* allocation (var-get seasonal-modifier)) u100)
)

;; Function to validate stakeholder type
(define-private (is-valid-stakeholder-type (stakeholder-type uint))
  (or 
    (is-eq stakeholder-type STAKEHOLDER-AGRICULTURAL)
    (is-eq stakeholder-type STAKEHOLDER-RESIDENTIAL)
    (is-eq stakeholder-type STAKEHOLDER-INDUSTRIAL)
  )
)

;; Read-only functions

;; Get stakeholder information
(define-read-only (get-stakeholder-info (address principal))
  (map-get? stakeholders { address: address })
)

;; Get water rights for a stakeholder
(define-read-only (get-water-rights (owner principal))
  (map-get? water-rights { owner: owner })
)

;; Get water usage history for a specific year
(define-read-only (get-water-usage (owner principal) (year uint))
  (map-get? usage-history { owner: owner, year: year })
)

;; Get water quality measurement by ID
(define-read-only (get-water-quality (measurement-id uint))
  (map-get? water-quality-measurements { measurement-id: measurement-id })
)

;; Get emergency status
(define-read-only (get-emergency-status)
  (var-get emergency-status)
)

;; Get seasonal modifier
(define-read-only (get-seasonal-modifier)
  (var-get seasonal-modifier)
)

;; Public functions

;; Register a new stakeholder
(define-public (register-stakeholder (stakeholder-type uint))
  (let ((caller tx-sender))
    (asserts! (not (is-registered caller)) ERR-ALREADY-REGISTERED)
    (asserts! (is-valid-stakeholder-type stakeholder-type) ERR-INVALID-STAKEHOLDER-TYPE)
    
    ;; Register stakeholder
    (map-set stakeholders 
      { address: caller } 
      { stakeholder-type: stakeholder-type, registered-at: block-height }
    )
    
    ;; Initialize water rights based on stakeholder type
    (map-set water-rights
      { owner: caller }
      { 
        annual-allocation: (if (is-eq stakeholder-type STAKEHOLDER-AGRICULTURAL)
                              u1000000  ;; 1,000,000 cubic meters for agricultural
                              (if (is-eq stakeholder-type STAKEHOLDER-INDUSTRIAL)
                                u500000  ;; 500,000 cubic meters for industrial
                                u100000  ;; 100,000 cubic meters for residential
                              )
                            ),
        current-balance: (if (is-eq stakeholder-type STAKEHOLDER-AGRICULTURAL)
                            u1000000
                            (if (is-eq stakeholder-type STAKEHOLDER-INDUSTRIAL)
                              u500000
                              u100000
                            )
                          )
      }
    )
    
    (ok true)
  )
)

;; Admin function to update a stakeholder's annual allocation
(define-public (update-annual-allocation (stakeholder principal) (new-allocation uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (is-registered stakeholder) ERR-NOT-REGISTERED)
    (asserts! (> new-allocation u0) ERR-INVALID-AMOUNT)
    
    (let ((current-rights (unwrap! (map-get? water-rights { owner: stakeholder }) ERR-NOT-REGISTERED)))
      (map-set water-rights
        { owner: stakeholder }
        { 
          annual-allocation: new-allocation,
          current-balance: new-allocation  ;; Reset balance to new allocation
        }
      )
      (ok true)
    )
  )
)

;; Record water usage for a stakeholder
(define-public (record-water-usage (amount uint))
  (let (
        (caller tx-sender)
        (current-year (/ block-height u525600))  ;; Approximate blocks in a year
       )
    (asserts! (is-registered caller) ERR-NOT-REGISTERED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (let ((rights (unwrap! (map-get? water-rights { owner: caller }) ERR-NOT-REGISTERED)))
      ;; Check if user has sufficient allocation
      (asserts! (>= (get current-balance rights) amount) ERR-INSUFFICIENT-ALLOCATION)
      
      ;; Update current balance
      (map-set water-rights
        { owner: caller }
        {
          annual-allocation: (get annual-allocation rights),
          current-balance: (- (get current-balance rights) amount)
        }
      )
      
      ;; Update usage history
      (let ((existing-usage (default-to { total-usage: u0 } 
                            (map-get? usage-history { owner: caller, year: current-year }))))
        (map-set usage-history
          { owner: caller, year: current-year }
          { total-usage: (+ (get total-usage existing-usage) amount) }
        )
      )
      
      (ok true)
    )
  )
)

;; Transfer water rights to another stakeholder
(define-public (transfer-water-rights (recipient principal) (amount uint))
  (let ((caller tx-sender))
    (asserts! (is-registered caller) ERR-NOT-REGISTERED)
    (asserts! (is-registered recipient) ERR-RECIPIENT-NOT-REGISTERED)
    (asserts! (not (is-eq caller recipient)) ERR-TRANSFER-TO-SELF)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (let (
          (sender-rights (unwrap! (map-get? water-rights { owner: caller }) ERR-NOT-REGISTERED))
          (recipient-rights (unwrap! (map-get? water-rights { owner: recipient }) ERR-RECIPIENT-NOT-REGISTERED))
         )
      ;; Check if sender has sufficient rights
      (asserts! (>= (get current-balance sender-rights) amount) ERR-INSUFFICIENT-RIGHTS)
      
      ;; Update sender's rights
      (map-set water-rights
        { owner: caller }
        {
          annual-allocation: (get annual-allocation sender-rights),
          current-balance: (- (get current-balance sender-rights) amount)
        }
      )
      
      ;; Update recipient's rights
      (map-set water-rights
        { owner: recipient }
        {
          annual-allocation: (get annual-allocation recipient-rights),
          current-balance: (+ (get current-balance recipient-rights) amount)
        }
      )
      
      (ok true)
    )
  )
)

;; Report water quality measurement
(define-public (report-water-quality (location (string-ascii 64)) (ph-level uint) (turbidity uint) (contaminants-level uint))
  (let ((caller tx-sender)
        (measurement-id (var-get next-measurement-id)))
    (asserts! (is-registered caller) ERR-NOT-REGISTERED)
    ;; Basic validation of measurement data
    (asserts! (and (>= ph-level u0) (<= ph-level u140)) ERR-INVALID-MEASUREMENT)  ;; pH 0-14.0 (multiplied by 10)
    (asserts! (>= turbidity u0) ERR-INVALID-MEASUREMENT)
    (asserts! (>= contaminants-level u0) ERR-INVALID-MEASUREMENT)
    
    ;; Record measurement
    (map-set water-quality-measurements
      { measurement-id: measurement-id }
      {
        reporter: caller,
        location: location,
        ph-level: ph-level,
        turbidity: turbidity,
        contaminants-level: contaminants-level,
        reported-at: block-height
      }
    )
    
    ;; Increment measurement ID
    (var-set next-measurement-id (+ measurement-id u1))
    
    (ok measurement-id)
  )
)

;; Admin function to declare water emergency
(define-public (declare-emergency (reduction-percent uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (and (> reduction-percent u0) (<= reduction-percent u100)) ERR-INVALID-AMOUNT)
    
    (var-set emergency-status true)
    (var-set emergency-reduction-percent reduction-percent)
    
    (ok true)
  )
)

;; Admin function to end water emergency
(define-public (end-emergency)
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (var-get emergency-status) ERR-EMERGENCY-ACTIVE)
    
    (var-set emergency-status false)
    (var-set emergency-reduction-percent u0)
    
    (ok true)
  )
)

;; Admin function to set seasonal modifier
(define-public (set-seasonal-modifier (modifier uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (> modifier u0) ERR-INVALID-AMOUNT)
    
    (var-set seasonal-modifier modifier)
    
    (ok true)
  )
)

;; Annual reset of water allocations (would typically be called by an automated system)
(define-public (reset-annual-allocations)
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    ;; In a real implementation, we would iterate through all stakeholders
    ;; Since Clarity doesn't support iteration, this would need to be handled
    ;; by external scripts calling a function to reset individual accounts
    
    (ok true)
  )
)

;; Reset allocation for a specific stakeholder (to be used with external iteration)
(define-public (reset-stakeholder-allocation (stakeholder principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (is-registered stakeholder) ERR-NOT-REGISTERED)
    
    (let ((rights (unwrap! (map-get? water-rights { owner: stakeholder }) ERR-NOT-REGISTERED)))
      (map-set water-rights
        { owner: stakeholder }
        {
          annual-allocation: (get annual-allocation rights),
          current-balance: (get annual-allocation rights)  ;; Reset to full allocation
        }
      )
      (ok true)
    )
  )
)