# TICKET QR CODE & OFFLINE SCANNING ARCHITECTURE v2

**Date**: June 4, 2026
**Supersedes**: May 17, 2026 (v1)
**Scope**: QR generation, ticket lifecycle, offline scanning, multi-day events, fraud prevention

---

## REVISION HISTORY

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

---

## CORE DESIGN PRINCIPLES

1. **The QR is a signed token, not a database ID** — it carries enough information to validate offline
2. **Versioned tickets** — every transfer/resale increments a version, invalidating old QRs
3. **Revocation-based offline sync** — scanners download a small list of *invalidated* tickets; everything else is assumed valid (proven by the token signature)
4. **First-scan-wins** — if two people present the same QR, the first scan succeeds, the second fails
5. **Graceful degradation** — offline mode works, syncs when network returns, resolves conflicts
6. **Asymmetric signing** — server holds the private key, scanners hold only the public key. A compromised scanner cannot forge QRs.

---

## 1. QR TOKEN FORMAT

The QR code does NOT contain a raw ticket UUID. It contains a **cryptographically signed JSON token** (compact, URL-safe):

```json
{
  "kid": "k_2026_q2",
  "tid": "550e8400-e29b-41d4-a716-446655440000",
  "eid": "event-uuid",
  "v": 3,
  "type": "vip",
  "days": ["2026-06-15", "2026-06-16"],
  "policy": "daily_single",
  "exp": 1718668800,
  "sig": "a1b2c3d4e5f6..."
}
```

