# DSCF-CORE → EVENT TICKETING PLATFORM: GEM AUDIT & RECOMMENDATIONS

**Date**: May 16, 2026
**Source**: `vendor/dscf-core` (Digital Supply Chain Financing engine)
**Target**: Event Ticketing & Operations Core

---

## EXECUTIVE SUMMARY

The dscf-core gem is a **well-architected Rails engine** with reusable patterns (auth, RBAC, file storage, audit, review workflows, code generators). However, it carries **heavy supply-chain-financing domain baggage** that must be stripped, restructured, or replaced for an event ticketing platform.

**Recommendation**: Keep it as a **vendor gem** (not copied into app), but **rename, strip domain models, and restructure** into a clean foundation engine. The generic infrastructure is genuinely valuable — the domain models are not.

---

## 1. WHAT TO KEEP (GENERIC INFRASTRUCTURE)

These are solid, reusable, domain-agnostic patterns:

### 1.1 Authentication System ✅ KEEP
- **Files**: `UserAuthenticatable`, `AuthService`, `TokenService`, `Authenticatable`, `TokenAuthenticatable`
- **Why**: JWT-based auth with refresh tokens, device tracking, IP validation
- **Changes needed**:
  - The current `User` model uses `has_secure_password` (email/password). For Ethiopia, you need **phone-first auth with OTP**. Keep the token infrastructure but replace password auth with OTP flow.
  - `UserAuthenticatable` validates `email OR phone` — good, but make phone the primary identity, email optional.
  - Remove `temp_password` concept (supply-chain artifact).

### 1.2 RBAC (Role-Based Access Control) ✅ KEEP
- **Files**: `Role`, `Permission`, `RolePermission`, `UserRole`, `Authorizable`, `ApplicationPolicy`
- **Why**: Fine-grained permission system with Pundit integration
- **Changes needed**:
  - The permission registry pattern is solid but the permission codes are supply-chain specific.
  - You'll need new permission codes like `events.create`, `tickets.scan`, `orders.manage`, etc.
  - The `PermissionRegistry` class is excellent — keep it.

### 1.3 File Storage System ✅ KEEP (with caveats)
- **Files**: `Attachable`, `FileAttachment`, `FileStorage::Client`, `FileStorage::Uploader`
- **Why**: Custom ActiveStorage-like system with MinIO backend, polymorphic attachments
- **Changes needed**:
  - **Major decision point**: The gem has BOTH `Attachable` (custom MinIO) AND `has_one_attached` (ActiveStorage) in use. This is confusing and redundant.
  - **Recommendation**: Pick ONE. For an event ticketing platform:
    - Use **ActiveStorage** for organizer uploads (banners, logos) — simpler, Rails-native
    - Use **custom storage** ONLY if you need QR code generation with specific signing
  - The `FileAttachment` model and `Attachable` concern are well-built but add complexity. If you use ActiveStorage exclusively, you can remove ~600 lines of code.
  - If you keep it: rename from MinIO-specific language to generic "storage" language.

### 1.4 Audit Logging ✅ KEEP
- **Files**: `AuditLog`, `AuditableModel`, `AuditableController`
- **Why**: Polymorphic audit trail with actor tracking, IP, user-agent
- **Changes needed**:
  - Rename table from `dscf_core_audit_logs` to your new namespace
  - The implementation is solid — no structural changes needed
  - Consider adding `qr_scan` as an auditable action type for gate operations

### 1.5 Code Generator ✅ KEEP & IMPROVE
- **Files**: `CommonGenerator`, templates
- **Why**: Rails generator for controller + serializer + spec + routes + locales + ransackable methods
- **Changes needed**:
  - Update templates for your new namespace
  - Add template for policy generation (currently missing)
  - Add template for service object generation
  - The auto-serializer-detection is clever — keep it

### 1.6 Controller Concerns ✅ KEEP
- **Files**: `Common`, `Pagination`, `Filterable`, `JsonResponse`, `Authorizable`
- **Why**: CRUD scaffolding, Ransack filtering, pagination, consistent JSON responses
- **Changes needed**:
  - The `Common` concern's `set_clazz` auto-resolution is clever but fragile with namespace changes
  - Consider simplifying — explicit is better than implicit for a new codebase

