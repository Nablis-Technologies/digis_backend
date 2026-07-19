# ORGANIZERS & ORGANIZATIONS ARCHITECTURE

**Date**: May 17, 2026
**Context**: How organizers fit into the identity model

---

## CORE PRINCIPLE: ONE USER MODEL, MANY ROLES

**Organizers are Users.** A person who buys tickets on Friday can create an event on Saturday. There is no separate "organizer account" — there's only a User who belongs to an Organization with organizer permissions.

```
User (phone, verified, profile)
  ├── Can buy tickets (always)
  ├── Can belong to Organizations (via Memberships)
  └── Can do things in Organizations (based on Membership role)
```

This eliminates:
- Dual auth systems (no "organizer login" vs "attendee login")
- Account switching (no "switch to organizer mode")
- Data silos (one identity, all activity)
- Support complexity (one account to reset, one phone to verify)

---

## DATA MODEL

### Organizations

```ruby
# db/migrate/XXXX_create_organizations.rb
create_table :organizations, id: :uuid do |t|
  t.string :name, null: false
  t.string :slug, null: false          # for public URLs: /orgs/addis-live
  t.text :description
  t.string :logo_url
  t.string :banner_url
  t.string :website_url
  t.string :phone                     # org contact phone (different from members)
  t.string :email                     # org contact email
  t.string :category                  # "music", "sports", "conference", "comedy", etc.
  t.boolean :verified, default: false  # platform-verified org
  t.datetime :verified_at

  # ── Social / discovery ──
  t.integer :followers_count, default: 0
  t.integer :events_count, default: 0

  t.timestamps
end

add_index :organizations, :slug, unique: true
add_index :organizations, :verified
add_index :organizations, :category
```

### Memberships

```ruby
# db/migrate/XXXX_create_memberships.rb
create_table :memberships, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.uuid :user_id, null: false
  t.string :role, null: false           # "owner", "admin", "staff", "scanner"
  t.string :status, default: "active"   # "active", "invited", "suspended"
  t.string :invitation_token            # for invite-based onboarding
  t.datetime :invitation_sent_at
  t.datetime :invitation_accepted_at
  t.uuid :invited_by_id                 # who invited them

  t.timestamps
end

add_index :memberships, [:organization_id, :user_id], unique: true
add_index :memberships, :invitation_token, unique: true
add_index :memberships, :role
add_index :memberships, :status
```

### Role Hierarchy

| Role | Can do | Cannot do |
|------|--------|-----------|
| `owner` | Everything: manage org, create events, manage members, view revenue, delete org | — |
| `admin` | Create/edit events, manage staff/scanners, view analytics, manage event settings | Delete org, remove owner, change org billing |
| `staff` | Create/edit events (limited), view analytics for their events | Manage org settings, manage members, view revenue |
| `scanner` | Scan QR codes, view entry logs for assigned events | Create events, view revenue, manage anything |

### Events (Organization-Owned)

```ruby
# db/migrate/XXXX_create_events.rb (partial — organization relationship)
create_table :events, id: :uuid do |t|
  t.uuid :organization_id, null: false
  t.uuid :created_by_id, null: false    # the User who created it
  # ... rest of event fields
end

add_index :events, :organization_id
add_index :events, :created_by_id
```

---

## RELATIONSHIP MAP

```
User ──── has_many ──── Memberships ──── belongs_to ──── Organization
  │                                                        │
  │                                                        │
  └─── has_many ──── Orders (as buyer)                     └─── has_many ──── Events
  │                                                        │
  └─── has_many ──── Tickets (as owner)                    └─── has_many ──── TicketTypes
  │                                                        │
  └─── has_many ──── Follows (as follower)                 └─── has_many ──── Announcements
                                                           │
                                                           └─── has_many ──── Memberships (members)
```

**Key relationships:**
- A User can belong to **many** Organizations (freelancer who helps multiple promoters)
- An Organization has **many** Users (team with different roles)
- An Event belongs to **one** Organization (not directly to a User)
- A User creates Events **on behalf of** their Organization

---

## AUTHENTICATION FLOWS FOR ORGANIZERS

### Flow 1: Attendee Becomes Organizer

```
1. User already exists (bought tickets, verified phone, completed profile)
2. Clicks "Create Organization" in app
3. Fills org details: name, category, description
4. System creates Organization + Membership(user: current_user, role: "owner")
5. User is now an organizer — can create events immediately
```

**No new account. No new login. No switching.** The same JWT tokens work. The frontend just shows different UI based on membership roles.

### Flow 2: Invited to an Organization

```
1. Org admin invites "+251911987654" via phone number
2. System creates Membership(user: nil, role: "staff", status: "invited", invitation_token: "...")
3. SMS sent: "You've been invited to join [Org] on [Core]. Accept: [link]"
4. If phone number already exists as a User:
   → User logs in → sees pending invitation → accepts → membership activated
5. If phone number doesn't exist:
   → Shadow User created → OTP verification → profile onboarding → membership activated
```