| Field | Purpose | Example |
|-------|---------|---------|
| `kid` | Key ID — identifies which signing key was used (for rotation) | `"k_2026_q2"` |
| `tid` | Ticket ID (UUID) | `"550e8400-..."` |
| `eid` | Event ID (UUID) | `"event-uuid"` |
| `v` | Version number (increments on transfer/resale) | `3` |
| `type` | Ticket type | `"vip"`, `"regular"`, `"vvip"` |
| `days` | Valid dates (for multi-day events) | `["2026-06-15", "2026-06-16"]` |
| `policy` | Entry policy | `"single"`, `"multi"`, `"daily_single"` |
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

    def self.generate_token(ticket)
      payload = {
        kid: current_kid,
        tid: ticket.id,
        eid: ticket.event_id,
        v: ticket.version,
        type: ticket.ticket_type.name,
        days: ticket.event.event_dates.map(&:to_s),
        policy: ticket.event.entry_policy,
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

## 2. TICKET VERSIONING (RESALE/TRANSFER INVALIDATION)

### The Problem

User A buys a ticket → gets QR with `v: 1` → resells to User B → User A still has the old QR screenshot → both try to enter.

### The Solution: Version Increment + Revocation

Every transfer or resale increments the ticket's version. The server also adds the *old* (ticket_id, version) pair to the revocation list. The new owner's QR has the new version, which is not on the revocation list.

```ruby
# app/models/ticket.rb
class Ticket < ApplicationRecord
  belongs_to :event
  belongs_to :ticket_type
  belongs_to :owner, class_name: "Core::User", foreign_key: :owner_user_id

  t.integer :version, default: 1, null: false
  t.string :qr_token, null: false
  t.string :status, default: "active"  # active, used, transferred, refunded, cancelled

  def transfer_to(new_owner)
    transaction do
      old_version = version

      # Bump version and reassign
      self.version += 1
      self.owner = new_owner
      self.status = "active"
      self.qr_token = Core::QrService.generate_token(self)
      save!

      # Record the transfer
      TicketTransfer.create!(
        ticket: self,
        from_user: owner_was,
        to_user: new_owner,
        previous_version: old_version,
        new_version: version
      )

      # Add old version to revocation list (this is what invalidates A's QR)
      RevocationService.revoke_version(self, through_version: old_version)
    end
  end

  def complete_resale(listing, buyer)
    transaction do
      old_version = version

      self.version += 1
      self.owner = buyer
      self.status = "active"
      self.qr_token = Core::QrService.generate_token(self)
      save!

      listing.update!(status: "sold", buyer: buyer, sold_at: Time.current)

      RevocationService.revoke_version(self, through_version: old_version)

      SmsService.send_ticket_transfer_notification(self.owner.phone, self)
      SmsService.send_resale_confirmation(listing.seller.phone, self)
    end
  end

  def refund!
    transaction do
      self.status = "refunded"
      save!

      # Revoke ALL versions of this ticket
      RevocationService.mark_dead(self)
    end
  end

  def cancel!
    transaction do
      self.status = "cancelled"
      save!

      RevocationService.mark_dead(self)
    end
  end
end
```

### How Revocation Invalidation Works

The scanner holds a small table:

```
ticket_id          | revoked_through_version | is_dead
-------------------|-------------------------|--------
uuid-A (transferred) | 1                       | 0
uuid-B (refunded)    | 2                       | 1
```

When a QR is presented:

1. Scanner verifies the Ed25519 signature (token is authentic)
2. Scanner looks up `ticket_id` in its revocation table
3. If `is_dead = 1` → reject (ticket was refunded/cancelled)
4. If `token.version <= revoked_through_version` → reject (old version, transferred away)
5. Otherwise → continue with policy/day checks

### How This Prevents Fraud

| Scenario | What Happens | Result |
|----------|-------------|--------|
| User A resells to User B | Version 1→2, `(uuid, 1)` added to revocation list, new QR with v:2 issued to B | A's old QR (v:1) is rejected: `1 <= 1` ✓ |
| User A screenshots QR, sends to friend | Both present same QR (v:1) | First scan succeeds (no prior scan), second fails (already in scan log) |
| User A transfers to B, then tries to use old QR | Token signature is valid, but revocation list has `(uuid, 1)` | `1 <= 1` → rejected |
| Resale listing created but not yet sold | Ticket locked, version unchanged, no revocation entry | Original QR still works, listing can be cancelled without invalidating the QR |
| User A's ticket is refunded | `is_dead = 1` added for that ticket | All versions of that ticket rejected forever |

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
      revocation.is_dead = false
      revocation.save!
      bump_revocation_version!(ticket.event)
    end

    def self.mark_dead(ticket)
      revocation = Revocation.find_or_initialize_by(ticket_id: ticket.id)
      revocation.revoked_through_version = ticket.version
      revocation.is_dead = true
      revocation.save!
      bump_revocation_version!(ticket.event)
    end

    def self.unrevoke(ticket)  # only for reversed transfers
      revocation = Revocation.find_by(ticket_id: ticket.id)
      return unless revocation
      # We don't un-revoke dead tickets
      return if revocation.is_dead
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
          is_dead: r.is_dead
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

Event postponement is the same pattern as a transfer, applied to every active ticket in the event. The old version of every ticket is added to the revocation list, a new token is generated with the new dates, and the event's `revocation_version` is bumped once. Scanners receive a single bulk delta and apply it atomically.

```ruby
# app/services/platform/event_postponement_service.rb
module Core
  class EventPostponementService
    def self.postpone(event, new_dates)
      ActiveRecord::Base.transaction do
        # 1. Replace the event's schedule
        event.event_dates.destroy_all
        new_dates.each { |d| event.event_dates.create!(date: d) }

        # Reload the event_dates collection so subsequent reads of
        # `ticket.event.event_dates` (inside QrService.generate_token) return
        # the NEW dates, not a stale in-memory cache. Without this reload,
        # the token's `days` field is correct by happy accident — it only
        # works because find_each doesn't pre-cache the event association.
        # If the query is later changed to use `includes(:event)`, the cache
        # becomes stale and tokens get signed with empty `days`.
        event.event_dates.reload

        # 2. Reserve a single new revocation version for the whole bulk operation
        new_revocation_version = event.revocation_version + 1

        # 3. Re-issue every active ticket with the new dates
        event.tickets.where(status: %w[active listed_for_resale]).find_each do |ticket|
          old_version = ticket.version

          # Add the OLD (ticket_id, version) to the revocation list.
          # All these entries share new_revocation_version so scanners
          # treat the postponement as a single atomic delta.
          Revocation.create!(
            event_id: event.id,
            ticket_id: ticket.id,
            revoked_through_version: old_version,
            is_dead: false,
            revocation_version: new_revocation_version
          )

          # Bump version and sign a new token with the new dates.
          ticket.update!(
            version: old_version + 1,
            qr_token: QrService.generate_token(ticket)
          )
        end

        # 4. Commit the new revocation version (single bump for the whole event)
        event.update!(revocation_version: new_revocation_version)

        # 5. Push the new QRs to user apps (handled async to avoid blocking)
        TicketReissueNotifierJob.perform_later(event.id)

        { event: event, revoked_count: event.tickets.count, new_revocation_version: new_revocation_version }
      end
    end
  end
end
```

**Why this works without changing the scanner algorithm:**

- A token with the old dates has an old version. The scanner's existing check (`payload[:v] <= revocation.revoked_through_version`) rejects it.
- A token with the new dates has the new version. The scanner's existing check passes.
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
    { "tid": "uuid-2", "revoked_through_version": 3, "is_dead": true }
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
      { "tid": "uuid-100", "revoked_through_version": 2, "is_dead": true }
    ],
    "removed": []
  }
}
```

Typical delta: 0-5 changes, <500 bytes. Worst case (100 transfers in a sync window): ~4KB.

#### Step 3: Local Storage (Scanner Device)

The scanner stores three tables in local SQLite:

```sql
-- The revocation list (the "manifest" — inverted)
CREATE TABLE revocations (
  ticket_id TEXT PRIMARY KEY,
  revoked_through_version INTEGER,  -- reject if token version <= this
  is_dead INTEGER,                  -- 1 = refunded/cancelled (all versions rejected)
  received_at INTEGER
);

