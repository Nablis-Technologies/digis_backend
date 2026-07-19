# TICKET QR CODE & OFFLINE SCANNING ARCHITECTURE v3

**Date**: July 17, 2026
**Supersedes**: June 4, 2026 (v2)
**Scope**: QR generation, ticket lifecycle, offline scanning, multi-day events, fraud prevention, **manual attendee lookup**

---

## REVISION HISTORY

### v3.4 — July 17, 2026 — Commercial Packages and All-or-Nothing Delegation

Adds a credential layer beneath the purchased commercial package.

1. A group/couple ticket remains one commercial package (`tid`) with one buyer, price, transfer boundary, and refund boundary.
2. Every QR/PNR has its own never-reused credential UUID (`cid`).
3. One active credential generation is either `group` (one package credential) or `delegated` (one individual credential per admission slot), never both.
4. Group scans consume every slot for the current product access/date; individual scans consume one slot. Multi-day uses remain independent.
5. Revocation now has package-dead, generation-version, and credential-UUID layers.
6. PNR/manual lookup indexes active credentials rather than assuming one QR maps directly to one commercial ticket.
7. Offline upload batches and their nested scans are independently idempotent.
8. Corrects the earlier claim that signed QR tokens eliminate the offline transfer/delegation fraud window: authenticity is offline, but freshness still depends on synchronized revocations.
9. Ticket-product transfers close at a configurable cutoff, defaulting to the applicable event/session start.
10. Entry validation defaults to QR/PNR and may additionally require a staff-recorded holder photo-ID match for higher-security products.
11. Buyer delegation uses the transfer cutoff; after-cutoff manager overrides are online-only and temporarily force online validation until scanner sync acknowledgement.
12. Transfers are free and sequential before cutoff, with one pending transfer and rate limiting rather than a lifetime count limit.
13. ID mismatches deny entry unless an authorized manager grants a reasoned, audited online override.
14. Venue/parking entry defaults to one use per slot/date, with explicit bounded or unlimited re-entry options.
15. OTP-verified holder-name corrections update the attendee index without reissuing the QR; after cutoff they require an online manager reason.
16. Change-of-mind refunds are not a launch path; package transfers are the attendee alternative when permitted.
17. Mistaken successful scans use append-only online manager reversals and versioned scanner deltas; original check-ins and uses are never deleted.
18. Named venue/parking zones validate both product grants and scanner-assignment scope without introducing reserved seating.
19. Package transfer carries only access rights defined directly on the ticket product; separately purchased add-ons remain independent.
20. Organizer complimentary issuance uses the normal registration, inventory, package, credential, QR, and PNR pipeline with zero financial rows.
21. Walk-up sales use ordinary connected mobile-money/card checkout; newly issued gate credentials remain online-required until scanner index acknowledgement.
22. Package revocation distinguishes permanent death from reversible fraud-review suspension, and organizer cancellation of a paid unused package is refund-backed rather than a silent void.
23. Versioned registration answers and exact-version consent evidence remain server-side registration data and never enter QR payloads or scanner indexes.
24. Per-user purchase limits are enforced transactionally before issuance; scanners validate issued credentials and do not recalculate commerce limits.
25. Registration forms may collect per-package-unit/admission-position responses, but answer data remains server-side and is never signed into credentials.
26. Buyer terms and personal slot waivers have separate signers; credentials with incomplete personal requirements have no QR/PNR/index entry.
27. Platform retention policies erase expired answer/consent payloads without changing ticket, credential, scan, or financial history.
28. Answer corrections and consent withdrawals are append-only server-side evidence; withdrawing a required personal waiver revokes/tombstones the affected active credential and returns it to pending requirements.
29. Controlled resale lists only a whole, unused package. Starting buyer checkout revokes the seller generation and temporarily suspends access; success issues a new buyer group generation and failure restores the seller only through a newer generation.
30. Resale price caps, seller marketplace fees, proceeds, payout accounts, and payout status never enter signed QR claims, attendee indexes, or scanner storage.
31. A disconnected scanner missing the resale reservation/revocation delta can temporarily accept the old seller credential; assigned scanners must synchronize before gates open, and high-risk resale windows may require online validation.

### v3.3 — June 18, 2026 — Lifecycle Hooks Wired, Privacy Table Fix

Historical release that connected lifecycle changes to delta-index updates and corrected privacy/concurrency notes. Its ticket-callback implementation has been superseded by v3.4 credential-generation transitions and transactional outbox/index events; do not reconstruct the old callback model from Git history.

### v3.2 — June 18, 2026 — Write Path Fix, Privacy Honesty, Code Bug Fixes

Addresses a second round of external review. Five categories of fixes:

1. **Delta sync write path** (critical): the old event-wide sync rewrote all 50K rows with one `index_version`, defeating delta sync. The canonical design now upserts or tombstones only credentials changed by a committed generation transition; a full rebuild is reconciliation/admin-only.
2. **Phone hash privacy honesty**: Removed false "zero PII on device" claims. Phone hashes (SHA-256 of ~100M Ethiopian phone numbers) are reversible via 3.2GB rainbow table. Added §3B privacy note with honest threat model and mitigation strategy (limit distribution, prefer PNR, encrypt at rest).
3. **Ruby code bugs**: Fixed `LookupCodeService.generate` NameError (`code_body` undefined), added `RecordNotUnique` rescue for race conditions. Fixed `build_entry` returning `phone_hashes` array key that didn't match schema columns. Fixed `changes_since` added/updated predicates being swapped.
4. **Delta response simplification**: Replaced `added[]`/`updated[]` with flat `changed[]` (scanner upserts unconditionally). Dropped `previously_existed` column — semantically fragile for scanners that miss multiple versions.
5. **Factual corrections**: Keyspace claim 32^8 → 22^8 (correct alphabet size). Sizing table updated for dual phone hash columns (~2MB compressed, not ~1.5MB).

### v3.1 — June 18, 2026 — Delta Sync Fix, Dual Phone Hashes, Trust Hardening

Addresses five implementation gaps identified in external review:

1. **Delta sync for attendee index** (critical): Replaced virtual index (full rebuild every call) with persisted `attendee_index_entries` table + per-row `index_version`. Delta sync now mirrors the revocation design exactly — `WHERE index_version > ?` returns only changed rows.
2. **holder_phone indexing**: Index now stores BOTH `phone_hash` (holder/attendee) and `owner_phone_hash` (purchaser). Fixes group bookings where Abebe buys tickets for Sara — Sara can now be found by her own phone number.
3. **Trust asymmetry mitigation**: Added mandatory `reason_code` for every manual check-in. Creates audit trail for detecting abuse patterns. Documented the fraud window in §5.4.
4. **Phone normalization bug fix**: Replaced hand-rolled regex with `Phonelib` gem (Ruby) / `libphonenumber` (mobile). Fixes the `251911234567` → `+251251911234567` double-prefix bug. Added cross-platform self-test at scanner startup.
5. **Minor fixes**: `pg_trgm` GIN index for ILIKE name search performance, name search trust model documentation, walk-up sales delta sync, cross-method first-scan-wins offline weakness acknowledgment.

### v3 — June 18, 2026 — Manual Lookup via PNR Code + Phone Hash

The headline addition: scanners can now validate attendees **without a QR code** via two paths: (1) an **8-character PNR code** included in credential delivery (primary), and (2) a **SHA-256 phone hash** (fallback). Under v3.4, group mode has one package PNR while delegated mode has one PNR per admission-slot credential. The phone hash catches users who forgot their code.

| Change | Before (v2) | After (v3) |
|---|---|---|
| Manual validation | Not possible — scanner has no searchable attendee data | **PNR code** (primary) + **phone hash** (fallback) — both offline |
| Ticket info visibility | Only visible via QR scan | Visible via QR scan OR PNR code OR phone lookup |
| Group bookings | No offline solution | Active credentials have unique PNRs: one package PNR in group mode or one per slot in delegated mode |
| Perks display | Not stored on scanner | Included in lookup index — operator sees VIP perks, access level |
| New scanner table | — | `attendee_lookup` (lookup_code PK, phone_hash + owner_phone_hash secondary indexes) |
| New API endpoints | — | `GET .../attendee-index`, `POST .../lookup` |
| Data size increase | — | ~2MB compressed for 50K attendees (two phone hash columns) |
| PII on device | None (v2 design preserved) | PNR codes are opaque. Phone hashes (SHA-256 of E.164) are present for fallback lookup — see privacy note in §3B |
| Name-based search | Not possible | **Online-only** via server API (names are too variable for hashing) |
| New DB column | — | `ticketing_credentials.lookup_code` (8-char, unique per event) |

Everything else — revocation-based validation, Ed25519 signing, versioning, multi-day policies, fraud layers, conflict resolution — carries forward **unchanged** from v2.

### v2 — June 4, 2026 — Revocation-Based Offline Validation

The biggest change: the scanner no longer downloads a list of *all valid tickets*. It downloads a list of *revoked* tickets, and accepts anything not on it. This inverts the data flow and shrinks the offline payload by ~98%.

| Change | Before (v1) | After (v2) |
|---|---|---|
| Offline data | Manifest of all valid tickets (~2MB for 50K) | Revocation list of bad tickets (~42KB typical) |
| "Is this ticket valid?" check | Scanner: "is this ticket in my valid set?" | Scanner: "is this ticket in my revocation list?" |
| Token signing | HMAC-SHA256 (shared secret) | Ed25519 (asymmetric, public key on scanner) |
| New ticket scanned | Must wait for manifest delta | Works immediately (token signature proves validity) |
| Transferred ticket | Old version rejected because manifest shows newer version | Old version rejected because added to revocation list |
| Refunded ticket | Removed from valid set in manifest | Added to revocation list with `is_dead: true` |

Everything else — versioning, multi-day policies, fraud layers, conflict resolution — carries forward with minor adjustments.

### v1 — May 17, 2026

Initial design using a manifest of all valid tickets. Worked, but pushed too much state to the scanner.

---

## v3.4 AUTHORITATIVE PACKAGE/CREDENTIAL CONTRACT

This section supersedes older one-ticket/one-QR examples wherever they conflict. Older Ed25519, key rotation, device security, delta sync, and privacy guidance remains applicable.

> **Core invariant:** A group/couple ticket is one commercial package, but its access credentials may change from one package QR to multiple individual QRs. Group and delegated credentials are never valid at the same time.

### Identity and payload

`tid` identifies the purchased commercial package. `cid` identifies the exact QR/PNR credential. `v` identifies the package's credential generation.

Group credential:

```json
{
  "kid": "k_2026_q3",
  "cid": "credential-uuid",
  "tid": "commercial-package-uuid",
  "eid": "event-uuid",
  "mode": "group",
  "slots": [1, 2, 3],
  "entry_limit": 3,
  "v": 4,
  "accesses": ["product-access-uuid"],
  "exp": 1784246400,
  "sig": "base64-ed25519-signature"
}
```

Delegated individual credential:

```json
{
  "kid": "k_2026_q3",
  "cid": "credential-uuid",
  "tid": "commercial-package-uuid",
  "eid": "event-uuid",
  "mode": "individual",
  "slots": [2],
  "entry_limit": 1,
  "v": 5,
  "accesses": ["product-access-uuid"],
  "exp": 1784246400,
  "sig": "base64-ed25519-signature"
}
```

The signed access identifiers determine event date/channel and usage policy. Mutable door labels and time windows come from the scanner's versioned schedule snapshot. Offline validation requires `slots` to contain unique positive integers, group mode to satisfy `slots.length == entry_limit`, and individual mode to contain exactly one position with `entry_limit == 1`.

The scanner cannot compare the list with live package rows while disconnected without reintroducing a validity manifest. The Ed25519 signature proves the server authorized the positions when it issued the credential. Server reconciliation resolves `(tid, slot_position)` and verifies that the signed set matches the package's immutable admission slots. Disabling or reallocating a slot requires a newer credential generation and revocation of the old one.

Credential UUIDs and PNRs are never reused. Reissuing a credential always creates a new `cid` and lookup code even when the package remains in the same delegated generation.

### Server records

The authoritative records are:

- `ticketing_tickets`: commercial package, buyer/owner, current credential mode/version, refund state;
- `ticketing_admission_slots`: fixed positions `1..admissions_per_unit`;
- `ticketing_credential_generations`: immutable group/delegated generations, one active per package;
- `ticketing_credentials`: exact `cid`, PNR, generation, signed slot positions, holder, and revocation state;
- `ticketing_credential_claims`: recipient invitation/acceptance without commercial ownership transfer;
- `ticketing_admission_uses`: successful slot plus product-access consumption;
- `ticketing_admission_use_reversals`: append-only manager correction and event-versioned scanner delta;
- `ticketing_checkin_logs`: append-only attempts referencing the exact credential;
- `ticketing_scan_uploads`: device-scoped batch idempotency;
- `ticketing_ticket_suspensions`: append-only temporary review cases whose active projection is published in the package-revocation feed;
- `marketplace_resale_listings`: whole-package sale intent and the sole active/reserved checkout projection;
- `marketplace_resale_sales`: immutable completed acquisition/ownership history that drives the credential transition but remains outside scanner payloads;
- event access zones plus product-access and scanner-assignment zone mappings;
- ticket-generation and credential-UUID revocation feeds.

Core invariants:

```text
UNIQUE(ticket_id, generation.version)
UNIQUE(event_id, credential.lookup_code)
UNIQUE(admission_slot_id, product_access_id, usage_number)
UNIQUE(admission_use_reversal.admission_use_id)
UNIQUE(checkin_log.client_scan_id)
UNIQUE(scanner_device_assignment_id, scan_upload.client_upload_id)
UNIQUE(ticket_suspension.idempotency_key)
```

A PostgreSQL partial unique index permits only one `ticketing_ticket_suspensions` row with `status = 'active'` per package.

Executable PostgreSQL partial unique indexes:

```sql
CREATE UNIQUE INDEX idx_one_active_generation_per_ticket
ON ticketing_credential_generations (ticket_id)
WHERE status = 'active';

CREATE UNIQUE INDEX idx_one_package_credential_per_generation
ON ticketing_credentials (credential_generation_id)
WHERE type = 'package';

CREATE UNIQUE INDEX idx_one_individual_credential_per_slot
ON ticketing_credentials (credential_generation_id, admission_slot_id)
WHERE type = 'individual';
```

Rails migration equivalents:

```ruby
add_index :ticketing_credential_generations,
  :ticket_id,
  unique: true,
  where: "status = 'active'",
  name: "idx_one_active_generation_per_ticket"

add_index :ticketing_credentials,
  :credential_generation_id,
  unique: true,
  where: "type = 'package'",
  name: "idx_one_package_credential_per_generation"

add_index :ticketing_credentials,
  [:credential_generation_id, :admission_slot_id],
  unique: true,
  where: "type = 'individual'",
  name: "idx_one_individual_credential_per_slot"
```

`Ticketing::Credential` declares `self.inheritance_column = nil`. Because `cid` is its never-reused UUID primary key, `UNIQUE(cid, version)` would be redundant. `UNIQUE(ticket_id, active_credential)` would be wrong because delegated mode intentionally has several active credentials.

The indexes prevent duplicate rows. They cannot prove that a group generation has exactly one package credential or that a delegated generation covers every slot. The locked transition service creates the complete set, and a deferred PostgreSQL constraint trigger verifies the mode/cardinality/no-mixed-mode invariant at transaction commit.

### Mode transitions

The first delegation performs one transaction:

1. lock package, active generation, every slot, and affected current-date uses;
2. reject the change if any slot was already used for an affected currently open access/date;
3. revoke the group generation and publish `(tid, v)` revocation;
4. increment the package version;
5. create a delegated generation with one credential per slot;
6. create recipient rows as `pending_claim` with no QR/PNR until acceptance; activate buyer-retained credentials immediately;
7. replace attendee-index entries and write audit/outbox events;
8. commit before delivering credentials.

Cancelling delegation follows the reverse transaction: revoke every individual credential/generation, increment version, and create a completely new group credential. No earlier QR or PNR is reactivated. Prior closed-date slot uses remain; the new credential applies only to remaining valid accesses.

Operational multi-day rule:

- block delegation or cancellation when any affected slot was used for the currently open access/date;
- usage on a closed past date does not block a mode change for future dates;
- a new generation never deletes or restores a previously recorded admission use;
- every still-valid future product access remains available in the new generation;
- refunded, cancelled, closed, or otherwise unavailable accesses are excluded.

Reassigning one slot while remaining delegated revokes that `cid` and creates a pending-claim row with a new never-reused `cid` for the same slot. Acceptance signs that `cid`, creates its PNR/index row, and activates it. It does not reactivate the group QR or grant the recipient resale/refund rights.

A pending claim is not a bearer credential: it has no signed QR or lookup code and is absent from the attendee index. Recipient acceptance atomically binds the intended user, creates the never-reused QR/PNR, marks the credential active, and publishes its index row. This prevents an authentic-but-not-yet-claimed token from being accepted by an offline revocation-list scanner.

### Product transfer and entry-validation policy

Transfers are allowed only when the ticket product is transferable and both initiation and acceptance occur before its effective cutoff. The product stores a nonnegative `transfer_cutoff_seconds_before_start`; `0` is the default and means the applicable event/session start. A selected-session product uses that session. A multi-date pass uses its earliest covered non-cancelled session. The current schedule is evaluated each time, so rescheduling moves the boundary and a pending transfer cannot preserve an earlier cutoff.

Transfers are free at launch and may occur sequentially without a lifetime count limit. Only one transfer may be pending per package. Initiation and acceptance are rate-limited and fully audited; rate limiting is abuse protection, not a hidden ownership rule.

Buyer delegation, cancellation of delegation, and slot reassignment use the same cutoff. After cutoff, only an authorized event manager may override it through an online server transaction with a required reason and while all affected current-access slots remain unused. The resulting old/new credentials are online-required until active scanner assignments acknowledge the new revocation and attendee-index versions; offline gate staff cannot perform the override.

Entry validation has two product modes:

- `qr` (default): the signed QR/PNR, revocation, access-window, and slot-use checks determine admission;
- `qr_and_id`: all QR checks still apply, then staff visually matches a presented photo ID to the credential-index holder name.

ID matching is a human decision, not automated document verification. The scanner records `matched` or `mismatch` plus the authenticated operator. It never photographs, scans, or stores an ID number, barcode, image, or OCR result. A mismatch creates a failed check-in attempt and no admission use unless an authorized event manager approves an online override with a required reason. The server revalidates authority, credential freshness, access, slot use, and idempotency before recording a successful admission; offline overrides are forbidden.

For a group credential, the displayed identity is the package holder and the group must arrive together. If an organizer needs one identity check per attendee, the product must use delegated individual credentials. Holder names are omitted from signed QR claims and public APIs; only authorized scanner/help-desk indexes receive them for `qr_and_id` products.

The authenticated credential holder may correct the operational holder name through OTP-verified self-service before the shared cutoff. General profile-name edits do not silently change issued credentials. After cutoff, only an authorized event manager may correct it online with a required reason. An idempotent correction command locks the credential, treats an unchanged normalized value as a no-op, updates the encrypted credential name, and publishes one attendee-index delta. It leaves `cid`, QR, PNR, slots, and generation version unchanged because the name is not a signed claim. Audit records actor/reason and the correction event without retaining old plaintext names.

An event may optionally enable named venue/parking access zones. The signed credential continues to claim stable product-access IDs; the scanner's versioned local policy maps those accesses to allowed zones and separately maps its device assignment to operational zones. Both must contain the selected zone. Events with no zones use the implicit general entrance. Zone checks do not model seats, rows, or reserved inventory.

Package transfer carries all access IDs defined directly on the ticket product, including included stream or parking rights. It never carries separately purchased add-on order items merely because they share an order.

### Complimentary issuance, walk-up sale, and organizer cancellation

Complimentary organizer issuance creates a normal confirmed zero-charge registration and the same package/credential records as any other ticket. Walk-up sale creates a normal digital order marked with the walk-up channel and accepts only a supported connected mobile-money/card payment. Neither path changes the QR format or scanner authorization algorithm.

A credential created at the gate is online-required for its first admission until the scanner assignment has acknowledged the attendee-index and revocation versions published by fulfillment. This avoids rejecting a legitimate new PNR from a stale index and prevents a staff device from treating an unacknowledged sale as durable offline authority. Cash/till sales are not part of the launch design.

An organizer may permanently revoke a financially free package with a reason, including a complimentary issue of an otherwise paid public product. Cancelling an unused package backed by an accepted buyer payment immediately suspends access and creates its applicable refund workflow; `is_dead` is published only after refund success. Suspected fraud publishes `is_suspended = true` without changing ownership, payment, or refund state. Review resolution either restores it through a newer delta, permanently revokes a financially free package, or completes refund-backed paid cancellation.

Suspension is freshness data. A disconnected scanner that has not received the latest suspension may accept the old credential, while a scanner that has not received a later restoration may conservatively reject it. High-risk events must require online validation during review and scanners must synchronize before gates open.

### Registration forms, consent, and purchase limits are upstream of QR issuance

Registration form responses and consent acceptances authorize a registration workflow, not gate entry. Questions may target the registration or stable `(package_unit_number, admission_position)` coordinates later linked to admission slots, but their answers remain encrypted server-side. They are excluded from signed QR claims, PNR lookup rows, attendee-index downloads, scan uploads, and operator screens. A scanner needs only the minimal holder data already required by the ticket product's entry-validation policy.

Buyer purchase terms must be complete before checkout/confirmation. When a ticket product requires attendee-signed personal consent, an unassigned or unaccepted slot leaves its credential `pending_requirements`. That state has no signed QR token, lookup code, or attendee-index row. A group credential activates only after all covered slots are clear; delegated credentials activate independently. Reassignment invalidates the old subject's authorization and requires the replacement attendee to accept the current document version before activation.

Retention expiry never changes a credential already validly issued. The server erases expired answer/evidence payloads according to platform policy while retaining only allowed structural tombstones; QR signatures, package ownership, admission uses, and revocation history remain independent.

The purchase-limit service serializes the verified user/product/date scope and reserves one allocation per package unit in the same transaction as inventory. Only confirmed/free or accepted-payment fulfillment may issue credentials. By the time a `cid` exists, the limit decision is complete; offline scanners neither know nor enforce per-user buying limits. A later whole-package refund may release the server-side allowance without changing historical scan records.

### Scanner validation algorithm

QR input and PNR/manual lookup both produce the same credential claims and call this validator:

```ruby
def validate_credential(payload, product_access, assignment:, access_zone: nil, now:, identity_check: nil)
  return :invalid_signature unless verify_ed25519(payload)
  return :wrong_event unless payload[:eid] == product_access.event_id
  return :wrong_access unless payload[:accesses].include?(product_access.id)
  return :outside_window unless product_access.open_at <= now && now <= product_access.close_at

  if ProductAccessZone.local_any?(product_access.id)
    return :zone_required unless access_zone
    return :wrong_zone unless ProductAccessZone.local_exists?(product_access.id, access_zone.id)
    return :wrong_zone unless ScannerAssignmentZone.local_exists?(assignment.id, access_zone.id)
  else
    return :wrong_zone if access_zone
  end

  package_revocation = PackageRevocation.local_find(payload[:tid])
  return :package_dead if package_revocation&.is_dead
  return :package_suspended if package_revocation&.is_suspended
  if package_revocation && payload[:v] <= package_revocation.revoked_through_version
    return :revoked_generation
  end
  return :revoked_credential if CredentialRevocation.local_exists?(payload[:cid])

  slots = Array(payload[:slots])
  return :invalid_claims unless slots.present?
  return :invalid_claims unless slots.all? { |position| position.is_a?(Integer) && position.positive? }
  return :invalid_claims unless slots.uniq.length == slots.length

  case payload[:mode]
  when "group"
    return :invalid_claims unless slots.length == payload[:entry_limit]
  when "individual"
    return :invalid_claims unless slots.length == 1 && payload[:entry_limit] == 1
  else
    return :invalid_claims
  end

  identity_result = "not_required"
  identity_checked_by_id = nil
  if product_access.entry_validation_mode == "qr_and_id"
    index_entry = AttendeeLookup.find_by(credential_id: payload[:cid])
    return :identity_data_unavailable unless index_entry&.holder_name.present?
    return :identity_check_required unless identity_check

    identity_result = identity_check.result
    identity_checked_by_id = identity_check.operator_user_id
    return :invalid_identity_check unless %w[matched mismatch].include?(identity_result)
    return :invalid_identity_check unless identity_checked_by_id.present?
    unless identity_result == "matched"
      return ScanRecorder.record_identity_mismatch!(
        payload: payload,
        product_access: product_access,
        operator_user_id: identity_checked_by_id,
        scanned_at: now
      )
    end
  end

  LocalDatabase.immediate_transaction do
    usage_claims = slots.map do |slot_position|
      active_count = LocalAdmissionUse.active_count(
        ticket_id: payload[:tid],
        slot_position: slot_position,
        product_access_id: product_access.id
      )
      if product_access.usage_limit && active_count >= product_access.usage_limit
        raise LocalAdmissionUse::LimitReached
      end
      next_number = LocalAdmissionUse.max_usage_number(
        ticket_id: payload[:tid],
        slot_position: slot_position,
        product_access_id: product_access.id
      ) + 1
      [slot_position, next_number]
    end

    scan = LocalScan.insert_once!(
      client_scan_id: SecureRandom.uuid,
      credential_id: payload[:cid],
      ticket_id: payload[:tid],
      credential_version: payload[:v],
      product_access_id: product_access.id,
      access_zone_id: access_zone&.id,
      identity_check_result: identity_result,
      identity_checked_by_id: identity_checked_by_id,
      scanned_at: now,
      result: "success"
    )
    usage_claims.each do |slot_position, usage_number|
      LocalAdmissionUse.insert_once!(
        ticket_id: payload[:tid],
        slot_position: slot_position,
        product_access_id: product_access.id,
        usage_number: usage_number,
        scan_id: scan.id
      )
    end
  end

  { result: :success, admit: slots.length }
rescue LocalAdmissionUse::LimitReached
  :already_used
end
```

`record_identity_mismatch!` is terminal for the offline validator and creates no local admission use. If the attendee requests an exception, the scanner first uploads that mismatch and sends its stored `client_scan_id` to the online manager-override endpoint. The server locks the original check-in and slots, verifies manager authority and a nonblank controlled reason, and reruns the current credential/revocation/access/usage checks. It never edits the mismatch: it idempotently appends one linked `success` check-in, preserves `identity_check_result = 'mismatch'`, records override actor/reason/time, and creates the admission uses. A unique `overrides_checkin_log_id` allows only one successful override of the failed attempt; retries return that same result.

For a three-day pass, Friday access, Saturday access, and Sunday access are different `product_access_id` values. A Friday group scan consumes all package slots for Friday only. Each slot remains available for Saturday and Sunday. In delegated mode, each individual credential consumes only its slot for that date/access.

Venue and parking access default to `usage_limit = 1`. An organizer may explicitly choose a larger positive bound or null for unlimited re-entry. The immediate local transaction allocates the next ordinal atomically for every affected slot; a group scan fails as a unit if any slot reached its bound. Server reconciliation repeats the allocation under deterministic slot locks and remains authoritative when disconnected scanners select conflicting ordinals.

### Idempotent server reconciliation

Every upload carries `client_upload_id`; every nested scan carries `client_scan_id`. Retrying either returns stored results.

```ruby
def process_offline_upload(assignment:, client_upload_id:, scans:)
  existing = ScanUpload.find_by(
    scanner_device_assignment: assignment,
    client_upload_id: client_upload_id
  )
  return existing.serialized_results if existing&.completed_at?

  ScanUpload.transaction do
    upload = ScanUpload.lock.find_or_create_by!(
      scanner_device_assignment: assignment,
      client_upload_id: client_upload_id
    )

    results = scans.map do |scan|
      prior = CheckinLog.find_by(client_scan_id: scan.fetch(:client_scan_id))
      next prior.serialized_result if prior

      reconcile_one_scan!(assignment: assignment, upload: upload, scan: scan)
    end

    upload.update!(completed_at: Time.current, results_snapshot: results)
    results
  end
end
```

Server reconciliation validates signed positions against package slots, locks them deterministically, and rechecks package/generation/credential revocations. For every slot it counts successful uses without a reversal, applies the configured active-use ceiling, and writes `MAX(usage_number) + 1`; the first normal single-entry use is therefore `1`. Reversed rows remain in that maximum but not in the active count. Explicit unlimited access skips only the ceiling. A group scan succeeds only if every required slot can be consumed atomically; it never partially admits a group.

### Mistaken admission reversal

Only an authenticated event manager may reverse a successful use, and the command is online-only. The server locks the original successful check-in and every use it created, requires a controlled reason, and appends one reversal row per use under a shared idempotent group ID and event reversal version. A group credential's scan is reversed as a whole. Original check-ins/uses are never edited or deleted.

Reversal restores allowance by reducing the active-unreversed count; it never reuses a historical `usage_number`. The next admission receives the next sequence. Scanner deltas identify authoritative server-use IDs and are applied transactionally before advancing `admission_use_reversal_version`. A disconnected scanner missing that delta may continue rejecting the attendee, but cannot incorrectly invent an extra allowance.

### PNR/manual lookup

The attendee index is credential-based:

- group mode: one row with `cid`, `tid`, all signed slot positions, mode `group`, and package entry limit;
- delegated mode: one row per slot credential with `cid`, `tid`, a one-position slots array, mode `individual`, and entry limit `1`;
- `qr_and_id` product: include the minimum holder name and validation mode needed for visual comparison; `qr` product: omit the name;
- mode switch: publish old generation/credential revocations before applying new index rows;
- recipient reassign: remove old PNR row and add the new `cid`/PNR row;
- package refund: mark `tid` dead and remove every active index row.

Manual lookup never bypasses credential validation. It resolves a signed/indexed claim set and runs the same revocation and slot-use checks as a camera scan.

### Honest offline limitation

Ed25519 proves that a credential was issued by the platform; it cannot prove to a disconnected scanner that the credential is still current. A scanner that has not received the latest generation or credential revocation may temporarily accept an old group QR or reassigned individual QR. Two disconnected scanners may also accept conflicting old/new credentials before server reconciliation.

Required mitigations:

- synchronize signing keys, package/generation revocations, credential revocations, attendee-index deltas, and schedule/access versions before opening a gate;
- include access-zone mappings in the schedule/access version and admission-use reversals in their own event delta version;
- apply revocations atomically before activating newly downloaded credential-index rows;
- continuously pull deltas while connected and return them with every scan upload;
- block offline session start when required versions are stale;
- use `online_required` delegated validation for high-security products/events;
- prohibit delegation/cancellation after a slot was used for an affected currently open date/access.

Missing a reversal delta fails conservatively—the stale scanner may still say `already_used`. Missing a newly restrictive zone-policy delta is different: zone policy freezes while offline gates operate. An emergency change increments the schedule version and requires affected scanners to reconnect and acknowledge it before continuing.

First-scan-wins limits damage but does not eliminate this freshness window. Server reconciliation determines the authoritative winner and flags the conflict for operations.

---

## PROBLEM INVENTORY

| # | Problem | Severity | Complexity |
|---|---------|----------|------------|
| 1 | Ticket invalidation on resale/transfer | Critical | High |
| 2 | Offline scanning (venue network failure) | Critical | High |
| 3 | Multi-day event entry (same QR, multiple days) | High | Medium |
| 4 | Screenshot/forwarding fraud | High | Medium |
| 5 | Counterfeit QR generation | Critical | Low |
| 6 | Replay attack (used ticket re-scanned) | Critical | Medium |
| 7 | Scanner device compromise | Medium | High |
| 8 | Large event scale (50K+ attendees) | Medium | Medium |
| 9 | Time sync issues on offline scanners | Low | Low |
| 10 | Partial network (some scanners online, some offline) | Medium | Medium |
| 11 | **Manual validation without QR (phone dead, QR lost, no printout)** | **High** | **Medium** |

---

## CORE DESIGN PRINCIPLES

