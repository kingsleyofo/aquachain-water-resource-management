;; ========================================
;; AQUACHAIN GOVERNANCE CONTRACT
;; ========================================
;;
;; This contract facilitates democratic governance of water resources through
;; a proposal and voting system. It allows stakeholders to participate in
;; resource management decisions including allocation formulas, conservation
;; measures, and infrastructure investments.
;;
;; The governance system includes special mechanisms for emergency drought response
;; and ensures equitable participation by balancing voting power through a combination
;; of water rights ownership and other factors to prevent domination by large users.

;; ========================================
;; Error Constants
;; ========================================

(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-PROPOSAL-EXISTS (err u1002))
(define-constant ERR-NO-SUCH-PROPOSAL (err u1003))
(define-constant ERR-PROPOSAL-EXPIRED (err u1004))
(define-constant ERR-PROPOSAL-ACTIVE (err u1005))
(define-constant ERR-ALREADY-VOTED (err u1006))
(define-constant ERR-NOT-STAKEHOLDER (err u1007))
(define-constant ERR-EMERGENCY-ACTIVE (err u1008))
(define-constant ERR-EMERGENCY-NOT-ACTIVE (err u1009))
(define-constant ERR-INVALID-VOTE (err u1010))
(define-constant ERR-VOTING-CLOSED (err u1011))
(define-constant ERR-VOTING-PERIOD-TOO-SHORT (err u1012))
(define-constant ERR-CANNOT-FINALIZE (err u1013))

;; ========================================
;; Data Maps and Variables
;; ========================================

;; Contract owner/administrator
(define-data-var contract-owner principal tx-sender)

;; Proposal data structure
(define-map proposals
  { proposal-id: uint }
  {
    title: (string-ascii 100),
    description: (string-utf8 1000),
    proposer: principal,
    proposal-type: (string-ascii 50),
    created-at: uint,
    expires-at: uint,
    executed: bool,
    emergency: bool,
    metadata: (optional (string-utf8 1000))
  }
)

;; Vote data for each proposal
(define-map proposal-votes
  { proposal-id: uint }
  {
    yes-votes: uint,
    no-votes: uint,
    abstain-votes: uint,
    quorum-reached: bool,
    finalized: bool
  }
)

;; Track individual votes to prevent double voting
(define-map user-votes
  { proposal-id: uint, voter: principal }
  { vote: (string-ascii 10), voting-power: uint }
)

;; Map to store stakeholders and their associated water rights
(define-map stakeholders
  { address: principal }
  { 
    water-rights-amount: uint,
    reputation-score: uint,
    last-active: uint, 
    resource-type: (string-ascii 20)
  }
)

;; Drought emergency status
(define-data-var drought-emergency-active bool false)

;; Proposal counter
(define-data-var proposal-counter uint u0)

;; Voting parameters
(define-data-var minimum-voting-period uint u1440) ;; Minimum 1 day (in blocks)
(define-data-var required-quorum-percentage uint u30) ;; 30% of total voting power

;; ========================================
;; Private Functions
;; ========================================

;; Calculate a stakeholder's voting power - combines water rights with other factors
;; for more equitable distribution of influence
(define-private (calculate-voting-power (stakeholder principal))
  (let (
    (stakeholder-data (default-to { water-rights-amount: u0, reputation-score: u0, last-active: u0, resource-type: "" } 
                      (map-get? stakeholders { address: stakeholder })))
    (water-rights (get water-rights-amount stakeholder-data))
    (reputation (get reputation-score stakeholder-data))
    (activity-score (- (unwrap-panic (get-block-info? time (- block-height u1))) 
                      (get last-active stakeholder-data)))
  )
  ;; Square root function to limit large stakeholder dominance
  ;; Base voting power on water rights with influence from reputation and activity
  (+ (sqrti water-rights) 
     (* u2 reputation) 
     (if (> activity-score u2592000) u0 u5)) ;; Award 5 points if active in last month
  )
)

;; Square root integer implementation
(define-private (sqrti (n uint))
  (sqrti-iter n u1 u0)
)

(define-private (sqrti-iter (n uint) (guess uint) (prev-guess uint))
  (if (or (= guess prev-guess) (= guess (+ prev-guess u1)))
      guess
      (sqrti-iter n (/ (+ guess (/ n guess)) u2) guess)
  )
)

;; Check if user is a registered stakeholder
(define-private (is-stakeholder (address principal))
  (is-some (map-get? stakeholders { address: address }))
)

;; Check if a proposal exists
(define-private (proposal-exists (proposal-id uint))
  (is-some (map-get? proposals { proposal-id: proposal-id }))
)

;; Check if current block is before proposal expiration
(define-private (is-proposal-active (proposal-id uint))
  (let ((proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) false)))
    (< block-height (get expires-at proposal))
  )
)

;; Get total voting power across all stakeholders
(define-private (get-total-stakeholder-power)
  ;; In a real implementation, this would iterate through all stakeholders
  ;; Since Clarity doesn't support loops, this would be tracked separately
  ;; For this example, we'll use a placeholder value
  u10000
)