-- Per-scan log (synced to server later)
CREATE TABLE scans (
  id INTEGER PRIMARY KEY,
  ticket_id TEXT,
  scan_date TEXT,                   -- "2026-06-15"
  scanner_id TEXT,
  scanned_at INTEGER,
  result TEXT,                      -- success, already_used, revoked, invalid_signature, ...
  synced INTEGER DEFAULT 0,
  server_scan_id TEXT
);

-- Scanner state
CREATE TABLE scanner_state (
  key TEXT PRIMARY KEY,
  value TEXT
);
-- Keys: 'event_id', 'revocation_version', 'last_sync_at', 'signing_key_id'
```

Size comparison for a 50K-ticket event with 1,000 transfers and 50 refunds:

| v1 (manifest) | v2 (revocation list) |
|---|---|
| 50,000 rows | 1,050 rows |
| ~2MB | ~42KB |
| Pre-event seed required | Cold-start works in 5 min |

**98% smaller.** This is the headline win of v2.

#### Step 4: Offline Scan Validation

> **Note on language:** The actual scanner is a mobile-native app (Swift on iOS, Kotlin on Android, or Flutter). The Ruby shown here is the algorithm expressed in the same language as the rest of this document. When implementing in Swift/Kotlin, port the logic line-for-line — the SQLite schema, query patterns, and decision tree are identical.

```ruby
# Scanner app (runs on device, mirrored from mobile-native code)
class Scanner::LocalValidator
  def self.validate(qr_token, current_date)
    # 1. Verify Ed25519 signature (uses cached public keys, ~50µs)
    payload = QrService.verify_token(qr_token)
    return :invalid_signature unless payload

    # 2. Check the revocation list
    revocation = Revocation.find_by(ticket_id: payload[:tid])
    return :revoked_dead if revocation&.is_dead
    return :revoked_old_version if revocation && payload[:v] <= revocation.revoked_through_version

    # 3. Check valid day
    return :not_valid_today unless payload[:days].include?(current_date.to_s)

    # 4. Check entry policy against local scan log
    case payload[:policy]
    when "single"
      return :already_used if Scan.where(ticket_id: payload[:tid], result: :success).exists?
    when "daily_single"
      return :already_used_today if Scan.where(ticket_id: payload[:tid], scan_date: current_date, result: :success).exists?
    when "multi"
      # Unlimited entries, no check needed
    end

    # 5. All checks passed — record scan
    Scan.create!(
      ticket_id: payload[:tid],
      scan_date: current_date,
      scanned_at: Time.current.to_i,
      result: :success,
      synced: false
    )
    :success
  end
