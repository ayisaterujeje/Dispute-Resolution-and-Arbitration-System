;; Dispute Manager Contract
;; Manages dispute creation, status transitions, and participant roles

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-DISPUTE-NOT-FOUND (err u101))
(define-constant ERR-INVALID-STATUS (err u102))
(define-constant ERR-INVALID-PARTICIPANT (err u103))
(define-constant ERR-DISPUTE-ALREADY-EXISTS (err u104))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u105))
(define-constant ERR-INVALID-AMOUNT (err u106))

;; Data Variables
(define-data-var next-dispute-id uint u1)
(define-data-var platform-fee-rate uint u250) ;; 2.5% in basis points

;; Data Maps
(define-map disputes
  { dispute-id: uint }
  {
    claimant: principal,
    respondent: principal,
    arbitrator: (optional principal),
    amount: uint,
    description: (string-ascii 500),
    status: (string-ascii 20),
    created-at: uint,
    updated-at: uint,
    resolution-deadline: (optional uint)
  }
)

(define-map dispute-participants
  { dispute-id: uint, participant: principal }
  { role: (string-ascii 20), active: bool }
)

(define-map arbitrator-pool
  { arbitrator: principal }
  { active: bool, cases-handled: uint, rating: uint }
)

(define-map dispute-fees
  { dispute-id: uint }
  { total-fee: uint, claimant-paid: uint, respondent-paid: uint, platform-fee: uint }
)

;; Read-only functions
(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

(define-read-only (get-participant-role (dispute-id uint) (participant principal))
  (map-get? dispute-participants { dispute-id: dispute-id, participant: participant })
)

(define-read-only (get-arbitrator-info (arbitrator principal))
  (map-get? arbitrator-pool { arbitrator: arbitrator })
)

(define-read-only (get-dispute-fees (dispute-id uint))
  (map-get? dispute-fees { dispute-id: dispute-id })
)

(define-read-only (get-next-dispute-id)
  (var-get next-dispute-id)
)

(define-read-only (get-platform-fee-rate)
  (var-get platform-fee-rate)
)

(define-read-only (is-participant (dispute-id uint) (participant principal))
  (is-some (map-get? dispute-participants { dispute-id: dispute-id, participant: participant }))
)

(define-read-only (is-dispute-active (dispute-id uint))
  (match (map-get? disputes { dispute-id: dispute-id })
    dispute-data (not (or
      (is-eq (get status dispute-data) "resolved")
      (is-eq (get status dispute-data) "enforced")
      (is-eq (get status dispute-data) "cancelled")
    ))
    false
  )
)

;; Private functions
(define-private (is-authorized-participant (dispute-id uint) (participant principal))
  (match (map-get? dispute-participants { dispute-id: dispute-id, participant: participant })
    participant-data (get active participant-data)
    false
  )
)

(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-rate)) u10000)
)

(define-private (validate-status-transition (current-status (string-ascii 20)) (new-status (string-ascii 20)))
  (or
    ;; From pending
    (and (is-eq current-status "pending")
         (or (is-eq new-status "active") (is-eq new-status "cancelled")))
    ;; From active
    (and (is-eq current-status "active")
         (or (is-eq new-status "evidence-review") (is-eq new-status "cancelled")))
    ;; From evidence-review
    (and (is-eq current-status "evidence-review")
         (or (is-eq new-status "deliberation") (is-eq new-status "active")))
    ;; From deliberation
    (and (is-eq current-status "deliberation")
         (or (is-eq new-status "resolved") (is-eq new-status "evidence-review")))
    ;; From resolved
    (and (is-eq current-status "resolved")
         (is-eq new-status "enforced"))
  )
)