### Flow 3: Organizer Dashboard Access

```
GET /api/v1/organizations
Authorization: Bearer <JWT>
→ Returns all organizations the user belongs to:
[
  { id: "uuid", name: "Addis Live", role: "owner", events_count: 12 },
  { id: "uuid", name: "Sheger Events", role: "staff", events_count: 3 }
]

GET /api/v1/organizations/:id/events
Authorization: Bearer <JWT>
→ Returns events for that org (filtered by user's role permissions)
```

---

## AUTHORIZATION: ORGANIZATION-LEVEL PERMISSIONS

### Policy Structure

```ruby
# app/policies/organization_policy.rb
class OrganizationPolicy < ApplicationPolicy
  def show?
    user.member_of?(record)
  end

  def update?
    user.has_role_in?(record, "owner", "admin")
  end

  def destroy?
    user.has_role_in?(record, "owner")
  end

  def manage_members?
    user.has_role_in?(record, "owner", "admin")
  end

  class Scope
    def resolve
      scope.joins(:memberships).where(memberships: { user_id: user.id, status: "active" })
    end
  end
end
```

### User Model Extensions

```ruby
# app/models/platform/user.rb (additions)
module Core
  class User < Core::ApplicationRecord
    # ── Existing associations ──
    has_many :user_roles, class_name: "Core::UserRole", ...
    has_many :roles, through: :user_roles, ...

    # ── Organization associations ──
    has_many :memberships, dependent: :destroy
    has_many :organizations, through: :memberships
    has_many :owned_organizations, -> { where(memberships: { role: "owner" }) },
             through: :memberships, source: :organization

    # ── Organizer helpers ──
    def organizer?
      memberships.active.exists?
    end

    def member_of?(organization)
      memberships.for_organization(organization).active.exists?
    end

    def has_role_in?(organization, *roles)
      memberships.for_organization(organization)
                 .active
                 .where(role: roles)
                 .exists?
    end

    def highest_role_in(organization)
      role_priority = { "owner" => 4, "admin" => 3, "staff" => 2, "scanner" => 1 }
      memberships.for_organization(organization)
                 .active
                 .pluck(:role)
                 .max_by { |r| role_priority[r] || 0 }
    end

    def can_create_events_for?(organization)
      has_role_in?(organization, "owner", "admin", "staff")
    end

    def can_scan_for?(organization)
      has_role_in?(organization, "owner", "admin", "staff", "scanner")
    end
  end
end
```

### Membership Model

```ruby
# app/models/membership.rb
class Membership < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  belongs_to :invited_by, class_name: "Core::User", optional: true

  ROLES = %w[owner admin staff scanner].freeze
  STATUSES = %w[active invited suspended].freeze

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :organization_id }

  scope :active, -> { where(status: "active") }
  scope :invited, -> { where(status: "invited") }
  scope :for_organization, ->(org) { where(organization_id: org) }
  scope :for_user, ->(user) { where(user_id: user) }
  scope :with_role, ->(role) { where(role: role) }

  after_commit :update_org_counts

  def accept!
    update!(status: "active", invitation_accepted_at: Time.current)
  end

  def suspend!
    update!(status: "suspended")
  end

  def owner?
    role == "owner"
  end

  def admin?
    role == "admin"
  end

  def scanner?
    role == "scanner"
  end

  private

  def update_org_counts
    organization.update_events_count
  end
end
```

### Organization Model

```ruby
# app/models/organization.rb
class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :events, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :generate_slug, on: :create

  def owners
    users.joins(:memberships).where(memberships: { role: "owner" })
  end

  def admins
    users.joins(:memberships).where(memberships: { role: "admin" })
  end

  def scanners
    users.joins(:memberships).where(memberships: { role: "scanner" })
  end

  def has_owner?
    memberships.active.where(role: "owner").exists?
  end

  def update_events_count
    update_column(:events_count, events.count)
  end

  def to_param
    slug
  end

  private

  def generate_slug
    return if slug.present?
    base = name.parameterize
    slug = base
    counter = 1
    while Organization.exists?(slug: slug)
      slug = "#{base}-#{counter}"
      counter += 1
    end
    self.slug = slug
  end
end
```

---

## FRONTEND: HOW THE APP KNOWS WHAT TO SHOW

### JWT Payload (Updated)

```ruby
{
  user_id: "uuid",
  phone: "+251911...",
  verified: true,
  profile_complete: true,
  type: "access",
  roles: ["user"],
  organizations: [
    { id: "uuid", name: "Addis Live", role: "owner" },
    { id: "uuid", name: "Sheger Events", role: "staff" }
  ],
  exp: 15.minutes.from_now
}
```

The `organizations` array is embedded in the JWT so the frontend knows immediately what orgs the user belongs to — no extra API call on app launch.