end
```

Five local lookups, all O(1) on indexed tables. Total latency: ~5-10ms on phone hardware.

#### Step 5: Sync Scans + Receive Latest Revocations

```ruby
# Background job on scanner device (runs whenever network is available)
class Scanner::SyncWorker
  def self.run(event_id, device_id)
    unsynced = Scan.where(synced: false).limit(500)
    return if unsynced.empty?

    response = HTTP.post("/api/v1/scanner/events/#{event_id}/scans", json: {
      device_id: device_id,
      scans: unsynced.map { |s|
        { ticket_id: s.ticket_id, scan_date: s.scan_date, scanned_at: s.scanned_at, result: s.result }
      }
    })

    return unless response.success?

    # Mark our scans as synced
    Scan.where(id: unsynced.map(&:id)).update_all(synced: true)

    # Apply any new revocations the server sent back
    apply_revocation_changes(response["revocation_changes"])

    # Update local version
    ScannerState.set("revocation_version", response["revocation_version"])
  end

  def self.apply_revocation_changes(changes)
    Array(changes["added"]).each do |r|
      Revocation.upsert(
        ticket_id: r["tid"],
        revoked_through_version: r["revoked_through_version"],
        is_dead: r["is_dead"]
      )
    end

    Array(changes["removed"]).each do |tid|
      Revocation.where(ticket_id: tid).delete_all  # only happens for unrevoke
    end
  end
end
```

Every scan upload also receives the latest revocation deltas, so the scanner self-heals without a separate sync call.

#### Step 6: Conflict Resolution

What if a ticket was scanned offline, but was actually transferred before the scan?

```ruby
# Server-side scan processing
#
# `scanner_revocation_version` is the version the scanner last synced. Used to
# compute the revocation delta returned in the response so the scanner can
# self-heal (apply any revocations it missed while offline).
def process_offline_scans(event_id, device_id, scans, scanner_revocation_version:)
  accepted = []
  rejected = []

  scans.each do |scan|
    ticket = Ticket.find_by(id: scan[:ticket_id], event_id: event_id)
    next rejected << { client_scan_id: scan[:id], reason: "unknown_ticket" } unless ticket

    # Server is source of truth — check current version
    if ticket.version > scan[:scanned_version]
      rejected << {
        client_scan_id: scan[:id],
        ticket_id: scan[:ticket_id],
        reason: "version_mismatch",
        current_version: ticket.version
      }
      next
    end

    if ticket.status_refunded? || ticket.status_cancelled?
      rejected << { client_scan_id: scan[:id], reason: "ticket_dead" }
      next
    end

    # Check for duplicate scan on server side (two scanners scanned same ticket offline)
    if CheckinLog.exists?(ticket_id: ticket.id, event_date: scan[:scan_date], result: 'success')
      rejected << { client_scan_id: scan[:id], reason: "server_already_scanned" }
      next
    end

    CheckinLog.create!(
      ticket: ticket,
      scanner_device_id: device_id,
      event_date: scan[:scan_date],
      scanned_at: scan[:scanned_at],
      result: 'success'
    )
    ticket.update!(first_scanned_at: scan[:scanned_at]) if ticket.first_scanned_at.nil?

    accepted << { client_scan_id: scan[:id], server_scan_id: CheckinLog.last.id }
  end

  # Always return latest revocation version so scanner self-heals.
  # Note: scanner_revocation_version is a method parameter, NOT a scan field —
  # it applies once to the whole batch, not per-scan.
  {
    accepted: accepted,
    rejected: rejected,
    revocation_version: event.current_revocation_version,
    revocation_changes: RevocationService.changes_since(event, scanner_revocation_version)[:changes]
  }
