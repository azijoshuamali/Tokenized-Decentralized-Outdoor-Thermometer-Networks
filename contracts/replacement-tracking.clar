;; Replacement Tracking Contract
;; Manages thermometer upgrade and substitution

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u500))
(define-constant err-not-found (err u501))
(define-constant err-already-exists (err u502))
(define-constant err-invalid-status (err u503))
(define-constant err-not-authorized (err u504))

;; Data Variables
(define-data-var replacement-reward uint u100)
(define-data-var upgrade-bonus uint u50)
(define-data-var warranty-period uint u52560) ;; ~1 year in blocks

;; Data Maps
(define-map thermometer-registry
  { device-id: uint }
  {
    owner: principal,
    model: (string-ascii 30),
    serial-number: (string-ascii 20),
    installation-date: uint,
    warranty-expires: uint,
    status: (string-ascii 15),
    location-lat: int,
    location-lon: int
  }
)

(define-map replacement-requests
  { request-id: uint }
  {
    device-id: uint,
    requester: principal,
    reason: (string-ascii 50),
    request-date: uint,
    approved: bool,
    processed: bool,
    replacement-device-id: (optional uint)
  }
)

(define-map upgrade-schedule
  { device-id: uint }
  {
    current-version: (string-ascii 10),
    target-version: (string-ascii 10),
    scheduled-date: uint,
    upgrade-status: (string-ascii 15),
    assigned-technician: (optional principal)
  }
)

(define-map device-lifecycle
  { device-id: uint }
  {
    manufacture-date: uint,
    deployment-date: uint,
    last-maintenance: uint,
    replacement-count: uint,
    total-uptime: uint,
    performance-score: uint
  }
)

(define-map token-balances
  { owner: principal }
  { balance: uint }
)

(define-data-var next-device-id uint u1)
(define-data-var next-request-id uint u1)

;; Public Functions

;; Register new thermometer device
(define-public (register-device (model (string-ascii 30)) (serial-number (string-ascii 20)) (location-lat int) (location-lon int))
  (let (
    (device-id (var-get next-device-id))
    (owner tx-sender)
  )
    (map-set thermometer-registry
      { device-id: device-id }
      {
        owner: owner,
        model: model,
        serial-number: serial-number,
        installation-date: block-height,
        warranty-expires: (+ block-height (var-get warranty-period)),
        status: "active",
        location-lat: location-lat,
        location-lon: location-lon
      }
    )

    ;; Initialize device lifecycle
    (map-set device-lifecycle
      { device-id: device-id }
      {
        manufacture-date: block-height,
        deployment-date: block-height,
        last-maintenance: u0,
        replacement-count: u0,
        total-uptime: u0,
        performance-score: u100
      }
    )

    (var-set next-device-id (+ device-id u1))
    (ok device-id)
  )
)

;; Request device replacement
(define-public (request-replacement (device-id uint) (reason (string-ascii 50)))
  (let (
    (device-data (unwrap! (map-get? thermometer-registry { device-id: device-id }) err-not-found))
    (request-id (var-get next-request-id))
    (requester tx-sender)
  )
    ;; Check if requester is device owner
    (asserts! (is-eq requester (get owner device-data)) err-not-authorized)

    (map-set replacement-requests
      { request-id: request-id }
      {
        device-id: device-id,
        requester: requester,
        reason: reason,
        request-date: block-height,
        approved: false,
        processed: false,
        replacement-device-id: none
      }
    )

    (var-set next-request-id (+ request-id u1))
    (ok request-id)
  )
)

;; Approve replacement request
(define-public (approve-replacement (request-id uint))
  (let (
    (request-data (unwrap! (map-get? replacement-requests { request-id: request-id }) err-not-found))
  )
    ;; Only contract owner can approve
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)

    (map-set replacement-requests
      { request-id: request-id }
      (merge request-data { approved: true })
    )

    (ok true)
  )
)

;; Process replacement
(define-public (process-replacement (request-id uint) (new-device-id uint))
  (let (
    (request-data (unwrap! (map-get? replacement-requests { request-id: request-id }) err-not-found))
    (old-device-id (get device-id request-data))
    (old-device-data (unwrap! (map-get? thermometer-registry { device-id: old-device-id }) err-not-found))
  )
    ;; Check if request is approved
    (asserts! (get approved request-data) err-not-authorized)

    ;; Check if not already processed
    (asserts! (not (get processed request-data)) err-already-exists)

    ;; Update old device status
    (map-set thermometer-registry
      { device-id: old-device-id }
      (merge old-device-data { status: "replaced" })
    )

    ;; Update replacement request
    (map-set replacement-requests
      { request-id: request-id }
      (merge request-data {
        processed: true,
        replacement-device-id: (some new-device-id)
      })
    )

    ;; Update device lifecycle
    (let (
      (lifecycle-data (unwrap! (map-get? device-lifecycle { device-id: old-device-id }) err-not-found))
    )
      (map-set device-lifecycle
        { device-id: old-device-id }
        (merge lifecycle-data {
          replacement-count: (+ (get replacement-count lifecycle-data) u1)
        })
      )
    )

    ;; Reward device owner
    (mint-tokens (get requester request-data) (var-get replacement-reward))

    (ok true)
  )
)

