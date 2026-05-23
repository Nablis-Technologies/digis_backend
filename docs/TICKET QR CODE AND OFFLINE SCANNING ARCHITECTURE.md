# TICKET QR CODE & OFFLINE SCANNING ARCHITECTURE

**Date**: May 17, 2026
**Scope**: QR generation, ticket lifecycle, offline scanning, multi-day events, fraud prevention

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
3. **Manifest-based offline sync** — scanners download a signed list of valid tickets before the event
4. **First-scan-wins** — if two people present the same QR, the first scan succeeds, the second fails
5. **Graceful degradation** — offline mode works, syncs when network returns, resolves conflicts

---

## 1. QR TOKEN FORMAT

The QR code does NOT contain a raw ticket UUID. It contains a **cryptographically signed JSON token** (compact, URL-safe):

```json
{
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
| `tid` | Ticket ID (UUID) | `"550e8400-..."` |
| `eid` | Event ID (UUID) | `"event-uuid"` |
| `v` | Version number (increments on transfer/resale) | `3` |
| `type` | Ticket type | `"vip"`, `"regular"`, `"vvip"` |
| `days` | Valid dates (for multi-day events) | `["2026-06-15", "2026-06-16"]` |
| `policy` | Entry policy | `"single"`, `"multi"`, `"daily_single"` |
| `exp` | Expiration timestamp (epoch) | `1718668800` |
| `sig` | HMAC-SHA256 signature | `"a1b2c3..."` |

### Signature

```ruby
# app/services/platform/qr_service.rb
module Core
  class QrService
    SECRET_KEY = ENV["QR_SIGNING_KEY"] || Rails.application.secret_key_base[0..31]

    def self.generate_token(ticket)
      payload = {
        tid: ticket.id,
        eid: ticket.event_id,
        v: ticket.version,
        type: ticket.ticket_type.name,
        days: ticket.event.event_dates.map(&:to_s),
        policy: ticket.event.entry_policy,
        exp: ticket.event.ends_at.to_i
      }

      payload_json = payload.to_json
      signature = OpenSSL::HMAC.hexdigest("SHA256", SECRET_KEY, payload_json)
      payload[:sig] = signature

      # Compact encoding: Base64URL, no padding
      Base64.urlsafe_encode64(payload_json, padding: false)
    end

    def self.verify_token(token_string)
      decoded = Base64.urlsafe_decode64(token_string)
      payload = JSON.parse(decoded, symbolize_names: true)

      expected_sig = payload.delete(:sig)
      expected_sig_payload = payload.merge(sig: expected_sig).to_json
      actual_sig = OpenSSL::HMAC.hexdigest("SHA256", SECRET_KEY, expected_sig_payload)

      return nil unless ActiveSupport::SecurityUtils.secure_compare(expected_sig, actual_sig)
      return nil if payload[:exp] < Time.current.to_i

      payload
    rescue
      nil
    end
  end