;; ========================================
;; Read-Only Functions
;; ========================================

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

;; Get proposal votes
(define-read-only (get-proposal-votes (proposal-id uint))
  (map-get? proposal-votes { proposal-id: proposal-id })
)

;; Get user's vote on a specific proposal
(define-read-only (get-user-vote (proposal-id uint) (voter principal))
  (map-get? user-votes { proposal-id: proposal-id, voter: voter })
)

;; Get stakeholder information
(define-read-only (get-stakeholder-info (address principal))
  (map-get? stakeholders { address: address })
)

;; Check if drought emergency is active
(define-read-only (is-drought-emergency)
  (var-get drought-emergency-active)
)

;; Get user's voting power
(define-read-only (get-voting-power (address principal))
  (if (is-stakeholder address)
    (ok (calculate-voting-power address))
    (err ERR-NOT-STAKEHOLDER)
  )
)

;; Check if a proposal has reached quorum
(define-read-only (has-reached-quorum (proposal-id uint))
  (let (
    (votes (default-to { yes-votes: u0, no-votes: u0, abstain-votes: u0, quorum-reached: false, finalized: false } 
                      (map-get? proposal-votes { proposal-id: proposal-id })))
    (total-votes (+ (get yes-votes votes) (get no-votes votes) (get abstain-votes votes)))
    (quorum-threshold (/ (* (get-total-stakeholder-power) (var-get required-quorum-percentage)) u100))
  )
  (>= total-votes quorum-threshold)
  )
)

;; Check if a proposal has passed
(define-read-only (has-proposal-passed (proposal-id uint))
  (let (
    (votes (default-to { yes-votes: u0, no-votes: u0, abstain-votes: u0, quorum-reached: false, finalized: false } 
                      (map-get? proposal-votes { proposal-id: proposal-id })))
  )
  (if (get quorum-reached votes)
    (> (get yes-votes votes) (get no-votes votes))
    false
  ))
)

;; ========================================
;; Public Functions
;; ========================================

;; Register a new stakeholder
(define-public (register-stakeholder (address principal) (water-rights-amount uint) (resource-type (string-ascii 20)))
  (begin
    ;; Only contract owner can register stakeholders
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    (map-set stakeholders
      { address: address }
      { 
        water-rights-amount: water-rights-amount,
        reputation-score: u1,
        last-active: (unwrap-panic (get-block-info? time block-height)),
        resource-type: resource-type
      }
    )
    (ok true)
  )
)

;; Update stakeholder information
(define-public (update-stakeholder (address principal) (water-rights-amount uint) (reputation-score uint))
  (begin
    ;; Only contract owner can update stakeholders
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    (let ((existing-data (unwrap! (map-get? stakeholders { address: address }) ERR-NOT-STAKEHOLDER)))
      (map-set stakeholders
        { address: address }
        { 
          water-rights-amount: water-rights-amount,
          reputation-score: reputation-score,
          last-active: (get last-active existing-data),
          resource-type: (get resource-type existing-data)
        }
      )
      (ok true)
    )
  )
)

;; Create a new proposal
(define-public (create-proposal 
  (title (string-ascii 100)) 
  (description (string-utf8 1000)) 
  (proposal-type (string-ascii 50)) 
  (voting-period uint) 
  (emergency bool)
  (metadata (optional (string-utf8 1000))))
  
  (let (
    (proposal-id (+ (var-get proposal-counter) u1))
    (current-time (unwrap-panic (get-block-info? time block-height)))
  )
    ;; Validate the proposer is a stakeholder
    (asserts! (is-stakeholder tx-sender) ERR-NOT-STAKEHOLDER)
    
    ;; Ensure voting period meets minimum requirements
    (asserts! (>= voting-period (var-get minimum-voting-period)) ERR-VOTING-PERIOD-TOO-SHORT)
    
    ;; Emergency proposals require special authorization or drought emergency status
    (asserts! (or (not emergency) (var-get drought-emergency-active) (is-eq tx-sender (var-get contract-owner))) ERR-NOT-AUTHORIZED)
    
    ;; Create the proposal
    (map-set proposals
      { proposal-id: proposal-id }
      {
        title: title,
        description: description,
        proposer: tx-sender,
        proposal-type: proposal-type,
        created-at: current-time,
        expires-at: (+ block-height voting-period),
        executed: false,
        emergency: emergency,
        metadata: metadata
      }
    )
    
    ;; Initialize vote tracking
    (map-set proposal-votes
      { proposal-id: proposal-id }
      {
        yes-votes: u0,
        no-votes: u0,
        abstain-votes: u0,
        quorum-reached: false,
        finalized: false
      }
    )
    
    ;; Update proposal counter
    (var-set proposal-counter proposal-id)
    
    ;; Update stakeholder activity time
    (let ((stakeholder-data (unwrap! (map-get? stakeholders { address: tx-sender }) ERR-NOT-STAKEHOLDER)))
      (map-set stakeholders
        { address: tx-sender }
        (merge stakeholder-data { last-active: current-time })
      )
    )
    
    (ok proposal-id)
  )
)