end
```

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

- **`single`**: if `Scan.where(ticket_id, result: 'success').any?` → reject
- **`daily_single`**: if `Scan.where(ticket_id, scan_date: today, result: 'success').any?` → reject
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
| 4 | **Dynamic QR (opt-in for online-connected users only)** | The app may offer a "secure mode" that refreshes the QR every 30 seconds — opt-in, not the default. | **No — not in v2** |

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

#### Future Enhancement: Dynamic QR (NOT in v2 scope)

This is included for reference only. **Do not implement in v2.** Re-evaluate after Phase 5 if your user base is reliably online at venues and screenshots stop being the primary delivery mechanism.

```ruby
# app/services/platform/ticket_dynamic_qr.rb
# Reuses QrService.sign_payload so the signing key and canonical JSON
# are identical to the static token — do NOT reimplement signing here.
class TicketDynamicQr
  def self.generate(ticket)
    payload = {
      kid: QrService.current_kid,
      tid: ticket.id,
      v: ticket.version,
      nonce: SecureRandom.hex(8),
      exp: 30.seconds.from_now.to_i
    }

    signed = payload.merge(sig: Base64.strict_encode64(QrService.sign_payload(payload)))
    Base64.urlsafe_encode64(signed.to_json, padding: false)
  end
end
```

If you later add this, the scanner accepts nonces within a 60-second window (30s before + 30s after). Screenshots older than 30 seconds would be invalid. **Only enable this for users who have explicitly opted in AND who have a live network connection at the venue.** Treat it as a power-user feature, not a default.

### 5.3 Replay Attack Prevention

**Problem**: Someone scans a used ticket's QR and tries to reuse it later.

**Solution**: Two layers:

1. **Offline**: scanner checks local `scans` table for prior successful scan of this ticket (per policy)
2. **Online (on sync)**: server checks `checkin_logs` for prior successful scan; rejects duplicates

```ruby
# Server-side duplicate detection
def process_scan(scan, ticket)
  if CheckinLog.exists?(ticket_id: ticket.id, event_date: scan[:scan_date], result: 'success')
    return { success: false, reason: "already_scanned_today" }
  end

  CheckinLog.create!(ticket: ticket, scanned_at: scan[:scanned_at], result: 'success')
  { success: true }
end
```

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
| Read data | See revocation list (ticket IDs + versions) | See PII (no phone numbers, names, emails in the revocation list) |
| Forge QRs | No (only has public key) | Forge valid QRs for any event |
| Fake scans | Yes (can write to local scan log) | — but server detects duplicates on sync |
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

## 11. DATABASE SCHEMA

```ruby
# Tickets
create_table :tickets, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :ticket_type_id, null: false
  t.uuid :owner_user_id                     # Current owner (Core::User)
  t.uuid :order_item_id, null: false
  t.integer :version, default: 1, null: false
  t.string :qr_token, null: false           # The signed QR payload
  t.string :status, default: "active", null: false
  t.string :holder_name
  t.string :holder_email
  t.string :holder_phone
  t.datetime :issued_at
  t.datetime :first_scanned_at
  t.datetime :last_scanned_at
  t.timestamps
end

# Revocations (the new "manifest" — server-side)
create_table :revocations, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :ticket_id, null: false
  t.integer :revoked_through_version, null: false  # reject token version <= this
  t.boolean :is_dead, default: false, null: false # true = refunded/cancelled (all versions dead)
  t.integer :revocation_version, null: false       # monotonic, for delta sync
  t.datetime :created_at, null: false
  t.timestamps
end
add_index :revocations, [:event_id, :revocation_version]
add_index :revocations, :ticket_id, unique: true

# Add revocation_version to events (for delta tracking)
add_column :events, :revocation_version, :integer, default: 0, null: false

# Check-in logs (server-side record of all scans)
create_table :checkin_logs, id: :uuid do |t|
  t.uuid :ticket_id, null: false
  t.uuid :scanner_device_id
  t.string :result, null: false             # success, duplicate, invalid, version_mismatch
  t.datetime :scanned_at, null: false
  t.string :event_date                      # "2026-06-15" (for multi-day tracking)
  t.timestamps
end

# Ticket transfers (audit trail)
create_table :ticket_transfers, id: :uuid do |t|
  t.uuid :ticket_id, null: false
  t.uuid :from_user_id
  t.uuid :to_user_id, null: false
  t.integer :previous_version, null: false
  t.integer :new_version, null: false
  t.string :transfer_type, null: false      # gift, resale
  t.integer :resale_price                   # Cents, null for gifts
  t.datetime :completed_at
  t.timestamps
end