end
```

**Why this works**:
- The signature prevents forgery (only the server can generate valid QRs)
- The version (`v`) enables invalidation on transfer/resale
- The payload is self-contained — offline scanners can validate without a database lookup
- Compact encoding keeps QR codes scannable (smaller data = smaller QR = faster scan)

---

## 2. TICKET VERSIONING (RESALE/TRANSFER INVALIDATION)

### The Problem

User A buys a ticket → gets QR with `v: 1` → resells to User B → User A still has the old QR screenshot → both try to enter.

### The Solution: Version Increment

Every transfer or resale increments the ticket's version. The old QR (with the old version) becomes invalid.

```ruby
# app/models/ticket.rb
class Ticket < ApplicationRecord
  belongs_to :event
  belongs_to :ticket_type
  belongs_to :owner, class_name: "Core::User", foreign_key: :owner_user_id

  # Version tracking
  t.integer :version, default: 1, null: false
  t.string :qr_token               # The signed QR payload
  t.string :status, default: "active"  # active, used, transferred, refunded, cancelled

  def transfer_to(new_owner)
    transaction do
      # Increment version
      self.version += 1
      self.owner = new_owner
      self.status = "active"  # Reset if it was previously used (depends on policy)
      self.qr_token = Core::QrService.generate_token(self)
      save!

      # Record the transfer
      TicketTransfer.create!(
        ticket: self,
        from_user: owner_was,
        to_user: new_owner,
        previous_version: version - 1,
        new_version: version
      )
    end
  end

  def resale_list(price)
    transaction do
      listing = ResaleListing.create!(
        ticket: self,
        seller: owner,
        price: price,
        status: "listed",
        ticket_version_at_listing: version
      )

      # Ticket is locked until sold or listing cancelled
      self.status = "listed_for_resale"
      save!

      listing
    end
  end

  def complete_resale(listing, buyer)
    transaction do
      # Increment version (invalidates old QR)
      self.version += 1
      self.owner = buyer
      self.status = "active"
      self.qr_token = Core::QrService.generate_token(self)
      save!

      listing.update!(status: "sold", buyer: buyer, sold_at: Time.current)

      # Notify both parties
      SmsService.send_ticket_transfer_notification(self.owner.phone, self)
      SmsService.send_resale_confirmation(listing.seller.phone, self)
    end
  end
end
```

### How This Prevents Fraud

| Scenario | What Happens | Result |
|----------|-------------|--------|
| User A resells to User B | Version goes from 1 → 2, new QR generated for B | A's old QR (v:1) is invalid |
| User A screenshots QR, sends to friend | Both present same QR (v:1) | First scan succeeds, second fails (already used) |
| User A transfers to B, then tries to use old QR | Scanner checks version against manifest | Version mismatch → rejected |
| Resale listing created but not yet sold | Ticket locked, version unchanged | Original QR still works, listing can be cancelled |

---

## 3. OFFLINE SCANNING ARCHITECTURE

### The Problem

Venue network fails. 500 people are in line. Scanners can't reach the server. Tickets must still be validated.

### The Solution: Manifest-Based Offline Sync

#### Step 1: Manifest Generation (Server-Side)

Before the event, the server generates a **Ticket Manifest** — a signed, compressed list of all valid tickets for that event:

```ruby
# app/services/platform/manifest_service.rb
module Core
  class ManifestService
    def self.generate(event)
      tickets = event.tickets.active.includes(:ticket_type)

      manifest = {
        event_id: event.id,
        generated_at: Time.current.iso8601,
        version: event.manifest_version,
        tickets: tickets.map { |t| {
          id: t.id,
          version: t.version,
          type: t.ticket_type.name,
          days: event.event_dates.map(&:to_s),
          policy: event.entry_policy,
          owner_phone: t.owner&.phone
        }},
        total_count: tickets.count
      }

      # Sign the manifest
      manifest_json = manifest.to_json
      signature = sign_manifest(manifest_json)
      manifest[:signature] = signature

      # Compress (gzip)
      compressed = Zlib.gzip(manifest_json)

      {
        data: compressed,
        size: compressed.bytesize,
        ticket_count: tickets.count,
        generated_at: manifest[:generated_at],
        version: manifest[:version]
      }
    end

    def self.sign_manifest(data)
      private_key = OpenSSL::PKey.read(ENV["MANIFEST_SIGNING_KEY"])
      Base64.strict_encode64(private_key.sign("SHA256", data))
    end
  end
end
```

#### Step 2: Manifest Download (Scanner App)

Scanners download the manifest before the event starts:

```
GET /api/v1/scanner/events/:event_id/manifest
Headers: If-None-Match: "manifest-version-5"