;; Schedule device upgrade
(define-public (schedule-upgrade (device-id uint) (target-version (string-ascii 10)) (scheduled-date uint))
  (let (
    (device-data (unwrap! (map-get? thermometer-registry { device-id: device-id }) err-not-found))
  )
    ;; Only device owner or contract owner can schedule
    (asserts! (or (is-eq tx-sender (get owner device-data)) (is-eq tx-sender contract-owner)) err-not-authorized)

    (map-set upgrade-schedule
      { device-id: device-id }
      {
        current-version: "1.0", ;; Default current version
        target-version: target-version,
        scheduled-date: scheduled-date,
        upgrade-status: "scheduled",
        assigned-technician: none
      }
    )

    (ok true)
  )
)

;; Complete device upgrade
(define-public (complete-upgrade (device-id uint))
  (let (
    (upgrade-data (unwrap! (map-get? upgrade-schedule { device-id: device-id }) err-not-found))
    (device-data (unwrap! (map-get? thermometer-registry { device-id: device-id }) err-not-found))
  )
    ;; Check if upgrade is scheduled
    (asserts! (is-eq (get upgrade-status upgrade-data) "scheduled") err-invalid-status)

    ;; Update upgrade status
    (map-set upgrade-schedule
      { device-id: device-id }
      (merge upgrade-data {
        upgrade-status: "completed",
        current-version: (get target-version upgrade-data)
      })
    )

    ;; Reward device owner for upgrade
    (mint-tokens (get owner device-data) (var-get upgrade-bonus))

    (ok true)
  )
)

;; Update device status
(define-public (update-device-status (device-id uint) (new-status (string-ascii 15)))
  (let (
    (device-data (unwrap! (map-get? thermometer-registry { device-id: device-id }) err-not-found))
  )
    ;; Only device owner can update status
    (asserts! (is-eq tx-sender (get owner device-data)) err-not-authorized)

    (map-set thermometer-registry
      { device-id: device-id }
      (merge device-data { status: new-status })
    )

    (ok true)
  )
)

;; Private Functions

;; Mint tokens to address
(define-private (mint-tokens (recipient principal) (amount uint))
  (let (
    (current-balance (default-to u0 (get balance (map-get? token-balances { owner: recipient }))))
  )
    (map-set token-balances
      { owner: recipient }
      { balance: (+ current-balance amount) }
    )
  )
)

;; Read-only Functions

;; Get device information
(define-read-only (get-device-info (device-id uint))
  (map-get? thermometer-registry { device-id: device-id })
)

;; Get replacement request
(define-read-only (get-replacement-request (request-id uint))
  (map-get? replacement-requests { request-id: request-id })
)

;; Get upgrade schedule
(define-read-only (get-upgrade-schedule (device-id uint))
  (map-get? upgrade-schedule { device-id: device-id })
)

;; Get device lifecycle
(define-read-only (get-device-lifecycle (device-id uint))
  (map-get? device-lifecycle { device-id: device-id })
)

;; Check if device is under warranty
(define-read-only (is-under-warranty (device-id uint))
  (let (
    (device-data (map-get? thermometer-registry { device-id: device-id }))
  )
    (match device-data
      some-device (> (get warranty-expires some-device) block-height)
      false
    )
  )
)

;; Get token balance
(define-read-only (get-balance (owner principal))
  (default-to u0 (get balance (map-get? token-balances { owner: owner })))
)

;; Get next device ID
(define-read-only (get-next-device-id)
  (var-get next-device-id)
)

;; Admin Functions

;; Set replacement reward
(define-public (set-replacement-reward (new-reward uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set replacement-reward new-reward)
    (ok true)
  )
)

;; Set upgrade bonus
(define-public (set-upgrade-bonus (new-bonus uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set upgrade-bonus new-bonus)
    (ok true)
  )
)

;; Set warranty period
(define-public (set-warranty-period (new-period uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set warranty-period new-period)
    (ok true)
  )
)
