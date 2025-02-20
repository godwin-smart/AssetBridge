;; AssetBridge: Advanced Real-World Asset Tokenization Protocol for Stacks
;;
;; A Bitcoin L2-native protocol enabling compliant tokenization of real-world assets
;; with secure fractional ownership capabilities. Built on Stacks for enhanced
;; security through Bitcoin settlement and PoX consensus.
;;
;; Core Technical Features:
;; - Bitcoin-anchored security through Stacks' PoX consensus
;; - Atomic ownership transfers with Bitcoin finality
;; - Compliant fractional ownership with built-in KYC/AML hooks
;; - Immutable asset provenance tracking
;; - Advanced compliance controls for institutional requirements
;;
;; Security & Compliance:
;; - Multi-layered security leveraging Bitcoin's hash power
;; - Automated compliance checks for regulatory adherence
;; - Granular transfer controls for institutional requirements
;; - Event logging with Bitcoin block anchoring

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant CONTRACT-ADMIN CONTRACT-OWNER)
(define-constant ERR-UNAUTHORIZED (err u1))
(define-constant ERR-INSUFFICIENT-FUNDS (err u2))
(define-constant ERR-INVALID-ASSET (err u3))
(define-constant ERR-TRANSFER-FAILED (err u4))
(define-constant ERR-COMPLIANCE-CHECK-FAILED (err u5))
(define-constant ERR-INVALID-INPUT (err u6))
(define-constant ERR-INSUFFICIENT-SHARES (err u7))
(define-constant ERR-EVENT-LOGGING (err u8))

;; Data Variables
(define-data-var next-asset-id uint u1)

;; Data Maps
(define-map asset-registry 
  {asset-id: uint} 
  {
    owner: principal,
    total-supply: uint,
    fractional-shares: uint,
    metadata-uri: (string-utf8 256),
    is-transferable: bool,
    created-at: uint
  }
)

(define-map compliance-status 
  {asset-id: uint, user: principal} 
  {
    is-approved: bool,
    last-updated: uint,
    approved-by: principal
  }
)

(define-map share-ownership
  {asset-id: uint, owner: principal}
  {shares: uint}
)

;; NFT Definition
(define-non-fungible-token asset-ownership-token uint)

;; Events
(define-data-var last-event-id uint u0)

(define-map events
  {event-id: uint}
  {
    event-type: (string-utf8 24),
    asset-id: uint,
    principal1: principal,
    timestamp: uint
  }
)

;; Private Functions - Event Logging
(define-private (log-event 
  (event-type (string-utf8 24))
  (asset-id uint)
  (principal1 principal)
) 
  (begin
    (let ((event-id (+ (var-get last-event-id) u1)))
      (map-set events
        {event-id: event-id}
        {
          event-type: event-type,
          asset-id: asset-id,
          principal1: principal1,
          timestamp: stacks-block-height
        }
      )
      (var-set last-event-id event-id)
      (ok event-id)
    )
  )
)

;; Private Functions - Validation
(define-private (is-valid-metadata-uri (uri (string-utf8 256)))
  (and 
    (> (len uri) u0)
    (<= (len uri) u256)
    (> (len uri) u5)
  )
)

(define-private (is-valid-asset-id (asset-id uint))
  (and
    (> asset-id u0)
    (< asset-id (var-get next-asset-id))
  )
)

(define-private (is-valid-principal (user principal))
  (and
    (not (is-eq user CONTRACT-OWNER))
    (not (is-eq user (as-contract tx-sender)))
  )
)

(define-private (is-compliance-check-passed 
  (asset-id uint) 
  (user principal)
) 
  (match (map-get? compliance-status {asset-id: asset-id, user: user})
    compliance-data (get is-approved compliance-data)
    false
  )
)

;; Private Functions - Share Management
(define-private (get-shares (asset-id uint) (owner principal))
  (default-to u0 
    (get shares 
      (map-get? share-ownership {asset-id: asset-id, owner: owner})
    )
  )
)