Response:
{
  "manifest": "<base64-gzip-compressed-data>",
  "version": 6,
  "generated_at": "2026-06-14T10:00:00Z",
  "ticket_count": 5000,
  "delta_from_version": 5,
  "changes": {
    "added": ["ticket-uuid-1", "ticket-uuid-2"],
    "updated": [{"id": "ticket-uuid-3", "version": 4}],
    "removed": ["ticket-uuid-4"]
  }
}
```

**Delta updates**: If the scanner already has version 5, the server only sends changes since version 5 — not the full manifest. This keeps downloads fast even for large events.

#### Step 3: Local Storage (Scanner Device)

The scanner stores the manifest in a local SQLite database:

```ruby
# Scanner's local database schema
create_table :manifest_tickets do
  column :ticket_id, :string, primary_key: true
  column :version, :integer
  column :ticket_type, :string
  column :valid_days, :string  # JSON array
  column :entry_policy, :string
  column :owner_phone, :string
end

create_table :scan_logs do
  column :id, :integer, primary_key: true
  column :ticket_id, :string
  column :scanned_at, :datetime
  column :result, :string  # success, duplicate, invalid, version_mismatch
  column :scanner_device_id, :string
  column :synced, :boolean, default: false
end

create_table :entry_counts do
  column :ticket_id, :string
  column :date, :date
  column :count, :integer
  column :primary_key: [:ticket_id, :date]
end
```

#### Step 4: Offline Scan Validation

When a QR is scanned offline:

```ruby
# Scanner app (pseudo-code, runs on device)
def validate_qr_offline(qr_token, current_date)
  # 1. Verify signature
  payload = QrService.verify_token(qr_token)
  return :invalid_signature unless payload

  # 2. Check against local manifest
  local_ticket = ManifestTicket.find_by(ticket_id: payload[:tid])
  return :not_found unless local_ticket

  # 3. Check version (detects transfer/resale)
  if payload[:v] < local_ticket.version
    return :version_mismatch  # Ticket was transferred/reselled after this QR was generated
  end

  # 4. Check entry policy
  case payload[:policy]
  when "single"
    if EntryCount.where(ticket_id: payload[:tid]).any?
      return :already_used
    end
  when "daily_single"
    if EntryCount.where(ticket_id: payload[:tid], date: current_date).any?
      return :already_used_today
    end
  when "multi"
    # Unlimited entries, no check needed
  end

  # 5. Check valid days
  unless payload[:days].include?(current_date.to_s)
    return :not_valid_today
  end

  # 6. All checks passed
  EntryCount.create!(ticket_id: payload[:tid], date: current_date, count: 1)
  ScanLog.create!(ticket_id: payload[:tid], result: :success, synced: false)
  :success
end
```

#### Step 5: Sync When Network Returns

```ruby
# Background job on scanner device
def sync_scan_logs
  unsynced = ScanLog.where(synced: false)
  return if unsynced.empty?

  response = HTTP.post("/api/v1/scanner/sync", json: {
    device_id: device_id,
    scans: unsynced.map { |s| { ticket_id: s.ticket_id, result: s.result, scanned_at: s.scanned_at } }
  })

  if response.success?
    unsynced.update_all(synced: true)

    # Apply server-side updates to local manifest
    if response["manifest_updates"]
      apply_manifest_updates(response["manifest_updates"])
    end
  end
end
```

#### Step 6: Conflict Resolution

What if a ticket was scanned offline, but was actually transferred before the scan?

```ruby
# Server-side sync endpoint
def sync_scans(device_id, scans)
  conflicts = []

  scans.each do |scan|
    ticket = Ticket.find_by(id: scan[:ticket_id])
    next unless ticket

    if ticket.version > scan[:expected_version]
      # Ticket was transferred after this scanner's manifest was generated
      conflicts << {
        ticket_id: ticket.id,
        issue: "version_mismatch",
        scanner_version: scan[:expected_version],
        current_version: ticket.version,
        action: "flag_for_review"
      }
      next
    end

    if ticket.status == "used"
      conflicts << {
        ticket_id: ticket.id,
        issue: "duplicate_scan",
        action: "reject"
      }
      next
    end

    # Record the scan on the server
    CheckinLog.create!(ticket: ticket, scanner_device_id: device_id, scanned_at: scan[:scanned_at])
    ticket.mark_used!
  end

  # Return updated manifest changes for this device
  {
    success: true,
    manifest_updates: generate_delta_for_device(device_id),
    conflicts: conflicts
  }