### Frontend Decision Tree

```
User opens app
  │
  ├── JWT has organizations? → Show "My Events" tab + "Attendee" tab
  │                              (dual-mode UI)
  │
  └── JWT has no organizations? → Show "Attendee" tab only
                                   + "Become an Organizer" CTA
```

### Dual-Mode UI

The app has two modes that coexist:

| Tab | Attendee Mode | Organizer Mode |
|-----|--------------|----------------|
| Home | Discover events, recommendations | Dashboard: sales, attendance, revenue |
| Events | Browse, buy tickets | Manage events, create new ones |
| Tickets | My tickets, QR codes | Scanner mode, entry logs |
| Profile | Edit profile, purchase history | Org settings, team management |

The user switches between modes with a toggle — **same account, same session, different views**.

---

## ORGANIZER ONBOARDING FLOW

```
Step 1: User decides to organize
→ Clicks "Create Organization"

Step 2: Org details
→ Name: "Addis Live"
→ Category: "Music"
→ Description: "Live music events in Addis Ababa"
→ Logo (optional)

Step 3: System creates
→ Organization(name: "Addis Live", slug: "addis-live")
→ Membership(user: current_user, role: "owner", status: "active")

Step 4: First event prompt
→ "Create your first event" → goes to event creation flow

Step 5: Team invitation (optional)
→ "Invite team members" → enter phone numbers → SMS invitations sent
```

---

## SCANNER-SPECIFIC FLOW

Scanners are a special case — they might be temporary staff who only need to scan QR codes, not manage events.

### Scanner-Only Onboarding

```
1. Org admin creates scanner account:
   → Enters phone: "+251911987654"
   → System creates/finds User
   → Creates Membership(user: user, organization: org, role: "scanner")
   → Sends SMS: "You've been added as a scanner for [Org]. Download the app to start scanning."

2. Scanner downloads app → enters phone → OTP verification
   → App detects scanner role → goes straight to scanner mode
   → No profile completion required (just phone + verified)
   → Can scan QR codes for assigned events
```

### Scanner Authorization

```ruby
# app/controllers/api/v1/scanner_controller.rb
class Api::V1::ScannerController < Core::ApplicationController
  before_action :require_scanner_role

  def scan
    # Scanner can only scan, nothing else
    ticket = Ticket.find_by!(qr_code: params[:qr_code])
    return render_error("Ticket not for your organization", status: :forbidden) unless current_user.can_scan_for?(ticket.event.organization)

    # ... scan logic
  end

  private

  def require_scanner_role
    return if current_user&.memberships&.active&.exists?
    render_error("Scanner access required", status: :forbidden, code: "scanner_required")
  end
end
```

---

## MULTI-ORGANIZER SCENARIOS

### Scenario 1: Freelance Event Manager

```
User: "+251911234567"
Memberships:
  - Organization: "Addis Live" (role: admin)
  - Organization: "Sheger Events" (role: staff)
  - Organization: "Comedy Night ET" (role: owner)

→ Can create events for all three orgs
→ Sees different dashboards depending on which org is selected
→ Same tickets, same purchase history across all
```

### Scenario 2: Venue + Promoter

```
Organization: "Arena Addis" (venue)
  - Members: venue staff (scanners), venue manager (admin)

Organization: "Concert Promoters ET" (promoter)
  - Members: promoter team (owner, admin, staff)

Event: "Artist X Live at Arena Addis"
  - organization_id: Concert Promoters ET (the promoter owns the event)
  - venue: "Arena Addis" (the venue hosts it)

→ Promoter creates and sells tickets
→ Venue staff scans at the gate
→ Both see relevant data through their org membership
```

---

## WHAT THIS AVOIDS

| Approach | Problem | Our Solution |
|----------|---------|--------------|
| Separate Organizer model | Two auth systems, account switching | One User, membership-based roles |
| Boolean `is_organizer` flag | Can't handle multi-org, no role granularity | Memberships with role hierarchy |
| STI (Organizer < User) | Complex queries, awkward associations | Single table, clean polymorphism via memberships |
| Org owns User accounts | Users can't belong to multiple orgs | Users own themselves, orgs have members |
| Separate organizer app | Fragmented user base, double development | One app, dual-mode UI |

---

## SUMMARY

**Organizers are Users who belong to Organizations.**

1. **One User model** — everyone authenticates the same way (phone → OTP → profile)
2. **Organizations are separate entities** — events belong to orgs, not users
3. **Memberships connect them** — with roles (owner, admin, staff, scanner)
4. **No account switching** — same session, different views based on membership
5. **Multi-org support** — a user can organize events for multiple organizations
6. **Scanner onboarding is minimal** — phone + OTP + assigned role, no profile required

This is how Eventbrite, Partiful, and Luma handle it. The user is the identity layer. Organizations are the permission layer. Events are the content layer. Clean separation, zero duplication.