(define-private (set-shares (asset-id uint) (owner principal) (amount uint))
  (map-set share-ownership 
    {asset-id: asset-id, owner: owner}
    {shares: amount}
  )
)

;; Public Functions - Asset Management
(define-public (create-asset 
  (total-supply uint) 
  (fractional-shares uint)
  (metadata-uri (string-utf8 256))
)
  (begin 
    (asserts! (> total-supply u0) ERR-INVALID-INPUT)
    (asserts! (> fractional-shares u0) ERR-INVALID-INPUT)
    (asserts! (<= fractional-shares total-supply) ERR-INVALID-INPUT)
    (asserts! (is-valid-metadata-uri metadata-uri) ERR-INVALID-INPUT)
    
    (let ((asset-id (var-get next-asset-id)))
      (map-set asset-registry 
        {asset-id: asset-id}
        {
          owner: tx-sender,
          total-supply: total-supply,
          fractional-shares: fractional-shares,
          metadata-uri: metadata-uri,
          is-transferable: true,
          created-at: stacks-block-height
        }
      )
      
      ;; Initialize share ownership
      (set-shares asset-id tx-sender total-supply)
      
      (unwrap! (nft-mint? asset-ownership-token asset-id tx-sender) ERR-TRANSFER-FAILED)
      (unwrap! (log-event u"ASSET_CREATED" asset-id tx-sender) ERR-EVENT-LOGGING)
      
      (var-set next-asset-id (+ asset-id u1))
      (ok asset-id)
    )
  )
)

(define-public (transfer-fractional-ownership 
  (asset-id uint) 
  (to-principal principal) 
  (amount uint)
)
  (let (
    (asset (unwrap! (map-get? asset-registry {asset-id: asset-id}) ERR-INVALID-ASSET))
    (sender tx-sender)
    (sender-shares (get-shares asset-id sender))
  )
    (asserts! (is-valid-asset-id asset-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-principal to-principal) ERR-INVALID-INPUT)
    (asserts! (get is-transferable asset) ERR-UNAUTHORIZED)
    (asserts! (is-compliance-check-passed asset-id to-principal) ERR-COMPLIANCE-CHECK-FAILED)
    (asserts! (>= sender-shares amount) ERR-INSUFFICIENT-SHARES)
    
    ;; Update share balances
    (set-shares asset-id sender (- sender-shares amount))
    (set-shares asset-id to-principal (+ (get-shares asset-id to-principal) amount))
    
    (unwrap! (log-event u"TRANSFER" asset-id sender) ERR-EVENT-LOGGING)
    
    (if (is-eq sender-shares amount)
      (unwrap! (nft-transfer? asset-ownership-token asset-id sender to-principal) ERR-TRANSFER-FAILED)
      true
    )
    
    (ok true)
  )
)

(define-public (set-compliance-status 
  (asset-id uint) 
  (user principal) 
  (is-approved bool)
)
  (begin
    (asserts! (is-valid-asset-id asset-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-principal user) ERR-INVALID-INPUT)
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    
    (map-set compliance-status 
      {asset-id: asset-id, user: user} 
      {
        is-approved: is-approved,
        last-updated: stacks-block-height,
        approved-by: tx-sender
      }
    )
    
    (unwrap! (log-event u"COMPLIANCE_UPDATE" asset-id user) ERR-EVENT-LOGGING)
    
    (ok is-approved)
  )
)

;; Read-only Functions
(define-read-only (get-asset-details (asset-id uint))
  (map-get? asset-registry {asset-id: asset-id})
)

(define-read-only (get-owner-shares (asset-id uint) (owner principal))
  (ok (get-shares asset-id owner))
)

(define-read-only (get-compliance-details (asset-id uint) (user principal))
  (map-get? compliance-status {asset-id: asset-id, user: user})
)

(define-read-only (get-event (event-id uint))
  (map-get? events {event-id: event-id})
)