end
```

---

## 4. MULTI-DAY EVENT ENTRY

### The Problem

An event runs for 2 days (June 15-16). A single ticket should grant entry on both days. But the scanner needs to track: has this ticket been used today? Can it be used tomorrow?

### The Solution: Entry Policies

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

```ruby
def check_entry_policy(ticket, current_date)
  case ticket.event.entry_policy
  when "single"
    # Has this ticket been used on ANY day?
    if CheckinLog.where(ticket_id: ticket.id).exists?
      return { valid: false, reason: "already_used" }
    end
  when "multi"
    # Always valid (within event dates)
    unless ticket.event.event_dates.exists?(date: current_date)
      return { valid: false, reason: "not_valid_today" }
    end
  when "daily_single"
    # Has this ticket been used TODAY?
    if CheckinLog.where(ticket_id: ticket.id, date: current_date).exists?
      return { valid: false, reason: "already_used_today" }
    end
    unless ticket.event.event_dates.exists?(date: current_date)
      return { valid: false, reason: "not_valid_today" }
    end
  end

  { valid: true }
end
```

### Offline Tracking

The scanner maintains a local `entry_counts` table:

```
ticket_id          | date       | count
-------------------|------------|------
550e8400-...       | 2026-06-15 | 1
550e8400-...       | 2026-06-16 | 0
```

When scanning offline:
- Check `entry_counts` for this ticket + today's date
- If count >= 1 and policy is `daily_single` → reject
- If count >= 1 and policy is `single` → reject
- Otherwise → accept, increment count

---

## 5. FRAUD PREVENTION

### 5.1 Counterfeit QR Prevention

**Problem**: Someone generates fake QR codes with random UUIDs.

**Solution**: Cryptographic signature (HMAC-SHA256). The scanner verifies the signature before accepting any QR.

```ruby
# Scanner verifies:
payload = QrService.verify_token(qr_string)
return :invalid if payload.nil?  # Signature doesn't match or expired
```

Only the server knows the signing key. Fake QRs will fail signature verification.

### 5.2 Screenshot/Forwarding Fraud

**Problem**: User screenshots QR, sends to friend. Both try to enter.

**Solution**: Layered defense:

| Layer | Mechanism | Effectiveness |
|-------|-----------|---------------|
| 1 | **First-scan-wins** | First person to scan gets in, second is rejected |
| 2 | **Dynamic QR (in-app)** | QR refreshes every 30 seconds in the app. Screenshots expire. |
| 3 | **Screenshot detection** | App detects screenshot and shows warning: "This ticket may be compromised" |
| 4 | **Owner phone match** | Scanner shows owner's phone number. Staff can verify identity. |

**Dynamic QR Implementation**:

```ruby
# In the app, the QR code includes a rotating nonce:
def generate_dynamic_qr(ticket)
  nonce = SecureRandom.hex(8)
  expires_at = 30.seconds.from_now.to_i

  payload = {
    tid: ticket.id,
    v: ticket.version,
    nonce: nonce,
    exp: expires_at,
    sig: sign({ tid: ticket.id, v: ticket.version, nonce: nonce, exp: expires_at })
  }

  Base64.urlsafe_encode64(payload.to_json, padding: false)
end
```

The scanner accepts nonces within a 60-second window (30s before + 30s after). Screenshots older than 30 seconds are invalid.

### 5.3 Replay Attack Prevention

**Problem**: Someone scans a used ticket's QR and tries to reuse it later.

**Solution**: Server tracks scan state. Offline scanners track locally. On sync, conflicts are resolved.

```ruby
# Server-side: mark ticket as used
def mark_ticket_used(ticket_id, scanner_device_id, scanned_at)
  ticket = Ticket.find(ticket_id)

  if ticket.used?
    # Already used — record the duplicate attempt
    CheckinLog.create!(
      ticket: ticket,
      scanner_device_id: scanner_device_id,
      scanned_at: scanned_at,
      result: "duplicate"
    )
    return { success: false, reason: "already_used" }
  end

  ticket.used!
  CheckinLog.create!(
    ticket: ticket,
    scanner_device_id: scanner_device_id,
    scanned_at: scanned_at,
    result: "success"
  )
  { success: true }