;; Public functions
(define-public (create-dispute (respondent principal) (amount uint) (description (string-ascii 500)))
  (let (
    (dispute-id (var-get next-dispute-id))
    (platform-fee (calculate-platform-fee amount))
    (total-required (+ amount platform-fee))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (not (is-eq tx-sender respondent)) ERR-INVALID-PARTICIPANT)

    ;; Create dispute record
    (map-set disputes
      { dispute-id: dispute-id }
      {
        claimant: tx-sender,
        respondent: respondent,
        arbitrator: none,
        amount: amount,
        description: description,
        status: "pending",
        created-at: block-height,
        updated-at: block-height,
        resolution-deadline: none
      }
    )

    ;; Set participant roles
    (map-set dispute-participants
      { dispute-id: dispute-id, participant: tx-sender }
      { role: "claimant", active: true }
    )

    (map-set dispute-participants
      { dispute-id: dispute-id, participant: respondent }
      { role: "respondent", active: true }
    )

    ;; Initialize fee structure
    (map-set dispute-fees
      { dispute-id: dispute-id }
      {
        total-fee: total-required,
        claimant-paid: u0,
        respondent-paid: u0,
        platform-fee: platform-fee
      }
    )

    ;; Increment dispute counter
    (var-set next-dispute-id (+ dispute-id u1))

    (ok dispute-id)
  )
)

(define-public (assign-arbitrator (dispute-id uint) (arbitrator principal))
  (let (
    (dispute-data (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status dispute-data) "pending") ERR-INVALID-STATUS)
    (asserts! (is-some (map-get? arbitrator-pool { arbitrator: arbitrator })) ERR-INVALID-PARTICIPANT)

    ;; Update dispute with arbitrator
    (map-set disputes
      { dispute-id: dispute-id }
      (merge dispute-data {
        arbitrator: (some arbitrator),
        status: "active",
        updated-at: block-height,
        resolution-deadline: (some (+ block-height u1440)) ;; ~10 days
      })
    )

    ;; Add arbitrator as participant
    (map-set dispute-participants
      { dispute-id: dispute-id, participant: arbitrator }
      { role: "arbitrator", active: true }
    )

    (ok true)
  )
)

(define-public (update-dispute-status (dispute-id uint) (new-status (string-ascii 20)))
  (let (
    (dispute-data (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
    (current-status (get status dispute-data))
  )
    (asserts! (is-authorized-participant dispute-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (validate-status-transition current-status new-status) ERR-INVALID-STATUS)

    (map-set disputes
      { dispute-id: dispute-id }
      (merge dispute-data {
        status: new-status,
        updated-at: block-height
      })
    )

    (ok true)
  )
)

(define-public (register-arbitrator)
  (begin
    (map-set arbitrator-pool
      { arbitrator: tx-sender }
      { active: true, cases-handled: u0, rating: u5 }
    )
    (ok true)
  )
)

(define-public (deactivate-arbitrator (arbitrator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? arbitrator-pool { arbitrator: arbitrator })) ERR-INVALID-PARTICIPANT)

    (map-set arbitrator-pool
      { arbitrator: arbitrator }
      { active: false, cases-handled: u0, rating: u0 }
    )
    (ok true)
  )
)

(define-public (pay-dispute-fee (dispute-id uint))
  (let (
    (dispute-data (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
    (fee-data (unwrap! (map-get? dispute-fees { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
    (participant-role (unwrap! (map-get? dispute-participants { dispute-id: dispute-id, participant: tx-sender }) ERR-NOT-AUTHORIZED))
    (fee-amount (/ (get total-fee fee-data) u2)) ;; Split fee between parties
  )
    (asserts! (is-dispute-active dispute-id) ERR-INVALID-STATUS)

    ;; Update fee payment based on participant role
    (if (is-eq (get role participant-role) "claimant")
      (map-set dispute-fees
        { dispute-id: dispute-id }
        (merge fee-data { claimant-paid: fee-amount })
      )
      (map-set dispute-fees
        { dispute-id: dispute-id }
        (merge fee-data { respondent-paid: fee-amount })
      )
    )

    (ok true)
  )
)

(define-public (cancel-dispute (dispute-id uint))
  (let (
    (dispute-data (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
  )
    (asserts! (or
      (is-eq tx-sender (get claimant dispute-data))
      (is-eq tx-sender CONTRACT-OWNER)
    ) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq (get status dispute-data) "resolved")) ERR-INVALID-STATUS)

    (map-set disputes
      { dispute-id: dispute-id }
      (merge dispute-data {
        status: "cancelled",
        updated-at: block-height
      })
    )

    (ok true)
  )
)

(define-public (set-platform-fee-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-rate u1000) ERR-INVALID-AMOUNT) ;; Max 10%
    (var-set platform-fee-rate new-rate)
    (ok true)
  )
)