### 1.7 Serializers ✅ KEEP
- **Files**: All `*_serializer.rb` files using `active_model_serializers`
- **Why**: Consistent API response formatting
- **Changes needed**:
  - All current serializers are for supply-chain models — replace with event ticketing serializers
  - The pattern is solid — keep the approach

### 1.8 Error Classes ✅ KEEP
- **Files**: `AuthenticationError`, `FileUploadError`
- **Why**: Custom error classes with status codes and hash serialization
- **Changes needed**:
  - Add domain-specific errors: `TicketNotFoundError`, `QrAlreadyScannedError`, `ResaleNotAllowedError`, `OfflineSyncError`

### 1.9 Review/Approval Workflow ⚠️ KEEP CONDITIONALLY
- **Files**: `ReviewableModel`, `ReviewableController`, `Review`
- **Why**: State machine-like approval workflow with transitions, feedback, multiple contexts
- **Changes needed**:
  - This is designed for **business verification** (draft → pending → approved/rejected)
  - For event ticketing, this maps to **event approval** (organizer submits event → platform approves)
  - Keep it but rename conceptually — it's really a "moderation workflow"
  - The implementation is sophisticated (transitions, contexts, callbacks) — genuinely valuable

---

## 2. WHAT TO REMOVE (DOMAIN-SPECIFIC MODELS)

These are supply-chain-financing specific and have **zero relevance** to event ticketing:

### 2.1 Business Model ❌ REMOVE
- **Files**: `Business`, `BusinessType`, `BusinessPolicy`, `BusinessSerializer`, `BusinessesController`
- **Why**: Represents registered businesses in a supply chain. Not applicable.
- **Replace with**: `Organizer` model (see section 3)

### 2.2 Document Model ❌ REMOVE
- **Files**: `Document`, `DocumentSerializer`
- **Why**: Represents verified business documents (licenses, claims). Not applicable.
- **Replace with**: Organizer verification documents if needed (but simpler to just use Attachable)

### 2.3 Address Model ❌ REMOVE (or simplify)
- **Files**: `Address`, `AddressSerializer`, `AddressesController`
- **Why**: Separate address table is overkill for event ticketing
- **Replace with**: Embed venue address directly on `Event` model (venue_name, venue_address, latitude, longitude)

### 2.4 UserProfile Model ❌ REMOVE (or simplify)
- **Files**: `UserProfile`, `UserProfileSerializer`
- **Why**: Separate profile table adds complexity. For ticketing, user = phone + name + avatar is enough.
- **Replace with**: Inline profile fields on `User` model

---

## 3. WHAT TO ADD (EVENT TICKETING SPECIFIC)

These are the core domain models your platform needs:

### 3.1 Identity & Organization Layer
| Model | Purpose | Notes |
|-------|---------|-------|
| `User` | Already exists | Modify for phone-first, OTP auth |
| `Organization` | Event organizers as teams | Multi-tenant, replaces Business |
| `Membership` | Users in organizations | Roles: owner, admin, staff, scanner |
| `UserProfile` | Optional inline | Name, avatar, preferences |

### 3.2 Event Domain
| Model | Purpose | Notes |
|-------|---------|-------|
| `Event` | Core event entity | Title, dates, venue, status, banner |
| `EventSetting` | Operational settings | Visibility, transfers, waitlist, approval |
| `EventFeature` | Composable capabilities | ticketing, rsvp, livestream, vip |
| `EventSeries` | Recurring events | RRULE support |

### 3.3 Access Domain
| Model | Purpose | Notes |
|-------|---------|-------|
| `AccessRule` | Unified access control | public, invite, guestlist, password |
| `InviteCode` | Invite-based access | Code, max_uses, expires |
| `GuestPass` | Guest list management | Allocated guests per organizer |

### 3.4 Commerce Domain
| Model | Purpose | Notes |
|-------|---------|-------|
| `TicketType` | Ticket tiers (VIP, Regular) | Price, quantity, sales window |
| `InventoryPool` | Shared inventory management | Capacity tracking, VIP pools |
| `Order` | Purchase transaction | NOT payment — business transaction |
| `OrderItem` | Line items per ticket type | Quantity, unit_price snapshot |
| `Payment` | Payment record | Provider, provider_id, status |
| `Refund` | Refund tracking | Amount, reason, status |
| `PromoCode` | Discount codes | Percentage/fixed, usage limits |