# Resale listings
create_table :resale_listings, id: :uuid do |t|
  t.uuid :ticket_id, null: false
  t.uuid :seller_id, null: false
  t.uuid :buyer_id                          # Null until sold
  t.integer :price, null: false             # Cents
  t.integer :original_price, null: false    # Cents (for price cap enforcement)
  t.string :status, default: "listed", null: false
  t.datetime :listed_at
  t.datetime :sold_at
  t.datetime :expires_at
  t.timestamps
end

# Scanner devices
create_table :scanner_devices, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.uuid :event_id                          # Assigned event (null for multi-event scanners)
  t.string :device_id, null: false
  t.string :device_token, null: false
  t.string :status, default: "active", null: false
  t.datetime :last_sync_at
  t.datetime :last_seen_at
  t.timestamps
end
# v1 had: t.string :manifest_key  → REMOVED in v2 (not needed)
# v1 had: separate `manifests` table → REMOVED in v2 (revocations is the manifest now)
```

### Schema Diff vs v1

| Removed | Added |
|---|---|
| `tickets.manifest_key` (per-device manifest encryption) | `revocations` table |
| `scanner_devices.manifest_key` | `events.revocation_version` |
| `manifests` table (generated manifest history) | `revocations.revocation_version` (for delta tracking) |

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
```

### Ticket Endpoints (unchanged from v1)

```
POST /api/v1/tickets/:id/transfer
  → Transfer ticket to another phone number
  → Increments version, generates new QR, adds old version to revocation list

POST /api/v1/tickets/:id/resale
  → List ticket for resale
  → Locks ticket, creates listing

POST /api/v1/resale_listings/:id/purchase
  → Buy a resale listing
  → Increments version, transfers to buyer, generates new QR, adds old version to revocation list

GET /api/v1/tickets/:id/qr
  → Get current QR token

GET /api/v1/tickets/:id/history
  → Full ownership and scan history
```

### Admin Endpoints (new in v2 for debugging)

```
GET /api/v1/admin/events/:event_id/revocations
  → View current revocation list (for support / debugging)

POST /api/v1/admin/events/:event_id/tickets/:id/revoke
  → Manually revoke a ticket (e.g., chargeback, fraud investigation)
  → Adds to revocation list with is_dead: true
```

---

## 13. IMPLEMENTATION PLAN

### Phase 1: Core QR System (Week 1-2)
1. `QrService` — Ed25519 token generation and verification
2. Key management — store private key in env, expose public keys via API
3. `Ticket` model with version tracking
4. QR code generation (using `rqrcode` gem)
5. Basic online scanning endpoint

### Phase 2: Revocation & Offline (Week 2-3)
1. `RevocationService` — generate, apply, delta
2. `Revocation` model + `Event#revocation_version`
3. Revocation download API (full + delta)
4. Scanner local database schema (`revocations`, `scans`, `scanner_state`)
5. Offline validation algorithm
6. Scan upload endpoint with conflict resolution

### Phase 3: Multi-Day & Policies (Week 3-4)
1. `EventDate` model
2. Entry policy enforcement (`single`, `multi`, `daily_single`)
3. Per-day entry tracking in scan log
4. Scanner UI for multi-day events

### Phase 4: Fraud Prevention & Device Security (Week 4-5)
1. (Optional) Dynamic QR with rotating nonce
2. Screenshot detection (app-side)
3. Device authentication and registration
4. GPS validation for scanners
5. Rate limiting on scan endpoint
6. Remote wipe capability

### Phase 5: Scale & Polish (Week 5-6)
1. Delta revocation optimization (batched, indexed)
2. (Optional) Hierarchical gateway sync for zero-cellular venues
3. NTP time sync
4. Scanner app UI (big success/failure indicators)
5. Admin dashboard for scan monitoring + revocation viewer
6. Conflict review workflow

**Estimated total: 6 weeks** (down from 8 weeks in v1, because Phases 2 and 5 are much smaller)

---

## 14. TECHNOLOGY STACK

