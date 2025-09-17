;; Automated Dividend Distribution for Tokenized Shares
;; A secure smart contract that automatically distributes dividends to tokenized share holders
;; based on their ownership percentage, with transparent tracking, withdrawal mechanisms,
;; and comprehensive dividend history management for corporate governance compliance.

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u400))
(define-constant ERR-INSUFFICIENT-BALANCE (err u401))
(define-constant ERR-NO-DIVIDENDS (err u402))
(define-constant ERR-INVALID-AMOUNT (err u403))
(define-constant ERR-ALREADY-CLAIMED (err u404))
(define-constant ERR-DISTRIBUTION-NOT-FOUND (err u405))
(define-constant ERR-INVALID-SHARES (err u406))
(define-constant MIN-DIVIDEND-AMOUNT u1000000) ;; 1 STX minimum
(define-constant MAX-SHAREHOLDERS u500)
(define-constant PRECISION-MULTIPLIER u1000000) ;; For percentage calculations

;; data maps and vars
(define-data-var total-shares uint u1000000) ;; Total tokenized shares
(define-data-var next-distribution-id uint u1)
(define-data-var total-dividends-distributed uint u0)
(define-data-var contract-paused bool false)

(define-map shareholder-balances
  principal
  uint) ;; Number of shares owned

(define-map dividend-distributions
  uint
  {
    total-amount: uint,
    per-share-amount: uint,
    distribution-block: uint,
    distributed-by: principal,
    total-claimed: uint,
    status: (string-ascii 20) ;; ACTIVE, COMPLETED
  })

(define-map dividend-claims
  {distribution-id: uint, shareholder: principal}
  {
    amount-claimed: uint,
    claim-block: uint,
    claimed: bool
  })

(define-map shareholder-history
  principal
  {
    total-dividends-received: uint,
    last-claim-block: uint,
    distributions-participated: uint
  })

;; private functions
(define-private (calculate-dividend-amount (shares uint) (per-share-amount uint))
  (/ (* shares per-share-amount) PRECISION-MULTIPLIER))

(define-private (get-shareholder-percentage (shareholder principal))
  (let ((shares (default-to u0 (map-get? shareholder-balances shareholder)))
        (total (var-get total-shares)))
    (if (> total u0)
      (/ (* shares PRECISION-MULTIPLIER) total)
      u0)))

(define-private (update-shareholder-history (shareholder principal) (amount uint))
  (let ((current-history (default-to 
                          {total-dividends-received: u0, last-claim-block: u0, distributions-participated: u0}
                          (map-get? shareholder-history shareholder))))
    (map-set shareholder-history shareholder {
      total-dividends-received: (+ (get total-dividends-received current-history) amount),
      last-claim-block: block-height,
      distributions-participated: (+ (get distributions-participated current-history) u1)
    })))

;; public functions
(define-public (issue-shares (recipient principal) (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (let ((current-shares (default-to u0 (map-get? shareholder-balances recipient))))
      (map-set shareholder-balances recipient (+ current-shares amount))
      (var-set total-shares (+ (var-get total-shares) amount))
      (ok amount))))

(define-public (transfer-shares (recipient principal) (amount uint))
  (let ((sender-shares (default-to u0 (map-get? shareholder-balances tx-sender))))
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (>= sender-shares amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (let ((recipient-shares (default-to u0 (map-get? shareholder-balances recipient))))
      (map-set shareholder-balances tx-sender (- sender-shares amount))
      (map-set shareholder-balances recipient (+ recipient-shares amount))
      (ok amount))))

(define-public (distribute-dividends (total-dividend-amount uint))
  (let ((distribution-id (var-get next-distribution-id))
        (total-shares-current (var-get total-shares)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (>= total-dividend-amount MIN-DIVIDEND-AMOUNT) ERR-INVALID-AMOUNT)
    (asserts! (> total-shares-current u0) ERR-INVALID-SHARES)
    
    ;; Transfer dividend funds to contract
    (try! (stx-transfer? total-dividend-amount tx-sender (as-contract tx-sender)))
    
    (let ((per-share-amount (/ (* total-dividend-amount PRECISION-MULTIPLIER) total-shares-current)))
      (map-set dividend-distributions distribution-id {
        total-amount: total-dividend-amount,
        per-share-amount: per-share-amount,
        distribution-block: block-height,
        distributed-by: tx-sender,
        total-claimed: u0,
        status: "ACTIVE"
      })
      
      (var-set next-distribution-id (+ distribution-id u1))
      (var-set total-dividends-distributed (+ (var-get total-dividends-distributed) total-dividend-amount))
      
      (print {event: "dividend-distribution-created", id: distribution-id, amount: total-dividend-amount})
      (ok distribution-id))))

(define-public (claim-dividend (distribution-id uint))
  (let ((distribution (unwrap! (map-get? dividend-distributions distribution-id) ERR-DISTRIBUTION-NOT-FOUND))
        (shareholder-shares (default-to u0 (map-get? shareholder-balances tx-sender))))
    
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (> shareholder-shares u0) ERR-INVALID-SHARES)
    (asserts! (is-eq (get status distribution) "ACTIVE") ERR-DISTRIBUTION-NOT-FOUND)
    
    (let ((existing-claim (map-get? dividend-claims {distribution-id: distribution-id, shareholder: tx-sender})))
      (asserts! (is-none existing-claim) ERR-ALREADY-CLAIMED)
      
      (let ((dividend-amount (calculate-dividend-amount shareholder-shares (get per-share-amount distribution))))
        (asserts! (> dividend-amount u0) ERR-NO-DIVIDENDS)
        
        ;; Record the claim
        (map-set dividend-claims {distribution-id: distribution-id, shareholder: tx-sender} {
          amount-claimed: dividend-amount,
          claim-block: block-height,
          claimed: true
        })
        
        ;; Update distribution totals
        (map-set dividend-distributions distribution-id 
                 (merge distribution {total-claimed: (+ (get total-claimed distribution) dividend-amount)}))
        
        ;; Transfer dividend to shareholder
        (try! (as-contract (stx-transfer? dividend-amount tx-sender tx-sender)))
        
        ;; Update shareholder history
        (update-shareholder-history tx-sender dividend-amount)
        
        (print {event: "dividend-claimed", distribution-id: distribution-id, shareholder: tx-sender, amount: dividend-amount})
        (ok dividend-amount)))))

(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))))