### 3.5 Attendance Domain
| Model | Purpose | Notes |
|-------|---------|-------|
| `Ticket` | Individual ticket instance | QR code, owner, status |
| `AttendanceRecord` | Unified participation | ticket/rsvp/guest |
| `CheckinLog` | Scan audit trail | Scanner, timestamp, result |
| `TicketTransfer` | Transfer history | From, to, timestamp |
| `ResaleListing` | Resale marketplace | Price, status, buyer |

### 3.6 Communication Domain
| Model | Purpose | Notes |
|-------|---------|-------|
| `Announcement` | Event updates | Scheduled, sent_at |
| `NotificationJob` | SMS/email campaigns | Batch processing |

### 3.7 Core Features
| Model | Purpose | Notes |
|-------|---------|-------|
| `FeaturedListing` | Promoted events | Duration, priority |
| `Follow` | Follow artists/venues/organizers | Social graph |
| `Rating` | Post-event feedback | Stars, comments |
| `Recommendation` | Location-based discovery | Geospatial queries |

---

## 4. ARCHITECTURAL DECISIONS

### 4.1 Should it be a gem or copied into the app?

**Recommendation: Keep as a vendor gem, but restructure**

| Option | Pros | Cons |
|--------|------|------|
| **Vendor gem (recommended)** | Clean separation, reusable across future projects, clear boundaries, engine isolation | Slightly more complex setup, namespace management |
| **Copy into app** | Simpler initially, no namespace overhead | Becomes messy fast, harder to extract later, mixes concerns |
| **Extract only generic parts** | Minimal footprint | Lose generator, lose patterns, rebuild from scratch |

**Why vendor gem wins**:
1. You already have the engine infrastructure working
2. The generic patterns (auth, RBAC, audit, file storage, generators) are genuinely reusable
3. Engine isolation prevents namespace collisions as you add domain modules
4. You can mount additional engines later (e.g., `ticketing/`, `analytics/`)

### 4.2 Naming & Namespace

**Current**: `Dscf::Core` (Digital Supply Chain Financing)

**Recommended**: Create a new namespace for your platform. Options:
- `Etix::Core` (Event Tickets)
- `Tiketi::Core` (Swahili for "ticket")
- `[YourBrand]::Core`

**Action**: Rename the gem, update all namespaces, regenerate migrations with new prefixes.

### 4.3 Database Strategy

**Current**: Migrations prefixed with `dscf_core_`

**Recommended**: 
- Keep the engine migration approach (auto-appending to host app)
- Use new table prefixes matching your namespace
- Consider UUID primary keys for all public-facing entities (tickets, orders, events)
- Use integer IDs only for internal/audit tables

### 4.4 Authentication: Password → OTP

**Current**: `has_secure_password` with email/phone