| Component | Technology | Why | v2 Change |
|---|---|---|---|
| QR generation | `rqrcode` gem | Pure Ruby, no native dependencies | Unchanged |
| QR scanning (app) | Native camera API (iOS/Android) | Fast, reliable, works offline | Unchanged |
| Token signing | **Ed25519** (OpenSSL built-in) | Asymmetric, scanner holds public key only, rotatable | **Was HMAC-SHA256 in v1** |
| Revocation list transport | HTTPS + JSON | Simple, debuggable | Unchanged (was manifest in v1) |
| Revocation list size | 42KB typical for 50K event | 98% smaller than v1 manifest | New metric |
| Scanner local DB | SQLite | Built-in, fast, reliable | Unchanged |
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
| Event date changes (postponed) | Run `EventPostponementService.postpone(event, new_dates)` — bulk-revokes every active ticket's old version and re-issues tokens with the new dates. Scanners receive a single atomic delta. See §3 "Bulk Operation: Event Postponement" for the full flow. |
| Ticket type upgrade at venue (Regular → VIP) | Server creates new ticket (new version), invalidates old (adds to revocation list). Scanner receives update on next sync. |
| Scanner battery dies mid-event | Swap to backup scanner. Backup downloads latest revocation list (42KB, ~1s). No data lost (scans synced to server). |
| Signing key rotation | Server signs new tokens with new `kid`, keeps old key active for grace period (e.g., 7 days). Scanner caches both public keys. Old tokens still verify until grace period ends. |
| Revocation list grows unbounded (long-running event) | Bound by ticket count, not transfers. For a 50K event, max ~50K rows (all tickets dead). Cap is acceptable. For multi-week events, consider archival of resolved revocations. |
| Server is down during entire event | All scanners operate offline with whatever revocation list they last synced. Worst case: some transfers from the offline window won't be reflected locally until server returns. Server-side conflict resolution catches these on sync. |
| Clock skew between server and scanner | Tokens use `days` (date-level granularity) not exact times, so clock skew is mostly irrelevant. For door-open time, server returns correction on sync. |
| Attacker tries to flood scanner with junk QR codes | Signature verification fails in <1ms. Combined with rate limiting per scanner, the attack is rejected without slowing the line. |

---

## SUMMARY

**The architecture is built on three pillars (v2):**

1. **Signed QR tokens (Ed25519)** — self-contained, verifiable, versioned. The scanner holds only the public key, so a compromised scanner cannot forge QRs.

2. **Revocation-based offline sync** — scanners download a *small* list of *invalidated* tickets (~42KB for 50K attendees), and accept any signed token not on that list. The token signature proves authenticity; the revocation list proves currency.

3. **Version increment on transfer/resale + revocation entry** — old QRs become invalid because the server explicitly added the old (ticket_id, version) pair to the revocation list. First-scan-wins prevents replay attacks on the local scanner.

**Multi-day events** are handled through entry policies (`single`, `multi`, `daily_single`) tracked in the scanner's local scan log, with the policy field itself signed in the token.

**Fraud prevention** is layered: Ed25519 signatures prevent forgery, revocation entries prevent reuse after transfer, first-scan-wins prevents duplicates, and device authentication + remote wipe protect against scanner compromise.

**Offline scanning** works because the *only* state needed offline is the small revocation list. The token is self-validating for authenticity. The scanner validates locally, logs scans, and syncs when the network returns.

### What Got Simpler

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

### What Stayed the Same

- Token format (signed JSON, base64-encoded)
- Version increment on transfer/resale
- Multi-day entry policies
- First-scan-wins + per-day scan tracking
- Server-side conflict resolution
- Tiered fraud defense (signatures, versioning, policies, device auth)

### Migration from v1

If v1 is already partially implemented:

1. **Drop the `manifests` table** and `manifest_key` columns
2. **Add the `revocations` table** + `events.revocation_version`
3. **Replace `ManifestService` with `RevocationService`** (much simpler)
4. **Swap HMAC for Ed25519** in `QrService`
5. **Change the scanner sync endpoints** from `/manifest` to `/revocations`
6. **Update the scanner app's local schema** (50K rows → 1K rows)
7. **Update transfer/refund logic** to call `RevocationService` instead of regenerating a manifest

Token format is backward-compatible *at the wire level* (still base64-JSON), but the signature algorithm and `kid` field need to be added for the new scanner build. Plan a hard cutover or a version flag in the token.