end
```

---

## 6. SCANNER DEVICE SECURITY

### Problem

A scanner device is stolen or compromised. The attacker could:
- Access the local manifest (see all ticket holder phone numbers)
- Mark tickets as scanned (denial of service)
- Generate fake "success" scans

### Solution

| Measure | Implementation |
|---------|---------------|
| **Device authentication** | Each scanner registers with the server, gets a device-specific token |
| **Manifest encryption** | Manifest is encrypted with a device-specific key. Stolen device can't read it without the key. |
| **Remote wipe** | Server can push a "wipe" command to a compromised device |
| **Scan rate limiting** | A single scanner can't scan more than X tickets per minute (detects automated attacks) |
| **GPS validation** | Scanner only accepts scans within the venue's GPS coordinates |

```ruby
# Scanner registration
def register_scanner(device_id, organization_id)
  device = ScannerDevice.create!(
    device_id: device_id,
    organization_id: organization_id,
    device_token: SecureRandom.hex(32),
    status: "active"
  )

  # Generate device-specific manifest encryption key
  device.manifest_key = OpenSSL::Cipher.new("aes-256-gcm").random_key
  device.save!

  device
end

# Manifest encryption for a specific device
def encrypt_manifest_for_device(manifest_json, device)
  cipher = OpenSSL::Cipher.new("aes-256-gcm")
  cipher.encrypt
  cipher.key = device.manifest_key
  cipher.iv = iv = cipher.random_iv
  cipher.auth_data = ""

  encrypted = cipher.update(manifest_json) + cipher.final
  tag = cipher.auth_tag

  Base64.strict_encode64(iv + encrypted + tag)
end
```

---

## 7. LARGE EVENT SCALE (50K+ ATTENDEES)

### Problem

A manifest for 50,000 tickets is ~5MB compressed. Downloading this to every scanner takes time and bandwidth.

### Solution

| Technique | Impact |
|-----------|--------|
| **Delta updates** | Only send changes since last manifest. Typical delta: <10KB |
| **Chunked download** | Split manifest into chunks. Resume interrupted downloads. |
| **Pre-event seeding** | Seed scanners 24 hours before the event. Only delta updates on event day. |
| **Manifest compression** | Use Brotli or Zstandard instead of gzip for better compression. |
| **Selective manifests** | Scanner only downloads tickets for the event it's scanning (not all events). |

```ruby
# Delta manifest generation
def generate_delta_manifest(event, since_version)
  changes_since = event.tickets.where("updated_at > ?", event.manifests.find_by(version: since_version)&.generated_at)

  {
    version: event.manifest_version,
    since_version: since_version,
    added: changes_since.where(status: "active").pluck(:id),
    updated: changes_since.where.not(status: "active").map { |t| { id: t.id, version: t.version, status: t.status } },
    removed: changes_since.where(status: %w[refunded cancelled]).pluck(:id)
  }
end
```

---

## 8. PARTIAL NETWORK SCENARIOS

### Problem

Some scanners have WiFi, some have cellular, some have nothing. How do they stay in sync?

### Solution: Hierarchical Sync

```
                    ┌─────────────┐
                    │   Server    │
                    └──────┬──────┘
                           │ (HTTPS)
                    ┌──────┴──────┐
                    │  Gateway    │
                    │ Scanner     │
                    └──┬──────┬──┘
                       │      │ (Local WiFi / Bluetooth)
                ┌──────┴──┐ ┌─┴────────┐
                │Scanner A│ │Scanner B │
                └─────────┘ └──────────┘