**Recommended for Ethiopia**:
- Phone number as primary identity
- OTP via SMS (Telebirr integration later)
- Auto-create account on first ticket purchase
- Keep JWT token infrastructure (it's solid)
- Remove password entirely for attendee flow
- Keep password optional for organizer/admin accounts

### 4.5 File Storage: ActiveStorage vs Custom

**Current**: BOTH ActiveStorage AND custom MinIO Attachable

**Recommended**: 
- Use **ActiveStorage** for organizer uploads (banners, logos, printed materials)
- Use **custom QR generation** service for ticket QR codes (not file storage)
- Remove the `Attachable` concern and `FileAttachment` model to reduce complexity
- Keep `FileStorage::Client` only if you have a separate file service

---

## 5. SPECIFIC CODE CHANGES NEEDED

### 5.1 User Model Changes

```ruby
# REMOVE:
- temp_password field and callback
- has_many :businesses
- has_many :addresses
- has_many :documents
- has_one :user_profile (inline instead)

# ADD:
- otp_code, otp_expires_at (for phone auth)
- has_many :organizations, through: :memberships
- has_many :orders (as buyer)
- has_many :tickets (as owner)
- has_many :follows
- phone as primary identity (required, unique)
- email as optional
```

### 5.2 Migration Strategy

```
Phase 1: Rename gem namespace (Dscf::Core → YourNamespace::Core)
Phase 2: Remove domain models (Business, Document, Address, UserProfile)
Phase 3: Add event ticketing models (Event, Ticket, Order, etc.)
Phase 4: Replace password auth with OTP
Phase 5: Simplify file storage (ActiveStorage only)
```

### 5.3 Controller Concern Changes

```ruby
# KEEP:
- Authenticatable (modify for OTP)
- Authorizable
- Pagination
- Filterable
- JsonResponse

# MODIFY:
- Common: Simplify set_clazz, make more explicit
- ReviewableController: Rename to ModeratableController, adapt for event approval

# REMOVE:
- FileUploadable (if switching to ActiveStorage)
```

### 5.4 Gem Dependencies

```ruby
# KEEP:
- rails (>= 8.0.2)
- bcrypt (for admin passwords)
- jwt
- pundit
- ransack
- active_model_serializers
- pg
- rack-cors
- noticed (for notifications)
- image_processing (for QR generation)

# REMOVE:
- ancestry (not needed for ticketing — no tree structures)
- httparty (only needed for MinIO client)

# ADD:
- rqrcode (QR code generation)
- chunky_png (QR code rendering)
- geocoder (location-based recommendations)
- sidekiq or solid_queue (background jobs for SMS, emails)
- money-rails or monetize (currency handling)
```

---

## 6. FEATURE MAPPING: GEM CAPABILITIES → TICKETING FEATURES

| Gem Feature | Ticketing Use | Effort |
|-------------|---------------|--------|
| Auth + JWT | User login, session management | Low (modify to OTP) |
| RBAC + Pundit | Organizer/staff/scanner permissions | Low (new permissions) |
| Audit Log | Ticket transfer history, scan logs | Low (already works) |
| Review Workflow | Event approval/moderation | Low (rename concept) |
| File Storage | Event banners, organizer logos | Medium (simplify) |
| Code Generator | Rapid CRUD for new models | Low (update namespace) |
| Pagination + Filtering | Event discovery, search | Low (already works) |
| Serializers | API responses | Low (new serializers) |
| Notifications (Noticed) | Event reminders, purchase confirmations | Low (already included) |
| Ransack | Admin search/filter | Low (already works) |

---

## 7. WHAT THE GEM DOES NOT COVER (MUST BUILD FROM SCRATCH)

These are core ticketing features with **no equivalent** in dscf-core:

1. **QR Code Generation & Validation** — Core to the product
2. **Offline Scanning Sync** — Critical for Ethiopia's network conditions
3. **Payment Gateway Integration** — Telebirr, Chapa
4. **Resale Marketplace** — Controlled ticket resale
5. **Ticket Transfer** — Ownership chain tracking
6. **Inventory Management** — Real-time capacity tracking
7. **Promo Code Engine** — Discount calculations
8. **Location-Based Recommendations** — Geospatial queries
9. **Featured Listings** — Monetization
10. **SMS Campaign System** — Organizer marketing
11. **Follow System** — Social graph (artists, venues, organizers)
12. **Rating & Feedback** — Post-event quality
13. **Real-time Dashboard** — Sales, attendance analytics
14. **Gate Scanner Interface** — Fast scan UI, offline mode
15. **Commission Engine** — Core revenue calculation

---

## 8. RECOMMENDED PROJECT STRUCTURE

```
vendor/
  etix-core/                    # Renamed foundation gem
    app/
      models/etix/core/
        user.rb                 # Phone-first, OTP auth
        organization.rb         # Multi-tenant organizers
        membership.rb           # Team-based access
        audit_log.rb            # Kept as-is
        review.rb               # Renamed to moderation
        role.rb                 # Kept as-is
        permission.rb           # Kept as-is
      concerns/etix/core/
        authenticatable.rb      # Modified for OTP
        authorizable.rb         # Kept as-is
        auditable_model.rb      # Kept as-is
        reviewable_model.rb     # Kept as-is
      controllers/concerns/
        authenticatable.rb
        authorizable.rb
        common.rb
        pagination.rb
        filterable.rb
        json_response.rb
        moderatable_controller.rb  # Renamed from reviewable
      services/etix/core/
        auth_service.rb         # Modified for OTP
        token_service.rb        # Kept as-is
        qr_service.rb           # NEW: QR generation
      policies/etix/core/
        application_policy.rb   # Kept as-is
      serializers/etix/core/    # New serializers
      errors/etix/core/         # New error classes
    lib/
      etix/
        core.rb
        core/
          engine.rb
          permission_registry.rb
          version.rb
      generators/
        common/                 # Updated templates
    db/migrate/                 # New migrations

app/                            # Main application
  models/
    event.rb
    event_setting.rb
    event_feature.rb
    ticket_type.rb
    inventory_pool.rb
    order.rb
    order_item.rb
    payment.rb
    ticket.rb
    attendance_record.rb
    checkin_log.rb
    ticket_transfer.rb
    resale_listing.rb
    promo_code.rb
    announcement.rb
    featured_listing.rb
    follow.rb
    rating.rb
  services/
    payment_gateway/
      telebirr.rb
      chapa.rb
    qr_validator.rb
    offline_sync.rb
    recommendation_engine.rb
    commission_calculator.rb
    sms_campaign.rb
  controllers/
    api/v1/
      events_controller.rb
      tickets_controller.rb
      orders_controller.rb
      scanner_controller.rb
      ...
```

---

## 9. RISK ASSESSMENT

| Risk | Impact | Mitigation |
|------|--------|------------|
| Over-engineering from supply chain patterns | High | Strip aggressively, only keep what's proven useful |
| Namespace collision during rename | Medium | Do it early, before any app code depends on it |
| File storage complexity | Medium | Pick ActiveStorage, remove custom Attachable |
| Password auth not fitting Ethiopia market | High | Switch to OTP early, don't build password flow |
| Review workflow overkill for events | Low | Simplify to basic approve/reject for event moderation |
| RBAC too complex for MVP | Medium | Start with simple roles (admin, organizer, scanner, user), expand later |

---

## 10. ACTION PLAN

### Phase 1: Foundation (Week 1-2)
1. Copy `vendor/dscf-core` to `vendor/etix-core` (or your chosen name)
2. Rename all namespaces: `Dscf::Core` → `Etix::Core`
3. Remove domain models: Business, BusinessType, Document, Address, UserProfile
4. Update gemspec, version, summary
5. Update generator templates
6. Run tests to verify nothing breaks

### Phase 2: Auth Overhaul (Week 2-3)
1. Modify User model for phone-first identity
2. Replace password auth with OTP flow
3. Add OTP code generation and validation
4. Keep JWT token infrastructure
5. Update AuthService for OTP
6. Test auth flow end-to-end

### Phase 3: File Storage Simplification (Week 3)
1. Decide: ActiveStorage only, or keep custom Attachable
2. If ActiveStorage: remove Attachable concern, FileAttachment model, FileStorage service
3. If keeping custom: rename from MinIO-specific language
4. Update Business model references (before removal)

### Phase 4: Domain Models (Week 3-5)
1. Create Organization, Membership models
2. Create Event, EventSetting, EventFeature models
3. Create TicketType, InventoryPool models
4. Create Order, OrderItem, Payment models
5. Create Ticket, AttendanceRecord, CheckinLog models
6. Create migrations, serializers, policies

### Phase 5: Core Features (Week 5-8)
1. QR code generation service
2. Payment gateway integration (Telebirr, Chapa)
3. Ticket purchase flow
4. Gate scanner API
5. Offline scanning sync
6. Resale marketplace
7. Ticket transfer

### Phase 6: Core Features (Week 8-12)
1. Location-based recommendations
2. Featured listings
3. Follow system
4. SMS/email campaigns
5. Rating & feedback
6. Admin dashboard
7. Analytics

---

## 11. FINAL VERDICT

**Keep the gem, but treat it as a foundation — not a template.**

The dscf-core gem contains **genuinely excellent infrastructure code** (auth, RBAC, audit, generators, controller concerns) that would take weeks to rebuild from scratch. But it also carries **significant domain baggage** (Business, Document, Address, supply-chain review workflows) that is irrelevant to event ticketing.

**Do NOT**:
- Copy-paste the whole thing into your app
- Keep the `Dscf::Core` namespace
- Keep the Business/Document/Address models
- Keep the dual file storage system (ActiveStorage + custom)
- Keep password-based auth for attendees

**DO**:
- Rename and restructure as a clean foundation gem
- Keep auth, RBAC, audit, generators, controller concerns
- Build event ticketing domain models from scratch
- Implement OTP-based phone authentication
- Use ActiveStorage for file uploads
- Build QR, payments, scanning, resale as new services

**Effort saved by keeping the gem**: ~2-3 weeks of infrastructure work
**Effort spent cleaning it**: ~1 week of refactoring
**Net benefit**: ~1-2 weeks saved, plus cleaner architecture from day one