;; Vote on a proposal
(define-public (vote (proposal-id uint) (vote-type (string-ascii 10)))
  (let (
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-NO-SUCH-PROPOSAL))
    (current-votes (unwrap! (map-get? proposal-votes { proposal-id: proposal-id }) ERR-NO-SUCH-PROPOSAL))
    (voting-power (calculate-voting-power tx-sender))
    (current-time (unwrap-panic (get-block-info? time block-height)))
  )
    ;; Check proposal is still active
    (asserts! (< block-height (get expires-at proposal)) ERR-PROPOSAL-EXPIRED)
    
    ;; Check voter is a stakeholder
    (asserts! (is-stakeholder tx-sender) ERR-NOT-STAKEHOLDER)
    
    ;; Check user hasn't already voted
    (asserts! (is-none (map-get? user-votes { proposal-id: proposal-id, voter: tx-sender })) ERR-ALREADY-VOTED)
    
    ;; Validate vote type
    (asserts! (or (is-eq vote-type "yes") (is-eq vote-type "no") (is-eq vote-type "abstain")) ERR-INVALID-VOTE)
    
    ;; Record the vote
    (map-set user-votes
      { proposal-id: proposal-id, voter: tx-sender }
      { vote: vote-type, voting-power: voting-power }
    )
    
    ;; Update vote tallies
    (map-set proposal-votes
      { proposal-id: proposal-id }
      (match vote-type
        "yes" (merge current-votes { yes-votes: (+ (get yes-votes current-votes) voting-power) })
        "no" (merge current-votes { no-votes: (+ (get no-votes current-votes) voting-power) })
        "abstain" (merge current-votes { abstain-votes: (+ (get abstain-votes current-votes) voting-power) })
        current-votes
      )
    )
    
    ;; Update stakeholder activity time
    (let ((stakeholder-data (unwrap! (map-get? stakeholders { address: tx-sender }) ERR-NOT-STAKEHOLDER)))
      (map-set stakeholders
        { address: tx-sender }
        (merge stakeholder-data { last-active: current-time })
      )
    )
    
    (ok true)
  )
)

;; Finalize a proposal after voting period ends
(define-public (finalize-proposal (proposal-id uint))
  (let (
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-NO-SUCH-PROPOSAL))
    (current-votes (unwrap! (map-get? proposal-votes { proposal-id: proposal-id }) ERR-NO-SUCH-PROPOSAL))
  )
    ;; Ensure voting period has ended
    (asserts! (>= block-height (get expires-at proposal)) ERR-PROPOSAL-ACTIVE)
    
    ;; Ensure proposal hasn't already been finalized
    (asserts! (not (get finalized current-votes)) ERR-CANNOT-FINALIZE)
    
    ;; Check if quorum was reached
    (let (
      (total-votes (+ (get yes-votes current-votes) (get no-votes current-votes) (get abstain-votes current-votes)))
      (quorum-threshold (/ (* (get-total-stakeholder-power) (var-get required-quorum-percentage)) u100))
      (quorum-reached (>= total-votes quorum-threshold))
      (proposal-passed (and quorum-reached (> (get yes-votes current-votes) (get no-votes current-votes))))
    )
      ;; Update proposal status
      (map-set proposal-votes
        { proposal-id: proposal-id }
        (merge current-votes 
          { 
            quorum-reached: quorum-reached,
            finalized: true
          }
        )
      )
      
      ;; Mark proposal as executed if passed
      (when proposal-passed
        (map-set proposals
          { proposal-id: proposal-id }
          (merge proposal { executed: true })
        )
      )
      
      (ok { quorum-reached: quorum-reached, proposal-passed: proposal-passed })
    )
  )
)

;; Declare a drought emergency
(define-public (declare-drought-emergency)
  (begin
    ;; Only contract owner can declare an emergency
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Ensure emergency isn't already active
    (asserts! (not (var-get drought-emergency-active)) ERR-EMERGENCY-ACTIVE)
    
    ;; Set emergency state
    (var-set drought-emergency-active true)
    
    (ok true)
  )
)

;; End a drought emergency
(define-public (end-drought-emergency)
  (begin
    ;; Only contract owner can end an emergency
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Ensure emergency is active
    (asserts! (var-get drought-emergency-active) ERR-EMERGENCY-NOT-ACTIVE)
    
    ;; End emergency state
    (var-set drought-emergency-active false)
    
    (ok true)
  )
)

;; Transfer contract ownership
(define-public (transfer-contract-ownership (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Update governance parameters
(define-public (update-governance-parameters (min-voting-period uint) (quorum-percentage uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set minimum-voting-period min-voting-period)
    (var-set required-quorum-percentage quorum-percentage)
    (ok true)
  )
)