```

- **Gateway Scanner**: One scanner per zone has network access. It syncs with the server.
- **Zone Scanners**: Other scanners sync with the Gateway via local WiFi or Bluetooth.
- **Conflict resolution**: Gateway is the source of truth. Zone scanners send their scan logs to Gateway, which forwards to server.

```ruby
# Zone scanner syncs with Gateway
def sync_with_gateway(gateway_url)
  unsynced = ScanLog.where(synced: false)
  return if unsynced.empty?

  response = HTTP.post("#{gateway_url}/api/v1/local-sync", json: {
    device_id: device_id,
    scans: unsynced.map { |s| { ticket_id: s.ticket_id, result: s.result, scanned_at: s.scanned_at } }
  })

  if response.success?
    unsynced.update_all(synced: true)
    # Gateway returns updated manifest changes
    apply_manifest_updates(response["manifest_updates"])
  end
end
```

---

## 9. TIME SYNC ISSUES

### Problem

Offline scanner's clock is wrong. It rejects a valid ticket because it thinks the event hasn't started yet.

### Solution

| Measure | Implementation |
|---------|---------------|
| **NTP sync on boot** | Scanner syncs clock via NTP when it has network |
| **Tolerance window** | Accept tickets within ±5 minutes of event start time |
| **Server-time validation** | On sync, server corrects scanner's clock drift |
| **Event dates, not times** | Manifest uses dates, not timestamps. Scanner checks "is today a valid day?" not "is it past door time?" |

---

## 10. COMPLETE TICKET LIFECYCLE

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          TICKET LIFECYCLE                               │
│                                                                         │
│  Purchase → Active (v:1) ──────────────────────────────────────────┐   │
│     │                                                              │   │
│     │ Transfer/Resale                                              │   │
│     ▼                                                              │   │
│  Active (v:2) ─────────────────────────────────────────────────────┤   │
│     │                                                              │   │
│     │ Day 1: daily_single event                                    │   │
│     ▼                                                              │   │
│  Used (Day 1) ──→ Day 2: valid again (if multi-day) ───────────────┤   │
│     │                                                              │   │
│     │ Refund/Cancel                                                │   │
│     ▼                                                              │   │
│  Refunded (invalid) ───────────────────────────────────────────────┤   │
│                                                                     │   │
│  At each stage: QR token is regenerated with new version            │   │
│  Old QR tokens become invalid on next manifest sync                 │   │
│                                                                     │   │
│  Offline scanners:                                                  │   │
│  - Accept QR if version >= manifest version                         │   │
│  - Track entries locally                                            │   │
│  - Sync when network returns                                        │   │
│  - Conflicts resolved server-side                                   │   │
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
  t.string :manifest_key                    # Encrypted manifest key
  t.string :status, default: "active", null: false
  t.datetime :last_sync_at
  t.datetime :last_seen_at
  t.timestamps
end

# Manifests (server-side record of generated manifests)
create_table :manifests, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.integer :version, null: false
  t.integer :ticket_count, null: false
  t.integer :size_bytes, null: false
  t.datetime :generated_at, null: false
  t.timestamps
end
```

---

## 12. API ENDPOINTS

### Scanner Endpoints

```
POST /api/v1/scanner/auth
  → Register/authenticate scanner device
  → Returns device token

GET /api/v1/scanner/events/:event_id/manifest
  → Download full or delta manifest
  → Headers: If-None-Match, If-Modified-Since
  → Returns compressed, encrypted manifest

POST /api/v1/scanner/sync
  → Upload scan logs from offline period
  → Returns: conflict list, manifest updates

POST /api/v1/scanner/verify
  → Online verification (fallback when offline validation is uncertain)
  → Returns: ticket status, owner info, entry history

POST /api/v1/scanner/events/:event_id/refresh-manifest
  → Force manifest refresh (admin action)
```

### Ticket Endpoints

```
POST /api/v1/tickets/:id/transfer
  → Transfer ticket to another phone number
  → Increments version, generates new QR

POST /api/v1/tickets/:id/resale
  → List ticket for resale
  → Locks ticket, creates listing

POST /api/v1/resale_listings/:id/purchase
  → Buy a resale listing
  → Increments version, transfers to buyer, generates new QR

GET /api/v1/tickets/:id/qr
  → Get current QR token (dynamic, with rotating nonce)

GET /api/v1/tickets/:id/history
  → Full ownership and scan history
```

