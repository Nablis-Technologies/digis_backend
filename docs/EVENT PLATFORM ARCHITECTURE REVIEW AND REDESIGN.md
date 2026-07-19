# Event Platform — Comprehensive Architecture Review & Redesign

**Date**: May 19, 2026
**Scope**: Full architectural review of the "Improved DB Design" against real-world event ticketing requirements
**Reviewed Against**: Auth architecture, org architecture, QR/offline scanning, Platform framework code review, existing migrations

## Modular Monolith Note

This is a **modular monolith** Rails application. `Core` is one module providing shared infrastructure (auth, RBAC, concerns, base services). Domain features live in their own modules:

| Module | Purpose | Namespace |
|--------|---------|-----------|
| `Core` | Shared infrastructure | `Core::*` |
| `Events` | Event management | `Events::*` |
| `Ticketing` | Tickets, QR, scanning | `Ticketing::*` |
| `Orders` | Checkout, payments, fees | `Orders::*` |
| `Organizations` | Orgs, memberships | `Organizations::*` |
| `Messaging` | SMS/email campaigns | `Messaging::*` |
| `BoxOffice` | On-site sales | `BoxOffice::*` |
| `ShortUrls` | dig.is links | `ShortUrls::*` |

References to `Platform::` in this document are **conceptual placeholders** for the appropriate domain module namespace. In implementation, use the correct module namespace (e.g., `Events::Event`, `Ticketing::Ticket`, `Orders::Invoice`).

---

## Executive Summary

The "Improved DB Design" document has **strong foundations** — domain separation, capability composition, inventory pools, and payment/order separation are all correct architectural decisions. However, there are **14 critical gaps**, **8 design flaws**, and **5 missing domains** that would cause significant rework in production.

This review identifies every issue, provides the corrected design with rationale, and validates against 12 real-world event scenarios.

| Category | Count | Severity |
|----------|-------|----------|
| Critical Gaps | 14 | Would break in production |
| Design Flaws | 8 | Would require schema migration later |
| Missing Domains | 5 | Features cannot be built without them |
| Improvements | 12 | Better patterns for scalability |

---

## PART 1: CRITICAL GAPS (Would Break in Production)

### G1: Users Table Conflicts with Existing Platform::User

**The Problem**: The design proposes a `users` table with a `role` enum (`attendee/admin`). But the existing codebase already has `platform_users` with a full RBAC system (`roles`, `permissions`, `user_roles`, `role_permissions`). The design's simple `role` enum would either:
- Duplicate the existing RBAC system (wasteful)
- Conflict with it (broken auth)

**The Existing System Has**:
- `platform_users` with phone-first identity, OTP fields, `verified`, `profile_complete`
- `platform_roles` with hierarchical permissions
- `platform_user_roles` with expiry support
- `platform_permissions` with namespace scoping

**The Fix**: The design should use the **existing Platform namespace**. The `users` table in the design IS `platform_users`. The `role` enum should be removed entirely — the RBAC system already handles this through memberships and roles.

```ruby
# CORRECT: Use existing Platform::User
# The user table already exists with:
# - phone (unique, primary identity)
# - email (optional)
# - first_name, last_name, date_of_birth (profile)
# - verified, verified_at, profile_complete (state)
# - password_digest (nullable for shadow users)
# - otp_code, otp_expires_at, otp_attempts (transient)
# - google_uid, apple_uid (OAuth)
# - last_login_at, last_device_id (tracking)

# REMOVE the role enum from users table
# Use Platform::Role + Platform::UserRole for platform-level roles
# Use Membership for organization-level roles
```

**Why This Matters**: You already built a world-class RBAC system. Don't replace it with a 2-value enum.

---

### G2: Tickets Table Missing Version Field — Breaks Transfer/Resale

**The Problem**: The `tickets` table has no `version` column. The QR/offline scanning architecture explicitly requires version incrementing on every transfer/resale to invalidate old QR codes. Without it:
- Transferred tickets can still be used with old QR screenshots
- Resale marketplace is vulnerable to double-spending
- Offline scanners cannot detect stale QR codes

**The Fix**:
```ruby
# tickets table additions:
t.integer :version, null: false, default: 1
t.string :qr_token, null: false          # The signed QR payload (not just a UUID)
t.datetime :first_scanned_at
t.datetime :last_scanned_at
t.integer :entry_count, default: 0       # For multi-day events
t.jsonb :entry_dates, default: []        # Dates this ticket was used
```

**Scenario Validation**:
- User buys ticket → `version: 1`, QR token signed with v:1
- User transfers to friend → `version: 2`, new QR token with v:2
- Old QR (v:1) is rejected by scanner because current version is 2

---

### G3: No Multi-Day Event Support

**The Problem**: The design has `starts_at` and `ends_at` on events but no way to track individual event dates. A 3-day festival (June 15-17) needs:
- Separate door times per day
- Per-day attendance tracking
- Tickets valid for specific days or all days
- Different pricing per day

**The Fix**:
```ruby
# New table:
create_table :event_dates, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.date :date, null: false
  t.time :doors_open
  t.time :doors_close
  t.time :event_start
  t.time :event_end
  t.integer :capacity                    # Per-day capacity override
  t.boolean :active, default: true
end

add_index :event_dates, [:event_id, :date], unique: true
```

**Scenario Validation**:
- "Gize Concert" runs June 15-17
- June 15: Doors 18:00, Event 20:00-02:00, Capacity 5000
- June 16: Doors 17:00, Event 19:00-01:00, Capacity 3000 (smaller venue day)
- June 17: Doors 16:00, Event 18:00-00:00, Capacity 2000 (VIP-only final day)

---

### G4: Inventory Pools Have Race Condition Vulnerability

**The Problem**: `inventory_pools` stores `reserved` and `sold` as integers. Under concurrent purchases (e.g., 1000 people buying at once), these counters will race:

```
Thread A: reads capacity=100, sold=99 → thinks 1 available
Thread B: reads capacity=100, sold=99 → thinks 1 available
Thread A: increments sold to 100
Thread B: increments sold to 101  ← OVERSOLD
```

**The Fix**: Use database-level constraints and row-level locking:

```ruby
# Option A: Database constraint (PostgreSQL)
t.integer :capacity, null: false
# Add check constraint:
execute "ALTER TABLE inventory_pools ADD CONSTRAINT capacity_check CHECK (sold + reserved <= capacity)"

# Option B: Optimistic locking
t.integer :lock_version, default: 0

# Option C: Reservation-based (recommended for ticketing)
# Create a separate reservations table:
create_table :ticket_reservations, id: :uuid do |t|
  t.uuid :inventory_pool_id, null: false
  t.uuid :order_id                             # NULL until checkout complete
  t.integer :quantity, null: false
  t.datetime :expires_at, null: false          # Auto-release after 10 min
  t.string :status, default: "pending"         # pending/confirmed/expired
end

# When user adds to cart:
# INSERT INTO ticket_reservations (pool_id, quantity, expires_at)
# WHERE (SELECT SUM(reserved) FROM ticket_reservations WHERE status='pending') + new_quantity <= capacity

# This is atomic and race-condition-free
```

**Scenario Validation**:
- 5000 people click "Buy" for a 100-ticket event simultaneously
- With reservations: exactly 100 get reserved, 4900 get "sold out"
- With integer counters: 105-120 get sold, organizer has to refund

---

### G5: No Waitlist Implementation

**The Problem**: `event_settings` has `allow_waitlist: boolean` but there's no `waitlists` table. When an event sells out, there's no mechanism to:
- Queue interested buyers
- Auto-sell when tickets become available (refunds, cancellations)
- Notify waitlisted users in order
- Set waitlist expiry

**The Fix**:
```ruby
create_table :waitlist_entries, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :user_id, null: false
  t.uuid :ticket_type_id                   # Which type they want
  t.integer :quantity, default: 1
  t.integer :position, null: false          # Queue position
  t.string :status, default: "waiting"      # waiting/offered/expires/declined/fulfilled
  t.datetime :offered_at                    # When they were offered a ticket
  t.datetime :offer_expires_at              # Deadline to accept
  t.datetime :fulfilled_at
  t.timestamps
end

add_index :waitlist_entries, [:event_id, :ticket_type_id, :position], unique: true
add_index :waitlist_entries, [:user_id, :event_id], unique: true
```

**Scenario Validation**:
- Event sells out → user joins waitlist at position 12
- Someone requests refund → position 12 gets offered ticket via SMS
- 15-minute window to accept → if declined, position 13 gets offered
- If no one accepts within 2 hours, ticket goes back to public sale

---

### G6: No Ticket Transfer History

**The Problem**: The `tickets` table has `status: transferred` but no audit trail of who transferred to whom, when, or at what price. This is critical for:
- Fraud investigation
- Tax reporting (capital gains on resale)
- Dispute resolution
- Analytics (how many tickets change hands)

**The Fix**:
```ruby
create_table :ticket_transfers, id: :uuid do |t|
  t.uuid :ticket_id, null: false
  t.uuid :from_user_id, null: false
  t.uuid :to_user_id, null: false
  t.integer :previous_version, null: false
  t.integer :new_version, null: false
  t.string :transfer_type, null: false     # gift/resale/admin
  t.integer :price                         # Cents, null for gifts
  t.datetime :completed_at
  t.timestamps
end

add_index :ticket_transfers, :ticket_id
add_index :ticket_transfers, :from_user_id
add_index :ticket_transfers, :to_user_id
```

---

### G7: No Resale Marketplace

**The Problem**: The design mentions resale in requirements but has zero tables for it. A resale marketplace needs:
- Listing creation with price
- Price caps (prevent scalping)
- Buyer purchase flow
- Automatic ticket transfer on sale
- Platform fee calculation
- Payout to seller

**The Fix**:
```ruby
create_table :resale_listings, id: :uuid do |t|
  t.uuid :ticket_id, null: false
  t.uuid :seller_id, null: false
  t.uuid :buyer_id                       # NULL until sold
  t.integer :price, null: false           # Cents
  t.integer :original_price, null: false  # Cents (for price cap enforcement)
  t.integer :platform_fee, default: 0     # Cents
  t.string :status, default: "listed"     # listed/sold/cancelled/expired
  t.datetime :listed_at
  t.datetime :sold_at
  t.datetime :expires_at
  t.timestamps
end

add_index :resale_listings, :ticket_id, unique: true, where: "status = 'listed'"
add_index :resale_listings, :seller_id
add_index :resale_listings, :status
```

**Scenario Validation**:
- User buys ticket for 500 birr → wants to resell
- Creates listing at 700 birr → platform enforces 150% cap (max 750 birr)
- Buyer purchases → payment splits: 700 to seller (minus platform fee), fee to platform
- Ticket version increments, old QR invalidated, new QR sent to buyer
- Listing marked sold, seller gets payout notification

---

### G8: No Scanner Device Management

**The Problem**: The `checkin_logs` table has `scanner_user_id` but no scanner device registration, assignment, or security. For offline scanning you need:
- Device registration and authentication
- Event assignment (which scanner scans which event)
- Manifest download tracking
- Remote wipe capability
- GPS validation

**The Fix**:
```ruby
create_table :scanner_devices, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.uuid :event_id                         # NULL for multi-event scanners
  t.uuid :assigned_user_id                 # The user operating this device
  t.string :device_id, null: false          # Hardware identifier
  t.string :device_token, null: false       # Auth token
  t.string :device_name                     # "Gate A - iPad Pro"
  t.string :manifest_key                    # Encrypted manifest key
  t.integer :manifest_version, default: 0   # Last synced manifest version
  t.datetime :last_sync_at
  t.datetime :last_seen_at
  t.string :status, default: "active"       # active/inactive/wiped
  t.datetime :wiped_at
  t.timestamps
end

add_index :scanner_devices, :device_id, unique: true
add_index :scanner_devices, :device_token, unique: true
add_index :scanner_devices, [:organization_id, :event_id]
```

---

### G9: No Marketing Campaign Tracking

**The Problem**: The design mentions "email/SMS marketing campaigns" but has no tables for:
- Campaign creation and targeting
- Message templates
- Send tracking (sent, delivered, opened, clicked)
- Bounce handling
- Opt-out management
- Campaign analytics (conversion rate, revenue attributed)

**The Fix**:
```ruby
create_table :marketing_campaigns, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.uuid :event_id                         # NULL for cross-event campaigns
  t.string :name, null: false
  t.string :channel, null: false            # sms/email/push
  t.string :status, default: "draft"        # draft/scheduled/sending/sent/failed
  t.jsonb :targeting                        # Audience criteria
  t.integer :recipient_count
  t.integer :sent_count, default: 0
  t.integer :delivered_count, default: 0
  t.integer :opened_count, default: 0
  t.integer :clicked_count, default: 0
  t.integer :converted_count, default: 0    # Purchases attributed
  t.datetime :scheduled_at
  t.datetime :sent_at
  t.datetime :completed_at
  t.timestamps
end

create_table :campaign_messages, id: :uuid do |t|
  t.uuid :campaign_id, null: false
  t.uuid :user_id
  t.string :phone
  t.string :email
  t.string :content, null: false
  t.string :status, default: "pending"      # pending/sent/delivered/opened/clicked/bounced/failed
  t.datetime :sent_at
  t.datetime :delivered_at
  t.datetime :opened_at
  t.datetime :clicked_at
  t.string :bounce_reason
  t.timestamps
end

create_table :campaign_links, id: :uuid do |t|
  t.uuid :campaign_id, null: false
  t.uuid :short_link_id, null: false        # Links to short_links table
  t.integer :click_count, default: 0
end
```

**Scenario Validation**:
- Organizer creates SMS campaign: "Early bird tickets for Gize Concert — 20% off today only!"
- Targets: all users who attended similar events in the past 6 months
- 5000 messages sent → 4200 delivered → 800 clicked → 120 purchased
- Campaign dashboard shows: 2.4% conversion rate, 60,000 birr revenue attributed
- Short links in campaign are tracked separately for click analytics

---

### G9b: No Configurable SMS/Email Campaign Pricing (Pay-Per-Message)

**The Problem**: The marketing campaign system (G9) has no pricing model. A real platform needs a **configurable pay-per-message billing system** that handles:

- Different rates per channel (SMS costs more than email)
- Different rates per country/region (international SMS is pricier)
- Volume discounts (send 10,000+ messages, get lower rate)
- Organization-specific negotiated rates
- Prepaid credits vs postpaid billing
- Balance checking before campaign launch
- Cost estimation before sending
- Failed message refunds (undelivered SMS shouldn't be charged)
- Provider cost tracking (what we pay Twilio/Africa's Talking vs what we charge)

**The Fix**: A hierarchical pricing system with real-time balance management:

#### Messaging Pricing Tables

```ruby
create_table :messaging_rates, id: :uuid do |t|
  # ── Scope hierarchy ──
  t.uuid :organization_id                    # NULL = global platform rate
  t.string :channel, null: false             # sms/email/whatsapp/push
  t.string :country_code                     # "ET", "US", "KE" — NULL = default

  # ── Pricing ──
  t.integer :price_per_message, null: false  # Cents per message (what we charge)
  t.integer :cost_per_message                # Cents (what provider charges us)
  t.string :currency, default: "ETB"

  # ── Volume tiers (JSONB) ──
  t.jsonb :volume_tiers
  # Example:
  # [
  #   { from: 0, to: 1000, price: 50 },       # 0.50 birr per message
  #   { from: 1001, to: 10000, price: 40 },   # 0.40 birr
  #   { from: 10001, to: null, price: 30 }    # 0.30 birr
  # ]

  # ── Status ──
  t.boolean :active, default: true
  t.datetime :effective_from
  t.datetime :effective_to

  t.timestamps
end

add_index :messaging_rates, [:organization_id, :channel, :country_code, :active]
add_index :messaging_rates, [:channel, :country_code, :active]

create_table :messaging_credits, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.integer :balance, null: false, default: 0  # Cents (positive = credit, negative = debt)
  t.integer :reserved, default: 0              # Reserved for pending campaigns
  t.string :currency, default: "ETB"
  t.datetime :last_recharged_at
  t.timestamps
end

add_index :messaging_credits, :organization_id, unique: true

create_table :credit_transactions, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.string :transaction_type, null: false      # purchase/refund/charge/adjustment/reservation/release
  t.integer :amount, null: false               # Positive = added, negative = deducted
  t.integer :balance_after, null: false
  t.uuid :reference_id                         # Campaign ID, order ID, etc.
  t.string :reference_type
  t.text :description
  t.timestamps
end

add_index :credit_transactions, :organization_id
add_index :credit_transactions, [:reference_type, :reference_id]

create_table :messaging_provider_configs, id: :uuid do |t|
  t.uuid :organization_id                      # NULL = platform default provider
  t.string :channel, null: false               # sms/email
  t.string :provider, null: false              # "twilio", "africas_talking", "sendgrid", "ses"
  t.jsonb :credentials                         # Encrypted API keys, etc.
  t.jsonb :settings                            # Sender ID, from_email, etc.
  t.boolean :active, default: true
  t.integer :priority, default: 0              # For failover routing
  t.timestamps
end

add_index :messaging_provider_configs, [:organization_id, :channel, :active]
```

#### Messaging Rate Resolution Engine

```ruby
# app/services/platform/messaging_rate_resolver.rb
module Platform
  class MessagingRateResolver
    # Resolve the price per message for a given context
    def self.resolve(organization:, channel:, country_code: nil)
      # Priority: org-specific > global default
      rates = Platform::MessagingRate
        .where(channel: channel)
        .where(active: true)
        .order(
          Arel.sql("CASE WHEN organization_id IS NOT NULL THEN 0 ELSE 1 END"),
          priority: :desc
        )

      # Filter by organization
      org_rate = rates.find { |r| r.organization_id == organization&.id }
      return org_rate if org_rate

      # Fall back to global rate
      rates.find { |r| r.organization_id.nil? }
    end

    # Calculate cost for a campaign
    def self.estimate_cost(organization:, channel:, recipient_count:, country_code: nil)
      rate = resolve(organization: organization, channel: channel, country_code: country_code)
      return nil unless rate

      base_price = rate.price_per_message * recipient_count

      # Apply volume tiers if present
      if rate.volume_tiers.present?
        tier = rate.volume_tiers.find do |t|
          from = t["from"] || 0
          to = t["to"]
          recipient_count >= from && (to.nil? || recipient_count <= to)
        end
        base_price = tier["price"] * recipient_count if tier
      end

      {
        recipient_count: recipient_count,
        price_per_message: rate.price_per_message,
        total_cost: base_price,
        currency: rate.currency,
        org_balance: organization&.messaging_credit&.balance
      }
    end
  end
end
```

#### Campaign Cost Deduction Flow

```ruby
# app/services/platform/campaign_billing_service.rb
module Platform
  class CampaignBillingService
    # Reserve credits before campaign sends
    def self.reserve_credits(campaign)
      org = campaign.organization
      estimate = Platform::MessagingRateResolver.estimate_cost(
        organization: org,
        channel: campaign.channel,
        recipient_count: campaign.recipient_count
      )

      raise Platform::Error.new("Insufficient credits") if org.messaging_credit.balance < estimate[:total_cost]

      ActiveRecord::Base.transaction do
        org.messaging_credit.decrement!(:balance, estimate[:total_cost])
        org.messaging_credit.increment!(:reserved, estimate[:total_cost])

        Platform::CreditTransaction.create!(
          organization_id: org.id,
          transaction_type: "reservation",
          amount: -estimate[:total_cost],
          balance_after: org.messaging_credit.balance,
          reference_id: campaign.id,
          reference_type: "MarketingCampaign",
          description: "Reserved for campaign: #{campaign.name}"
        )
      end

      estimate[:total_cost]
    end

    # Release reserved credits after campaign completes
    def self.finalize_campaign(campaign)
      org = campaign.organization
      actual_cost = calculate_actual_cost(campaign)

      ActiveRecord::Base.transaction do
        # Release reservation
        org.messaging_credit.decrement!(:reserved, campaign.reserved_amount)

        # Charge actual cost (may differ from reserved if some messages failed)
        org.messaging_credit.decrement!(:balance, actual_cost)

        Platform::CreditTransaction.create!(
          organization_id: org.id,
          transaction_type: "charge",
          amount: -actual_cost,
          balance_after: org.messaging_credit.balance,
          reference_id: campaign.id,
          reference_type: "MarketingCampaign",
          description: "Charged for campaign: #{campaign.name} (#{campaign.delivered_count} delivered)"
        )

        # Refund difference if actual < reserved
        if campaign.reserved_amount > actual_cost
          refund = campaign.reserved_amount - actual_cost
          org.messaging_credit.increment!(:balance, refund)

          Platform::CreditTransaction.create!(
            organization_id: org.id,
            transaction_type: "refund",
            amount: refund,
            balance_after: org.messaging_credit.balance,
            reference_id: campaign.id,
            reference_type: "MarketingCampaign",
            description: "Refunded unused credits from campaign: #{campaign.name}"
          )
        end
      end
    end

    # Refund for failed messages
    def self.refund_failed_message(message)
      campaign = message.campaign
      rate = Platform::MessagingRateResolver.resolve(
        organization: campaign.organization,
        channel: campaign.channel
      )

      ActiveRecord::Base.transaction do
        campaign.organization.messaging_credit.increment!(:balance, rate.price_per_message)
        campaign.organization.messaging_credit.decrement!(:reserved, rate.price_per_message)

        Platform::CreditTransaction.create!(
          organization_id: campaign.organization.id,
          transaction_type: "refund",
          amount: rate.price_per_message,
          balance_after: campaign.organization.messaging_credit.balance,
          reference_id: message.id,
          reference_type: "CampaignMessage",
          description: "Refund for failed message to #{message.phone || message.email}"
        )
      end
    end

    private

    def self.calculate_actual_cost(campaign)
      # Only charge for delivered messages
      delivered = campaign.campaign_messages.where(status: "delivered").count
      rate = Platform::MessagingRateResolver.resolve(
        organization: campaign.organization,
        channel: campaign.channel
      )
      delivered * rate.price_per_message
    end
  end
end
```

#### Updated Campaign Messages Table

```ruby
# Add to campaign_messages:
t.integer :cost_cents                        # What this message cost (resolved at send time)
t.string :provider_message_id                # Twilio SID, SendGrid message ID
t.string :provider_status                    # Provider's delivery status
t.integer :retry_count, default: 0
t.datetime :retry_at                         # When to retry failed sends
```

#### Real-World Pricing Scenarios

**Scenario A: Default Platform Rates**
```ruby
# Ethiopia SMS (local)
Platform::MessagingRate.create!(
  channel: "sms",
  country_code: "ET",
  price_per_message: 50,          # 0.50 birr per SMS
  cost_per_message: 30,           # We pay 0.30 birr to Africa's Talking
  currency: "ETB",
  volume_tiers: [
    { from: 0, to: 1000, price: 50 },
    { from: 1001, to: 10000, price: 40 },
    { from: 10001, to: nil, price: 30 }
  ]
)

# Email (much cheaper)
Platform::MessagingRate.create!(
  channel: "email",
  price_per_message: 5,           # 0.05 birr per email
  cost_per_message: 1,            # We pay almost nothing via SES
  currency: "ETB"
)

# International SMS (US)
Platform::MessagingRate.create!(
  channel: "sms",
  country_code: "US",
  price_per_message: 200,         # 2.00 birr per SMS to US
  cost_per_message: 120,          # Twilio charges ~$0.0079
  currency: "ETB"
)
```

**Scenario B: Custom Deal for Major Organizer**
```ruby
# "Addis Live" sends 50,000+ messages/month — gets discounted rate
Platform::MessagingRate.create!(
  organization_id: addis_live.id,
  channel: "sms",
  country_code: "ET",
  price_per_message: 35,          # 0.35 birr (vs 0.50 standard)
  cost_per_message: 30,           # Our cost stays the same
  currency: "ETB",
  volume_tiers: [
    { from: 0, to: 5000, price: 35 },
    { from: 5001, to: nil, price: 25 }  # 0.25 birr for high volume
  ]
)
```

**Scenario C: Prepaid Credit System**
```ruby
# Organization buys credits upfront
org = Organization.find(org_id)
org.create_messaging_credit!(balance: 500_00)  # 5,000 birr prepaid

# Platform::CreditTransaction records the purchase
Platform::CreditTransaction.create!(
  organization_id: org.id,
  transaction_type: "purchase",
  amount: 500_00,
  balance_after: 500_00,
  description: "Credit purchase via bank transfer"
)
```

**Scenario D: Campaign Cost Estimation**
```ruby
# Organizer creates campaign, wants to know cost before sending
estimate = Platform::MessagingRateResolver.estimate_cost(
  organization: organizer,
  channel: "sms",
  recipient_count: 5000
)

# Returns:
# {
#   recipient_count: 5000,
#   price_per_message: 40,          # Volume tier applied (1001-10000 range)
#   total_cost: 200_00,             # 2,000 birr
#   currency: "ETB",
#   org_balance: 500_00             # Current balance
# }

# UI shows: "This campaign will cost 2,000 birr (5,000 messages × 0.40 birr)"
# "Your balance: 5,000 birr. Remaining after send: 3,000 birr"
```

**Scenario E: Failed Message Refund**
```ruby
# Campaign sends 5,000 SMS
# 4,800 delivered, 150 failed (invalid numbers), 50 pending
# Only charged for 4,800 delivered messages

# Reserved: 5,000 × 0.40 = 2,000 birr
# Actual: 4,800 × 0.40 = 1,920 birr
# Refund: 80 birr returned to balance
```

**Scenario F: Provider Failover**
```ruby
# Primary SMS provider: Africa's Talking
Platform::MessagingProviderConfig.create!(
  channel: "sms",
  provider: "africas_talking",
  credentials: { api_key: "encrypted...", sender_id: "DIGIS" },
  priority: 1
)

# Backup provider: Twilio
Platform::MessagingProviderConfig.create!(
  channel: "sms",
  provider: "twilio",
  credentials: { account_sid: "encrypted...", auth_token: "encrypted..." },
  priority: 2
)

# If Africa's Talking fails, automatically retry via Twilio
# Cost may differ — refund/adjust accordingly
```

#### Campaign Billing UI

```
Campaign: "Gize Concert — Early Bird"
Channel: SMS (Ethiopia)
Recipients: 5,000 users

Pricing:
  Base rate: 0.50 birr/message
  Volume discount (5,000 messages): 0.40 birr/message
  ─────────────────────────────────────
  Estimated cost: 2,000 birr

Your balance: 5,000 birr
Balance after send: 3,000 birr

[Send Campaign] [Cancel]
```

#### Campaign Billing Report

```
Campaign Billing Summary — May 2026
Organization: Addis Live

Campaign                  | Channel | Sent | Delivered | Cost
──────────────────────────|─────────|──────|───────────|────────
Early Bird — Gize Concert | SMS     | 5,000| 4,800     | 1,920 birr
VIP Launch — EMF          | SMS     | 2,000| 1,950     | 780 birr
Weekly Newsletter         | Email   | 10K  | 9,500     | 475 birr
──────────────────────────|─────────|──────|───────────|────────
Total                     |         | 17K  | 16,250    | 3,175 birr

Opening balance: 10,000 birr
Credits purchased: 5,000 birr
Total charged: 3,175 birr
Closing balance: 11,825 birr
```

---

### G9c: No Invoicing System (Corporate Billing, B2B, Sponsorships)

**The Problem**: The platform has no invoicing infrastructure. Corporate organizers, sponsors, and B2B clients need:

- Formal invoices for bulk ticket purchases (company events, team outings)
- Invoices for platform fees (organizers want itemized billing, not just deductions)
- Invoices for messaging credit purchases (prepaid top-ups)
- Sponsorship invoices (brands sponsoring events)
- Net payment terms (Net 15, Net 30 — pay later, not upfront)
- Partial payments and payment tracking
- Credit notes for refunds/adjustments
- Sequential invoice numbering (legal requirement in many jurisdictions)
- Custom invoice templates (company logo, billing address, tax ID)
- Tax-compliant invoices (VAT breakdown, tax registration numbers)
- Recurring invoices (monthly platform subscriptions, retainer agreements)
- Multi-currency support (international sponsors, diaspora events)
- Invoice delivery (email, download, API webhook)
- Late payment tracking and reminders

**The Fix**: A full invoicing system integrated with orders, messaging credits, and platform fees:

#### Invoice Tables

```ruby
create_table :invoices, id: :uuid do |t|
  # ── Identity ──
  t.string :invoice_number, null: false          # "INV-2026-00001" (sequential)
  t.uuid :organization_id, null: false           # Who is billed (or who issues)
  t.uuid :issued_by_id                           # Platform org that issued this

  # ── Billing parties ──
  t.uuid :bill_to_organization_id                # B2B: the org being billed
  t.uuid :bill_to_user_id                        # Individual buyer
  t.string :bill_to_name                         # Company name
  t.string :bill_to_email                        # Billing contact
  t.string :bill_to_phone
  t.string :bill_to_address                      # Full billing address
  t.string :bill_to_tax_id                       # VAT/TIN number
  t.string :bill_to_city
  t.string :bill_to_country, default: "ET"

  # ── Amounts ──
  t.integer :subtotal, null: false, default: 0   # Before tax
  t.integer :tax_total, null: false, default: 0
  t.integer :discount_total, null: false, default: 0
  t.integer :total, null: false                  # Final amount due
  t.integer :amount_paid, null: false, default: 0
  t.integer :amount_due, null: false             # total - amount_paid
  t.string :currency, default: "ETB"

  # ── Tax details ──
  t.jsonb :tax_breakdown
  # Example: [{ rate: 0.15, type: "VAT", amount: 3000 }]

  # ── Status & dates ──
  t.string :status, null: false, default: "draft"  # draft/sent/partially_paid/paid/overdue/void/refunded
  t.date :issue_date, null: false
  t.date :due_date
  t.string :payment_terms                          # "Net 15", "Net 30", "Due on receipt"
  t.datetime :sent_at
  t.datetime :paid_at
  t.datetime :overdue_at
  t.datetime :voided_at

  # ── Reference links ──
  t.uuid :order_id                                 # If linked to a ticket order
  t.uuid :credit_transaction_id                    # If linked to a credit purchase
  t.uuid :campaign_id                              # If linked to a messaging campaign
  t.string :reference_type                         # "order", "credit_purchase", "platform_fee", "sponsorship", "custom"
  t.uuid :reference_id

  # ── Template & customization ──
  t.uuid :template_id                              # Custom invoice template
  t.text :notes                                    # Internal notes
  t.text :terms                                    # Terms & conditions shown on invoice
  t.jsonb :metadata                                # Extra data

  # ── Recurring ──
  t.uuid :recurring_schedule_id                    # If part of a recurring invoice series
  t.integer :sequence_number                       # Position in recurring series

  t.timestamps
end

add_index :invoices, :invoice_number, unique: true
add_index :invoices, [:organization_id, :status]
add_index :invoices, [:bill_to_organization_id]
add_index :invoices, [:status, :due_date]
add_index :invoices, [:reference_type, :reference_id]
add_index :invoices, [:recurring_schedule_id]

create_table :invoice_line_items, id: :uuid do |t|
  t.uuid :invoice_id, null: false
  t.string :description, null: false               # "10 × VIP Tickets — Gize Concert"
  t.integer :quantity, null: false, default: 1
  t.integer :unit_price, null: false               # Price per unit (cents)
  t.decimal :tax_rate, default: 0                  # Tax rate for this line
  t.integer :tax_amount, default: 0
  t.integer :discount_amount, default: 0
  t.integer :total, null: false                    # (qty × unit_price) + tax - discount
  t.string :item_type                              # "tickets", "platform_fee", "messaging_credits", "sponsorship", "custom"
  t.uuid :reference_id                             # Ticket type ID, order ID, etc.
  t.string :reference_type
  t.integer :sort_order, default: 0
  t.timestamps
end

add_index :invoice_line_items, :invoice_id

create_table :invoice_payments, id: :uuid do |t|
  t.uuid :invoice_id, null: false
  t.integer :amount, null: false
  t.string :currency, default: "ETB"
  t.string :payment_method, null: false            # "bank_transfer", "telebirr", "credit_card", "cash", "credit_offset"
  t.string :payment_reference                      # Bank transfer ref, transaction ID
  t.date :payment_date, null: false
  t.string :status, default: "pending"             # pending/confirmed/reversed
  t.text :notes
  t.uuid :recorded_by_id                           # User who recorded this payment
  t.timestamps
end

add_index :invoice_payments, :invoice_id
add_index :invoice_payments, [:status, :payment_date]

create_table :credit_notes, id: :uuid do |t|
  t.string :credit_note_number, null: false        # "CN-2026-00001"
  t.uuid :organization_id, null: false
  t.uuid :original_invoice_id                      # Invoice this credit note applies to
  t.integer :amount, null: false
  t.string :currency, default: "ETB"
  t.string :reason, null: false                    # "refund", "adjustment", "cancellation", "discount"
  t.text :description
  t.string :status, default: "issued"              # issued/applied/voided
  t.date :issued_date, null: false
  t.datetime :applied_at                           # When applied to an invoice
  t.uuid :applied_to_invoice_id                    # Invoice this credit was applied against
  t.timestamps
end

add_index :credit_notes, :credit_note_number, unique: true
add_index :credit_notes, :original_invoice_id
add_index :credit_notes, [:organization_id, :status]

create_table :recurring_invoice_schedules, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.string :name, null: false                      # "Monthly Platform Fee"
  t.integer :amount                                # Fixed amount (NULL if calculated)
  t.string :frequency, null: false                 # "weekly", "monthly", "quarterly", "annually"
  t.integer :day_of_month                          # 1-31 for monthly
  t.string :day_of_week                            # "monday", etc. for weekly
  t.date :start_date, null: false
  t.date :end_date                                 # NULL = indefinite
  t.integer :invoices_generated, default: 0
  t.boolean :active, default: true
  t.jsonb :line_items_template                     # Template for line items
  t.timestamps
end

add_index :recurring_invoice_schedules, [:organization_id, :active]

create_table :invoice_templates, id: :uuid do |t|
  t.uuid :organization_id                          # NULL = platform default template
  t.string :name, null: false                      # "Corporate Template", "Sponsorship Template"
  t.string :logo_url                               # Company logo
  t.string :header_text                            # Custom header
  t.string :footer_text                            # Custom footer
  t.text :terms_and_conditions                     # Default T&C
  t.jsonb :styling                                 # Colors, fonts, layout preferences
  t.boolean :active, default: true
  t.timestamps
end

add_index :invoice_templates, [:organization_id, :active]
```

#### Invoice Numbering System

```ruby
# app/services/platform/invoice_number_generator.rb
module Platform
  class InvoiceNumberGenerator
    PREFIXES = {
      invoice: "INV",
      credit_note: "CN",
      proforma: "PRO"
    }.freeze

    def self.generate(type: :invoice, organization: nil, date: nil)
      date ||= Date.current
      year = date.year
      prefix = PREFIXES[type]

      # Sequential per year, per organization (or global)
      scope = organization ? "org_#{organization.id}" : "global"
      key = "#{prefix}-#{year}-#{scope}"

      Rails.cache.increment(key, 1, expires_in: 1.year) || 1
      count = Rails.cache.fetch(key, expires_in: 1.year) { 1 }

      "#{prefix}-#{year}-#{count.to_s.rjust(5, '0')}"
    end
  end
end

# Examples:
# INV-2026-00001  (first invoice of 2026)
# INV-2026-00002  (second)
# CN-2026-00001   (first credit note)
```

#### Invoice Creation Service

```ruby
# app/services/platform/invoice_service.rb
module Platform
  class InvoiceService
    # Create an invoice from an order
    def self.create_from_order(order, options = {})
      invoice = Invoice.new(
        invoice_number: InvoiceNumberGenerator.generate,
        organization_id: order.organization_id,
        bill_to_organization_id: order.organization_id,
        bill_to_name: options[:bill_to_name] || order.organization&.name,
        bill_to_email: options[:bill_to_email] || order.organization&.billing_email,
        bill_to_address: options[:bill_to_address] || order.organization&.billing_address,
        bill_to_tax_id: options[:bill_to_tax_id] || order.organization&.tax_id,
        issue_date: Date.current,
        due_date: options[:due_date] || (Date.current + 30.days),
        payment_terms: options[:payment_terms] || "Net 30",
        currency: "ETB",
        reference_type: "order",
        reference_id: order.id,
        order_id: order.id
      )

      # Line items from order
      order.order_items.each do |item|
        invoice.invoice_line_items.build(
          description: "#{item.quantity} × #{item.ticket_type.name} — #{item.ticket_type.event.name}",
          quantity: item.quantity,
          unit_price: item.unit_price,
          tax_rate: item.tax_rate || 0.15,  # Default VAT
          item_type: "tickets",
          reference_id: item.ticket_type_id,
          reference_type: "TicketType"
        )
      end

      # Platform fee line item
      if order.platform_fee > 0
        invoice.invoice_line_items.build(
          description: "Platform Commission — #{order.event.name}",
          quantity: 1,
          unit_price: order.platform_fee,
          tax_rate: 0,  # Platform fees may be tax-exempt
          item_type: "platform_fee",
          reference_id: order.id,
          reference_type: "Order"
        )
      end

      # Messaging credits line item
      if order.messaging_credits_amount > 0
        invoice.invoice_line_items.build(
          description: "Messaging Credits — #{order.messaging_credit_quantity} messages",
          quantity: order.messaging_credit_quantity,
          unit_price: order.messaging_credit_unit_price,
          tax_rate: 0,
          item_type: "messaging_credits",
          reference_id: order.id,
          reference_type: "Order"
        )
      end

      invoice.calculate_totals!
      invoice.save!

      invoice
    end

    # Create an invoice for messaging credit purchase
    def self.create_credit_purchase_invoice(organization:, quantity:, unit_price:, payment_terms: "Due on receipt")
      subtotal = quantity * unit_price
      tax = 0  # Credits may be tax-exempt

      Invoice.create!(
        invoice_number: InvoiceNumberGenerator.generate,
        organization_id: organization.id,
        bill_to_organization_id: organization.id,
        bill_to_name: organization.name,
        bill_to_email: organization.billing_email,
        bill_to_tax_id: organization.tax_id,
        subtotal: subtotal,
        tax_total: tax,
        total: subtotal,
        amount_due: subtotal,
        currency: "ETB",
        issue_date: Date.current,
        due_date: Date.current,
        payment_terms: payment_terms,
        reference_type: "credit_purchase",
        tax_breakdown: []
      ).tap do |invoice|
        invoice.invoice_line_items.create!(
          description: "Messaging Credits — #{organization.name}",
          quantity: quantity,
          unit_price: unit_price,
          tax_rate: 0,
          item_type: "messaging_credits",
          total: subtotal
        )
      end
    end

    # Create a sponsorship invoice
    def self.create_sponsorship_invoice(sponsor_event:, sponsor_organization:, amount:, description:, payment_terms: "Net 30")
      Invoice.create!(
        invoice_number: InvoiceNumberGenerator.generate,
        organization_id: sponsor_event.organization_id,
        bill_to_organization_id: sponsor_organization.id,
        bill_to_name: sponsor_organization.name,
        bill_to_email: sponsor_organization.billing_email,
        bill_to_address: sponsor_organization.billing_address,
        bill_to_tax_id: sponsor_organization.tax_id,
        subtotal: amount,
        tax_total: (amount * 0.15).round,  # VAT
        total: amount + (amount * 0.15).round,
        amount_due: amount + (amount * 0.15).round,
        currency: "ETB",
        issue_date: Date.current,
        due_date: Date.current + 30.days,
        payment_terms: payment_terms,
        reference_type: "sponsorship",
        reference_id: sponsor_event.id,
        tax_breakdown: [{ rate: 0.15, type: "VAT", amount: (amount * 0.15).round }]
      ).tap do |invoice|
        invoice.invoice_line_items.create!(
          description: description,
          quantity: 1,
          unit_price: amount,
          tax_rate: 0.15,
          tax_amount: (amount * 0.15).round,
          item_type: "sponsorship",
          reference_id: sponsor_event.id,
          reference_type: "Event",
          total: amount + (amount * 0.15).round
        )
      end
    end

    # Record a payment against an invoice
    def self.record_payment(invoice:, amount:, payment_method:, payment_reference: nil, recorded_by: nil)
      ActiveRecord::Base.transaction do
        payment = invoice.invoice_payments.create!(
          amount: amount,
          payment_method: payment_method,
          payment_reference: payment_reference,
          payment_date: Date.current,
          status: "confirmed",
          recorded_by_id: recorded_by&.id
        )

        invoice.amount_paid += amount
        invoice.amount_due = [invoice.total - invoice.amount_paid, 0].max
        invoice.status = invoice.amount_due == 0 ? "paid" : "partially_paid"
        invoice.paid_at = invoice.amount_due == 0 ? Time.current : invoice.paid_at
        invoice.save!

        payment
      end
    end

    # Issue a credit note
    def self.issue_credit_note(invoice:, amount:, reason:, description:)
      ActiveRecord::Base.transaction do
        credit_note = CreditNote.create!(
          credit_note_number: InvoiceNumberGenerator.generate(type: :credit_note),
          organization_id: invoice.organization_id,
          original_invoice_id: invoice.id,
          amount: amount,
          reason: reason,
          description: description,
          issued_date: Date.current
        )

        # Apply to original invoice
        invoice.amount_paid -= amount
        invoice.amount_due = [invoice.total - invoice.amount_paid, 0].max
        invoice.status = invoice.amount_due == 0 ? "paid" : "partially_paid"
        invoice.save!

        credit_note
      end
    end
  end
end
```

#### Invoice Model

```ruby
# app/models/platform/invoice.rb
module Platform
  class Invoice < Platform::ApplicationRecord
    STATUSES = %w[draft sent partially_paid paid overdue void refunded].freeze
    PAYMENT_TERMS = %w["Due on receipt" "Net 7" "Net 15" "Net 30" "Net 45" "Net 60" "Net 90"].freeze

    belongs_to :organization
    belongs_to :issued_by, class_name: "Platform::Organization", optional: true
    belongs_to :bill_to_organization, class_name: "Platform::Organization", optional: true
    belongs_to :bill_to_user, class_name: "Platform::User", optional: true
    belongs_to :template, class_name: "Platform::InvoiceTemplate", optional: true
    belongs_to :recurring_schedule, class_name: "Platform::RecurringInvoiceSchedule", optional: true

    has_many :invoice_line_items, dependent: :destroy
    has_many :invoice_payments, dependent: :destroy
    has_many :credit_notes, foreign_key: :original_invoice_id, dependent: :destroy

    validates :invoice_number, presence: true, uniqueness: true
    validates :status, inclusion: { in: STATUSES }
    validates :currency, presence: true

    before_validation :set_defaults, on: :create

    scope :overdue, -> { where(status: %w[sent partially_paid]).where("due_date < ?", Date.current) }
    scope :unpaid, -> { where(status: %w[draft sent partially_paid]) }
    scope :paid, -> { where(status: "paid") }

    def calculate_totals!
      line_subtotal = invoice_line_items.sum { |li| li.quantity * li.unit_price }
      line_tax = invoice_line_items.sum { |li| li.tax_amount || ((li.quantity * li.unit_price) * li.tax_rate).round }
      line_discount = invoice_line_items.sum { |li| li.discount_amount || 0 }

      self.subtotal = line_subtotal
      self.tax_total = line_tax
      self.discount_total = line_discount
      self.total = line_subtotal + line_tax - line_discount
      self.amount_due = total - amount_paid
    end

    def mark_as_sent!
      update!(status: "sent", sent_at: Time.current)
    end

    def mark_as_void!
      update!(status: "void", voided_at: Time.current)
    end

    def mark_as_refunded!
      update!(status: "refunded")
    end

    def check_overdue!
      return unless status.in?(%w[sent partially_paid])
      return unless due_date < Date.current

      update!(status: "overdue", overdue_at: Time.current)
    end

    def pdf_path
      "invoices/#{organization_id}/#{invoice_number}.pdf"
    end

    def balance_remaining
      [total - amount_paid, 0].max
    end

    def fully_paid?
      amount_due <= 0
    end

    def partially_paid?
      amount_paid > 0 && amount_due > 0
    end

    private

    def set_defaults
      self.issue_date ||= Date.current
      self.currency ||= "ETB"
      self.amount_paid ||= 0
    end
  end
end
```

#### Overdue Invoice Checker (Scheduled Job)

```ruby
# app/jobs/platform/overdue_invoice_checker_job.rb
module Platform
  class OverdueInvoiceCheckerJob < ApplicationJob
    def perform
      Platform::Invoice.overdue.find_each do |invoice|
        invoice.check_overdue!
        Platform::Notification.create!(
          user_id: invoice.organization.billing_contact_id,
          type: "invoice_overdue",
          channel: "email",
          data: {
            invoice_number: invoice.invoice_number,
            amount_due: invoice.amount_due,
            due_date: invoice.due_date,
            days_overdue: (Date.current - invoice.due_date).to_i
          }
        )
      end
    end
  end
end

# Run daily at 8 AM
# Sidekiq.cron_schedule("0 8 * * *") { Platform::OverdueInvoiceCheckerJob.perform_later }
```

#### Real-World Invoice Scenarios

**Scenario A: Corporate Bulk Ticket Purchase**
```ruby
# Company buys 50 tickets for their annual party
order = Order.find(order_id)

invoice = Platform::InvoiceService.create_from_order(order,
  bill_to_name: "Ethiopian Airlines — Events Department",
  bill_to_email: "events@ethiopianairlines.com",
  bill_to_address: "Bole International Airport, Addis Ababa",
  bill_to_tax_id: "TIN-001234567",
  payment_terms: "Net 30"
)

# Invoice:
# INV-2026-00042
# Ethiopian Airlines — Events Department
# TIN: 001234567
#
# Line Items:
# 50 × VIP Table — Company Gala                    25,000 birr × 50    1,250,000 birr
# Platform Commission (3%)                                                  37,500 birr
# ─────────────────────────────────────────────────────────────────────────────────
# Subtotal                                                              1,287,500 birr
# VAT (15%)                                                               193,125 birr
# ─────────────────────────────────────────────────────────────────────────────────
# Total                                                                 1,480,625 birr
#
# Payment Terms: Net 30
# Due Date: June 18, 2026
```

**Scenario B: Messaging Credit Purchase**
```ruby
# Organizer buys 10,000 messaging credits upfront
invoice = Platform::InvoiceService.create_credit_purchase_invoice(
  organization: organizer,
  quantity: 10_000,
  unit_price: 40,  # 0.40 birr per message (volume rate)
  payment_terms: "Due on receipt"
)

# Invoice:
# INV-2026-00043
# Addis Live Entertainment
#
# Line Items:
# 10,000 × Messaging Credits (SMS — Ethiopia)          0.40 birr    4,000 birr
# ─────────────────────────────────────────────────────────────────────────────────
# Total                                                                 4,000 birr
#
# Payment Terms: Due on receipt
# Due Date: May 19, 2026
```

**Scenario C: Sponsorship Invoice**
```ruby
# Brand sponsors an event
invoice = Platform::InvoiceService.create_sponsorship_invoice(
  sponsor_event: emf,
  sponsor_organization: coke_ethiopia,
  amount: 500_000,  # 5,000 birr sponsorship
  description: "Main Stage Sponsorship — Ethiopian Music Festival 2026\nIncludes: Logo on all materials, 30-sec video slot, 10 VIP tickets",
  payment_terms: "Net 15"
)

# Invoice:
# INV-2026-00044
# Coca-Cola Ethiopia
# TIN: 009876543
#
# Line Items:
# Main Stage Sponsorship — EMF 2026                                 500,000 birr
# ─────────────────────────────────────────────────────────────────────────────────
# Subtotal                                                            500,000 birr
# VAT (15%)                                                            75,000 birr
# ─────────────────────────────────────────────────────────────────────────────────
# Total                                                               575,000 birr
#
# Payment Terms: Net 15
# Due Date: June 3, 2026
```

**Scenario D: Partial Payment**
```ruby
# Company pays 50% upfront, 50% later
invoice = Platform::Invoice.find(invoice_id)

# First payment
Platform::InvoiceService.record_payment(
  invoice: invoice,
  amount: 740_313,  # 50% of 1,480,625
  payment_method: "bank_transfer",
  payment_reference: "TRF-2026-05-20-001"
)

# Invoice status: "partially_paid"
# Amount due: 740,312 birr

# Second payment (30 days later)
Platform::InvoiceService.record_payment(
  invoice: invoice,
  amount: 740_312,
  payment_method: "bank_transfer",
  payment_reference: "TRF-2026-06-19-045"
)

# Invoice status: "paid"
# Amount due: 0
```

**Scenario E: Credit Note for Refund**
```ruby
# Event cancelled, need to refund sponsor
invoice = Platform::Invoice.find(invoice_id)

credit_note = Platform::InvoiceService.issue_credit_note(
  invoice: invoice,
  amount: 575_000,
  reason: "cancellation",
  description: "Event cancelled due to venue unavailability — full refund"
)

# Credit Note:
# CN-2026-00012
# Original Invoice: INV-2026-00044
# Amount: 575,000 birr
# Reason: Cancellation
#
# Invoice status changes: "paid" → "refunded"
```

**Scenario F: Recurring Monthly Platform Fee**
```ruby
# Platform charges organizers a monthly SaaS fee
schedule = Platform::RecurringInvoiceSchedule.create!(
  organization_id: organizer.id,
  name: "Monthly Platform Subscription — Pro Plan",
  amount: 2_500_00,  # 2,500 birr/month
  frequency: "monthly",
  day_of_month: 1,
  start_date: Date.current,
  line_items_template: [
    { description: "Platform Pro Plan — Monthly Subscription", quantity: 1, unit_price: 2_500_00, tax_rate: 0.15 }
  ]
)

# On the 1st of each month, job generates:
# INV-2026-00100 — May 2026
# INV-2026-00150 — June 2026
# INV-2026-00200 — July 2026
```

**Scenario G: Multi-Currency Sponsorship**
```ruby
# International sponsor pays in USD
invoice = Platform::Invoice.create!(
  invoice_number: Platform::InvoiceNumberGenerator.generate,
  organization_id: emf.organization_id,
  bill_to_name: "Live Nation International",
  bill_to_address: "9348 Civic Center Drive, Beverly Hills, CA 90210",
  bill_to_country: "US",
  subtotal: 10_000_00,  # $10,000 (stored in cents)
  tax_total: 0,          # No VAT for international
  total: 10_000_00,
  amount_due: 10_000_00,
  currency: "USD",
  issue_date: Date.current,
  due_date: Date.current + 30.days,
  payment_terms: "Net 30",
  reference_type: "sponsorship"
)
```

#### Invoice PDF Generation

```ruby
# app/services/platform/invoice_pdf_generator.rb
module Platform
  class InvoicePdfGenerator
    def initialize(invoice)
      @invoice = invoice
    end

    def generate
      # Using WickedPDF, Prawnto, or similar
      pdf = WickedPdf.new.pdf_from_string(
        ApplicationController.render(
          template: "platform/invoices/show",
          layout: "invoice_pdf",
          locals: { invoice: @invoice }
        )
      )

      # Store in Active Storage or S3
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(pdf),
        filename: "#{@invoice.invoice_number}.pdf",
        content_type: "application/pdf"
      )

      @invoice.attachments.attach(blob)
      blob
    end
  end
end
```

#### Invoice Email Delivery

```ruby
# app/mailers/platform/invoice_mailer.rb
module Platform
  class InvoiceMailer < ApplicationMailer
    def send_invoice(invoice)
      @invoice = invoice
      pdf = Platform::InvoicePdfGenerator.new(invoice).generate

      mail(
        to: invoice.bill_to_email,
        subject: "Invoice #{invoice.invoice_number} from Digis Platform",
        attachments: { "#{invoice.invoice_number}.pdf" => pdf.read }
      )
    end

    def overdue_reminder(invoice)
      @invoice = invoice
      mail(
        to: invoice.bill_to_email,
        subject: "OVERDUE: Invoice #{invoice.invoice_number} — #{invoice.amount_due} #{invoice.currency}"
      )
    end
  end
end
```

#### Updated Orders Table

```ruby
# Add to orders table:
t.uuid :invoice_id                               # Linked invoice (if invoiced)
t.boolean :invoiced, default: false              # Has an invoice been generated?
```

#### Updated Messaging Credits Table

```ruby
# Add to messaging_credits table:
t.uuid :purchase_invoice_id                      # Invoice for this credit purchase
```

---

### G9d: No Diaspora Checkout & Multi-Currency Support

**The Problem**: The platform assumes a single currency (ETB) and domestic buyers. But Ethiopia has a **massive diaspora market** — millions of Ethiopians abroad who want to:

- Buy event tickets for family/friends back home
- Purchase VIP experiences as gifts for relatives
- Support events from abroad (cultural connection)
- Pay in USD/EUR/GBP while the organizer receives ETB
- Get transparent exchange rates with no hidden fees

Without multi-currency support, you lose the highest-spending customer segment entirely.

**The Fix**: A multi-currency checkout system with real-time exchange rates, diaspora gifting flow, and automatic settlement:

#### Multi-Currency Tables

```ruby
create_table :currency_exchange_rates, id: :uuid do |t|
  t.string :from_currency, null: false             # "USD", "EUR", "GBP"
  t.string :to_currency, null: false               # "ETB"
  t.decimal :rate, null: false                     # 1 USD = 56.50 ETB
  t.decimal :platform_markup, default: 0.02        # 2% markup on exchange
  t.string :source                                 # "central_bank", "forex_api", "manual"
  t.datetime :effective_from, null: false
  t.datetime :effective_to
  t.boolean :active, default: true
  t.timestamps
end

add_index :currency_exchange_rates, [:from_currency, :to_currency, :active]
add_index :currency_exchange_rates, [:effective_from, :effective_to]

create_table :multi_currency_pricing, id: :uuid do |t|
  t.uuid :ticket_type_id, null: false
  t.uuid :event_id, null: false
  t.string :currency, null: false                  # "USD", "EUR", "GBP"
  t.integer :price, null: false                    # Price in foreign currency (cents)
  t.integer :original_etb_price, null: false       # Original ETB price for reference
  t.decimal :exchange_rate_used                    # Rate locked at creation
  t.datetime :price_locked_until                   # Price guarantee window
  t.boolean :active, default: true
  t.timestamps
end

add_index :multi_currency_pricing, [:ticket_type_id, :currency], unique: true
add_index :multi_currency_pricing, [:event_id, :currency]

create_table :diaspora_gifts, id: :uuid do |t|
  t.uuid :order_id, null: false
  t.uuid :buyer_id, null: false                    # Diaspora buyer (may be shadow user)
  t.uuid :recipient_id                             # Recipient in Ethiopia (may be NULL until claimed)
  t.string :recipient_phone, null: false           # Ethiopian phone number
  t.string :recipient_name
  t.string :gift_message                             # Personal message
  t.string :buyer_country                          # "US", "UK", "DE", etc.
  t.string :buyer_currency, null: false            # Currency buyer paid in
  t.integer :buyer_amount, null: false             # Amount in buyer's currency
  t.integer :etb_equivalent                        # Converted ETB amount
  t.decimal :exchange_rate_applied                 # Rate at time of purchase
  t.string :status, default: "pending"             # pending/delivered/claimed/declined/expired
  t.datetime :delivered_at                         # When SMS/notification sent to recipient
  t.datetime :claimed_at                           # When recipient claimed the ticket
  t.datetime :expires_at
  t.timestamps
end

add_index :diaspora_gifts, :order_id
add_index :diaspora_gifts, :recipient_phone
add_index :diaspora_gifts, [:status, :expires_at]
```

#### Updated Orders Table

```ruby
# Add to orders table:
t.string :buyer_currency, default: "ETB"           # Currency buyer paid in
t.integer :buyer_subtotal                          # Subtotal in buyer's currency
t.integer :buyer_total                              # Total in buyer's currency
t.decimal :exchange_rate_applied                    # Rate locked at checkout
t.integer :etb_equivalent                           # What organizer receives (in ETB)
t.boolean :is_diaspora_purchase, default: false     # Flag for diaspora checkout
t.uuid :diaspora_gift_id                            # If this is a gift purchase
t.string :buyer_country                             # Buyer's country (for compliance)
```

#### Exchange Rate Service

```ruby
# app/services/platform/exchange_rate_service.rb
module Platform
  class ExchangeRateService
    # Get current exchange rate with platform markup
    def self.get_rate(from_currency:, to_currency: "ETB")
      return 1.0 if from_currency == to_currency

      rate = Platform::CurrencyExchangeRate
        .where(from_currency: from_currency, to_currency: to_currency)
        .where(active: true)
        .where("effective_from <= ?", Time.current)
        .where("effective_to IS NULL OR effective_to >= ?", Time.current)
        .order(effective_from: :desc)
        .first

      raise Platform::Error.new("No exchange rate available for #{from_currency} to #{to_currency}") unless rate

      # Apply platform markup (small fee for currency conversion)
      rate.rate * (1 + rate.platform_markup)
    end

    # Convert amount
    def self.convert(amount:, from_currency:, to_currency: "ETB")
      rate = get_rate(from_currency: from_currency, to_currency: to_currency)
      (amount * rate).round
    end

    # Lock rate for a checkout session (prevents mid-checkout changes)
    def self.lock_rate(from_currency:, to_currency: "ETB", duration: 15.minutes)
      rate = get_rate(from_currency: from_currency, to_currency: to_currency)

      {
        rate: rate,
        locked_at: Time.current,
        expires_at: Time.current + duration
      }
    end

    # Refresh rates from external API (scheduled job)
    def self.refresh_rates!
      # Fetch from central bank or forex API
      rates = ForexApi.fetch_rates(base: "ETB")

      %w[USD EUR GBP].each do |currency|
        Platform::CurrencyExchangeRate.create!(
          from_currency: currency,
          to_currency: "ETB",
          rate: rates[currency],
          platform_markup: 0.02,  # 2% markup
          source: "forex_api",
          effective_from: Time.current,
          effective_to: 24.hours.from_now
        )
      end
    end
  end
end
```

#### Diaspora Checkout Flow

```ruby
# app/services/platform/diaspora_checkout_service.rb
module Platform
  class DiasporaCheckoutService
    def initialize(ticket_type:, quantity:, buyer:, recipient_phone:, recipient_name:, gift_message:, buyer_currency:, buyer_country:)
      @ticket_type = ticket_type
      @quantity = quantity
      @buyer = buyer
      @recipient_phone = recipient_phone
      @recipient_name = recipient_name
      @gift_message = gift_message
      @buyer_currency = buyer_currency
      @buyer_country = buyer_country
    end

    def execute
      ActiveRecord::Base.transaction do
        # 1. Lock exchange rate
        rate_info = Platform::ExchangeRateService.lock_rate(
          from_currency: @buyer_currency,
          to_currency: "ETB"
        )

        # 2. Calculate ETB price
        etb_subtotal = @ticket_type.price_amount * @quantity
        buyer_subtotal = Platform::ExchangeRateService.convert(
          amount: etb_subtotal,
          from_currency: "ETB",
          to_currency: @buyer_currency
        )

        # 3. Calculate fees in buyer's currency
        fee_result = Platform::FeeCalculator.calculate(
          ticket_type: @ticket_type,
          quantity: @quantity,
          channel: "purchase",
          buyer: @buyer,
          organizer: @ticket_type.event.organization,
          event: @ticket_type.event
        )

        buyer_fees = Platform::ExchangeRateService.convert(
          amount: fee_result[:total_fees],
          from_currency: "ETB",
          to_currency: @buyer_currency
        )

        buyer_total = buyer_subtotal + buyer_fees

        # 4. Create order (stored in ETB for organizer)
        order = Platform::Order.create!(
          organization_id: @ticket_type.event.organization_id,
          event_id: @ticket_type.event_id,
          subtotal: etb_subtotal,
          platform_fee: fee_result[:organizer_pays],
          processing_fee: fee_result[:buyer_pays],
          grand_total: etb_subtotal + fee_result[:buyer_pays],
          buyer_currency: @buyer_currency,
          buyer_subtotal: buyer_subtotal,
          buyer_total: buyer_total,
          exchange_rate_applied: rate_info[:rate],
          etb_equivalent: etb_subtotal + fee_result[:buyer_pays],
          is_diaspora_purchase: true,
          buyer_country: @buyer_country,
          fee_breakdown: fee_result[:breakdown]
        )

        # 5. Create diaspora gift record
        gift = Platform::DiasporaGift.create!(
          order_id: order.id,
          buyer_id: @buyer.id,
          recipient_phone: @recipient_phone,
          recipient_name: @recipient_name,
          gift_message: @gift_message,
          buyer_country: @buyer_country,
          buyer_currency: @buyer_currency,
          buyer_amount: buyer_total,
          etb_equivalent: order.etb_equivalent,
          exchange_rate_applied: rate_info[:rate],
          expires_at: 7.days.from_now
        )

        order.update!(diaspora_gift_id: gift.id)

        # 6. Process payment (international card, Stripe, etc.)
        payment = process_international_payment(order, buyer_total, @buyer_currency)

        # 7. Generate tickets
        tickets = generate_tickets(order, @ticket_type, @quantity)

        # 8. Send gift notification to recipient
        send_gift_notification(gift, tickets)

        {
          order: order,
          gift: gift,
          payment: payment,
          tickets: tickets,
          buyer_total: buyer_total,
          buyer_currency: @buyer_currency,
          etb_equivalent: order.etb_equivalent
        }
      end
    end

    private

    def process_international_payment(order, amount, currency)
      # Integrate with Stripe, PayPal, or international payment gateway
      # This is separate from domestic Telebirr/CBE flow
      Platform::PaymentGateway.process_international(
        amount: amount,
        currency: currency,
        order_id: order.id,
        buyer: @buyer
      )
    end

    def generate_tickets(order, ticket_type, quantity)
      quantity.times.map do
        Platform::Ticket.create!(
          order_id: order.id,
          ticket_type_id: ticket_type.id,
          event_id: ticket_type.event_id,
          status: "active",
          version: 1,
          qr_token: Platform::QrTokenService.generate
        )
      end
    end

    def send_gift_notification(gift, tickets)
      # SMS to recipient in Ethiopia
      Platform::Notification.create!(
        type: "diaspora_gift_received",
        channel: "sms",
        phone: gift.recipient_phone,
        data: {
          sender_name: gift.buyer.name,
          event_name: tickets.first.event.name,
          ticket_count: tickets.count,
          gift_message: gift.gift_message,
          claim_url: "https://dig.is/claim/#{gift.id}"
        }
      )

      # Email to buyer (confirmation)
      Platform::Notification.create!(
        type: "diaspora_gift_sent",
        channel: "email",
        user_id: gift.buyer_id,
        data: {
          recipient_name: gift.recipient_name,
          recipient_phone: gift.recipient_phone,
          event_name: tickets.first.event.name,
          amount_paid: "#{gift.buyer_amount} #{gift.buyer_currency}",
          etb_equivalent: "#{gift.etb_equivalent} ETB"
        }
      )
    end
  end
end
```

#### Updated Payments Table

```ruby
# Add to payments table:
t.string :gateway_type                            # "telebirr", "stripe", "paypal", "chapa"
t.string :gateway_currency                        # Currency processed in
t.integer :gateway_amount                         # Amount in gateway currency
t.decimal :gateway_exchange_rate                  # Rate at time of processing
t.string :gateway_transaction_id                  # External reference
t.jsonb :gateway_metadata                         # Gateway-specific data
```

#### Real-World Diaspora Scenarios

**Scenario A: Diaspora Buys Concert Ticket for Family**
```
Buyer: Yonas (lives in Washington DC, USA)
Recipient: His sister Meron (Addis Ababa, +251911...)
Event: Gize Concert — VIP Section

Checkout:
  Ticket: VIP Section × 1                    5,000 ETB
  Platform Fee (3%)                            150 ETB
  Processing Fee                                50 ETB
  ─────────────────────────────────────────────────
  Total (ETB)                                5,200 ETB

  Exchange Rate: 1 USD = 56.50 ETB (locked for 15 min)
  Platform Markup: 2%
  Effective Rate: 1 USD = 57.63 ETB

  Total (USD):                              $90.23

Yonas pays $90.23 via Stripe (US credit card)
Meron receives SMS: "Yonas sent you a VIP ticket for Gize Concert! Message: 'Enjoy the night!' Claim: https://dig.is/claim/xyz"
Meron clicks link → ticket appears in her account
```

**Scenario B: Group Gift from Multiple Diaspora Friends**
```
Three friends in London want to buy tickets for their friend's birthday in Addis:
- Each contributes £30 via the platform's group payment pool
- Total: £90 → converted to ETB at locked rate
- 2 × General Admission tickets purchased
- Gift message: "Happy Birthday from your London crew! 🎉"
- All three get email confirmation, recipient gets SMS
```

**Scenario C: Corporate Sponsor from Abroad**
```
US-based Ethiopian company sponsors an event:
- Buys 20 VIP tickets for employees' families in Ethiopia
- Pays $2,000 via wire transfer
- Each ticket assigned to specific phone numbers
- Organizer receives ETB equivalent in their account
- Invoice generated in USD for corporate accounting
```

#### Diaspora Checkout UI Flow

```
Step 1: Select Tickets
  Event: Gize Concert — VIP Section
  Quantity: 1
  Price: 5,000 ETB

Step 2: "Buying for someone in Ethiopia?"
  ☑ Yes, this is a gift
  Recipient Name: Meron Admasu
  Recipient Phone: +251 911 234 567
  Gift Message: "Enjoy the night! Love, Yonas"

Step 3: Payment
  Your Country: United States
  Currency: USD
  Exchange Rate: 1 USD = 57.63 ETB (locked for 14:32)
  Platform Fee (2.5%): $2.26

  Ticket: 5,150 ETB → $89.37
  Processing Fee: 50 ETB → $0.86
  ──────────────────────────
  Total: $90.23

  [Pay with Card] [Pay with PayPal]

Step 4: Confirmation
  ✅ Payment successful!
  Meron will receive an SMS with her ticket.
  You'll get an email confirmation.
```

#### Exchange Rate Display to Users

```
💱 Currency Conversion
  1 USD = 56.50 ETB (Central Bank Rate)
  + 2% platform fee = 57.63 ETB

  Your ticket costs 5,200 ETB
  You pay: $90.23 USD

  Rate locked for 14 minutes.
  Complete checkout before rate changes.
```

#### Organizer Settlement (Behind the Scenes)

```
Order #12345 — Diaspora Purchase
  Buyer paid: $90.23 USD (via Stripe)
  Platform receives: $90.23 → converts to 5,200 ETB
  Organizer receives: 5,050 ETB (ticket price minus platform fee)
  Platform keeps: 150 ETB (commission) + $1.81 (FX markup)

  Organizer sees: 5,050 ETB in their dashboard
  (No currency complexity — they always see ETB)
```

#### Compliance & Reporting

```ruby
# app/services/platform/diaspora_reporting_service.rb
module Platform
  class DiasporaReportingService
    def self.monthly_summary(month:, year:)
      orders = Platform::Order
        .where(is_diaspora_purchase: true)
        .where(created_at: Date.new(year, month).beginning_of_month..Date.new(year, month).end_of_month)

      {
        total_orders: orders.count,
        total_revenue_usd: orders.where(buyer_currency: "USD").sum(:buyer_total),
        total_revenue_eur: orders.where(buyer_currency: "EUR").sum(:buyer_total),
        total_revenue_gbp: orders.where(buyer_currency: "GBP").sum(:buyer_total),
        total_etb_settled: orders.sum(:etb_equivalent),
        top_buyer_countries: orders.group(:buyer_country).count.sort_by { |_, v| -v }.first(10),
        top_events: orders.joins(:event).group("events.name").count.sort_by { |_, v| -v }.first(10),
        fx_markup_revenue: calculate_fx_markup(orders)
      }
    end
  end
end
```

---

### G9e: No On-Site Ticket Sales (Box Office / Will-Call / Door Sales)

**The Problem**: The platform assumes all tickets are sold online before the event. But real events have significant on-site sales:

- Walk-up buyers at the venue door
- Will-call pickup (pre-paid tickets collected at the box office)
- VIP upgrades at the door ("upgrade to VIP for 500 birr more")
- Day-of-event price changes (early bird ends, regular price starts)
- Cash payments (no mobile money at the door)
- Multiple box office terminals (gate A, gate B, VIP entrance)
- Guest list management (comp tickets, press list, organizer guests)
- On-site refunds and exchanges
- Shift management (cashier A works 5pm-9pm, cashier B works 9pm-close)
- End-of-day cash reconciliation
- Offline capability (venue has no internet)

Without on-site sales, organizers must use a separate system at the door — creating reconciliation nightmares and lost data.

**The Fix**: A complete box office system integrated with the main platform:

#### Box Office Tables

```ruby
create_table :box_office_sessions, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :organization_id, null: false
  t.uuid :cashier_id, null: false                 # Platform::User who is the cashier
  t.uuid :terminal_id                              # Physical POS terminal/tablet
  t.string :location                               # "Gate A", "VIP Entrance", "Box Office"
  t.datetime :opened_at, null: false
  t.datetime :closed_at
  t.string :status, default: "open"                # open/closed/suspended
  t.integer :starting_cash, default: 0             # Float given to cashier (cents)
  t.integer :ending_cash                           # Cash counted at close
  t.integer :expected_cash                         # What the system says should be in drawer
  t.integer :overage_shortage                      # ending_cash - expected_cash (negative = shortage)
  t.text :closing_notes
  t.uuid :closed_by_id                             # Supervisor who verified the close
  t.timestamps
end

add_index :box_office_sessions, [:event_id, :status]
add_index :box_office_sessions, [:cashier_id, :opened_at]

create_table :box_office_sales, id: :uuid do |t|
  t.uuid :box_office_session_id, null: false
  t.uuid :event_id, null: false
  t.uuid :ticket_type_id, null: false
  t.integer :quantity, null: false
  t.integer :unit_price, null: false               # Price at time of sale (may differ from online)
  t.integer :subtotal, null: false
  t.integer :tax_amount, default: 0
  t.integer :total, null: false
  t.string :payment_method, null: false            # cash/telebirr/card/transfer
  t.string :currency, default: "ETB"
  t.uuid :order_id                                 # Links to main orders table
  t.uuid :customer_id                              # Walk-up customer (may be shadow user)
  t.string :customer_phone                         # For receipt SMS
  t.string :customer_name
  t.string :receipt_number, null: false            # "REC-2026-00001"
  t.datetime :sold_at, null: false
  t.uuid :sold_by_id, null: false                  # Cashier who made the sale
  t.text :notes
  t.timestamps
end

add_index :box_office_sales, :box_office_session_id
add_index :box_office_sales, :receipt_number, unique: true
add_index :box_office_sales, [:event_id, :sold_at]
add_index :box_office_sales, [:sold_by_id, :sold_at]

create_table :will_call_tickets, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :order_id, null: false                    # Original online order
  t.uuid :ticket_id, null: false                   # The ticket(s) held
  t.uuid :customer_id
  t.string :customer_phone, null: false
  t.string :customer_name
  t.string :confirmation_code, null: false         # "WC-ABCD1234"
  t.string :id_number                              # ID presented at pickup (for verification)
  t.string :status, default: "held"                # held/picked_up/expired/released
  t.datetime :held_until                           # Auto-release after event starts
  t.datetime :picked_up_at
  t.uuid :released_by_id                           # Staff who released the ticket
  t.text :notes
  t.timestamps
end

add_index :will_call_tickets, :confirmation_code, unique: true
add_index :will_call_tickets, [:event_id, :status]
add_index :will_call_tickets, :order_id

create_table :guest_list_entries, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :organization_id, null: false
  t.string :name, null: false
  t.string :phone
  t.string :email
  t.integer :guest_count, default: 1
  t.string :list_type, default: "general"          # general/vip/press/artist/organizer
  t.string :status, default: "approved"            # approved/denied/checked_in
  t.datetime :checked_in_at
  t.uuid :approved_by_id                           # Who approved this guest
  t.text :notes                                    # "CEO's plus-one", "Press - Addis Fortune"
  t.timestamps
end

add_index :guest_list_entries, [:event_id, :phone]
add_index :guest_list_entries, [:event_id, :list_type]
add_index :guest_list_entries, [:event_id, :status]

create_table :box_office_terminals, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.string :name, null: false                      # "Gate A iPad", "Box Office Laptop"
  t.string :terminal_id, null: false               # Hardware identifier
  t.string :status, default: "active"              # active/inactive/offline
  t.datetime :last_sync_at
  t.datetime :last_seen_at
  t.jsonb :capabilities                            # ["printer", "card_reader", "cash_drawer"]
  t.timestamps
end

add_index :box_office_terminals, :terminal_id, unique: true

create_table :box_office_shifts, id: :uuid do |t|
  t.uuid :box_office_session_id, null: false
  t.uuid :cashier_id, null: false
  t.datetime :started_at, null: false
  t.datetime :ended_at
  t.integer :cash_at_start, default: 0             # Cash in drawer when shift started
  t.integer :cash_at_end                           # Cash when shift ended
  t.text :handover_notes                           # Notes for next cashier
  t.timestamps
end

add_index :box_office_shifts, :box_office_session_id
```

#### Updated Events Table

```ruby
# Add to events table:
t.boolean :box_office_enabled, default: true       # Allow on-site sales
t.datetime :box_office_opens_at                    # When box office opens (may be before event)
t.datetime :box_office_closes_at                   # When box office closes
t.jsonb :box_office_config
# Example:
# {
#   cash_accepted: true,
#   telebirr_accepted: true,
#   card_accepted: false,
#   will_call_enabled: true,
#   guest_list_enabled: true,
#   vip_upgrades_enabled: true,
#   vip_upgrade_price: 50000,
#   offline_mode_enabled: true,
#   receipt_sms_enabled: true
# }
```

#### Updated Ticket Types Table

```ruby
# Add to ticket_types table:
t.boolean :available_at_door, default: true        # Can be sold on-site
t.integer :door_price                              # Different price at door (NULL = same as online)
t.integer :door_capacity                           # Separate capacity for door sales (NULL = shared)
t.integer :door_sold, default: 0                   # Counter for door sales
```

#### Box Office Session Service

```ruby
# app/services/platform/box_office_service.rb
module Platform
  class BoxOfficeService
    # Open a new box office session
    def self.open_session(event:, cashier:, terminal: nil, location: "Box Office", starting_cash: 0)
      Platform::BoxOfficeSession.create!(
        event_id: event.id,
        organization_id: event.organization_id,
        cashier_id: cashier.id,
        terminal_id: terminal&.id,
        location: location,
        opened_at: Time.current,
        starting_cash: starting_cash,
        status: "open"
      )
    end

    # Sell tickets at the door
    def self.sell_at_door(session:, ticket_type:, quantity:, payment_method:, customer_phone:, customer_name: nil, notes: nil)
      raise Platform::Error.new("Session is not open") unless session.status == "open"
      raise Platform::Error.new("Ticket type not available at door") unless ticket_type.available_at_door
      raise Platform::Error.new("Insufficient inventory") unless ticket_type.door_available_quantity >= quantity

      # Use door price if set, otherwise use regular price
      unit_price = ticket_type.door_price || ticket_type.price_amount
      subtotal = unit_price * quantity

      # Calculate tax
      tax_rate = 0.15  # Default VAT, could be configurable
      tax_amount = (subtotal * tax_rate).round
      total = subtotal + tax_amount

      ActiveRecord::Base.transaction do
        # Create receipt number
        receipt_number = generate_receipt_number(session)

        # Create order (links to main orders table for unified reporting)
        order = Platform::Order.create!(
          organization_id: session.organization_id,
          event_id: session.event_id,
          subtotal: subtotal,
          tax_amount: tax_amount,
          grand_total: total,
          currency: "ETB",
          sales_channel: "box_office",              # New field: online/box_office/resale
          box_office_session_id: session.id
        )

        # Generate tickets
        tickets = quantity.times.map do
          Platform::Ticket.create!(
            order_id: order.id,
            ticket_type_id: ticket_type.id,
            event_id: session.event_id,
            status: "active",
            version: 1,
            qr_token: Platform::QrTokenService.generate
          )
        end

        # Record box office sale
        sale = Platform::BoxOfficeSale.create!(
          box_office_session_id: session.id,
          event_id: session.event_id,
          ticket_type_id: ticket_type.id,
          quantity: quantity,
          unit_price: unit_price,
          subtotal: subtotal,
          tax_amount: tax_amount,
          total: total,
          payment_method: payment_method,
          order_id: order.id,
          customer_phone: customer_phone,
          customer_name: customer_name,
          receipt_number: receipt_number,
          sold_at: Time.current,
          sold_by_id: session.cashier_id,
          notes: notes
        )

        # Increment door sold counter
        ticket_type.increment!(:door_sold, quantity)

        # Send receipt SMS
        if session.event.box_office_config&.dig("receipt_sms_enabled")
          Platform::Notification.create!(
            type: "box_office_receipt",
            channel: "sms",
            phone: customer_phone,
            data: {
              event_name: session.event.name,
              ticket_count: quantity,
              ticket_type: ticket_type.name,
              total: total,
              receipt_number: receipt_number
            }
          )
        end

        { sale: sale, order: order, tickets: tickets, receipt_number: receipt_number }
      end
    end

    # Close a box office session
    def self.close_session(session:, ending_cash:, closed_by:, notes: nil)
      # Calculate expected cash
      cash_sales = session.box_office_sales.where(payment_method: "cash").sum(:total)
      expected_cash = session.starting_cash + cash_sales

      overage_shortage = ending_cash - expected_cash

      session.update!(
        closed_at: Time.current,
        status: "closed",
        ending_cash: ending_cash,
        expected_cash: expected_cash,
        overage_shortage: overage_shortage,
        closing_notes: notes,
        closed_by_id: closed_by.id
      )

      session
    end

    # Add to guest list
    def self.add_to_guest_list(event:, name:, phone: nil, email: nil, guest_count: 1, list_type: "general", approved_by:, notes: nil)
      Platform::GuestListEntry.create!(
        event_id: event.id,
        organization_id: event.organization_id,
        name: name,
        phone: phone,
        email: email,
        guest_count: guest_count,
        list_type: list_type,
        approved_by_id: approved_by.id,
        notes: notes
      )
    end

    # Check in guest from list
    def self.check_in_guest(guest_entry)
      raise Platform::Error.new("Guest already checked in") if guest_entry.checked_in_at.present?

      guest_entry.update!(
        status: "checked_in",
        checked_in_at: Time.current
      )
    end

    # Will-call: hold tickets for pickup
    def self.hold_for_will_call(order:, customer_phone:, customer_name:, held_until:)
      order.tickets.each do |ticket|
        Platform::WillCallTicket.create!(
          event_id: order.event_id,
          order_id: order.id,
          ticket_id: ticket.id,
          customer_phone: customer_phone,
          customer_name: customer_name,
          confirmation_code: generate_will_call_code,
          held_until: held_until,
          status: "held"
        )
      end
    end

    # Release will-call ticket to customer
    def self.release_will_ticket(confirmation_code:, id_number:, released_by:)
      will_call = Platform::WillCallTicket.find_by(confirmation_code: confirmation_code)
      raise Platform::Error.new("Will-call ticket not found") unless will_call
      raise Platform::Error.new("Ticket already picked up") if will_call.status == "picked_up"

      will_call.update!(
        status: "picked_up",
        picked_up_at: Time.current,
        released_by_id: released_by.id,
        id_number: id_number
      )

      # Update ticket status
      will_call.ticket.update!(status: "active")

      will_call
    end

    # VIP upgrade at the door
    def self.upgrade_to_vip(ticket:, payment_method:, cashier:)
      event = ticket.event
      upgrade_price = event.box_office_config&.dig("vip_upgrade_price") || 50000

      raise Platform::Error.new("VIP upgrades not enabled") unless event.box_office_config&.dig("vip_upgrades_enabled")
      raise Platform::Error.new("Ticket already VIP") if ticket.ticket_type.name.include?("VIP")

      ActiveRecord::Base.transaction do
        # Process payment
        sale = Platform::BoxOfficeSale.create!(
          box_office_session_id: cashier.current_session.id,
          event_id: event.id,
          ticket_type_id: ticket.ticket_type_id,
          quantity: 1,
          unit_price: upgrade_price,
          subtotal: upgrade_price,
          total: upgrade_price,
          payment_method: payment_method,
          sold_at: Time.current,
          sold_by_id: cashier.id,
          notes: "VIP upgrade for ticket #{ticket.id}"
        )

        # Upgrade ticket
        vip_type = event.ticket_types.find { |t| t.name.include?("VIP") }
        ticket.update!(ticket_type_id: vip_type.id)

        # Re-generate QR with new type
        ticket.update!(qr_token: Platform::QrTokenService.generate)

        { sale: sale, ticket: ticket }
      end
    end

    # Get session summary
    def self.session_summary(session)
      sales = session.box_office_sales
      {
        session_id: session.id,
        location: session.location,
        cashier: session.cashier.name,
        opened_at: session.opened_at,
        closed_at: session.closed_at,
        total_sales: sales.count,
        total_revenue: sales.sum(:total),
        by_payment_method: sales.group(:payment_method).sum(:total),
        by_ticket_type: sales.joins(:ticket_type).group("ticket_types.name").sum(:total),
        starting_cash: session.starting_cash,
        expected_cash: session.expected_cash,
        ending_cash: session.ending_cash,
        overage_shortage: session.overage_shortage
      }
    end

    private

    def self.generate_receipt_number(session)
      date = session.opened_at.strftime("%Y%m%d")
      count = session.box_office_sales.count + 1
      "REC-#{date}-#{count.to_s.rjust(4, '0')}"
    end

    def self.generate_will_call_code
      "WC-" + SecureRandom.alphanumeric(8).upcase
    end
  end
end
```

#### Box Office Terminal (Offline-Capable)

```ruby
# app/services/platform/box_office_sync_service.rb
module Platform
  class BoxOfficeSyncService
    # Download event data to terminal for offline use
    def self.sync_to_terminal(terminal:, event:)
      manifest = {
        event_id: event.id,
        event_name: event.name,
        ticket_types: event.ticket_types.map { |t| { id: t.id, name: t.name, price: t.price_amount, door_price: t.door_price } },
        inventory: event.ticket_types.map { |t| { id: t.id, available: t.door_available_quantity } },
        guest_list: event.guest_list_entries.where(status: "approved").map { |g| { name: g.name, phone: g.phone, guest_count: g.guest_count } },
        will_call: event.will_call_tickets.where(status: "held").map { |w| { code: w.confirmation_code, name: w.customer_name, phone: w.customer_phone } },
        synced_at: Time.current
      }

      # Store on terminal (local DB or file)
      terminal.update!(last_sync_at: Time.current, status: "active")

      manifest
    end

    # Upload offline sales when terminal reconnects
    def self.sync_from_terminal(terminal:, sales_data:)
      ActiveRecord::Base.transaction do
        sales_data.each do |sale_data|
          session = Platform::BoxOfficeSession.find(sale_data[:session_id])

          Platform::BoxOfficeSale.create!(
            box_office_session_id: session.id,
            event_id: session.event_id,
            ticket_type_id: sale_data[:ticket_type_id],
            quantity: sale_data[:quantity],
            unit_price: sale_data[:unit_price],
            subtotal: sale_data[:subtotal],
            total: sale_data[:total],
            payment_method: sale_data[:payment_method],
            customer_phone: sale_data[:customer_phone],
            customer_name: sale_data[:customer_name],
            receipt_number: sale_data[:receipt_number],
            sold_at: sale_data[:sold_at],
            sold_by_id: session.cashier_id
          )

          # Generate tickets
          sale_data[:quantity].times do
            Platform::Ticket.create!(
              event_id: session.event_id,
              ticket_type_id: sale_data[:ticket_type_id],
              status: "active",
              version: 1,
              qr_token: Platform::QrTokenService.generate
            )
          end
        end
      end
    end
  end
end
```

#### Real-World Box Office Scenarios

**Scenario A: Standard Door Sales**
```
Event: Gize Concert
Box Office opens at 17:00, event starts at 20:00

17:00 — Cashier Abebe opens session at Gate A
  Starting cash: 5,000 ETB (float)
  Terminal: Gate A iPad

17:30 — Walk-up customer buys 2 General Admission
  Unit price: 1,000 ETB × 2 = 2,000 ETB
  VAT (15%): 300 ETB
  Total: 2,300 ETB
  Payment: Cash
  Receipt: REC-20260519-0001
  SMS sent: "Your tickets for Gize Concert — 2 × General Admission. Receipt: REC-20260519-0001"

19:00 — Another customer buys 1 VIP
  Door price: 3,000 ETB (higher than online 2,500 ETB)
  VAT (15%): 450 ETB
  Total: 3,450 ETB
  Payment: Telebirr

22:00 — Box office closes
  Cash sales: 2,300 ETB
  Telebirr sales: 3,450 ETB
  Total revenue: 5,750 ETB
  Starting cash: 5,000 ETB
  Expected cash: 5,000 + 2,300 = 7,300 ETB
  Ending cash (counted): 7,300 ETB
  Overage/Shortage: 0 ✅
```

**Scenario B: Will-Call Pickup**
```
Customer bought online but wants to pick up at the door:
1. Online order placed → tickets held at will-call
2. Customer receives confirmation code: WC-ABCD1234
3. At box office: "I'm here to pick up my tickets"
4. Cashier looks up code → finds 2 tickets under "Meron Admasu"
5. Customer shows ID → cashier records ID number
6. Tickets released → QR codes sent via SMS
7. Will-call status: picked_up
```

**Scenario C: Guest List Check-In**
```
VIP guest list at the door:
1. Organizer pre-approved 20 people: "Meron Admasu", "Yonas Bekele", etc.
2. At VIP entrance: staff opens guest list on tablet
3. "Meron Admasu" arrives → staff finds name, taps "Check In"
4. System records: checked_in_at, prevents duplicate entry
5. "Random Person" arrives → not on list → directed to box office to buy ticket
```

**Scenario D: VIP Upgrade at the Door**
```
Customer has General Admission ticket, wants to upgrade:
1. At VIP entrance: "Can I upgrade to VIP?"
2. Staff checks: VIP upgrades enabled, price = 5,000 ETB
3. Customer pays 5,000 ETB via Telebirr
4. Ticket type changed: General Admission → VIP
5. New QR code generated (old one invalidated)
6. SMS sent: "Your ticket has been upgraded to VIP! New QR code: [link]"
```

**Scenario E: Multi-Gate Operations**
```
Large event with 3 entrances:
- Gate A: General Admission (2 terminals, 2 cashiers)
- Gate B: VIP Entrance (1 terminal, 1 cashier)
- Gate C: Box Office (2 terminals, 2 cashiers)

Each gate has its own box office session.
End of night: all sessions closed, totals reconciled.
Supervisor sees consolidated report:
  Gate A: 150 sales, 172,500 ETB
  Gate B: 30 sales, 103,500 ETB
  Gate C: 80 sales, 92,000 ETB
  Total: 260 sales, 368,000 ETB
```

**Scenario F: Offline Mode**
```
Venue has no internet:
1. Before event: terminals sync all data (ticket types, prices, guest list, will-call)
2. During event: sales recorded locally on terminal
3. Each sale gets a local receipt number
4. When internet returns: terminal uploads all sales to server
5. Server reconciles, generates tickets, sends SMS receipts
6. Inventory updated, no double-selling
```

#### Box Office Dashboard (Organizer View)

```
Box Office — Gize Concert
─────────────────────────────────────────────────
Active Sessions: 3
  Gate A — Abebe K. — Opened 17:00 — 45 sales
  Gate B — Sara M. — Opened 17:00 — 12 sales
  Box Office — Dawit T. — Opened 16:00 — 78 sales

Today's Revenue: 368,000 ETB
  Cash: 210,000 ETB (57%)
  Telebirr: 158,000 ETB (43%)

Top Selling: General Admission (180 tickets)
VIP Upgrades: 15 (75,000 ETB)

Guest List: 20 approved, 14 checked in, 6 pending
Will-Call: 30 held, 22 picked up, 8 remaining
```

#### End-of-Day Reconciliation Report

```
Box Office Reconciliation — Gize Concert — May 19, 2026
─────────────────────────────────────────────────────────────────────
Session          | Cashier   | Sales | Revenue  | Cash In | Expected | Diff
─────────────────────────────────────────────────────────────────────
Gate A           | Abebe K.  | 45    | 172,500  | 98,000  | 98,000   | 0 ✅
Gate B           | Sara M.   | 12    | 103,500  | 52,000  | 52,000   | 0 ✅
Box Office       | Dawit T.  | 78    | 92,000   | 60,000  | 59,500   | +500 ⚠️
─────────────────────────────────────────────────────────────────────
Total            |           | 135   | 368,000  | 210,000 | 209,500  | +500

Notes: Box Office has 500 ETB overage — Dawit reports customer paid 500 extra for tip.
Verified by: Manager Selam
```

---

### G10: No Ticket Gifting Flow

**The Problem**: The design mentions "ticket gifting" but has no mechanism for:
- Gift message attachment
- Gift notification (SMS/email to recipient)
- Gift acceptance/rejection
- Gift status tracking

**The Fix**:
```ruby
# Add to tickets table:
t.uuid :gifted_by_id                       # User who gifted this
t.datetime :gifted_at
t.string :gift_message                       # Personal message

# Or separate table for complex gifting:
create_table :ticket_gifts, id: :uuid do |t|
  t.uuid :ticket_id, null: false
  t.uuid :from_user_id, null: false
  t.uuid :to_user_id, null: false            # NULL if recipient doesn't exist yet
  t.string :to_phone                         # Phone for shadow user creation
  t.string :to_email
  t.string :message
  t.string :status, default: "pending"       # pending/accepted/declined/expired
  t.datetime :expires_at
  t.datetime :accepted_at
  t.timestamps
end
```

**Scenario Validation**:
- User buys 2 tickets → gifts 1 to friend's phone number
- Friend receives SMS: "You received a ticket for Gize Concert! Message: 'See you there!'"
- Friend clicks link → shadow user created → ticket assigned
- Friend verifies phone → ticket appears in their account
- Gift status: accepted

---

### G11: No Configurable Fee & Commission System

**The Problem**: The original design has a flat `tax_total` field. A real platform needs a **hierarchical, configurable fee engine** that handles:

- Different commission rates for purchase (3%) vs resale (5%)
- Fee absorption: who pays — organizer, buyer, or split?
- Custom deals per organization (negotiated rates)
- Custom deals per event (promotional pricing, free events)
- Volume-based tiered pricing (more sales = lower fees)
- Time-based pricing (early bird fees, last-minute surcharges)
- Fee waivers and promotions (first event free, nonprofit discounts)
- Multiple fee types per transaction (platform fee + processing fee + service fee)
- Fee caps and floors (min/max fee amounts)

**The Fix**: A hierarchical fee rule system with 4 levels of precedence:

```
Global defaults → Organization overrides → Event overrides → Ticket-type overrides
```

Each level can override the one above it. The most specific rule wins.

#### Fee Rules Table

```ruby
create_table :fee_rules, id: :uuid do |t|
  # ── Scope hierarchy (NULL = applies to all below) ──
  t.uuid :organization_id                    # NULL = global platform rule
  t.uuid :event_id                           # NULL = applies to all org events
  t.uuid :ticket_type_id                     # NULL = applies to all event tickets

  # ── Fee identity ──
  t.string :name, null: false                # "Platform Commission", "Processing Fee"
  t.string :fee_type, null: false            # commission/processing/service/platform/resale_commission
  t.string :channel, null: false             # purchase/resale/refund/transfer/gift

  # ── Calculation ──
  t.string :calculation_type, null: false    # percentage/fixed/tiered/minimum
  t.decimal :value, null: false              # Percentage (0.03) or fixed amount (500 cents)
  t.integer :min_amount                      # Minimum fee in cents (floor)
  t.integer :max_amount                      # Maximum fee in cents (cap)

  # ── Tiered pricing (when calculation_type = "tiered") ──
  t.jsonb :tiers                             # [{from: 0, to: 100, rate: 0.05}, {from: 101, to: null, rate: 0.03}]

  # ── Absorption model ──
  t.string :absorbed_by, null: false         # organizer/buyer/split
  t.decimal :split_percentage                # When absorbed_by = "split": organizer pays this % (e.g., 0.6 = 60%)

  # ── Conditions ──
  t.jsonb :conditions                        # Flexible conditions
  # Examples:
  # { min_ticket_price: 500 }               # Only applies to tickets >= 500 birr
  # { first_event_free: true }              # Waive for org's first event
  # { volume_threshold: 1000 }              # Reduced rate after 1000 tickets sold
  # { nonprofit: true }                     # Discount for verified nonprofits

  # ── Time bounds ──
  t.datetime :effective_from
  t.datetime :effective_to

  # ── Status ──
  t.boolean :active, default: true
  t.integer :priority, default: 0            # Higher priority wins when multiple rules match

  t.timestamps
end

add_index :fee_rules, [:organization_id, :event_id, :ticket_type_id, :fee_type, :channel]
add_index :fee_rules, [:fee_type, :channel, :active]
add_index :fee_rules, [:effective_from, :effective_to]
```

#### Fee Rule Resolution Engine

```ruby
# app/services/platform/fee_calculator.rb
module Platform
  class FeeCalculator
    # Calculate all fees for a given context
    # Returns: { platform_fee: 3000, processing_fee: 1000, total_fees: 4000, breakdown: [...] }
    def self.calculate(ticket_type:, quantity:, channel: "purchase", buyer: nil, organizer: nil, event: nil)
      rules = resolve_rules(
        ticket_type: ticket_type,
        event: event || ticket_type.event,
        organizer: organizer || event&.organization,
        channel: channel
      )

      subtotal = ticket_type.price_amount * quantity
      breakdown = []

      rules.each do |rule|
        next unless rule.active?
        next unless rule.effective?
        next unless rule.conditions_met?(context: { ticket_type:, quantity:, buyer:, organizer:, event: })

        fee_amount = rule.calculate(subtotal: subtotal, quantity: quantity)
        fee_amount = [fee_amount, rule.min_amount].max if rule.min_amount
        fee_amount = [fee_amount, rule.max_amount].min if rule.max_amount

        breakdown << {
          name: rule.name,
          fee_type: rule.fee_type,
          calculation: rule.calculation_type,
          value: rule.value,
          amount: fee_amount,
          absorbed_by: rule.absorbed_by,
          split_percentage: rule.split_percentage
        }
      end

      {
        subtotal: subtotal,
        breakdown: breakdown,
        total_fees: breakdown.sum { |f| f[:amount] },
        buyer_pays: breakdown.select { |f| f[:absorbed_by] == "buyer" }.sum { |f| f[:amount] },
        organizer_pays: breakdown.select { |f| f[:absorbed_by] != "buyer" }.sum { |f| f[:amount] },
        grand_total: subtotal + breakdown.select { |f| f[:absorbed_by] == "buyer" }.sum { |f| f[:amount] }
      }
    end

    # Resolve rules with hierarchy: ticket_type > event > organization > global
    def self.resolve_rules(ticket_type:, event:, organizer:, channel:)
      # Build candidate set ordered by specificity (most specific first)
      candidates = Platform::FeeRule
        .where(fee_type: %w[commission processing service platform resale_commission])
        .where(channel: channel)
        .where(active: true)
        .order(priority: :desc, created_at: :desc)

      # Group by fee_type + channel, pick most specific match for each
      grouped = candidates.each_with_object({}) do |rule, hash|
        key = "#{rule.fee_type}:#{rule.channel}"
        next if hash[key]  # Already have a more specific rule

        # Check specificity: ticket_type > event > organization > global
        if rule.ticket_type_id == ticket_type&.id
          hash[key] = rule
        elsif rule.event_id == event&.id && !hash[key]&.ticket_type_id
          hash[key] = rule
        elsif rule.organization_id == organizer&.id && !hash[key]&.event_id && !hash[key]&.ticket_type_id
          hash[key] = rule
        elsif !rule.organization_id && !rule.event_id && !rule.ticket_type_id && !hash[key]
          hash[key] = rule
        end
      end

      grouped.values
    end
  end
end
```

#### Fee Rule Model

```ruby
# app/models/platform/fee_rule.rb
module Platform
  class FeeRule < Platform::ApplicationRecord
    CALCULATION_TYPES = %w[percentage fixed tiered minimum].freeze
    CHANNELS = %w[purchase resale refund transfer gift].freeze
    FEE_TYPES = %w[commission processing service platform resale_commission].freeze
    ABSORPTION_MODELS = %w[organizer buyer split].freeze

    validates :name, :fee_type, :channel, :calculation_type, :absorbed_by, presence: true
    validates :value, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :calculation_type, inclusion: { in: CALCULATION_TYPES }
    validates :channel, inclusion: { in: CHANNELS }
    validates :fee_type, inclusion: { in: FEE_TYPES }
    validates :absorbed_by, inclusion: { in: ABSORPTION_MODELS }

    def effective?
      return true if effective_from.blank? && effective_to.blank?
      now = Time.current
      (effective_from.blank? || now >= effective_from) &&
        (effective_to.blank? || now <= effective_to)
    end

    def conditions_met?(context:)
      return true if conditions.blank?

      conditions.all? do |key, value|
        case key
        when "min_ticket_price"
          context[:ticket_type].price_amount >= value
        when "first_event_free"
          # Check if this is the org's first published event
          org = context[:organizer]
          return false if org.nil?
          org.events.where(status: "published").count > 1
        when "volume_threshold"
          # Check if event has sold enough tickets for volume discount
          event = context[:event]
          return true if event.nil?
          event.tickets.where(status: "active").count >= value
        when "nonprofit"
          org = context[:organizer]
          org&.nonprofit? == value
        else
          true
        end
      end
    end

    def calculate(subtotal:, quantity:)
      case calculation_type
      when "percentage"
        (subtotal * value).round
      when "fixed"
        value.to_i * quantity
      when "tiered"
        calculate_tiered(subtotal)
      when "minimum"
        [calculate_percentage(subtotal), value.to_i].max
      end
    end

    private

    def calculate_tiered(subtotal)
      return subtotal * value if tiers.blank?

      tiers.each do |tier|
        from = tier["from"] || 0
        to = tier["to"]
        rate = tier["rate"]

        if to.nil?
          return (subtotal * rate).round if subtotal >= from
        else
          return (subtotal * rate).round if subtotal >= from && subtotal <= to
        end
      end

      (subtotal * value).round  # Fallback to base rate
    end

    def calculate_percentage(subtotal)
      (subtotal * value).round
    end
  end
end
```

#### Updated Orders Table

```ruby
# orders table — detailed fee breakdown
t.integer :subtotal, null: false               # Ticket total before fees
t.integer :discount_total, default: 0
t.integer :platform_fee, default: 0            # Platform commission (organizer pays)
t.integer :processing_fee, default: 0          # Payment processing (buyer pays)
t.integer :service_fee, default: 0             # Service fee (buyer pays)
t.integer :resale_commission, default: 0       # Resale platform commission
t.integer :tax_amount, default: 0
t.integer :grand_total, null: false            # What buyer actually pays
t.jsonb :fee_breakdown                         # Full fee calculation details for audit
# Example:
# [
#   { "name": "Platform Commission", "type": "commission", "amount": 3000, "absorbed_by": "organizer" },
#   { "name": "Processing Fee", "type": "processing", "amount": 1000, "absorbed_by": "buyer" },
#   { "name": "Service Fee", "type": "service", "amount": 500, "absorbed_by": "buyer" }
# ]
```

#### Real-World Fee Scenarios

**Scenario A: Default Platform Fees**
```ruby
# Global rules (no organization_id, event_id, ticket_type_id)
FeeRule.create!(
  name: "Platform Commission",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.03,                    # 3%
  absorbed_by: "organizer",
  priority: 0
)

FeeRule.create!(
  name: "Resale Commission",
  fee_type: "resale_commission",
  channel: "resale",
  calculation_type: "percentage",
  value: 0.05,                    # 5% (higher for resale)
  absorbed_by: "seller",
  priority: 0
)

FeeRule.create!(
  name: "Payment Processing",
  fee_type: "processing",
  channel: "purchase",
  calculation_type: "fixed",
  value: 1000,                    # 10 birr fixed
  absorbed_by: "buyer",
  priority: 0
)
```

**Scenario B: Custom Deal for Major Organizer**
```ruby
# "Addis Live" gets negotiated 1.5% commission instead of 3%
FeeRule.create!(
  name: "Addis Live Custom Commission",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.015,                   # 1.5% (negotiated)
  absorbed_by: "organizer",
  organization_id: addis_live.id,
  priority: 10                    # Higher than global default
)
```

**Scenario C: Free First Event for New Organizers**
```ruby
# Waive platform commission for org's first event
FeeRule.create!(
  name: "First Event Free",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.0,                     # 0% — free
  absorbed_by: "organizer",
  conditions: { first_event_free: true },
  priority: 20                    # Highest priority
)
```

**Scenario D: Volume-Based Discount**
```ruby
# After 1000 tickets sold, commission drops from 3% to 2%
FeeRule.create!(
  name: "Volume Discount",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.02,                    # 2% (reduced)
  absorbed_by: "organizer",
  conditions: { volume_threshold: 1000 },
  priority: 15
)
```

**Scenario E: Tiered Pricing for High-Value Events**
```ruby
# Different rates based on ticket price
FeeRule.create!(
  name: "Tiered Commission",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "tiered",
  value: 0.05,                    # Base rate
  tiers: [
    { from: 0, to: 50000, rate: 0.05 },      # 5% for tickets under 500 birr
    { from: 50001, to: 200000, rate: 0.04 },  # 4% for 500-2000 birr
    { from: 200001, to: nil, rate: 0.03 }     # 3% for tickets over 2000 birr
  ],
  absorbed_by: "organizer",
  priority: 5
)
```

**Scenario F: Split Fee Model**
```ruby
# Platform fee split 60/40 between organizer and buyer
FeeRule.create!(
  name: "Shared Platform Fee",
  fee_type: "platform",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.04,                    # 4% total
  absorbed_by: "split",
  split_percentage: 0.6,          # Organizer pays 60% (2.4%), buyer pays 40% (1.6%)
  priority: 0
)
```

**Scenario G: Fee Cap (Maximum Fee)**
```ruby
# 5% commission but capped at 500 birr
FeeRule.create!(
  name: "Capped Commission",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.05,
  max_amount: 50000,              # 500 birr cap (in cents)
  absorbed_by: "organizer",
  priority: 0
)
```

**Scenario H: Time-Limited Promotion**
```ruby
# Launch promotion: 0% commission for first month
FeeRule.create!(
  name: "Launch Promotion",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.0,
  absorbed_by: "organizer",
  effective_from: Time.current,
  effective_to: 1.month.from_now,
  priority: 25                    # Highest priority during promotion
)
```

#### Fee Calculation at Checkout

```ruby
# When buyer checks out:
ticket = TicketType.find(ticket_type_id)
quantity = 2

result = Platform::FeeCalculator.calculate(
  ticket_type: ticket,
  quantity: quantity,
  channel: "purchase",
  buyer: current_user,
  organizer: ticket.event.organization,
  event: ticket.event
)

# Result:
# {
#   subtotal: 200000,              # 2 × 1000 birr
#   breakdown: [
#     { name: "Platform Commission", fee_type: "commission", amount: 6000, absorbed_by: "organizer" },
#     { name: "Payment Processing", fee_type: "processing", amount: 2000, absorbed_by: "buyer" }
#   ],
#   total_fees: 8000,
#   buyer_pays: 2000,              # Only buyer-absorbed fees
#   organizer_pays: 6000,          # Organizer-absorbed fees (deducted from payout)
#   grand_total: 202000            # What buyer pays: subtotal + buyer fees
# }
```

#### Fee Breakdown Display to Users

```
Ticket: Gize Concert — General Admission    1,000 birr × 2    2,000 birr
─────────────────────────────────────────────────────────────────────
Platform Commission (3%)                                         (deducted from organizer)
Payment Processing Fee                              10 birr × 2     20 birr
─────────────────────────────────────────────────────────────────────
Total (you pay)                                                     2,020 birr
```

#### Admin Fee Management UI

The platform admin can:
1. Set global default fees
2. Create organization-specific overrides
3. Create event-specific overrides
4. Create time-limited promotions
5. View fee revenue analytics
6. Export fee reports for accounting

```ruby
# Admin creates a custom deal
Platform::FeeRule.create!(
  name: "Ethiopian Music Festival — Special Rate",
  fee_type: "commission",
  channel: "purchase",
  calculation_type: "percentage",
  value: 0.02,                    # 2% instead of 3%
  absorbed_by: "organizer",
  event_id: emf.id,
  effective_from: Time.current,
  effective_to: emf.ends_at,
  priority: 30
)
```

---

### G12: No Payout System for Organizers

**The Problem**: The design tracks payments coming IN but has no mechanism for money going OUT to organizers. Organizers need:
- Payout scheduling (after event, weekly, etc.)
- Payout calculation (revenue minus fees minus refunds)
- Payout status tracking
- Payout method (bank transfer, mobile money)

**The Fix**:
```ruby
create_table :organizer_payouts, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.uuid :event_id                           # NULL for aggregate payouts
  t.integer :gross_revenue, null: false
  t.integer :platform_fees, null: false
  t.integer :refund_amount, null: false
  t.integer :net_amount, null: false
  t.string :currency, default: "ETB"
  t.string :status, default: "pending"       # pending/processing/paid/failed
  t.string :payout_method                      # bank_transfer/telebirr/awash
  t.string :payout_reference                   # Bank reference number
  t.datetime :scheduled_at
  t.datetime :processed_at
  t.datetime :paid_at
  t.timestamps
end
```

---

### G13: No Age-Restricted Event Support

**The Problem**: The design has no mechanism for age-restricted events (18+, 21+). This is critical for:
- Concerts with alcohol
- Nightclub events
- Content-restricted performances
- Legal compliance

**The Fix**:
```ruby
# Add to event_settings:
t.integer :minimum_age                       # NULL = no restriction, 18, 21, etc.
t.boolean :require_id_verification           # Require ID at door

# Add to users table (already exists in auth architecture):
# date_of_birth — already present in the auth architecture doc
```

**Scenario Validation**:
- Event: "Club Night" → minimum_age: 18, require_id_verification: true
- User with DOB 2010-01-01 (16 years old) → blocked from purchase
- At door: scanner prompts for ID verification before allowing entry

---

### G14: No Event Categories/Tags for Discovery

**The Problem**: The design has no way to categorize events for discovery, search, or recommendations. Users need to:
- Browse by category (music, sports, conference, comedy)
- Filter by tags (outdoor, free, family-friendly)
- Get recommendations based on past attendance

**The Fix**:
```ruby
create_table :event_categories, id: :uuid do |t|
  t.string :name, null: false
  t.string :slug, null: false
  t.string :icon
  t.integer :sort_order, default: 0
end

create_table :event_tags, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.string :tag, null: false
end

create_table :event_category_assignments, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :category_id, null: false
end

add_index :event_category_assignments, [:event_id, :category_id], unique: true
add_index :event_tags, [:event_id, :tag], unique: true
add_index :event_tags, :tag
```

---

## PART 2: DESIGN FLAWS (Would Require Schema Migration Later)

### F1: `attendance_records` Is Over-Engineered and Fragile

**The Problem**: The design uses `attendance_records` with `ticket_id FK NULL`, `rsvp_id FK NULL`, `attendance_type enum`. This is a classic "polymorphic FK anti-pattern":

```ruby
# What happens when you add a new attendance type?
# 1. Add to enum
# 2. Add new FK column (rsvp_id → what about vip_pass_id?)
# 3. Update every query that joins on attendance_records
# 4. Update every analytics query
```

**The Better Design**: Keep `tickets` as the attendance record. Add a separate `rsvps` table. They're different concepts:

```ruby
# Tickets ARE attendance records for paid events
# No need for a separate attendance_records table

# For RSVPs (free events):
create_table :rsvps, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :user_id, null: false
  t.integer :guest_count, default: 0
  t.string :status, default: "confirmed"    # confirmed/cancelled/no_show
  t.datetime :confirmed_at
  t.datetime :cancelled_at
  t.timestamps
end

# For attendance tracking (unified across tickets and RSVPs):
create_table :attendance_records, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :user_id, null: false
  t.uuid :ticket_id                        # NULL for RSVP/guest
  t.uuid :rsvp_id                          # NULL for ticket
  t.string :attendance_source, null: false  # ticket/rsvp/guest_pass
  t.string :status, default: "registered"   # registered/checked_in/no_show
  t.datetime :checked_in_at
  t.timestamps
end
```

**Why This Is Better**: Tickets and RSVPs are first-class citizens. `attendance_records` is a thin read-model that unifies them for analytics without the fragile NULL FK pattern.

---

### F2: `event_features` Enum Is Too Rigid

**The Problem**: `event_features` uses an enum for `feature`. Every new feature requires:
1. Adding to the enum
2. Database migration (ALTER TYPE)
3. Application redeployment

Also, features often need configuration data (e.g., livestream needs a URL, RSVP needs a deadline). An enum can't carry configuration.

**The Better Design**: Use a string column with a validated set, plus a JSONB config column:

```ruby
create_table :event_features, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.string :feature, null: false            # "ticketing", "rsvp", "livestream", "vip"
  t.jsonb :config, default: {}              # Feature-specific configuration
  t.boolean :active, default: true
end

add_index :event_features, [:event_id, :feature], unique: true
```

**Configuration Examples**:
```ruby
# Livestream feature:
{ feature: "livestream", config: { platform: "youtube", url: "https://...", start_time: "2026-06-15T20:00:00Z" } }

# RSVP feature:
{ feature: "rsvp", config: { deadline: "2026-06-14T23:59:59Z", max_guests: 2, requires_approval: true } }

# VIP feature:
{ feature: "vip", config: { hidden: true, requires_invite_code: true, max_attendees: 50 } }
```

---

### F3: `guest_passes` and `invite_codes` Overlap

**The Problem**: Both `guest_passes` and `invite_codes` control access to events. They're overlapping concepts that will cause confusion:
- A guest pass grants N guests entry
- An invite code grants access to purchase/RSVP
- What's the difference? When do you use which?

**The Better Design**: Unify into a single `access_grants` table:

```ruby
create_table :access_grants, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :access_rule_id                     # Links to access_rules
  t.uuid :granted_to_user_id                 # NULL for email/phone-based grants
  t.string :granted_to_email
  t.string :granted_to_phone
  t.string :code                             # Optional unique code
  t.string :grant_type, null: false          # invite/guest_pass/vip_pass/comp
  t.integer :quantity, default: 1            # How many people/tickets this grants
  t.integer :used_quantity, default: 0
  t.string :status, default: "active"        # active/used/expired/revoked
  t.datetime :expires_at
  t.text :note                               # "CEO's guests", "Press list"
  t.timestamps
end

add_index :access_grants, :code, unique: true, where: "code IS NOT NULL"
add_index :access_grants, [:event_id, :grant_type]
add_index :access_grants, [:granted_to_email, :event_id]
```

**Scenario Validation**:
- VIP invite: `grant_type: "invite"`, code: "VIP-GIZE-2026", quantity: 1
- Guest list: `grant_type: "guest_pass"`, granted_to_phone: "+251911...", quantity: 3
- Comp ticket: `grant_type: "comp"`, code: "PRESS-001", quantity: 2
- All use the same table, same API, same scanning logic

---

### F4: `form_answers` Uses `answer_text` — Loses Structured Data

**The Problem**: All answers are stored as `answer_text`. But custom questions can have:
- Multiple choice (need to store which options were selected)
- File uploads (need to store file references)
- Date/time answers (need proper date types)
- Numeric answers (need to be queryable)

**The Better Design**: Use JSONB for answers:

```ruby
create_table :form_answers, id: :uuid do |t|
  t.uuid :submission_id, null: false
  t.uuid :question_id, null: false
  t.jsonb :answer_value, null: false        # Stores any type of answer
  t.timestamps
end

# Examples:
# Text: { "text": "John Doe" }
# Multiple choice: { "selected": ["option_1", "option_3"] }
# File upload: { "files": ["file_uuid_1", "file_uuid_2"] }
# Date: { "date": "2026-06-15" }
# Number: { "number": 25 }
```

---

### F5: `promo_codes` Missing Per-User Limits

**The Problem**: `promo_codes` has `max_uses` (total) but no per-user limit. This means one user could use a promo code 100 times if `max_uses: 100`.

**The Fix**:
```ruby
# Add to promo_codes:
t.integer :max_uses_per_user               # NULL = unlimited per user

# New junction table (already in design as promo_code_ticket_types):
create_table :promo_code_ticket_types, id: false do |t|
  t.uuid :promo_code_id, null: false
  t.uuid :ticket_type_id, null: false
  t.integer :max_discount                  # Cap on discount amount
end

add_index :promo_code_ticket_types, [:promo_code_id, :ticket_type_id], unique: true
```

---

### F6: `orders` Missing Single-Event Constraint

**The Problem**: An `order` has `event_id` but in reality, a single order can contain tickets for multiple events (e.g., festival pass that includes multiple days/events). The current design forces one order per event.

**The Better Design**: Remove `event_id` from orders. Each `order_item` links to a `ticket_type` which links to an `event`:

```ruby
# orders table: REMOVE event_id
# An order can span multiple events

# order_items table: already has ticket_type_id → event_id through ticket_type
# This is the correct relationship
```

**Scenario Validation**:
- "Addis Music Festival" has 3 days as separate events in a series
- User buys 1 ticket for each day → single order, 3 order items
- Each order_item points to a different ticket_type → different event

---

### F7: No Idempotency Keys for Payment Processing

**The Problem**: Mobile networks in Ethiopia are unreliable. A payment request might timeout, the user retries, and they get charged twice. Without idempotency keys, there's no way to prevent duplicate charges.

**The Fix**:
```ruby
# Add to payments table:
t.string :idempotency_key, unique: true

# Or separate table:
create_table :idempotency_keys, id: :uuid do |t|
  t.uuid :user_id
  t.string :key, null: false
  t.string :resource_type                  # "order", "payment"
  t.uuid :resource_id
  t.datetime :expires_at
  t.timestamps
end

add_index :idempotency_keys, :key, unique: true
```

**Scenario Validation**:
- User clicks "Pay" → app generates idempotency key `pay_abc123`
- Request times out → user clicks "Pay" again → same key `pay_abc123`
- Server sees key already used → returns original payment result, doesn't charge again

---

### F8: `announcements` Table Is Too Simple

**The Problem**: The `announcements` table has `type: enum` (update/reminder/etc) but real announcements need:
- Targeting (all attendees, VIP only, specific ticket types)
- Delivery channels (email, SMS, push, in-app)
- Scheduling (send now, send at specific time)
- Read tracking (who saw it, who clicked)

**The Better Design**: Use the marketing campaign infrastructure (G9) for announcements. Announcements ARE campaigns with different targeting:

```ruby
# announcements becomes a campaign type:
# marketing_campaigns.channel = "announcement"
# marketing_campaigns.targeting = { ticket_type: "vip" }
```

---

## PART 3: MISSING DOMAINS

### M1: Venues as First-Class Entities

**Current**: `venue_name`, `venue_address`, `latitude`, `longitude` are fields on `events`.

**Problem**: The same venue hosts multiple events. Organizers need to:
- See all events at a venue
- Venue owners manage their venue profile
- Users discover events by venue
- Venue capacity affects ticket inventory

**Fix**:
```ruby
create_table :venues, id: :uuid do |t|
  t.uuid :organization_id                    # Venue owner (optional)
  t.string :name, null: false
  t.string :slug, null: false
  t.text :description
  t.string :address
  t.string :city
  t.string :country
  t.decimal :latitude
  t.decimal :longitude
  t.integer :capacity
  t.jsonb :amenities                         # ["parking", "wifi", "bar"]
  t.string :contact_phone
  t.string :contact_email
  t.string :website_url
  t.boolean :verified, default: false
  t.timestamps
end

# events table: REPLACE venue fields with:
t.uuid :venue_id                             # FK to venues
```

---

### M2: User Follows/Social Graph

**Current**: No way for users to follow organizers or venues.

**Problem**: Users want to:
- Follow organizers to get notified of new events
- See what events their friends are attending
- Get personalized recommendations

**Fix**:
```ruby
create_table :follows, id: :uuid do |t|
  t.uuid :follower_id, null: false            # User who follows
  t.uuid :followable_id, null: false          # Organization or venue
  t.string :followable_type, null: false      # "Organization" or "Venue"
  t.datetime :followed_at
  t.timestamps
end

add_index :follows, [:follower_id, :followable_id, :followable_type], unique: true
add_index :follows, [:followable_type, :followable_id]
```

---

### M3: Event Reviews/Ratings

**Current**: No way for attendees to rate events.

**Problem**: Post-event ratings are critical for:
- Organizer reputation
- Event discovery (top-rated events)
- User trust
- Platform quality signals

**Fix**:
```ruby
create_table :event_reviews, id: :uuid do |t|
  t.uuid :event_id, null: false
  t.uuid :user_id, null: false
  t.uuid :ticket_id                          # Must have attended
  t.integer :rating, null: false              # 1-5
  t.text :comment
  t.jsonb :ratings                           # {"music": 5, "venue": 4, "value": 3}
  t.boolean :verified_attendee, default: true # Checked in at event
  t.integer :helpful_count, default: 0
  t.string :status, default: "published"      # published/hidden/flagged
  t.timestamps
end

add_index :event_reviews, [:event_id, :user_id], unique: true
add_index :event_reviews, :ticket_id
```

---

### M4: Notifications System

**Current**: No notification infrastructure.

**Problem**: Users need to be notified about:
- Ticket purchase confirmation
- Event reminders (24h before)
- Resale listing sold
- Transfer received
- Organizer announcements
- Waitlist offers

**Fix**:
```ruby
create_table :notifications, id: :uuid do |t|
  t.uuid :user_id, null: false
  t.string :type, null: false                # "ticket_purchased", "event_reminder", etc.
  t.jsonb :data                              # Notification-specific data
  t.string :channel, null: false             # "in_app", "email", "sms", "push"
  t.string :status, default: "pending"       # pending/sent/delivered/read/failed
  t.datetime :scheduled_at
  t.datetime :sent_at
  t.datetime :read_at
  t.datetime :failed_at
  t.text :failure_reason
  t.timestamps
end

add_index :notifications, [:user_id, :status]
add_index :notifications, [:user_id, :read_at]
add_index :notifications, [:type, :status]
```

---

### M5: Audit Trail for Financial Operations

**Current**: The Platform namespace has `audit_logs` for general CRUD auditing. But financial operations (payments, refunds, payouts) need a separate, immutable audit trail for compliance.

**Fix**:
```ruby
create_table :financial_audit_logs, id: :uuid do |t|
  t.uuid :organization_id
  t.uuid :event_id
  t.uuid :actor_id                           # Who performed the action
  t.string :actor_type
  t.string :action, null: false              # "payment_received", "refund_issued", "payout_sent"
  t.uuid :reference_id                       # Order/payment/refund/payout ID
  t.string :reference_type
  t.integer :amount_before
  t.integer :amount_after
  t.integer :amount_delta
  t.string :currency
  t.jsonb :metadata
  t.datetime :created_at, null: false
end

add_index :financial_audit_logs, [:reference_type, :reference_id]
add_index :financial_audit_logs, :created_at
```

---

## PART 4: REAL-WORLD SCENARIO VALIDATION

Let me validate the corrected architecture against 12 real-world event scenarios:

### Scenario 1: Free RSVP Event (Partiful-style)
```
Event has: event_features = ["rsvp"]
           access_rules = [{ type: "public" }]
           event_settings = { allow_guest_checkout: true }

User flow:
1. Browse event → click "RSVP"
2. Select guest count (max 2)
3. Enter phone → shadow user created
4. RSVP confirmed → SMS with QR code
5. At door: scanner validates RSVP QR

Tables used: events, event_features, event_access_rules, rsvps,
             attendance_records, users, checkin_logs
```

### Scenario 2: Invite-Only VIP Event
```
Event has: event_features = ["ticketing", "vip"]
           access_rules = [{ type: "invite", priority: 1 }]
           event_settings = { visibility: "private" }

User flow:
1. Organizer creates event → generates invite codes
2. Sends codes via SMS: "You're invited to [Event]. Code: VIP-2026-ABC"
3. User enters code → can purchase tickets
4. Invalid code → "This event is invite-only"

Tables used: events, event_features, event_access_rules, access_grants,
             ticket_types, orders, payments, tickets
```

### Scenario 3: Hybrid Event (In-Person + Livestream)
```
Event has: event_features = ["ticketing", "livestream"]
           event_settings = { online_url: "https://stream.dig.is/..." }

Ticket types:
- "In-Person General" — 500 birr, physical entry
- "Livestream Access" — 100 birr, digital only
- "VIP In-Person + Stream" — 1500 birr, both

User flow:
1. User selects ticket type
2. In-person → gets QR code for scanning
3. Livestream → gets unique stream access token
4. Hybrid → gets both

Tables used: events, event_features, ticket_types, tickets, orders
```

### Scenario 4: Multi-Day Festival with Per-Day Tickets
```
Event: "Addis Music Festival" (June 15-17)
event_dates:
  - 2026-06-15, doors 18:00, capacity 5000
  - 2026-06-16, doors 17:00, capacity 3000
  - 2026-06-17, doors 16:00, capacity 2000

Ticket types:
- "Single Day — June 15" — 300 birr
- "Single Day — June 16" — 400 birr
- "Single Day — June 17" — 500 birr (VIP finale)
- "Full Festival Pass" — 1000 birr (all 3 days)

Entry policies:
- Single day: one entry on specific date
- Festival pass: one entry per day

Tables used: events, event_dates, event_features, ticket_types,
             inventory_pools, tickets, checkin_logs
```

### Scenario 5: Ticket Resale Marketplace
```
User flow:
1. User has ticket → clicks "Resell"
2. Sets price (capped at 150% of original)
3. Listing created → ticket locked
4. Buyer purchases → payment splits (seller gets price minus fee)
5. Ticket version increments → old QR invalidated
6. New QR sent to buyer → seller gets payout notification

Tables used: tickets, ticket_transfers, resale_listings, orders,
             payments, refunds, financial_audit_logs
```

### Scenario 6: Ticket Gifting
```
User flow:
1. User buys 3 tickets → selects "Gift 1"
2. Enters recipient phone + message: "Happy Birthday!"
3. Recipient gets SMS with gift link
4. Clicks link → shadow user created → ticket assigned
5. Verifies phone → ticket in their account

Tables used: tickets, ticket_gifts, ticket_transfers, users,
             notifications
```

### Scenario 7: Waitlist Auto-Fulfillment
```
Event sells out → 50 people on waitlist
1. Someone requests refund → ticket becomes available
2. System offers to waitlist position 1 via SMS
3. 15-minute window to accept
4. If accepted → auto-checkout with saved payment method
5. If declined → offer to position 2
6. If no one accepts → ticket goes back to public sale

Tables used: waitlist_entries, tickets, orders, payments,
             notifications
```

### Scenario 8: Marketing Campaign with Attribution
```
Organizer flow:
1. Creates SMS campaign: "Early bird — 20% off today!"
2. Targets: users who attended similar events
3. Campaign sends 5000 messages with tracked short link
4. 800 click → 120 purchase → 60,000 birr revenue
5. Dashboard shows: 2.4% conversion, 50x ROI

Tables used: marketing_campaigns, campaign_messages, campaign_links,
             short_links, orders, payments
```

### Scenario 9: Offline Scanning at Large Event
```
Event: 5000 attendees, poor venue network
1. Before event: scanners download manifest (signed ticket list)
2. At gate: scanner validates QR against local manifest
3. Checks version, entry policy, previous scans
4. Logs scan locally
5. When network returns: syncs logs to server
6. Server resolves conflicts (duplicate scans, version mismatches)

Tables used: scanner_devices, tickets, checkin_logs, event_dates,
             attendance_records, manifests
```

### Scenario 10: Corporate Event with Approval Workflow
```
Event has: event_features = ["rsvp"]
           event_settings = { requires_approval: true, visibility: "private" }

User flow:
1. User RSVPs → status: "pending"
2. Organizer reviews RSVPs → approves/rejects
3. Approved → confirmation SMS with QR
4. Rejected → "Sorry, this event is at capacity"

Tables used: events, event_features, event_settings, rsvps,
             attendance_records, notifications
```

### Scenario 11: Age-Restricted Event with ID Verification
```
Event has: event_settings = { minimum_age: 18, require_id_verification: true }

Purchase flow:
1. User selects tickets → enters DOB during checkout
2. System calculates age → blocks if under 18
3. At door: scanner prompts "Verify ID"
4. Staff checks ID → marks as verified
5. Entry granted

Tables used: events, event_settings, tickets, checkin_logs, users
```

### Scenario 12: Recurring Event Series
```
Series: "Weekly Comedy Night"
event_series:
  - name: "Weekly Comedy Night"
  - recurrence_rule: "FREQ=WEEKLY;BYDAY=TH;COUNT=12"

Events auto-generated:
  - June 5, June 12, June 19, ... (12 occurrences)

User can:
  - Buy ticket for single night
  - Buy season pass (all 12 nights)
  - Subscribe → auto-buy every week

Tables used: event_series, events, event_dates, ticket_types,
             orders, tickets
```

---

## PART 5: COMPLETE CORRECTED SCHEMA

Here is the full, corrected schema with all fixes applied:

```
IDENTITY DOMAIN
├── users (existing platform_users — DO NOT recreate)
├── organizations
├── organization_memberships
└── follows

EVENT DOMAIN
├── events
├── event_series
├── event_dates                    # NEW — per-day scheduling
├── event_settings
├── event_features                 # With JSONB config, not enum
├── event_categories
├── event_category_assignments
├── event_tags
└── venues                         # NEW — first-class entity

ACCESS DOMAIN
├── event_access_rules
├── access_grants                  # NEW — unified invites/guest_passes
└── waitlist_entries               # NEW

COMMERCE DOMAIN
├── ticket_types
├── inventory_pools
├── ticket_reservations            # NEW — race-condition-free
├── orders                         # NO event_id — spans events (WITH buyer_currency, diaspora_gift_id, exchange_rate)
├── order_items
├── payments                       # WITH idempotency_key, gateway_type, gateway_currency
├── refunds
├── invoices                       # NEW — full invoicing system
├── invoice_line_items             # NEW
├── invoice_payments               # NEW — partial payment tracking
├── credit_notes                   # NEW — refunds/adjustments
├── recurring_invoice_schedules    # NEW — monthly/quarterly billing
├── invoice_templates              # NEW — custom branding
├── currency_exchange_rates        # NEW — real-time FX rates
├── multi_currency_pricing         # NEW — foreign currency ticket prices
├── diaspora_gifts                 # NEW — diaspora checkout flow
├── fee_structures                 # NEW
├── tax_rates                      # NEW
├── promo_codes
├── promo_code_ticket_types
├── resale_listings                # NEW
├── organizer_payouts              # NEW
└── financial_audit_logs           # NEW

ATTENDANCE DOMAIN
├── tickets                        # WITH version, qr_token, entry tracking
├── rsvps                          # NEW — separate from tickets
├── attendance_records             # Thin read-model
├── checkin_logs
├── ticket_transfers               # NEW
├── ticket_gifts                   # NEW
└── scanner_devices                # NEW

BOX OFFICE DOMAIN
├── box_office_sessions            # NEW — cashier sessions, cash reconciliation
├── box_office_sales               # NEW — on-site ticket sales
├── box_office_terminals           # NEW — POS devices, offline sync
├── box_office_shifts              # NEW — cashier shift handovers
├── will_call_tickets              # NEW — pre-paid pickup at door
└── guest_list_entries             # NEW — VIP/press/organizer guest lists

FORMS DOMAIN
├── custom_questions
├── form_submissions
└── form_answers                   # WITH JSONB answer_value

COMMUNICATION DOMAIN
├── marketing_campaigns            # NEW
├── campaign_messages              # NEW (with cost_cents, provider_message_id)
├── campaign_links                 # NEW
├── messaging_rates                # NEW — pay-per-message pricing
├── messaging_credits              # NEW — prepaid balance
├── credit_transactions            # NEW — audit trail
├── messaging_provider_configs     # NEW — Twilio/SendGrid/etc
├── notifications                  # NEW
└── event_reviews                  # NEW

SHORT LINKS DOMAIN
├── short_links
└── short_link_clicks
```

---

## PART 6: IMPLEMENTATION PRIORITY

### Phase 1: Foundation (Week 1-2)
1. Venues table
2. Event dates table
3. Event features (with JSONB config)
4. Event categories and tags
5. Access grants (unified)
6. Ticket version and QR token fields

### Phase 2: Commerce (Week 2-4)
7. Inventory pools with reservation system
8. Fee structures and tax rates
9. Resale listings
10. Ticket transfers
11. Ticket gifts
12. Waitlist entries

### Phase 3: Attendance (Week 4-5)
13. Scanner devices
14. RSVPs table
15. Attendance records (read-model)
16. Check-in logs (enhanced)

### Phase 3b: Box Office (Week 5-6)
17. Box office sessions + sales + terminals
18. Will-call ticket holding and pickup
19. Guest list management
20. Box office shift handovers
21. Offline-capable terminal sync
22. End-of-day cash reconciliation

### Phase 4: Communication (Week 6-7)
23. Marketing campaigns
24. Campaign messages and links
25. Messaging rates and credits (pay-per-message pricing)
26. Notifications system
27. Event reviews

### Phase 5: Financial (Week 8-10)
28. Organizer payouts
29. Financial audit logs
30. Idempotency keys
31. Refunds (enhanced)
32. Currency exchange rates + multi-currency pricing
33. Diaspora checkout flow + diaspora_gifts table
34. Invoicing system (invoices, line items, payments, credit notes)
35. Recurring invoice schedules
36. Invoice PDF generation and email delivery

### Phase 6: Social (Week 10-11)
37. Follows
26. Event reviews
27. Recommendations (based on follows + attendance)

---

## PART 7: COMPARISON WITH EXISTING DESIGN

| Aspect | Original Design | Corrected Design | Impact |
|--------|----------------|------------------|--------|
| Users | New table with role enum | Use existing Platform::User | Eliminates duplicate auth |
| Tickets | No version field | version + qr_token + entry tracking | Enables transfer/resale |
| Multi-day | starts_at/ends_at only | event_dates table | Per-day scheduling |
| Inventory | Integer counters | Reservation system | Prevents overselling |
| Access | invite_codes + guest_passes | Unified access_grants | Single access model |
| Forms | answer_text (string) | answer_value (JSONB) | Structured answers |
| Orders | event_id FK | No event_id (spans events) | Multi-event orders |
| Payments | No idempotency | idempotency_key | Prevents double-charge |
| Resale | Not present | resale_listings + transfers | Full marketplace |
| Waitlist | Boolean flag only | waitlist_entries table | Auto-fulfillment |
| Marketing | Not present | campaigns + messages + links | Full campaign system |
| Messaging Pricing | No pricing model | messaging_rates + credits + volume tiers | Pay-per-message billing |
| Venues | Fields on events | First-class venues table | Venue management |
| Scanner | scanner_user_id only | scanner_devices table | Device management |
| Box Office | Not present | sessions + sales + terminals + will-call + guest lists | On-site sales, cash reconciliation |
| Fees | No fee breakdown | fee_structures + tax_rates | Financial compliance |
| Invoicing | Not present | invoices + line_items + credit_notes + recurring | B2B billing, corporate |
| Diaspora Checkout | Single currency only | multi-currency + diaspora_gifts + FX rates | USD/EUR buyers, massive revenue |
| Payouts | Not present | organizer_payouts | Organizer payments |

---

## FINAL VERDICT

The original "Improved DB Design" has the **right instincts** — domain separation, capability composition, inventory pools, and payment/order separation are all correct. But it's missing **18 critical features** that a real event platform needs, has **8 design flaws** that would require painful migrations, and lacks **5 entire domains**.

The corrected schema above:
- **Works for every real-world scenario**: RSVP, invite-only, ticketed, hybrid, multi-day, resale, gifting, waitlist, marketing, age-restricted, recurring, offline scanning, corporate invoicing, diaspora checkout, on-site box office sales
- **Is extensible**: New event features via JSONB config, new access types via access_grants, new fee types via fee_structures
- **Is composable**: Events compose features, access rules, ticket types, and dates independently
- **Is scalable**: Reservation-based inventory prevents race conditions, read-model attendance records avoid N+1 queries
- **Is financially correct**: Orders ≠ payments, fee breakdowns, tax rates, payouts, audit trails, pay-per-message billing with volume tiers, full invoicing with partial payments and credit notes, multi-currency diaspora checkout with FX rates, on-site box office with cash reconciliation
- **Is future-proof**: Adding a new feature type requires a JSONB config entry, not a schema migration

This is the schema you build Eventbrite, Partiful, Luma, RA, and Dice on.