1. **The QR is a signed token, not a database ID** — it carries enough information to validate offline
2. **Versioned tickets** — every transfer/resale increments a version, invalidating old QRs
3. **Revocation-based offline sync** — scanners download a small list of *invalidated* tickets; everything else is assumed valid (proven by the token signature)
4. **First-scan-wins** — if two people present the same QR, the first scan succeeds, the second fails
5. **Graceful degradation** — offline mode works, syncs when network returns, resolves conflicts
6. **Asymmetric signing** — server holds the private key, scanners hold only the public key. A compromised scanner cannot forge QRs.
7. **Manual lookup with minimal PII** — scanners can validate by PNR code (primary, genuinely PII-free) or phone hash (fallback, low PII risk — see §3B privacy note). PNR codes are opaque and unique per ticket. Phone hashes are SHA-256 of E.164-normalized numbers, limited to gate-lead devices where possible.

---

## 1. QR TOKEN FORMAT

The QR contains the commercial package UUID and exact credential UUID only inside a **cryptographically signed JSON token** (compact, URL-safe):

```json
{
  "kid": "k_2026_q2",
  "cid": "credential-uuid",
  "tid": "550e8400-e29b-41d4-a716-446655440000",
  "eid": "event-uuid",
  "v": 3,
  "mode": "individual",
  "slots": [2],
  "entry_limit": 1,
  "product": "vip-group-of-3",
  "accesses": ["product-access-uuid"],
  "exp": 1718668800,
  "sig": "a1b2c3d4e5f6..."
}
```

| Field | Purpose | Example |
|-------|---------|---------|
| `kid` | Key ID — identifies which signing key was used (for rotation) | `"k_2026_q2"` |
| `cid` | Exact never-reused credential ID (UUID) | `"credential-uuid"` |
| `tid` | Purchased commercial package ID (UUID) | `"550e8400-..."` |
| `eid` | Event ID (UUID) | `"event-uuid"` |
| `v` | Package credential-generation version | `3` |
| `mode` | Credential mode | `"group"` or `"individual"` |
| `slots` | Explicit unique positive admission-slot positions | `[2]` |
| `entry_limit` | People admitted together; package size for group, `1` for individual | `1` |
| `product` | Product label/slug snapshot | `"vip-group-of-3"` |
| `accesses` | Stable allowed product-access UUIDs | `["product-access-uuid"]` |
| `exp` | Expiration timestamp (epoch) | `1718668800` |
| `sig` | Ed25519 signature (64 bytes, base64-encoded) | `"a1b2c3..."` |

### Signature (Ed25519, asymmetric)

```ruby
# app/services/platform/qr_service.rb
module Core
  class QrService
    SIGNING_KEYS = {
      "k_2026_q2" => OpenSSL::PKey.read(ENV.fetch("QR_SIGNING_KEY_K_2026_Q2")),
      "k_2026_q1" => OpenSSL::PKey.read(ENV.fetch("QR_SIGNING_KEY_K_2026_Q1")) # grace period
    }.freeze

    def self.generate_token(credential)
      generation = credential.credential_generation
      ticket = credential.ticket
      payload = {
        kid: current_kid,
        cid: credential.id,
        tid: ticket.id,
        eid: ticket.event_id,
        v: generation.version,
        mode: generation.group? ? "group" : "individual",
        slots: credential.slot_positions,
        entry_limit: credential.entry_limit,
        product: ticket.event_product.slug,
        accesses: ticket.event_product.product_accesses.ids,
        exp: ticket.event.ends_at.to_i
      }

      signed = payload.merge(sig: Base64.strict_encode64(sign_payload(payload)))
      Base64.urlsafe_encode64(signed.to_json, padding: false)
    end

    # Public signing helper — used by generate_token and by dynamic-QR code
    # that needs to sign a custom payload (e.g., with a nonce). Always returns
    # a raw Ed25519 signature; callers must base64-encode and attach as :sig.
    def self.sign_payload(payload)
      SIGNING_KEYS[current_kid].sign(nil, canonical_json(payload))
    end

    def self.verify_token(token_string)
      decoded = JSON.parse(Base64.urlsafe_decode64(token_string), symbolize_names: true)
      key = SIGNING_KEYS[decoded[:kid]]
      return nil unless key # unknown key id

      signature_b64 = decoded[:sig]
      return nil unless signature_b64

      signature = Base64.strict_decode64(signature_b64)

      payload_without_sig = decoded.dup
      payload_without_sig.delete(:sig)
      payload_json = canonical_json(payload_without_sig)

      return nil unless key.verify(nil, signature, payload_json)
      return nil if decoded[:exp] < Time.current.to_i

      decoded
    rescue
      nil
    end

    # RFC 8785-style canonical JSON: sorted keys, no whitespace, deterministic bytes.
    # Both generate_token and verify_token MUST use this so the signed bytes match
    # exactly across processes, Ruby versions, and JSON library configurations.
    def self.canonical_json(hash)
      sorted_pairs = hash.map { |k, v| [k.to_s, canonicalize_value(v)] }.sort_by(&:first)
      JSON.generate(sorted_pairs.to_h)
    end

    def self.canonicalize_value(value)
      case value
      when Hash  then JSON.parse(canonical_json(value))
      when Array then value.map { |v| canonicalize_value(v) }
      else value
      end
    end

    def self.current_kid
      SIGNING_KEYS.keys.first # newest first
    end

    def self.public_keys_for_scanner
      SIGNING_KEYS.transform_values { |k| Base64.strict_encode64(k.public_to_der) }
    end
  end
end
```

**Three correctness notes on this code:**

1. **Ed25519 takes `nil` for the digest slot, not a digest name string.** Ed25519 is PureEdDSA — the signature is computed over the data directly with no pre-hash. Passing `"Ed25519"` as a digest name will raise `OpenSSL::PKey::PKeyError`. The Ruby OpenSSL docs are explicit: for Ed25519/Ed448 keys, the digest argument is `nil`.

2. **Both `generate_token` and `verify_token` go through `canonical_json`.** Ed25519 signs exact bytes. If the signed bytes on generate differ from the bytes on verify by even one space, verification fails. Default `Hash#to_json` happens to be deterministic in current Ruby, but it depends on Hash insertion order, JSON.parse preserving order, and no whitespace in `JSON.generate`. Any of those assumptions can break across Ruby versions or with a configured JSON backend. `canonical_json` removes that fragility by always producing sorted keys with `JSON.generate` (which emits no whitespace).

3. **`payload.merge(sig: ...)` is non-mutating.** Avoids the side effect of mutating the original `payload` hash — safer if `payload` is ever passed around or memoized.