---

## 13. IMPLEMENTATION PLAN

### Phase 1: Core QR System (Week 1-2)
1. `QrService` — token generation and verification
2. `Ticket` model with version tracking
3. QR code generation (using `rqrcode` gem)
4. Basic online scanning endpoint

### Phase 2: Manifest & Offline (Week 2-4)
1. `ManifestService` — generation, signing, compression
2. Manifest download API (full + delta)
3. Scanner local database schema
4. Offline validation logic
5. Sync endpoint with conflict resolution

### Phase 3: Multi-Day & Policies (Week 4-5)
1. `EventDate` model
2. Entry policy enforcement (`single`, `multi`, `daily_single`)
3. Per-day entry tracking
4. Scanner UI for multi-day events

### Phase 4: Fraud Prevention (Week 5-6)
1. Dynamic QR with rotating nonce
2. Screenshot detection (app-side)
3. Device authentication and manifest encryption
4. GPS validation for scanners
5. Rate limiting on scan endpoint

### Phase 5: Scale & Polish (Week 6-8)
1. Delta manifest optimization
2. Hierarchical sync (gateway scanners)
3. NTP time sync
4. Scanner app UI (big success/failure indicators)
5. Admin dashboard for scan monitoring

---

## 14. TECHNOLOGY STACK

| Component | Technology | Why |
|-----------|-----------|-----|
| QR generation | `rqrcode` gem | Pure Ruby, no native dependencies |
| QR scanning (app) | Native camera API (iOS/Android) | Fast, reliable, works offline |
| Manifest compression | Zlib (gzip) or Brotli | Built-in, good compression ratio |
| Manifest signing | Ed25519 or RSA | Fast verification, compact signatures |
| QR token signing | HMAC-SHA256 | Fast, simple, shared secret |
| Scanner local DB | SQLite | Built-in, fast, reliable |
| Sync transport | HTTPS + JSON | Simple, debuggable |
| Background jobs | Solid Queue (Rails 8) | Built-in, reliable |
| Real-time monitoring | Turbo Streams | Live scan counts on admin dashboard |

---

## 15. EDGE CASES & RESOLUTIONS

| Edge Case | Resolution |
|-----------|-----------|
| Ticket scanned offline, then refunded before sync | Server marks as conflict, alerts staff, refunds stand |
| Two scanners scan same ticket simultaneously offline | Both record success locally. Server detects duplicate on sync, flags for review. |
| Scanner loses manifest, event starts in 30 minutes | Emergency manifest download (compressed, <1MB for most events). Fallback to online verification. |
| User's phone dies, they have a printed QR | Printed QR has static version. Works if not transferred. Staff can verify owner identity manually. |
| Event date changes (postponed) | Server pushes manifest update with new dates. All scanners refresh. Old dates rejected. |
| Ticket type upgrade at venue (Regular → VIP) | Server creates new ticket (new version), invalidates old. Scanner receives update on next sync. |
| Scanner battery dies mid-event | Swap to backup scanner. Backup downloads latest manifest. No data lost (scans synced to server). |

---

## SUMMARY

**The architecture is built on three pillars:**

1. **Signed QR tokens** — self-contained, verifiable, versioned. No database lookup needed for basic validation.
2. **Manifest-based offline sync** — scanners download a signed list of valid tickets, validate locally, sync when online.
3. **Version increment on transfer/resale** — old QRs become invalid automatically. First-scan-wins prevents replay attacks.

**Multi-day events** are handled through entry policies (`single`, `multi`, `daily_single`) tracked in the manifest and enforced by the scanner's local entry count table.

**Fraud prevention** is layered: cryptographic signatures prevent forgery, versioning prevents reuse after transfer, dynamic QRs prevent screenshots, first-scan-wins prevents duplicates, and device authentication prevents scanner compromise.

**Offline scanning** works because the manifest contains everything the scanner needs: ticket IDs, versions, valid dates, entry policies. The scanner validates locally, logs scans, and syncs when the network returns.
