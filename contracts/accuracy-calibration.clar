;; Accuracy Calibration Contract
;; Ensures temperature reading precision and reliability

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-invalid-reading (err u102))
(define-constant err-already-calibrated (err u103))
(define-constant err-insufficient-balance (err u104))

;; Data Variables
(define-data-var calibration-reward uint u100)
(define-data-var accuracy-threshold uint u50) ;; 0.5 degrees in tenths
(define-data-var calibration-interval uint u2016) ;; ~2 weeks in blocks

;; Data Maps
(define-map thermometer-calibrations
  { thermometer-id: uint }
  {
    last-calibration: uint,
    accuracy-score: uint,
    reference-temp: int,
    measured-temp: int,
    calibrated-by: principal,
    is-accurate: bool
  }
)

(define-map calibrator-stats
  { calibrator: principal }
  {
    total-calibrations: uint,
    successful-calibrations: uint,
    reputation-score: uint
  }
)

(define-map token-balances
  { owner: principal }
  { balance: uint }
)

;; Public Functions

;; Submit calibration reading
(define-public (submit-calibration (thermometer-id uint) (reference-temp int) (measured-temp int))
  (let (
    (temp-diff (if (> reference-temp measured-temp)
                   (- reference-temp measured-temp)
                   (- measured-temp reference-temp)))
    (is-accurate (<= (to-uint temp-diff) (var-get accuracy-threshold)))
    (calibrator tx-sender)
  )
    (asserts! (is-none (map-get? thermometer-calibrations { thermometer-id: thermometer-id })) err-already-calibrated)

    ;; Record calibration
    (map-set thermometer-calibrations
      { thermometer-id: thermometer-id }
      {
        last-calibration: block-height,
        accuracy-score: (if is-accurate u100 u0),
        reference-temp: reference-temp,
        measured-temp: measured-temp,
        calibrated-by: calibrator,
        is-accurate: is-accurate
      }
    )

    ;; Update calibrator stats
    (update-calibrator-stats calibrator is-accurate)

    ;; Reward calibrator
    (if is-accurate
        (begin
          (mint-tokens calibrator (var-get calibration-reward))
          (ok true))
        (ok true)
    )
  )
)

;; Check if thermometer needs calibration
(define-public (needs-calibration (thermometer-id uint))
  (let (
    (calibration-data (map-get? thermometer-calibrations { thermometer-id: thermometer-id }))
  )
    (match calibration-data
      some-data (ok (> (- block-height (get last-calibration some-data)) (var-get calibration-interval)))
      (ok true) ;; Never calibrated, needs calibration
    )
  )
)

;; Get thermometer accuracy status
(define-read-only (get-accuracy-status (thermometer-id uint))
  (map-get? thermometer-calibrations { thermometer-id: thermometer-id })
)

;; Get calibrator statistics
(define-read-only (get-calibrator-stats (calibrator principal))
  (map-get? calibrator-stats { calibrator: calibrator })
)

;; Private Functions

;; Update calibrator statistics
(define-private (update-calibrator-stats (calibrator principal) (successful bool))
  (let (
    (current-stats (default-to
      { total-calibrations: u0, successful-calibrations: u0, reputation-score: u0 }
      (map-get? calibrator-stats { calibrator: calibrator })
    ))
    (new-total (+ (get total-calibrations current-stats) u1))
    (new-successful (if successful
                        (+ (get successful-calibrations current-stats) u1)
                        (get successful-calibrations current-stats)))
    (new-reputation (/ (* new-successful u100) new-total))
  )
    (map-set calibrator-stats
      { calibrator: calibrator }
      {
        total-calibrations: new-total,
        successful-calibrations: new-successful,
        reputation-score: new-reputation
      }
    )
  )
)

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

;; Admin Functions

;; Set calibration reward (owner only)
(define-public (set-calibration-reward (new-reward uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set calibration-reward new-reward)
    (ok true)
  )
)

;; Set accuracy threshold (owner only)
(define-public (set-accuracy-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set accuracy-threshold new-threshold)
    (ok true)
  )
)

;; Read-only Functions

;; Get token balance
(define-read-only (get-balance (owner principal))
  (default-to u0 (get balance (map-get? token-balances { owner: owner })))
)

;; Get calibration reward
(define-read-only (get-calibration-reward)
  (var-get calibration-reward)
)

;; Get accuracy threshold
(define-read-only (get-accuracy-threshold)
  (var-get accuracy-threshold)
)