**Why Ed25519 over HMAC-SHA256 (v1's choice):**

| Property | HMAC-SHA256 (v1) | Ed25519 (v2) |
|---|---|---|
| Key in scanner app | Shared secret (32 bytes) — same as server | Public key only — server keeps private |
| Scanner compromise | Attacker can forge QRs for *all* events | Attacker can verify but not forge |
| Signature size | 32 bytes (binary) | 64 bytes (binary) |
| Key rotation | One global secret — rotate = invalidate every QR | Per-key-id rotation with grace period |
| Verification speed | ~1µs | ~50µs (still fast) |

The signature-size increase (32→64 bytes) makes the QR slightly denser. After base64 + JSON wrapping, the token is ~280 bytes total — still well within scannable QR range (Version 25-30).

**Why this still works:**
- The signature proves authenticity (only the server can sign valid QRs)
- The version (`v`) combined with the revocation list proves currency (old versions are explicitly rejected)
- The payload is self-contained — offline scanners can validate the *signature* without a database lookup
- The revocation list (separately downloaded) handles *currency* — what was once valid but isn't anymore

---

## 2. PACKAGE GENERATIONS AND CREDENTIAL INVALIDATION

The commercial package owns current commercial ownership, access, transfer, and package-level refund state; immutable primary/resale acquisitions own their own price, payment, and refund relationships. Credentials are replaceable access representations beneath the package.

Three revocation checks protect every scan:

1. **Package-dead (`tid`)** rejects every credential after package refund/cancellation.
2. **Generation (`tid`, `v`)** rejects all credentials from an older group/delegated generation after a mode switch, package transfer, or date-policy reissue.
3. **Credential (`cid`)** rejects one individual credential after slot reassignment without disturbing other credentials in the delegated generation.

Mode changes and package ownership transfers increment the package's credential generation. Reassigning a single delegated slot creates a new `cid` in the same generation and publishes a credential-level revocation. No old QR/PNR is ever reactivated.

| Scenario | Server action | Scanner result after sync |
|---|---|---|
| Group package delegates one slot | Revoke generation 1; create version 2 with one individual credential per slot | Group QR v1 rejected; only v2 individual credentials work |
| Buyer cancels delegation | Revoke generation 2; create new group generation 3 | Every delegated QR rejected; only new group QR works |
| Buyer reassigns slot 2 | Revoke old slot-2 `cid`; issue new `cid`/PNR in same generation | Old recipient rejected; other delegated slots unaffected |
| Whole package transferred | Revoke active generation; change owner; issue new group generation | Every old-owner/delegated credential rejected |
| Resale checkout reserved | Revoke seller generation; publish temporary package suspension; expose no active seller credential | Seller QR/PNR/manual lookup rejected after sync while payment is pending |
| Resale payment accepted | Change owner/acquisition; clear temporary suspension; issue new buyer group generation | Only the buyer's new credential is accepted |
| Resale checkout fails/expires | Keep seller ownership; clear temporary suspension only after issuing a newer seller group generation | Old seller credential remains rejected; only newly issued seller credential works |
| Package refunded | Mark `tid` dead and remove active index entries | Every generation and credential rejected |
| Fraud review opened | Set package `is_suspended`; retain ownership/payment/index history | Every credential rejected until a newer restore/resolution delta |
| Fraud review cleared | Clear `is_suspended` only if package is otherwise active | Current generation becomes usable again; old generations remain revoked |
| Required personal waiver incomplete | Keep affected credential `pending_requirements`; issue no QR/PNR/index row | Nothing exists for offline scanners to accept |
| Replacement attendee accepts waiver | Activate/sign/index the current credential in one transaction | Credential appears through the normal attendee-index delta |
| Screenshot reused | Same `cid` and slot/access usage key presented twice | First scan wins; duplicate rejected |

Revocation is freshness data. A signed old QR can still pass on a disconnected scanner that has not synchronized the revocation; Section v3.4 documents mandatory mitigations and reconciliation.

---

## 3. OFFLINE SCANNING ARCHITECTURE

### The Problem

Venue network fails. 500 people are in line. Scanners can't reach the server. Tickets must still be validated.

### The Solution: Revocation-Based Offline Sync

The scanner downloads a *small* list of revoked tickets (typically ~1KB-40KB). It accepts any signed token that isn't on this list.

#### Step 1: Revocation List Generation (Server-Side)

```ruby
# app/services/platform/revocation_service.rb
module Core
  class RevocationService
    def self.revoke_version(ticket, through_version:)
      revocation = Revocation.find_or_initialize_by(ticket_id: ticket.id)
      revocation.revoked_through_version = [
        revocation.revoked_through_version || 0,
        through_version
      ].max
      revocation.is_dead ||= false
      revocation.is_suspended ||= false
      revocation.save!
      bump_revocation_version!(ticket.event)
    end

    def self.mark_dead(ticket)
      revocation = Revocation.find_or_initialize_by(ticket_id: ticket.id)
      revocation.revoked_through_version = ticket.credential_version
      revocation.is_dead = true
      revocation.is_suspended = false
      revocation.save!
      bump_revocation_version!(ticket.event)
    end

    def self.suspend(ticket)
      revocation = Revocation.find_or_initialize_by(ticket_id: ticket.id)
      raise "dead package" if revocation.is_dead
      revocation.revoked_through_version ||= 0
      revocation.is_suspended = true
      revocation.save!
      bump_revocation_version!(ticket.event)
    end

    def self.restore(ticket)
      revocation = Revocation.find_by!(ticket_id: ticket.id)
      raise "dead package" if revocation.is_dead
      revocation.update!(is_suspended: false)
      bump_revocation_version!(ticket.event)
    end

    def self.unrevoke(ticket)  # only for reversed transfers
      revocation = Revocation.find_by(ticket_id: ticket.id)
      return unless revocation
      # We don't remove permanent or active-review package state.
      return if revocation.is_dead || revocation.is_suspended
      revocation.destroy!
      bump_revocation_version!(ticket.event)
    end

    def self.list_for_event(event, since_version: nil)
      revocations = event.revocations
      if since_version
        revocations = revocations.where("revocation_version > ?", since_version)
      end
      {
        revocation_version: event.current_revocation_version,
        revocations: revocations.map { |r| {
          tid: r.ticket_id,
          revoked_through_version: r.revoked_through_version,
          is_dead: r.is_dead,
          is_suspended: r.is_suspended
        }}
      }
    end

    def self.changes_since(event, since_version)
      current_version = event.current_revocation_version
      return { revocation_version: current_version, changes: { added: [], removed: [] } } if since_version >= current_version

      {
        revocation_version: current_version,
        changes: {
          added: list_for_event(event, since_version: since_version)[:revocations],
          removed: removed_since(event, since_version)  # unrevoke events
        }
      }
    end

    def self.bump_revocation_version!(event)
      Event.where(id: event.id).update_all(
        "revocation_version = revocation_version + 1, updated_at = NOW()"
      )
    end
  end
end
```

#### Bulk Operation: Event Postponement

Event postponement is the same generation-reissue pattern applied to every active commercial package. The active group/delegated mode is preserved, the old generation is revoked, and a replacement generation is signed with the new product-access IDs. Scanners receive one bulk revocation/index delta and apply revocations before additions.

The postponement service must use the canonical schedule-change and credential-generation services. In one durable operation it:

1. records the replacement schedule without deleting historical schedule facts;
2. locks each affected commercial package;
3. revokes its active credential generation;
4. creates the next generation in the same group/delegated mode, preserving slot assignment and historical uses;
5. signs credentials with the replacement product-access claims and explicit slot positions;
6. reserves a bulk revocation/index version and publishes the delta after commit; and
7. asynchronously notifies holders that replacement credentials are available.

No QR, PNR, holder, or credential version is written to `ticketing_tickets`.

**Why this works without changing the scanner algorithm:**

- A token with the old access claims belongs to a revoked generation and is rejected.
- A token from the replacement generation has the new access claims and passes when otherwise valid.
- The user's app receives the new QR (via push or fetch on next open) and displays it. The user has no action to take.

**Sizing:** For a 50K-ticket event, the postponement delta is ~50K entries × 40 bytes = ~2MB. Larger than the typical 42KB but still small for a planned, announced-in-advance operation. All entries share one `revocation_version`, so scanners apply them as a single atomic update.

**If you need to optimize:** an "event-level revocation" entry can replace the per-ticket entries — one row saying "reject all tokens in event X with version < N." 40 bytes instead of 2MB. Trade-off: the scanner needs a second lookup pattern. Not worth the complexity in v2; revisit if postponements become frequent or event sizes exceed 200K tickets.

#### Step 2: Revocation List Download (Scanner App)

Scanners download the revocation list before the event starts (and pull deltas throughout):

```
GET /api/v1/scanner/events/:event_id/revocations
Headers:
  Authorization: Bearer <device_token>
  X-Scanner-Version: 0   # 0 = send full list; otherwise send delta

Response 200:
{
  "revocation_version": 7,
  "signing_keys": {
    "k_2026_q2": "<base64-pubkey>",
    "k_2026_q1": "<base64-pubkey>"  # grace period
  },
  "revocations": [
    { "tid": "uuid-1", "revoked_through_version": 1 },
    { "tid": "uuid-2", "revoked_through_version": 3, "is_dead": true, "is_suspended": false },
    { "tid": "uuid-3", "revoked_through_version": 0, "is_dead": false, "is_suspended": true }
  ]
}
```

**Delta updates** — same shape, much smaller:

```
GET /api/v1/scanner/events/:event_id/revocations?since=7
Headers:
  X-Scanner-Version: 7

Response 200:
{
  "revocation_version": 8,
  "changes": {
    "added": [
      { "tid": "uuid-99", "revoked_through_version": 1 },
      { "tid": "uuid-100", "revoked_through_version": 2, "is_dead": true, "is_suspended": false }
    ],
    "removed": []
  }
}
```

Typical delta: 0-5 changes, <500 bytes. Worst case (100 transfers in a sync window): ~4KB.

#### Step 3: Local Storage (Scanner Device)

The scanner stores versioned credential, policy, usage, reversal, and scan tables in local SQLite:

```sql
-- The revocation list (the "manifest" — inverted)
CREATE TABLE revocations (
  ticket_id TEXT PRIMARY KEY,
  revoked_through_version INTEGER,  -- reject if token version <= this
  is_dead INTEGER,                  -- 1 = refunded/cancelled (all versions rejected)
  is_suspended INTEGER,             -- 1 = temporary review hold (all credentials rejected)
  received_at INTEGER
);

CREATE TABLE credential_revocations (
  credential_id TEXT PRIMARY KEY,
  reason TEXT,
  received_at INTEGER
);

-- Per-scan log (synced to server later)
CREATE TABLE scans (
  id INTEGER PRIMARY KEY,
  client_scan_id TEXT NOT NULL UNIQUE,
  credential_id TEXT NOT NULL,
  ticket_id TEXT,
  slot_positions TEXT NOT NULL,     -- JSON array from signed claims
  credential_version INTEGER NOT NULL,
  product_access_id TEXT NOT NULL,
  access_zone_id TEXT,
  scanner_id TEXT,
  scanned_at INTEGER,
  result TEXT,                      -- success, already_used, revoked, invalid_signature, ...
  lookup_via TEXT,                  -- "qr", "code", "phone" (how the ticket was found)
  reason_code TEXT,                 -- NEW in v3.1: why manual lookup was used (phone_dead, no_qr, etc.)
  identity_check_result TEXT NOT NULL DEFAULT 'not_required', -- not_required, matched, mismatch
  identity_checked_by_id TEXT,      -- authenticated operator; required for matched/mismatch
  synced INTEGER DEFAULT 0,
  server_scan_id TEXT
);

CREATE TABLE local_admission_uses (
  id INTEGER PRIMARY KEY,
  server_admission_use_id TEXT UNIQUE,
  ticket_id TEXT NOT NULL,
  slot_position INTEGER NOT NULL,
  product_access_id TEXT NOT NULL,
  usage_number INTEGER NOT NULL,
  scan_id INTEGER,
  UNIQUE(ticket_id, slot_position, product_access_id, usage_number)
);
CREATE INDEX idx_local_active_use_scope
  ON local_admission_uses(ticket_id, slot_position, product_access_id);

CREATE TABLE admission_use_reversals (
  admission_use_id TEXT PRIMARY KEY,
  reversal_group_id TEXT NOT NULL,
  reversal_version INTEGER NOT NULL,
  reversed_at INTEGER NOT NULL
);
CREATE INDEX idx_local_reversal_version
  ON admission_use_reversals(reversal_version);

CREATE TABLE access_zones (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL
);

CREATE TABLE product_access_zones (
  product_access_id TEXT NOT NULL,
  access_zone_id TEXT NOT NULL,
  PRIMARY KEY(product_access_id, access_zone_id)
);

CREATE TABLE scanner_assignment_zones (
  scanner_assignment_id TEXT NOT NULL,
  access_zone_id TEXT NOT NULL,
  PRIMARY KEY(scanner_assignment_id, access_zone_id)
);

-- NEW in v3: Dual-lookup index for manual validation
-- Primary key: PNR code (8-char alphanumeric, Crockford Base-32)
-- Secondary: phone hash (SHA-256) for fallback lookup
-- v3.1: added index_version per row for delta sync, owner_phone_hash for group bookings
CREATE TABLE attendee_lookup (
  lookup_code TEXT PRIMARY KEY,        -- PNR code: "X7K2MP9Q"
  phone_hash TEXT,                     -- sha256(holder_phone) — the actual attendee
  owner_phone_hash TEXT,               -- sha256(owner.phone) — the purchaser (for group bookings)
  holder_name TEXT,                    -- present only when qr_and_id policy requires visual matching
  credential_id TEXT NOT NULL,
  ticket_id TEXT NOT NULL,             -- commercial package tid
  slot_positions TEXT NOT NULL,        -- JSON array: all group positions or one individual position
  credential_mode TEXT NOT NULL,       -- group or individual
  entry_limit INTEGER NOT NULL,
  ticket_type TEXT NOT NULL,           -- "vip", "regular", "vvip"
  ticket_type_label TEXT,              -- "VIP - All Access" (human-readable)
  perks TEXT,                          -- JSON array: ["drink","lounge","priority_entry"]
  version INTEGER NOT NULL,
  product_access_ids TEXT NOT NULL,    -- JSON array of stable date/channel access UUIDs
  entry_validation_mode TEXT NOT NULL, -- qr or qr_and_id
  index_version INTEGER NOT NULL,      -- per-row version for delta sync (mirrors revocations.revocation_version)
  received_at INTEGER
);
CREATE INDEX idx_attendee_phone_hash ON attendee_lookup(phone_hash);       -- fallback: attendee's phone
CREATE INDEX idx_attendee_owner_hash ON attendee_lookup(owner_phone_hash); -- fallback: purchaser's phone
CREATE INDEX idx_attendee_ticket ON attendee_lookup(ticket_id);
CREATE UNIQUE INDEX idx_attendee_credential ON attendee_lookup(credential_id);
CREATE INDEX idx_attendee_index_version ON attendee_lookup(index_version); -- delta sync queries

-- Scanner state
CREATE TABLE scanner_state (
  key TEXT PRIMARY KEY,
  value TEXT
);
-- Keys: 'event_id', 'revocation_version', 'last_sync_at', 'signing_key_id',
--        'attendee_index_version', 'schedule_version',
--        'admission_use_reversal_version'
```

`LocalAdmissionUse.active_count` counts local/server-confirmed use rows whose `server_admission_use_id` has no matching reversal row. `max_usage_number` remains monotonic across reversed history. A reversal delta can restore local eligibility only after the original use has a server ID; an unsynced local use cannot be reversed. Zone tables arrive with the versioned schedule/access snapshot, and empty product/assignment mappings never mean “all zones” once zones are enabled.

Size comparison for a 50K-ticket event with 1,000 transfers and 50 refunds:

| v1 (manifest) | v2 (revocation list) | v3 (revocation + lookup) |
|---|---|---|
| 50,000 rows | 1,050 rows | 1,050 + 50,000 rows |
| ~2MB | ~42KB | ~42KB + ~2MB (compressed) |
| Pre-event seed required | Cold-start works in 5 min | Cold-start works in 10 min |

**Still smaller than v1**, and the attendee index is a one-time download before the event. The revocation list (the hot path) remains 42KB. The PNR code column (8 bytes per entry) is 8x smaller than the phone hash column (64 bytes per entry).

#### Step 4: Offline Scan Validation

> **Note on language:** The actual scanner is a mobile-native app (Swift on iOS, Kotlin on Android, or Flutter). The Ruby shown here is the algorithm expressed in the same language as the rest of this document. When implementing in Swift/Kotlin, port the logic line-for-line — the SQLite schema, query patterns, and decision tree are identical.

```ruby
# Scanner app (runs on device, mirrored from mobile-native code)
class Scanner::LocalValidator
  def self.validate(qr_token, product_access, assignment:, access_zone: nil, now: Time.current)
    payload = QrService.verify_token(qr_token)
    return :invalid_signature unless payload
    PackageCredentialValidator.validate_credential(
      payload,
      product_access,
      assignment: assignment,
      access_zone: access_zone,
      now: now
    )
  end
end
```

`PackageCredentialValidator` is the authoritative v3.4 algorithm above. Its package-generation, credential-revocation, and slot-use lookups are indexed and local.

#### Step 5: Sync Scans + Receive Latest Revocations

```ruby
# Background job on scanner device (runs whenever network is available)
class Scanner::SyncWorker
  def self.run(event_id, device_id)
    unsynced = Scan.where(synced: false).limit(500)
    batch = SyncBatch.heartbeat_or_for_scans!(unsynced) # stable client_upload_id across retries

    response = HTTP.post("/api/v1/scanner/events/#{event_id}/scans", json: {
      device_id: device_id,
      client_upload_id: batch.client_upload_id,
      scans: unsynced.map { |s|
        { client_scan_id: s.client_scan_id, credential_id: s.credential_id,
          ticket_id: s.ticket_id, credential_version: s.credential_version,
          product_access_id: s.product_access_id, access_zone_id: s.access_zone_id,
          scanned_at: s.scanned_at,
          result: s.result, lookup_via: s.lookup_via, reason_code: s.reason_code,
          identity_check_result: s.identity_check_result,
          identity_checked_by_id: s.identity_checked_by_id }
      }
    })

    return unless response.success?

    # Mark our scans as synced
    Scan.where(id: unsynced.map(&:id)).update_all(synced: true)

    # Apply any new revocations the server sent back
    apply_revocation_changes(response["revocation_changes"])
    apply_credential_revocation_changes(response["credential_revocation_changes"])
    apply_attendee_index_changes(response["attendee_index_changes"])
    apply_admission_use_results(response["admission_use_results"])
    apply_admission_use_reversals(response["admission_use_reversal_changes"])
    apply_zone_policy_changes(response["zone_policy_changes"])

    # Update local version
    ScannerState.set("revocation_version", response["revocation_version"])
    ScannerState.set("admission_use_reversal_version", response["admission_use_reversal_version"])
  end

  def self.apply_revocation_changes(changes)
    Array(changes["added"]).each do |r|
      Revocation.upsert(
        ticket_id: r["tid"],
        revoked_through_version: r["revoked_through_version"],
        is_dead: r["is_dead"],
        is_suspended: r["is_suspended"]
      )
    end

    Array(changes["removed"]).each do |tid|
      Revocation.where(ticket_id: tid).delete_all  # only happens for unrevoke
    end
  end

  def self.apply_admission_use_reversals(changes)
    Array(changes["added"]).each do |reversal|
      AdmissionUseReversal.upsert(
        admission_use_id: reversal["admission_use_id"],
        reversal_group_id: reversal["reversal_group_id"],
        reversal_version: reversal["reversal_version"],
        reversed_at: reversal["reversed_at"]
      )
    end
  end
end
```

Every scan upload or empty heartbeat receives credential, usage-reversal, zone-policy, and schedule deltas, so a quiet scanner still self-heals. Apply server admission-use IDs before reversal rows, then advance versions only after the whole local transaction commits.

#### Step 6: Conflict Resolution

What if a ticket was scanned offline, but was actually transferred before the scan?

```ruby
# Server-side scan processing
#
# `scanner_revocation_version` is the version the scanner last synced. Used to
# compute the revocation delta returned in the response so the scanner can
# self-heal (apply any revocations it missed while offline).
def process_offline_scans(assignment:, client_upload_id:, scans:, sync_versions:)
  results = process_offline_upload(
    assignment: assignment,
    client_upload_id: client_upload_id,
    scans: scans
  )

  {
    results: results,
    revocation_changes: RevocationService.changes_since(assignment.event, sync_versions[:revocations]),
    credential_revocation_changes: CredentialRevocationService.changes_since(assignment.event, sync_versions[:revocations]),
    attendee_index_changes: AttendeeIndexService.changes_since(assignment.event, sync_versions[:attendee_index])
  }
end
```

---

## 3B. MANUAL ATTENDEE LOOKUP (NEW IN V3)

### The Problem

An attendee arrives at the gate without a QR code. Common reasons:
- Phone died and they only have an SMS confirmation
- Never received the SMS with the ticket link
- Printed ticket was lost/damaged
- App won't load (no connectivity, app crash)
- Group booking: family member has no phone, no QR, just knows their name

In v2, the scanner had **no way** to look up this person. The only option was to send them to a help desk with a laptop that has network access. This creates bottlenecks at the gate and frustrates attendees.

### The Solution: Dual-Path Lookup (PNR Code + Phone Hash)

v3 provides **two offline lookup paths** plus an online fallback:

| Priority | Method | Key | Offline? | Solves |
|---|---|---|---|---|
| 1 | **PNR code** (primary) | 8-char alphanumeric code | Yes | Dead phone, lost QR, group bookings |
| 2 | **Phone hash** (fallback) | SHA-256 of phone number | Yes | Forgot PNR code but remembers phone |
| 3 | **Name search** (last resort) | Server-side fuzzy search | No (online) | Lost everything, help desk only |

### Why PNR Code as Primary (Not Phone Hash)

An earlier version of this doc used phone hashing as the sole offline mechanism. Three problems emerged:

1. **Normalization bugs** — phone formatting is fragile (`0911234567` vs `+251911234567` vs `911234567`). If the server hashes one form and the operator types another with a normalization bug, lookup **silently fails**. A PNR code is exact: type these 8 characters, get a match.

2. **Group/gift bookings** — if Abebe buys 4 tickets on his phone number, all 4 map to the same phone hash. The operator sees 4 results and can't tell which family member is at the gate. Each PNR code is unique per ticket.

3. **SMS survival** — users receive the PNR code in the confirmation SMS ("Your code: X7K2MP9Q"). Even with a dead phone, the code might be in notifications or memorized. A phone number is something they know, but under stress people forget.

Phone hashing remains as a **fallback** for users who forgot their PNR code but remember their phone number. It's not removed — it's demoted from primary to secondary.

### PNR Code Design

| Property | Value | Why |
|---|---|---|
| Length | 8 characters | Seven random characters plus one deterministic check digit; online attempts must be rate-limited. |
| Alphabet | Crockford Base-32 (no O/0, I/1/L ambiguity) | `23456789CFGHJKMNPQRVWX` — 22 usable chars after removing confusing pairs. No typing errors from visual ambiguity. |
| Generation | Cryptographically random per credential | `SecureRandom` from a restricted alphabet. No sequential patterns. |
| Uniqueness | Unique per active or historical credential per event | Database-enforced unique index. Codes are never reused. |
| Display | Shown in SMS, app, email, printout | Always visible to the attendee. |
| Checksum | Last char is a Luhn-mod-`ALPHABET.size` check digit | Catches common typing errors before hitting the index. |

**Effective random keyspace**: `22^7 ≈ 2.49 billion`; the eighth character is deterministic and adds typo detection, not entropy. At 50K credentials, generation collisions are possible but cheap to retry behind the unique index. PNR lookup must be device-authenticated and rate-limited because an 8-character human code is a recovery credential, not a cryptographic secret. Increase the random body length before launch if operational testing shows the human-entry trade-off permits it.

### Step 1: PNR Code Generation (Server-Side)

```ruby
# app/services/core/lookup_code_service.rb
module Core
  class LookupCodeService
    # Crockford Base-32 minus ambiguous characters.
    # Excludes: 0 (zero), 1 (one), O, I, L, U, D (visual confusion)
    ALPHABET = "23456789CFGHJKMNPQRVWX".chars.freeze

    # Generate a unique 8-char PNR code for a credential.
    # The last character is a check digit (Luhn mod N).
    def self.generate(event_id)
      loop do
        code_body = generate_random_code(7)
        code = code_body + generate_check_digit(code_body)
        # Unique within this event; the database unique index is authoritative.
        break code unless Ticketing::Credential.exists?(lookup_code: code, event_id: event_id)
      end
    end

    # Validate a PNR code entered by the scanner operator.
    # Returns the code normalized to uppercase if valid, nil if check digit fails.
    def self.validate(raw_code)
      code = raw_code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
      return nil unless code.length == 8
      return nil unless code.chars.all? { |c| ALPHABET.include?(c) }
      return nil unless valid_check_digit?(code)
      code
    end

    private

    def self.generate_random_code(length)
      Array.new(length) { ALPHABET.sample(random: SecureRandom) }.join
    end

    def self.generate_check_digit(body)
      # Luhn mod |alphabet| check digit
      sum = body.chars.reverse.each_with_index.sum do |char, i|
        value = ALPHABET.index(char)
        i.odd? ? value : (value * 2) % ALPHABET.size + (value * 2) / ALPHABET.size
      end
      ALPHABET[(ALPHABET.size - (sum % ALPHABET.size)) % ALPHABET.size]
    end

    def self.valid_check_digit?(code)
      body = code[0...-1]
      expected = generate_check_digit(body)
      code[-1] == expected
    end
  end
end
```

### Step 2: Attendee Index Generation (Server-Side)

The attendee index is a persisted, versioned projection of active credentials. It is not the commercial ticket table and must never be generated from package-level QR fields.

Each active credential contributes one entry:

- group mode: one entry containing the package credential ID and every signed slot position;
- delegated mode: one entry per accepted individual credential containing its single signed slot position;
- pending or revoked claims: no active QR/PNR entry;
- every entry: commercial ticket ID, credential ID, generation version/mode, entry limit, product-access IDs, PNR, and the minimum holder/owner lookup hashes required by the configured lookup policy.

The per-change writer allocates a new event index version, upserts by `(event_id, credential_id)`, and tombstones credentials removed by a generation transition. A bulk reconciliation may rebuild the projection for recovery, but it is not the normal write path. Delta reads return only rows whose `index_version` is greater than the scanner's last applied version.

Generation transitions publish their attendee-index changes only after the database transaction commits. The scanner applies revocations and tombstones before additions from the same transition version. This prevents a replacement credential from becoming usable locally before its predecessor is invalidated.

### Step 3: Index Download (Scanner App)

```json
GET /api/v1/scanner/events/:event_id/attendee-index
Headers:
  Authorization: Bearer <device_token>
  X-Index-Version: 0   # 0 = send full index; otherwise send delta

Response 200:
{
  "index_version": 3,
  "generated_at": "2026-06-14T22:00:00Z",
  "count": 48500,
  "entries": [
    {
      "lookup_code": "X7K2MP9Q",
      "phone_hash": "a3f2b8c9d1e4...",
      "cid": "credential-uuid",
      "tid": "commercial-package-uuid",
      "mode": "group",
      "slots": [1, 2, 3],
      "entry_limit": 3,
      "version": 2,
      "accesses": ["friday-access-uuid", "saturday-access-uuid"],
      "entry_validation_mode": "qr_and_id",
      "holder_name": "Abebe Example",
      "display_label": "VIP - All Access",
      "perks": ["complimentary_drink", "lounge_access"]
    },
    ...
  ]
}
```

**Size comparison** for the key columns alone (50K attendees):

| Field | Size per entry | Total (50K) |
|---|---|---|
| `lookup_code` (8 chars) | 8 bytes | 400 KB |
| `phone_hash` (64 hex chars) | 64 bytes | 3.2 MB |
| `owner_phone_hash` (64 hex chars) | 64 bytes | 3.2 MB |
| Credential/package/access claims and display metadata | variable | measure from production-shaped fixtures |
| **Total** | **variable** | **benchmark before setting sync limits** |

Compression helps, but credential IDs, slot arrays, access arrays, and display metadata make a fixed byte estimate misleading. Set cold-start and delta budgets from production-shaped fixtures at expected event sizes.

**Delta updates** (when tickets change after initial download):

The scanner sends its last known `index_version`. The server uses `AttendeeIndexService.changes_since` to return only entries with `index_version > since_version`. This works because the index is now a persisted table with per-row versions (see Step 2).

```json
GET /api/v1/scanner/events/:event_id/attendee-index?since=3

Response 200:
{
  "index_version": 5,
  "changes": {
    "changed": [
      { "lookup_code": "R3N8LW4J", "cid": "new-credential-uuid", "tid": "package-uuid", ... },
      { "lookup_code": "X7K2MP9Q", "cid": "replacement-credential-uuid", "tid": "package-uuid", "version": 3, ... }
    ],
    "removed": ["OLD_CODE_OF_TRANSFERRED_TICKET"]
  }
}
```

> **Design note (v3.2):** The delta uses a flat `changed[]` list (not `added[]`/`updated[]`). The scanner upserts unconditionally — `INSERT OR REPLACE` on `lookup_code` primary key. The added/updated distinction was semantically fragile: a scanner that missed two versions would read the `previously_existed` flag from the latest write, not the state at its `since_version`. The revocation design avoids this by only having add/remove (unambiguous).

**Walk-up sales during the event**: packages sold at the gate create an initial group credential. `AttendeeIndexService.upsert_entry(credential)` touches only that active credential row, so scanners receive it on the next delta sync (typically every 30-60 seconds).

### Step 4: Offline Manual Lookup Validation

> **v3.4 amendment:** The lookup result reconstructs the same `cid`/`tid`/slots/mode/version/entry-limit/access claim set used by QR input and calls `PackageCredentialValidator`. Manual lookup does not check package use by `ticket_id` alone and does not bypass credential-level revocation or slot-level first-scan-wins.

The scanner tries PNR code first, then phone hash as fallback.

> **Trust note (v3.1):** Manual lookup has a weaker trust model than QR scanning. QR validation uses an Ed25519 signature — the bearer possesses a server-issued token. Manual lookup only proves "this phone hash is in our index" — anyone who knows an attendee's phone number could check them in. To mitigate this, every manual check-in records a **reason code** explaining why the QR wasn't scanned. This creates an audit trail so patterns of abuse are visible after the fact. See §5.4 for the full trust asymmetry analysis.

```ruby
# Scanner app (runs on device, mirrored from mobile-native code)
class Scanner::ManualLookup
  # Entry point: operator chooses "Code" or "Phone" on the scanner UI.
  # Both paths go through the same validation pipeline.
  # REASON CODE is required — the operator must explain why QR wasn't scanned.
  # Valid codes: phone_dead, no_qr_printout, no_qr_sms, app_crash, no_connectivity,
  #              forgot_code, group_booking, other

  # PRIMARY PATH: PNR code lookup
  def self.lookup_by_code(raw_code, product_access, assignment:, access_zone: nil, reason_code:)
    # 1. Validate and normalize the code (uppercase, strip invalid chars, check digit)
    code = LookupCodeService.validate(raw_code)
    return { status: :invalid_code, message: "Invalid code format or check digit" } unless code

    # 2. Look up in the attendee index (indexed on lookup_code)
    entry = AttendeeLookup.find_by(lookup_code: code)
    return { status: :not_found, message: "No ticket found for this code" } unless entry

    # 3. Run the shared validation pipeline
    validate_entry(entry, product_access, assignment: assignment, access_zone: access_zone,
                   lookup_via: :code, reason_code: reason_code)
  end

  # FALLBACK PATH: Phone hash lookup (for users who forgot their PNR code)
  # Searches BOTH holder phone hash and owner phone hash.
  def self.lookup_by_phone(raw_phone, product_access, assignment:, access_zone: nil, reason_code:)
    # 1. Normalize and hash using libphonenumber (same library as server Phonelib)
    normalized = PhoneNumberUtil.instance.parse(raw_phone, "ET")
    phone_hash = Digest::SHA256.hexdigest(
      PhoneNumberUtil.instance.format(normalized, :e164)
    )

    # 2. Search both hash columns (holder + owner) — handles group bookings
    entries = AttendeeLookup.where("phone_hash = ? OR owner_phone_hash = ?",
                                    phone_hash, phone_hash).to_a
    if entries.empty?
      return { status: :not_found, message: "No ticket found for this phone number" }
    end

    # 3. If multiple tickets on the same phone, let operator pick
    if entries.size == 1
      return validate_entry(entries.first, product_access,
                             assignment: assignment, access_zone: access_zone,
                             lookup_via: :phone, reason_code: reason_code)
    end

    # Multiple tickets found — display them for operator selection.
    {
      status: :multiple_tickets,
      message: "#{entries.size} tickets found. Select the correct one.",
      tickets: entries.map { |e|
        {
          lookup_code: e.lookup_code,
          ticket_type: e.ticket_type_label,
          perks: JSON.parse(e.perks || "[]"),
          valid_days: JSON.parse(e.valid_days)
        }
      }
    }
  end

  # SHARED: Validation pipeline (identical for both lookup paths)
  def self.validate_entry(entry, product_access, assignment:, access_zone: nil, lookup_via:, reason_code:)
    payload = entry.to_credential_claims
    result = PackageCredentialValidator.validate_credential(
      payload,
      product_access,
      assignment: assignment,
      access_zone: access_zone,
      now: Time.current
    )
    ManualLookupAudit.record!(entry: entry, lookup_via: lookup_via, reason_code: reason_code)
    result
  end

  def self.display_info(entry)
    {
      ticket_type: entry.ticket_type_label,
      perks: JSON.parse(entry.perks || "[]"),
      valid_days: JSON.parse(entry.valid_days),
      policy: entry.policy
    }
  end
end
```

### Step 5: Name-Based Search (Online Only)

Names are too variable for safe offline hashing. Name search is an authenticated, online help-desk operation over active credentials and their accepted holder identity or commercial package owner.

The endpoint returns a credential-shaped result: `cid`, `tid`, signed slot positions, mode, generation version, product-access claims, current revocation state, PNR, and only the PII the operator needs to disambiguate results. Selecting a result sends the same credential claims through the shared validator; it does not create a separate ticket-level check-in path.

Production requirements:

- use PostgreSQL `pg_trgm` indexes for configured searchable identity fields and debounce queries;
- restrict the endpoint to trusted help-desk devices rather than ordinary gate scanners;
- audit operator, device, query reason, selected credential, and outcome;
- rate-limit searches and cap result counts;
- do not claim that the client cannot persist returned PII; minimizing and expiring it is policy and device-management enforcement, not a cryptographic guarantee.

### How Manual Lookup Interacts with the Scan Pipeline

A manual lookup check-in goes through the **exact same validator and scan log** as a QR scan. The `scans` table records `client_scan_id`, `credential_id`, commercial `ticket_id`, generation version, product access, result, and `lookup_via`. On sync, the server processes it as a normal credential scan. This means:

- **The same usage policy still applies**: for the default single-entry policy, a prior QR use makes manual lookup return `already_used`; bounded/unlimited products allocate their next permitted ordinal through the same local transaction
- **Server-side duplicate detection still works**: if two scanners check in the same person (one via QR, one via PNR code), the server catches the duplicate on sync
- **No special conflict resolution needed**: manual lookup uses the same pipeline as QR scanning
- **Scan records include lookup method and reason**: `scans` table has `lookup_via` (`qr`, `code`, `phone`) and `reason_code` for audit analysis

> **Cross-method first-scan-wins is offline-weak:** Two disconnected scanners may consume the same slot/product-access key through QR and manual lookup before either sees the other's use. Server reconciliation accepts the authoritative first use and rejects/flags the conflict. Group scans create several slot conflicts atomically rather than reducing the package to one ticket-level duplicate check.

### When to Use Each Lookup Method

| Scenario | Use |
|---|---|
| Attendee presents a QR code (screenshot, printout, app) | QR scan (primary path, fastest) |
| Attendee's phone is dead, they have the SMS with their code | **PNR code lookup (primary manual path)** |
| Attendee forgot their code but remembers their phone number | Phone hash lookup (fallback) |
| Group/couple package | **PNR code** (one package code in group mode or one code per slot in delegated mode) |
| Attendee has nothing — no QR, no code, no phone memory | Online name search (help desk) |
| Network is down and attendee has no QR | PNR code (offline) or phone hash (offline) |
| Attendee claims they bought a ticket but has no proof | PNR code (offline) → phone hash (offline) → name search (online) |

### PNR Code vs Phone Hash: Honest Comparison

| Axis | PNR Code | Phone Hash |
|---|---|---|
| Normalization risk | None — exact string match | Real — phone format bugs cause silent failures |
| Group bookings | Each person has unique code | All tickets on same phone collapse to one hash |
| User carries it | SMS, app, email, printout, memory | Just their phone number (already in their head) |
| Dead phone survival | Code is in SMS notifications / written down | Phone number is memorized but forgotten under stress |
| Keyspace | 22^8 ≈ 55B valid codes | 2^256 (effectively infinite) |
| Payload per entry | 8 bytes | 64 bytes |
| New thing to remember | Yes (but it's in their SMS) | No (it's their phone number) |
| Works for walk-up purchases | Only if code generated at purchase time | Yes (phone number known immediately) |
| Privacy | Non-reversible to identity | Reversible via rainbow table (low-entropy space) — see §3B |

**Neither is strictly better.** PNR code wins for group bookings and normalization safety. Phone hash wins for "I know nothing but my number." That's why v3 has both.

### Privacy Note: Phone Hash Is Not PII-Free (v3.2 acknowledgment)

The PNR code path is genuinely PII-free — opaque random strings reveal nothing about the attendee. The phone hash path is **not**:

- Ethiopian phone numbers are a low-entropy space (~100M possible numbers)
- Unsalted SHA-256 of a known-entropy space is the textbook broken-hashing case
- An attacker with a stolen scanner's database could build a 3.2GB rainbow table (one-time build, fits on a thumb drive, reusable across all events) and recover every attendee's phone number, mapped to their ticket type and perks

This matters for compliance reviews and security audits. Claiming "zero PII on device" while shipping reversible phone hashes would get the project blocked.

**Honest privacy model:**

| Path | PII risk | Mitigation |
|---|---|---|
| QR scan | None | Ed25519 signature, no lookup data needed |
| PNR code | None | Opaque random string, no reverse mapping |
| Phone hash | **Low-medium** | SHA-256 of low-entropy space; rainbow table feasible |
| Name search | PII returned over HTTPS | Online-only, help desk devices only |

**Mitigations for phone hash (in order of priority):**

1. **Prefer PNR code.** The phone hash path exists only for the narrow "remembers phone, forgot code" case. UX should nudge users toward PNR.
2. **Limit distribution.** Gate-lead devices download the full index. Per-gate scanners receive only the PNR column (no phone hashes) unless they explicitly need phone lookup.
3. **Encrypt at rest** (future). Phone hash columns encrypted with an event-scoped key, decrypted in memory only during lookup.
4. **Audit.** Every phone-hash lookup is logged with `lookup_via: phone` and `reason_code`. Unusual patterns trigger alerts.

**If the "remembers phone but not code" case proves rare in production data**, consider dropping the phone hash fallback entirely. The PNR code is strictly better on every axis except that one narrow case, and it carries zero PII risk.

---

## 4. MULTI-DAY EVENT ENTRY

### The Problem

An event runs for 2 days (June 15-16). A single ticket should grant entry on both days. But the scanner needs to track: has this ticket been used today? Can it be used tomorrow?

### The Solution: Entry Policies (unchanged from v1)

```ruby
# Event model
class Event < ApplicationRecord
  ENTRY_POLICIES = {
    single: "One entry total (any day)",
    multi: "Unlimited entries (any day, any time)",
    daily_single: "One entry per day"
  }

  enum :entry_policy, ENTRY_POLICIES

  has_many :event_dates, dependent: :destroy
end

# EventDate model
class EventDate < ApplicationRecord
  belongs_to :event
  t.date :date
  t.time :doors_open
  t.time :doors_close
end
```

### How Each Policy Works

| Policy | Day 1 | Day 2 | Day 3 | Use Case |
|--------|-------|-------|-------|----------|
| `single` | ✅ Entry | ❌ Already used | ❌ Already used | One-time events, single-entry festivals |
| `multi` | ✅ Entry | ✅ Entry | ✅ Entry | All-access passes, conference badges |
| `daily_single` | ✅ Entry | ✅ Entry | ✅ Entry | Multi-day festivals (one entry per day) |

### Scanner Logic

The scanner uses the `policy` field from the token (signed, so trustworthy) plus its local scan log:

- **single use**: reject when the target `(admission_slot_id, product_access_id)` already has usage ordinal `1`;
- **multi-use**: reject when the slot/access usage count reached the immutable product-access limit.
- **`multi`**: skip the check (still must be a valid day)

The token's `days` array is also signed, so the scanner can trust it: if `current_date` isn't in `days`, reject as `not_valid_today`.

### Multi-Scanner Coordination

For multi-day events with multiple scanners, the same ticket presented at two different entrances on the same day is a conflict. The server resolves this on sync (Step 6 above). In practice:
- The second scanner's offline scan will succeed locally
- On upload, the server detects the duplicate and rejects the second scan
- The duplicate is logged for review but doesn't grant entry
- The scanner's local scan log is updated to reflect the rejection (corrected on next sync)

---

## 5. FRAUD PREVENTION

### 5.1 Counterfeit QR Prevention

**Problem**: Someone generates fake QR codes with random UUIDs.

**Solution**: Ed25519 signature. The scanner verifies the signature before accepting any QR.

```ruby
# Scanner verifies:
payload = QrService.verify_token(qr_string)
return :invalid_signature if payload.nil?  # Signature doesn't match, unknown key, or expired
```

Only the server holds the private key. Fake QRs fail signature verification. **No manifest lookup needed for this check** — the signature is self-contained proof of authenticity.

### 5.2 Screenshot/Forwarding Fraud

**Problem**: User screenshots QR, sends to friend. Both try to enter.

**Platform constraint — screenshots MUST work.** Venue network is unreliable (see Project Context: Ethiopian market, low-signal venues). Tickets are often delivered as SMS links that the user opens, screenshots, and presents at the gate. Some users arrive with dead phones and no connectivity. The QR must be valid from a static screenshot for the entire event duration. Any mechanism that invalidates screenshots by design is incompatible with this requirement.

**Solution — layered defense, static-QR-first:**

| Layer | Mechanism | Effectiveness | Always on? |
|-------|-----------|---------------|------------|
| 1 | **First-scan-wins** (primary defense) | First person to scan gets in, second is rejected by local scan log + server-side duplicate check on sync | Yes |
| 2 | **Screenshot warning (UX hint)** | App detects a screenshot was taken and shows a non-blocking banner: "This ticket may be shared — only the first person to scan will be admitted." | Yes |
| 3 | **Owner phone match** | Scanner displays the owner's phone number. Staff can verbally verify identity for high-value tickets. | Yes (VIP/press only) |
| 4 | **Dynamic QR (opt-in for online-connected users only)** | The app may offer a "secure mode" that refreshes the QR every 30 seconds — opt-in, not the default. | **Not included in v3.4 launch scope** |

**Why dynamic QR is NOT the default in v2:**

| Reason | Impact |
|---|---|
| Venue network is unreliable | User may not be able to fetch a fresh QR right when they need to enter |
| Dead phones are common | A user with a dead phone has only the last screenshot — which would be invalid |
| SMS delivery is the norm | Tickets arrive as links; the user screenshots the rendered QR, not a live app view |
| First-scan-wins already handles sharing | For `single` and `daily_single` policies, the second person is rejected anyway |
| `multi` policy accepts re-entry by design | A screenshot shared in a multi-entry event doesn't enable fraud beyond the original holder's intended use |

**Defense-in-depth for `multi` tickets:** the only "fraud" a screenshot enables in a multi-entry event is the friend gets one free entry. The original holder can still enter too. This is an acceptable trade-off for the offline reliability we get in return. If a particular event needs tighter control (e.g., an all-access press pass), use owner-phone-match as a manual check.

---

#### Future Enhancement: Dynamic QR (not included in v3.4 launch scope)

This is included for reference only. **Not included in v3.4 launch scope.** Re-evaluate after Phase 5 if your user base is reliably online at venues and screenshots stop being the primary delivery mechanism.

```ruby
# app/services/platform/ticket_dynamic_qr.rb
# Reuses QrService.sign_payload so the signing key and canonical JSON
# are identical to the static token — do NOT reimplement signing here.
class TicketDynamicQr
  def self.generate(credential)
    payload = credential.signed_claims.merge(
      nonce: SecureRandom.hex(8),
      exp: 30.seconds.from_now.to_i
    )

    signed = payload.merge(sig: Base64.strict_encode64(QrService.sign_payload(payload)))
    Base64.urlsafe_encode64(signed.to_json, padding: false)
  end
end
```

If you later add this, the scanner accepts nonces within a 60-second window (30s before + 30s after). Screenshots older than 30 seconds would be invalid. **Only enable this for users who have explicitly opted in AND who have a live network connection at the venue.** Treat it as a power-user feature, not a default.

### 5.3 Replay Attack Prevention

**Problem**: Someone scans a used ticket's QR and tries to reuse it later.

**Solution**: Two layers:

1. **Offline**: scanner checks local admission uses for every slot/product-access key the credential would consume.
2. **Online (on sync)**: server locks those slots and relies on unique slot/product-access usage ordinals; conflicting scans are rejected and audited.

```ruby
# Server-side duplicate detection
def process_scan(scan)
  PackageScanReconciler.consume_slots!(
    credential_id: scan.fetch(:credential_id),
    product_access_id: scan.fetch(:product_access_id),
    client_scan_id: scan.fetch(:client_scan_id),
    scanned_at: scan.fetch(:scanned_at)
  )
end
```

### 5.4 Trust Asymmetry Between QR and Manual Paths (NEW in v3.1)

The two lookup paths have fundamentally different trust models. This is an acknowledged trade-off, not a gap.

| Axis | QR Path | Manual Path (PNR / Phone) |
|---|---|---|
| **Authenticity proof** | Ed25519 signature — bearer has the server-issued token | "This phone hash is in our index" — bearer knows a phone number or code |
| **Forgery cost** | Steal the server's private key | Know or guess an attendee's phone number |
| **Offline transfer/delegation fraud window** | Open when revocation state is stale; signature proves authenticity, not freshness | Open when index or revocation state is stale |

**The fraud scenario**: If a package was transferred or switched between group/delegated mode while a scanner was disconnected, the scanner may not know that the old generation or `cid` was revoked. An old QR, PNR, or phone-index entry can therefore validate locally. Ed25519 proves that the server issued the credential; only synchronized revocation state proves that it remains current.

**Mitigation layers:**

1. **Reason codes (mandatory):** Every manual check-in records WHY the QR wasn't scanned (`phone_dead`, `no_qr_printout`, `forgot_code`, `app_crash`, etc.). This creates an audit trail visible on the admin dashboard. Patterns of abuse (one scanner with 80% manual lookups) trigger alerts.

2. **Revocation cross-check:** Manual lookup still checks the local revocation list. If the transfer happened before the last sync, the old version is already revoked locally.

3. **Server-side duplicate detection:** On sync, the server sees the manual check-in and the new owner's QR check-in for the same ticket. The second scan is rejected, the conflict is flagged for review.

4. **Practical risk is bounded:** The attacker must (a) know the victim's phone number, (b) be at the gate before the victim, (c) the window closes on first sync (typically minutes). The victim gets rejected at the gate — staff investigates.

**Additional mitigation:** Products configured as `qr_and_id` require the current visual holder-name match described above. This works offline after the authorized device receives the credential index; it reduces casual impersonation but does not close a stale-revocation window by itself.

**Not in v3.4 launch scope but documented for the future:**
- **SMS verification code:** When online, send a one-time code to the attendee's phone. Confirms they actually have the phone. Useful for high-value tickets (VIP, press).

---

## 6. SCANNER DEVICE SECURITY

### Problem

A scanner device is stolen or compromised. The attacker could:
- Access the local revocation list (see what tickets have been transferred/refunded)
- Mark tickets as scanned (denial of service via fake scans)
- Generate fake "success" scans

### Solution

| Measure | Implementation | v2 Status |
|---|---|---|
| **Device authentication** | Each scanner registers with the server, gets a device-specific token | Unchanged |
| **Ed25519 public key only** | Scanner has the public key, not the private key. A compromised scanner cannot forge QRs. | **New in v2** (was shared HMAC secret in v1) |
| **Remote wipe** | Server can push a "wipe" command to a compromised device (clears local DB + revokes device token) | Unchanged |
| **Scan rate limiting** | A single scanner can't scan more than X tickets per minute (detects automated attacks) | Unchanged |
| **GPS validation** | Scanner only accepts scans within the venue's GPS coordinates | Unchanged |
| **Manifest encryption** | (v1 only) Encrypted manifest per device. Not needed in v2 — the revocation list contains no PII. | **Removed in v2** |

```ruby
# Scanner registration
def register_scanner(device_id, organization_id)
  device = ScannerDevice.create!(
    device_id: device_id,
    organization_id: organization_id,
    device_token: SecureRandom.hex(32),
    status: "active"
  )
  device
end

# Server pushes revocation list + signing keys
# Scanner stores the PUBLIC keys, never any private material
def auth_response(device)
  {
    device_token: device.device_token,
    revocation_version: device.event&.current_revocation_version || 0,
    signing_keys: QrService.public_keys_for_scanner  # public keys only
  }
end
```

### What a Compromised Scanner Can/Cannot Do

| Capability | Compromised scanner can... | Compromised scanner cannot... |
|---|---|---|
| Read data | See revocation list (ticket IDs + versions) and attendee index (PNR codes + phone hashes) | See PII (no raw phone numbers, names, or emails) |
| Forge QRs | No (only has public key) | Forge valid QRs for any event |
| Fake scans | Yes (can write to local scan log) | — but server detects duplicates on sync |
| Abuse manual lookup | Yes (can check in attendees by PNR/phone) | — but reason codes create audit trail for post-hoc detection |
| Cause lasting damage | Limited — server-side conflict resolution catches most fraud | Generate tickets that survive server validation |

---

## 7. LARGE EVENT SCALE (50K+ ATTENDEES)

### Problem

A v1 manifest for 50,000 tickets is ~2MB compressed. Downloading this to every scanner takes time and bandwidth, especially with bad venue cellular.

### Solution: The problem mostly evaporates

| Technique (v1) | Impact | v2 Status |
|---|---|---|
| **Delta updates** | Only send changes since last manifest. Typical delta: <10KB | **Still useful**, but the initial download is also small (42KB) |
| **Chunked download** | Split manifest into chunks. Resume interrupted downloads | **Not needed** — 42KB fits in one HTTP response |
| **Pre-event seeding** | Seed scanners 24 hours before the event | **Not needed** — cold-start works in 5 minutes |
| **Manifest compression** | Use Brotli or Zstandard instead of gzip for better compression | **Not needed** — 42KB is small regardless |
| **Selective manifests** | Scanner only downloads tickets for the event it's scanning | **Inherent** — revocation list is always per-event |

```ruby
# Delta revocation generation (similar shape to v1 manifest deltas, much smaller)
def generate_delta_revocations(event, since_version)
  {
    revocation_version: event.current_revocation_version,
    since_version: since_version,
    added: event.revocations
                .where("revocation_version > ?", since_version)
                .where(is_dead: false)
                .map { |r| { tid: r.ticket_id, revoked_through_version: r.revoked_through_version } },
    removed: event.revocations
                  .where("revocation_version > ?", since_version)
                  .where(is_dead: true)  # actually we don't remove dead ones
                  .pluck(:ticket_id)
  }
end
```

### Worst-Case Sizing

| Event size | Transfers | Refunds | Revocation list size | Download (3G) |
|---|---|---|---|---|
| 1K tickets | 50 | 10 | 2.4 KB | <1s |
| 10K tickets | 500 | 50 | 22 KB | <1s |
| 50K tickets | 1,000 | 100 | 44 KB | ~1s |
| 100K tickets | 5,000 | 500 | 220 KB | ~5s |

Even at 100K tickets with unusually high transfer activity, the list fits in 5 seconds of bad cellular. This is the scalability win of v2.

### Attendee Index at Scale (NEW in v3)

The attendee index is larger than the revocation list (~2MB compressed for 50K attendees with dual phone hashes) but is a **one-time download** before the event. Delta sync keeps it current:

| Event size | Initial index (compressed) | Typical delta (10 changes) | Delta frequency |
|---|---|---|---|
| 1K tickets | 30 KB | <1 KB | Every sync cycle (30-60s) |
| 10K tickets | 300 KB | <1 KB | Every sync cycle |
| 50K tickets | 2 MB | <2 KB | Every sync cycle |
| 100K tickets | 3 MB | <2 KB | Every sync cycle |

Because the index is now a persisted table with per-row `index_version` (v3.1 fix), delta sync works exactly like revocation deltas — `WHERE index_version > ?` returns only changed rows. During an event with walk-up sales and transfers, scanners get incremental updates instead of re-downloading 2MB on every sync.

---

## 8. PARTIAL NETWORK SCENARIOS

### Problem

Some scanners have WiFi, some have cellular, some have nothing. How do they stay in sync?

### Solution: Per-Scanner Sync (simplified from v1)

In v1, the hierarchical gateway pattern was needed to distribute the 2MB manifest. In v2, the revocation list is so small (42KB) that **every scanner can sync directly** with the server. No gateway tier is needed for revocation distribution.

The gateway pattern is still useful for **scan upload** at venues with extremely poor or zero cellular, but it's now optional.

```
                    ┌─────────────┐
                    │   Server    │
                    └──────┬──────┘
                           │ (HTTPS — direct from each scanner works)
              ┌────────────┼────────────┐
              │            │            │
         ┌────┴────┐  ┌────┴────┐  ┌────┴────┐
         │Scanner A│  │Scanner B│  │Scanner C│
         └─────────┘  └─────────┘  └─────────┘
```

Optional: at zero-cellular venues, one scanner acts as a gateway for the others over local WiFi/Bluetooth. This pattern from v1 still works — it just isn't required.

```ruby
# Zone scanner syncs with Gateway (optional, for zero-cellular venues)
def sync_with_gateway(gateway_url)
  unsynced = Scan.where(synced: false).limit(500)
  return if unsynced.empty?

  response = HTTP.post("#{gateway_url}/api/v1/local-sync", json: {
    device_id: device_id,
    scans: unsynced.map { |s| { ticket_id: s.ticket_id, result: s.result, scanned_at: s.scanned_at } }
  })

  if response.success?
    unsynced.update_all(synced: true)
    apply_revocation_changes(response["revocation_changes"])
  end
end
```

---

## 9. TIME SYNC ISSUES

Unchanged from v1. The revocation list contains no time-sensitive data; the `days` field in the token is signed and trustworthy. The scanner's clock only needs to be accurate for "is today a valid day?" comparison, which has natural day-level granularity.

| Measure | Implementation |
|---------|----------------|
| **NTP sync on boot** | Scanner syncs clock via NTP when it has network |
| **Tolerance window** | Accept tokens within ±5 minutes of doors-open time (server-supplied, not from manifest) |
| **Event dates, not times** | Tokens use dates, not timestamps. Scanner checks "is today a valid day?" not "is it past door time?" |
| **Server-time validation** | On sync, server corrects scanner's clock drift |

---

## 10. COMPLETE TICKET LIFECYCLE

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          TICKET LIFECYCLE                               │
│                                                                         │
│  Purchase → Active (v:1) ──────────────────────────────────────────┐   │
│     │                                                              │   │
│     │ Transfer/Resale → version++, (tid, old_v) added to revocations │ │
│     ▼                                                              │   │
│  Active (v:2) ─────────────────────────────────────────────────────┤   │
│     │                                                              │   │
│     │ Day 1: daily_single event                                    │   │
│     ▼                                                              │   │
│  Used (Day 1) ──→ Day 2: valid again (if multi-day) ───────────────┤   │
│     │                                                              │   │
│     │ Refund/Cancel → mark_dead on revocations                     │   │
│     ▼                                                              │   │
│  Refunded (all versions rejected) ───────────────────────────────┘   │
│                                                                         │
│  At each stage:                                                        │
│  - QR token is regenerated with new version                            │
│  - Old version added to revocation list (offline scanners see it)      │
│  - Dead tickets (refunded/cancelled) marked with is_dead: true          │
│                                                                         │
│  Offline scanners:                                                      │
│  - Verify token signature (Ed25519 public key)                          │
│  - Reject if ticket is in revocation list (dead or old version)         │
│  - Track entries locally                                                │
│  - Sync when network returns, receive revocation deltas                 │
│  - Conflicts resolved server-side                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 11. IMPLEMENTATION SCHEMA AUTHORITY

The canonical implementation schema is defined in `COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`, specifically the normalized ticket/credential/use/check-in tables plus `ticketing_admission_use_reversals`, `events_access_zones`, `catalog_product_access_zones`, and `ticketing_scanner_assignment_zones`.

Historical v1-v3.3 migration sketches were deliberately removed from this document. They looked executable but placed QR tokens, PNRs, versions, and holder identity directly on the commercial ticket package. That model conflicts with package/delegated credential modes. Git history remains the historical reference; it is not an implementation source.

Implementation rules:

- `ticketing_tickets` is the purchased commercial package and refund boundary.
- QR tokens, lookup codes, credential versions, signed slot positions, and credential holders belong to `ticketing_credentials`.
- `ticketing_revocations.ticket_id` intentionally identifies the commercial package for package-wide death, temporary suspension, or generation revocation state; generation- and credential-level revocations remain independently enforceable.
- `ticketing_checkin_logs.ticket_id` intentionally identifies the commercial package for audit and reconciliation, but every credential-based scan must also record `credential_id` and `product_access_id`.
- Use the executable partial indexes and the deferred generation-cardinality constraint documented in the canonical database design. Do not reconstruct schema from older examples in this QR document.

### Schema Diff vs v1

| Removed | Added |
|---|---|
| `tickets.manifest_key` (per-device manifest encryption) | `revocations` table |
| `scanner_devices.manifest_key` | `events.revocation_version` |
| `manifests` table (generated manifest history) | `revocations.revocation_version` (for delta tracking) |
| | `ticketing_credentials.lookup_code` + event-scoped unique index (**v3.4**) |
| | `events.attendee_index_version` (**new in v3**) |
| | **`attendee_index_entries` table** (**new in v3.1** — persisted index with per-row versioning) |
| | `checkin_logs.lookup_via` + `checkin_logs.reason_code` (**new in v3.1** — audit trail) |
| | admission slots, credential generations, credentials, claims, slot uses, credential revocations, and idempotent scan uploads (**v3.4**) |

### Scanner-Side Schema: v2 vs v3

| v2 | v3 |
|---|---|
| `revocations` table | `revocations` table (+ `is_suspended` reversible package-review projection) |
| `scans` table | `scans` table (+ `client_scan_id`, `credential_id`, slot/access/version, `lookup_via`, and `reason_code`) |
| `scanner_state` table | `scanner_state` table (+ `attendee_index_version` key) |
| — | **`credential_revocations` table** keyed by `cid` |
| — | **local admission uses** keyed by `tid`/slot/product access |
| — | **admission-use reversal delta** keyed by authoritative use ID/version |
| — | **access-zone policy tables** mapping product access and scanner assignment to named zones |
| — | **`attendee_lookup` table** (lookup code, `cid`, `tid`, signed slots/mode/entry limit, phone hashes, index version) |

---

## 12. API ENDPOINTS

### Scanner Endpoints

```
POST /api/v1/scanner/auth
  → Register/authenticate scanner device
  → Returns: device_token, current revocation_version, signing public keys

GET /api/v1/scanner/events/:event_id/revocations
  → Download full or delta revocation list
  → Headers: X-Scanner-Version: 0 (or last known version)
  → Returns: revocation_version, signing_keys, revocations[] (or changes{})

POST /api/v1/scanner/events/:event_id/scans
  → Upload scan logs from offline period
  → Returns: { accepted[], rejected[], revocation_version, revocation_changes }

POST /api/v1/scanner/verify
  → Online verification (fallback when offline validation is uncertain)
  → Returns: ticket status, owner info, entry history

POST /api/v1/scanner/events/:event_id/refresh-revocations
  → Force revocation refresh (admin action)

GET /api/v1/scanner/events/:event_id/attendee-index
  → Download full or delta hashed phone index for manual lookup (NEW in v3)
  → Headers: X-Index-Version: 0 (or last known version)
  → Returns: index_version, entries[] (or changes{})
  → Entries contain: phone_hash, ticket_id, ticket_type, ticket_type_label, perks, version, valid_days, policy

POST /api/v1/scanner/events/:event_id/lookup
  → Online name/phone search (NEW in v3, requires network)
  → Body: { query: "Abebe" } or { query: "+251911234567" }
  → Returns: matching active credential claims plus minimal disambiguating holder data
  → Restricted to trusted help-desk devices; access and result selection are audited
```

### Commercial Package and Credential Endpoints

```
POST /api/v1/tickets/:id/transfer
  → Transfer the entire commercial package when product/event policy permits
  → Initiation and acceptance must precede the current product cutoff (default: applicable session start)
  → Free and sequential with one pending transfer; rate-limited, no lifetime count limit
  → Carries only access rights on this ticket product; separate add-on order items stay put
  → Revokes the active generation and issues a replacement generation to the accepted owner

POST /api/v1/tickets/:id/resale
  → List the entire commercial package for resale when policy permits
  → Requires seller ownership, group mode, no use/refund/suspension/pending transfer, cutoff eligibility, and remaining resale count
  → Enforces exactly one organizer cap rule: fixed maximum OR percentage of seller acquisition value

POST /api/v1/resale_listings/:id/purchase
  → Atomically reserve the listing and create a normal quantity-one resale order/payment
  → Reservation first revokes the seller generation and temporarily suspends package access
  → Accepted payment transfers ownership and creates a new buyer group generation
  → Failure/expiry restores the seller only through a newer group generation; no old QR/PNR is reactivated
  → Seller fee/proceeds/payout data is server-side commerce state and never scanner data

POST /api/v1/tickets/:id/delegations
  → Switch group mode to delegated mode and create one credential per admission slot
  → Buyer uses transfer cutoff; after-cutoff manager override is online-only, reasoned, and audited

DELETE /api/v1/tickets/:id/delegation
  → Revoke all individual credentials and issue a new group credential

POST /api/v1/credentials/:id/claims
  → Invite a recipient for one delegated slot; pending claims have no QR or PNR

POST /api/v1/credential_claims/:token/accept
  → Bind the intended recipient and issue the individual QR/PNR atomically

GET /api/v1/tickets/:id/credentials
  → Return the caller-authorized active package or individual credentials

PATCH /api/v1/credentials/:id/holder_name
  → OTP-authenticated holder before cutoff; online event manager with reason afterward
  → Publishes attendee-index delta; does not replace QR/PNR or generation

GET /api/v1/tickets/:id/history
  → Authorized package ownership, credential-generation, delegation, and scan history

POST /api/v1/checkin_logs/:id/identity_override
  → Authorized event manager only; requires online revalidation and a controlled reason
  → Appends one linked successful check-in without editing the original mismatch

POST /api/v1/checkin_logs/:id/admission_use_reversal
  → Online event-manager correction for a mistaken successful scan
  → Reverses every use from a package group scan together; appends delta/audit rows, deletes nothing

POST /api/v1/events/:event_id/complimentary_tickets
  → Authorized manager issues a normal zero-charge registration/package to a phone identity
  → Requires controlled reason and idempotency key; consumes inventory/capacity and creates no financial rows

POST /api/v1/events/:event_id/orders
  → A gate-assisted checkout sends sales_channel: walk_up and initiating staff identity
  → Uses ordinary online mobile-money/card payment and fulfillment; cash/offline promises are rejected

POST /api/v1/tickets/:id/suspension
  → Opens one temporary fraud-review case and publishes is_suspended: true
  → Requires authorized actor, controlled reason, review deadline, and idempotency key

POST /api/v1/ticket_suspensions/:id/restore
  → Resolves review and publishes is_suspended: false only if the package is otherwise active

POST /api/v1/tickets/:id/organizer_cancellation
  → Free package: reasoned permanent revocation; paid unused package: suspend and create applicable item refund
  → Paid package becomes dead only after refund success; ordinary organizer path rejects already-used paid packages
```

### Admin Endpoints (v2 for debugging, v3 additions)

```
GET /api/v1/admin/events/:event_id/revocations
  → View current revocation list (for support / debugging)

POST /api/v1/admin/events/:event_id/tickets/:id/revoke
  → Permanently revoke only for an authorized terminal cause (e.g., completed chargeback or free-ticket cancellation)
  → Adds to revocation list with is_dead: true

POST /api/v1/admin/events/:event_id/tickets/:id/suspend
  → Open temporary fraud/risk review without confiscating payment or changing ownership
  → Adds/updates revocation projection with is_suspended: true

POST /api/v1/admin/events/:event_id/regenerate-attendee-index
  → Force regenerate the attendee lookup index (NEW in v3)
  → Used after bulk ticket changes (e.g., mass transfer, event merge)
```

---

## 13. IMPLEMENTATION PLAN

### Phase 1: Core QR System (Week 1-2)
1. `QrService` — Ed25519 token generation and verification
2. Key management — store private key in env, expose public keys via API
3. Commercial packages, admission slots, credential generations, and credentials
4. `cid`/`tid`/slots/mode/version QR generation
5. Basic online package/individual slot-consumption endpoint

### Phase 2: Revocation & Offline (Week 2-3)
1. Package-generation and credential-level revocation services — generate, apply, delta
2. Package/credential revocation models + `Event#revocation_version`
3. Revocation download API (full + delta)
4. Scanner local database schema (`revocations`, `credential_revocations`, `scans`, local slot uses, `scanner_state`)
5. Offline validation algorithm
6. Idempotent upload/scan endpoint with slot-level conflict resolution

### Phase 3: Multi-Day & Policies (Week 3-4)
1. `EventDate` model
2. Product-access usage-limit enforcement
3. Per-date/access admission-slot usage tracking
4. Scanner UI for multi-day events

### Phase 3.5: Manual Attendee Lookup (Week 4) — NEW in v3
1. `LookupCodeService` — PNR code generation (Crockford Base-32, check digit, uniqueness enforcement)
2. **`AttendeeIndexEntry` persisted table** + migration (per-row `index_version`, dual phone hashes)
3. `AttendeeIndexService` — sync (upsert entries), generate (full download), changes_since (delta)
4. **Phone normalization via Phonelib** (replaces hand-rolled regex that had double-prefix bug)
5. credential lookup-code column + event-scoped unique index; backfill the active credential generation for existing packages
6. Attendee index download API (full + delta) — uses `changes_since` for real delta sync
7. Scanner `attendee_lookup` table (with `index_version`, `phone_hash`, `owner_phone_hash`) and dual-path validation logic (PNR first, phone fallback)
8. **Reason code UI** on scanner — operator must select why QR wasn't scanned before manual lookup
9. **Phone normalization self-test** at scanner startup (hash known strings, compare to known hashes from server)
10. Online name/phone search endpoint with `pg_trgm` GIN index
11. Scanner UI: PNR code entry screen (with check digit validation feedback) + phone entry fallback + results display
12. PNR code included in SMS/email ticket confirmations
13. Credential-index versioning on generation switches, claims, reassignments, package transfers/refunds, and new sales
14. Gate walk-up fulfillment acknowledgement: newly issued credentials stay online-required until the scanner assignment reaches their attendee-index/revocation versions

### Phase 3.6: Package Delegation (Week 4-5) — NEW in v3.4

1. All-or-nothing group/delegated generation transition service
2. Recipient claim through existing user, claimed shadow identity, or unclaimed invitation
3. Buyer-only revoke/reassign flow for delegated slots
4. Atomic revocation-before-index delta ordering
5. Scanner UI that displays group admission count or delegated slot identity
6. Mode-transition cutoff checks against affected open-date slot uses
7. `online_required` validation option for high-security delegation
8. Shared transfer/delegation cutoff enforcement; online manager delegation override forces online validation until scanner sync acknowledgement
9. Free sequential transfer workflow with one pending transfer, endpoint rate limits, immutable ownership history, and no lifetime count limit
10. Product `qr_and_id` mode, holder-name index minimization, operator confirmation UI, immutable mismatch attempt, and linked online manager override
11. Single-entry venue/parking default with explicit bounded/unlimited re-entry and atomic local/server usage-ordinal allocation
12. OTP-verified pre-cutoff holder-name correction plus reasoned online manager correction after cutoff; both publish index deltas without QR reissue
13. Append-only online admission-use reversal service, complete group-scan reversal, versioned scanner deltas, and active-unreversed usage counting
14. Named venue/parking zone policy with product-access grants, scanner-assignment scope, and wrong-zone audit results
15. Transfer boundary tests proving separate add-on order items stay with their owner while ticket-product access rows move with the package
16. Complimentary manager issuance through the normal zero-charge registration/package path, with reason, actor, idempotency, capacity, and inventory tests
17. Digital walk-up checkout channel tests proving the normal online payment/fulfillment path is used and cash/offline promises are rejected
18. Temporary package-suspension review cases, `is_suspended` deltas, restore safety checks, free revocation, and refund-backed paid organizer cancellation
19. Privacy tests proving registration answers and consent evidence never appear in QR/PNR payloads, attendee-index deltas, scanner databases, or scan APIs
20. Fulfillment tests proving purchase-limit allocation is committed before credential issuance and retrying fulfillment cannot issue packages beyond allocated units
21. `pending_requirements` credential tests: no QR/PNR/index row before personal consent; group requires every slot, delegated credentials activate independently
22. Reassignment tests proving prior attendee acceptance never authorizes the replacement subject and only the newly cleared credential enters index deltas

### Phase 3.7: Controlled Whole-Package Resale (after core checkout and credentials)

1. Organizer policy checks for resale enablement, cutoff, completed-resale limit, and exactly one cap mode per ticket type
2. Whole-unused-package listing service; reject delegated claims, partial multi-day use, refunds, suspension, pending transfer, and mismatched ownership
3. Atomic listing reservation plus quantity-one resale order/payment and buyer purchase-limit allocation without primary-inventory reservation
4. Revocation-before-payment ordering: seller generation tombstone and temporary package suspension must commit before checkout is exposed
5. Accepted-payment fulfillment that changes owner/acquisition, increments resale count, and issues a new buyer group generation exactly once
6. Expiry/failure recovery that issues a newer seller group generation before making the listing active again
7. Offline tests proving stale scanners can expose the documented revocation window and current scanners reject every pre-resale credential
8. Privacy tests proving cap, fee, seller proceeds, payout destination, and acquisition-chain data never enter QR/PNR/index/scanner responses
9. Event/date cancellation and chargeback tests across the immutable acquisition chain; these affect server-side refunds/ledger state while QR invalidation still follows package generation/death rules

### Phase 4: Fraud Prevention & Device Security (Week 5-6)
1. (Optional) Dynamic QR with rotating nonce
2. Screenshot detection (app-side)
3. Device authentication and registration
4. GPS validation for scanners
5. Rate limiting on scan endpoint
6. Remote wipe capability

### Phase 5: Scale & Polish (Week 6-7)
1. Delta revocation optimization (batched, indexed)
2. Delta attendee index verification — confirm `changes_since` produces correct deltas under load (walk-up sales + transfers during event)
3. (Optional) Hierarchical gateway sync for zero-cellular venues
4. NTP time sync
5. Scanner app UI (big success/failure indicators)
6. Admin dashboard for scan monitoring + revocation viewer + **manual lookup audit trail (reason code analysis)**
7. Conflict review workflow
8. **pg_trgm index verification** — benchmark ILIKE search at 50K rows, add debouncing if needed
9. Admission-use/reversal reconciliation under concurrent scanners, retries, group scans, and bounded/unlimited re-entry

**Estimated total: 7 weeks** (v2 was 6 weeks; the manual lookup phase adds ~1 week)

---

## 14. TECHNOLOGY STACK

| Component | Technology | Why | v3 Change |
|---|---|---|---|
| QR generation | `rqrcode` gem | Pure Ruby, no native dependencies | Unchanged |
| QR scanning (app) | Native camera API (iOS/Android) | Fast, reliable, works offline | Unchanged |
| Token signing | **Ed25519** (OpenSSL built-in) | Asymmetric, scanner holds public key only, rotatable | Unchanged from v2 |
| Revocation list transport | HTTPS + JSON | Simple, debuggable | Unchanged |
| Revocation list size | 42KB typical for 50K event | 98% smaller than v1 manifest | Unchanged |
| **PNR code generation** | **SecureRandom + Crockford Base-32** | Ambiguity-free 8-char codes, check digit for typo protection | **New in v3** |
| **Phone hashing** | **SHA-256** (Digest::SHA256) | One-way, deterministic, fallback lookup | **New in v3** |
| **Phone normalization** | **Phonelib gem** (Ruby) / **libphonenumber** (mobile) | Wraps Google's libphonenumber. Fixes double-prefix bug. Same library on both sides ensures cross-platform consistency. | **New in v3.1** |
| **Name search indexing** | **pg_trgm** (PostgreSQL extension) | GIN trigram index for ILIKE fuzzy search at 50K rows. Without it, name search is a full table scan per keystroke. | **New in v3.1** |
| **Attendee index storage** | **`attendee_index_entries` table** (PostgreSQL) | Persisted table with per-row `index_version`. Enables real delta sync (mirrors revocation design). | **New in v3.1** |
| **Attendee index transport** | **HTTPS + JSON** | Same as revocation list, delta-capable | **New in v3** |
| **Attendee index size** | **~2MB compressed for 50K event** | One-time download, PNR code + dual phone hashes + metadata | **New in v3** |
| Scanner local DB | SQLite | Built-in, fast, reliable | **New table: `attendee_lookup`** |
| Sync transport | HTTPS + JSON | Simple, debuggable | Unchanged |
| Background jobs | Solid Queue (Rails 8) | Built-in, reliable | Unchanged |
| Real-time monitoring | Turbo Streams | Live scan counts on admin dashboard | Unchanged |
| ~~Manifest compression~~ | ~~Zlib/Brotli~~ | ~~Built-in, good compression ratio~~ | **Removed in v2** — not needed |
| ~~Manifest signing~~ | ~~Ed25519/RSA~~ | ~~Fast verification, compact signatures~~ | **Replaced** by token Ed25519 signing (same algorithm, different purpose) |

---

## 15. EDGE CASES & RESOLUTIONS

| Edge Case | Resolution |
|---|---|
| Ticket scanned offline, then refunded before sync | Server marks as conflict (rejection reason: `ticket_dead`), alerts staff, refund stands |
| Two scanners scan same ticket simultaneously offline | Both record success locally. Server detects duplicate on sync, flags for review, second one rejected |
| Scanner loses revocation list, event starts in 30 minutes | Emergency revocation download (42KB, <1s on 3G). Fallback to online verification. |
| User's phone dies, they have a printed QR | Printed QR has static version. Works if not transferred. Staff can verify owner identity manually. |
| **User's phone dies, no QR, no printout (NEW in v3)** | **Operator uses PNR code lookup (primary path). Attendee reads code from SMS notification, memory, or written note. Same scan pipeline as QR. Fallback to phone hash if code is forgotten.** |
| **User doesn't know registered phone number (NEW in v3)** | **Online name search via `POST /api/v1/scanner/events/:event_id/lookup`. Requires network. Help desk handles, not gate scanner.** |
| **Phone number entered with different formatting (NEW in v3)** | **Fallback path only. PNR code has no normalization issue. For phone hash: both server (Phonelib) and scanner (libphonenumber) normalize to E.164 before hashing. v3.1 fixed the double-prefix bug (`251911234567` no longer produces `+251251911234567`). Scanner runs self-test at startup to verify cross-platform consistency.** |
| **Ticket transferred, old owner tries manual lookup (NEW in v3)** | **Old owner's PNR code is now revoked (transfer bumps version, adds to revocation list). Cross-check catches it: `version <= revoked_through_version` → rejected. Old phone hash also caught the same way.** |
| **Group booking: 4 tickets on one phone (NEW in v3)** | **Each person has their own PNR code. Operator types each code independently. Phone hash fallback returns multiple results — operator selects the correct ticket from the list.** |
| **Attendee index not downloaded yet (NEW in v3)** | **Manual lookup unavailable offline. Scanner UI shows "Lookup index not synced — use QR scan or go to help desk." Index downloads opportunistically when network is available.** |
| **PNR code typo at the gate (NEW in v3)** | **Check digit (Luhn mod 32) catches single-char typos and transpositions before hitting the index. Scanner shows "Invalid code — please check and re-enter" instead of "Not found."** |
| **Attacker tries to brute-force PNR codes (NEW in v3)** | **22^7 × 22 ≈ 55B valid codes. At 1 scan/second, brute-forcing one valid code takes ~1,700 years. Rate limiting on the lookup UI adds further protection.** |
| Event date changes (postponed) | Preserve schedule history, bulk-revoke each active package generation, and issue a replacement generation in the same group/delegated mode with updated product-access IDs. Apply revocations before new index rows. |
| Ticket type upgrade at venue (Regular → VIP) | Server creates new ticket (new version), invalidates old (adds to revocation list). Scanner receives update on next sync. **Attendee index entry updated via delta with new type + perks.** |
| Scanner battery dies mid-event | Swap to backup scanner. Backup downloads latest revocation list (42KB, ~1s). No data lost (scans synced to server). |
| Signing key rotation | Server signs new tokens with new `kid`, keeps old key active for grace period (e.g., 7 days). Scanner caches both public keys. Old tokens still verify until grace period ends. |
| Revocation list grows unbounded (long-running event) | Bound by ticket count, not transfers. For a 50K event, max ~50K rows (all tickets dead). Cap is acceptable. For multi-week events, consider archival of resolved revocations. |
| Server is down during entire event | All scanners operate offline with whatever revocation list they last synced. Worst case: some transfers from the offline window won't be reflected locally until server returns. Server-side conflict resolution catches these on sync. |
| Clock skew between server and scanner | Tokens use `days` (date-level granularity) not exact times, so clock skew is mostly irrelevant. For door-open time, server returns correction on sync. |
| Attacker tries to flood scanner with junk QR codes | Signature verification fails in <1ms. Combined with rate limiting per scanner, the attack is rejected without slowing the line. |
| **Attacker tries to brute-force phone hashes (NEW in v3)** | **SHA-256 is not directly reversible, but Ethiopian phone numbers are a low-entropy space (~100M possible numbers). An attacker with the hash table could build a 3.2GB rainbow table and recover all phone numbers. Mitigation: (1) limit attendee index download to gate-lead devices only, not all scanners; (2) consider encrypting phone hash columns at rest with an event-scoped key; (3) the PNR code path has zero PII risk and should be preferred. Rate limiting prevents online brute-forcing.** |
| **Walk-up package sold at gate, other scanners need the credential** | **The initial group credential is indexed with `upsert_entry(credential)`. Other scanners receive that one-row delta on their next sync.** |
| **Group booking: Abebe buys for Sara, Sara looks up by HER phone (NEW in v3.1)** | **Index stores BOTH `phone_hash` (holder/Sara) and `owner_phone_hash` (owner/Abebe). Sara's phone lookup matches the `phone_hash` column. Abebe's phone lookup matches `owner_phone_hash`. Both find the same ticket. Before v3.1, only owner.phone was indexed — Sara couldn't be found by her own number.** |
| **Operator manually checks in suspiciously many attendees (NEW in v3.1)** | **Every manual check-in records a `reason_code` (phone_dead, no_qr, etc.) and `lookup_via` (code, phone). Admin dashboard monitors manual lookup rates per scanner. A scanner with >50% manual lookups triggers an alert for investigation. Patterns reveal compromised or negligent operators.** |
| **Ruby and Swift normalize the same phone differently (NEW in v3.1)** | **Both sides use libphonenumber (Phonelib on Ruby, libphonenumber on Swift/Kotlin). Scanner runs a self-test at startup: hash known test numbers, compare to server-provided hashes. Mismatch disables phone lookup and falls back to PNR code only.** |

---

## SUMMARY

**The architecture is built on five pillars (v3.4):**

1. **Signed QR tokens (Ed25519)** — self-contained, verifiable, versioned. The scanner holds only the public key, so a compromised scanner cannot forge QRs.

2. **Layered revocation-based offline sync** — scanners check package-dead, package-generation, and exact-credential revocations. The signature proves authenticity; synchronized revocations provide freshness.

3. **All-or-nothing credential generations** — one commercial package has either one group credential or one credential per admission slot. Mode switches revoke the old generation before activating the new one.

4. **Slot/product-access first-scan-wins** — group scans atomically consume all package slots for the current access/date; delegated scans consume one slot. Multi-day history survives every mode change.

5. **Credential-based PNR + phone lookup** — group mode indexes one PNR; delegated mode indexes one per slot. Both manual and QR entry execute the same credential revocation and slot-use validator.

**Multi-day events** use stable product-access IDs and admission-slot uses. A slot consumed Friday remains independently available for allowed Saturday/Sunday accesses.

**Fraud prevention** is layered: Ed25519 signatures prevent forgery, revocation entries prevent reuse after transfer, first-scan-wins prevents duplicates, and device authentication + remote wipe protect against scanner compromise.

**Offline scanning** uses package/credential revocations, local slot uses, and the attendee index. The token is self-validating only for authenticity; stale revocations create a documented temporary fraud window that server reconciliation resolves.

**Manual validation** (new in v3) uses the same scan pipeline as QR scanning — the only difference is the entry point (typed PNR code or phone number instead of camera). The scan log, revocation check, policy enforcement, and conflict resolution are identical. **Trust asymmetry** between QR and manual paths is mitigated by mandatory reason codes that create an audit trail, and acknowledged as a documented trade-off (§5.4).

### What Got Simpler (v1 → v2)

| Concern | v1 (manifest) | v2 (revocation) |
|---|---|---|
| Initial scanner setup | 2MB download, pre-event seeding | 42KB download, cold-start works |
| Pre-event infrastructure | Required (seed scanners 24h before) | Not required |
| Sync protocol complexity | Full + delta + chunked + hierarchical | Full + delta (small) |
| Scanner storage | 50K-row manifest table | 1K-row revocation table |
| Gateway pattern | Required for manifest distribution | Optional (only for zero-cellular venues) |
| Token security | Shared HMAC secret (symmetric) | Ed25519 public key (asymmetric) |
| PII in offline data | Phone numbers, holder names | Just ticket IDs (no PII) |
| Encryption requirements | Per-device manifest encryption | Not needed |

### What's New in v3

| Concern | v2 (revocation only) | v3 (revocation + dual lookup) |
|---|---|---|
| Manual validation | Not possible | **PNR code** (primary) + **phone hash** (fallback) |
| Ticket info at gate | Only via QR scan | QR scan OR PNR code OR phone lookup |
| Group bookings | No offline support | One active package PNR in group mode or one PNR per slot in delegated mode |
| **Group booking phone lookup** | N/A | **Index stores both holder_phone hash AND owner.phone hash (v3.1 fix)** |
| PII on device | None | PNR codes are PII-free. Phone hashes (SHA-256) are present — see privacy note in §3B |
| Name-based search | Not possible | **Online-only** via server API (pg_trgm indexed, v3.1) |
| **Delta sync for attendee index** | N/A | **Real delta via `attendee_index_entries` table with per-row `index_version` (v3.1 fix)** |
| **Trust asymmetry** | N/A | **Acknowledged trade-off. Mandatory reason codes create audit trail (v3.1, §5.4)** |
| **Phone normalization** | N/A | **Phonelib gem (libphonenumber) on both sides + startup self-test (v3.1 fix)** |
| Additional download | — | ~2MB one-time (50K event, compressed), then <2KB deltas |
| New server table | — | `attendee_index_entries` (persisted index with per-row versioning) |
| New scanner table | — | `attendee_lookup` (lookup_code PK, phone_hash + owner_phone_hash indexes) |
| New API endpoints | — | `GET .../attendee-index`, `POST .../lookup` |
| Implementation time | 6 weeks | 7 weeks (+1 week for lookup phase) |

### What Stayed the Same from v2

- Token envelope (signed JSON, base64-encoded, Ed25519); v3.4 adds `cid`, mode, explicit slots, entry limit, and product-access IDs
- Revocation-based offline sync (42KB list)
- Version/generation invalidation on transfer/resale
- Multi-day access behavior
- First-scan-wins, now at slot/product-access level
- Server-side conflict resolution
- Tiered fraud defense (signatures, versioning, policies, device auth)
- All v2 edge case resolutions
- Cross-method first-scan-wins has the **same offline duplicate window** as v2's cross-scanner QR duplicates (acknowledged in v3.1, not fixed — inherent to offline operation)

### Migration from v2

If v2 is already partially implemented:

1. **Add `LookupCodeService`** — generates 8-char PNR codes with Crockford Base-32 + check digit
2. **Add credential generations/credentials and `ticketing_credentials.lookup_code`**; backfill one group generation/credential per existing package
3. **Add `attendee_index_entries` table** — persisted index with per-row `index_version`, dual phone hashes (`phone_hash` + `owner_phone_hash`)
4. **Add `AttendeeIndexService`** — sync (upsert), generate (full download), changes_since (delta). Uses `Phonelib` for phone normalization (replaces hand-rolled regex).
5. **Add `attendee_lookup` table** to scanner's local SQLite schema (with `index_version`, `phone_hash`, `owner_phone_hash`)
6. **Add `reason_code` column** to scanner `scans` table and server `checkin_logs` — mandatory for manual lookups
7. **Add attendee index download endpoint** (`GET /api/v1/scanner/events/:event_id/attendee-index`) — supports real delta sync via `changes_since`
8. **Add online name search endpoint** (`POST /api/v1/scanner/events/:event_id/lookup`) with `pg_trgm` GIN index
9. **Add PNR code to SMS/email confirmations** alongside the QR code
10. **Add manual lookup UI** to scanner app (PNR code entry with check digit feedback, phone fallback, reason code selector, results display)
11. **Add phone normalization self-test** at scanner startup (hash known strings, compare to server-provided hashes)
12. **Publish credential-generation/index outbox events** so one committed mode-switch transaction tombstones old credential rows before adding the new generation; do not add the superseded ticket-callback write path.
13. **Add credential-level revocation deltas** keyed by `cid` alongside package-generation revocations keyed by `(tid, v)`.
14. **Add local and server admission-slot uses** keyed by slot and product access; backfill existing successful scans to slot 1 for single-admission packages.
15. **Add idempotent scan uploads** with device-scoped `client_upload_id` and globally unique nested `client_scan_id`.
16. **Require a current pre-gate sync** and support `online_required` delegated validation for high-security products.
17. **Add approved product policies:** shared transfer/delegation cutoff, free sequential rate-limited transfers, and optional `qr_and_id` visual holder matching with linked online manager overrides and no ID-document storage.
18. **Apply launch refund scope:** no buyer change-of-mind refund endpoint; only documented cancellation, schedule-change, payment-reversal, legal, and administrative refund causes may revoke credentials.
19. **Add approved gate policies:** append-only admission-use reversals and delta version, lightweight access zones, scanner zone assignments, and explicit ticket-versus-add-on transfer boundaries.
20. **Add issuance/sales channels:** organizer complimentary registration with manager audit and digital walk-up checkout with scanner-version acknowledgement; do not add separate complimentary tickets or cash/till tables.
21. **Add reversible package suspension:** one active review case per ticket, scanner `is_suspended` projection/deltas, safe restoration, and the rule that paid organizer cancellation becomes dead only after its refund succeeds.
22. **Keep form/consent/limit data server-side:** verify that only successfully allocated and fully eligible registrations reach credential issuance; do not add these records to scanner schemas.
23. **Add pending-requirement activation:** backfill existing active credentials as already clear, then gate only products configured with personal consent; never synthesize acceptance evidence.
24. **Add controlled resale transitions:** whole-package listing reservation revokes the seller generation and publishes temporary suspension before checkout; accepted payment issues a buyer group generation, while failure issues a newer seller group generation.
25. **Keep marketplace commerce off scanners:** resale caps, fees, proceeds, payout accounts, acquisition chains, and seller-ledger state remain server-only; scanner changes are limited to existing package suspension, generation revocation, attendee-index, and ownership-safe credential projections.

The v2 one-ticket/one-QR scanner and revocation assumptions must be replaced by the v3.4 package/generation/credential and slot-use rules. Manual lookup is an additional input into that same credential validator, not a separate authorization path.

### Migration from v1

If v1 is already partially implemented:

1. **Drop the `manifests` table** and `manifest_key` columns
2. **Add the `revocations` table** + `events.revocation_version`
3. **Replace `ManifestService` with `RevocationService`** (much simpler)
4. **Swap HMAC for Ed25519** in `QrService`
5. **Change the scanner sync endpoints** from `/manifest` to `/revocations`
6. **Update the scanner app's local schema** (50K rows → 1K rows)
7. **Update transfer/refund logic** to call `RevocationService` instead of regenerating a manifest
8. **Then follow v2→v3 migration above** for the manual lookup capability

Token format is backward-compatible *at the wire level* (still base64-JSON), but the signature algorithm and `kid` field need to be added for the new scanner build. Plan a hard cutover or a version flag in the token.
