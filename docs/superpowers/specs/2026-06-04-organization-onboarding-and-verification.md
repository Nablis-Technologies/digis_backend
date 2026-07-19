# Organization Onboarding & Verification — Design Spec

## Overview

Upgrade the organization onboarding flow from minimal MVP to a full business onboarding system with rich organization profiles, tiered verification, enhanced membership roles/statuses, and document uploads. Invitations are explicitly deferred.

---

## Scope

| In Scope | Deferred |
|---|---|
| Rich organization schema (business info, organizer profile, contact) | Invitation flow (SMS/email, shadow users, tokens) |
| Document uploads (business license, TIN certificate) | Scanner role (depends on QR scanning feature) |
| Tiered verification (auto-approve + manual admin review) | JWT org embedding (needs auth token refresh logic) |
| Membership roles: owner, admin, staff | |
| Membership statuses: active, suspended | |
| ReviewableModel-based verification workflow | |
| Owner abandonment prevention | |
| Strict role hierarchy in policies | |

---

## 1. Organization Schema

### `organizations_organizations` — New Migration (add columns)

| Column | Type | Constraints | Notes |
|---|---|---|---|
| **Existing** | | | |
| id | uuid | PK, default `uuidv7()` | |
| name | string | not null | unchanged |
| slug | string | not null, unique index | unchanged |
| description | text | nullable | unchanged |
| followers_count | integer | default 0, not null | unchanged |
| social_links | jsonb | default `{}` | unchanged |
| created_at | datetime | not null | |
| updated_at | datetime | not null | |
| **New — Identity** | | | |
| organizer_type | string | not null | `"individual"`, `"company"`, `"ngo"`, `"government"`, `"collective"` |
| category | string | not null | `"music"`, `"sports"`, `"conference"`, `"comedy"`, `"theater"`, `"festival"`, `"workshop"`, `"exhibition"`, `"other"` |
| **New — Contact & Location** | | | |
| contact_phone | string | nullable | org contact phone |
| contact_email | string | nullable | org contact email |
| website_url | string | nullable | optional |
| tin_number | string | nullable | Tax Identification Number |
| address_line1 | string | nullable | |
| address_line2 | string | nullable | |
| city | string | nullable | |
| region | string | nullable | e.g., "Addis Ababa", "Oromia" |
| **New — Event Pattern** | | | |
| estimated_audience | string | nullable | `"under_100"`, `"100_500"`, `"500_1000"`, `"1000_5000"`, `"5000_plus"` |
| event_frequency | string | nullable | `"one_time"`, `"monthly"`, `"quarterly"`, `"weekly"`, `"seasonal"` |
| **New — Counters** | | | |
| events_count | integer | default 0, not null | counter cache for events |
| **New — Verification** | | | |
| verification_status | string | default `"unverified"`, not null | enum: `unverified`, `pending`, `verified`, `rejected` |
| verified_at | datetime | nullable | set/cleared by service only |
| last_rejection_feedback | text | nullable | denormalized from Core::Review; persists across resubmit; cleared on approve |

### Migration: Add Verification Columns to Organizations

```ruby
class AddVerificationToOrganizationsOrganizations < ActiveRecord::Migration[8.1]
  def change
    change_table :organizations_organizations do |t|
      t.string  :verification_status,        default: "unverified", null: false
      t.datetime :verified_at
      t.text     :last_rejection_feedback
    end

    add_index :organizations_organizations, :verification_status
  end
end
```

### Active Storage Attachments

```ruby
has_one_attached :profile            # logo (existing)
has_one_attached :banner             # cover image (new)
has_one_attached :business_license   # PDF or image (new)
has_one_attached :tin_certificate    # PDF or image (new)
```

### Document Storage Security

Business licenses and TIN certificates are **sensitive legal documents** and must not be publicly accessible.

- Active Storage signed URLs expire after 5 minutes by default — this is the short-lived access model.
- `profile` and `banner` remain public (standard Active Storage signed URLs).
- `business_license` and `tin_certificate` require an **authenticated download endpoint** that gates access by role:

| Who can download | Role requirement |
|---|---|
| Org owner/admin | Owner or admin of the organization |
| Platform admin | super_admin global role |
| Staff | No (read-only on org settings page, no direct download) |
| Public/anonymous | No access |

Implementation: a `DocumentsController` action that validates membership role before redirecting to a fresh signed URL. No direct blob URLs are exposed to the client.

```ruby
# GET /api/v1/organizations/owner/:organization_id/documents/:document_type
# document_type: "business_license" or "tin_certificate"
# Requires: owner or admin membership, OR super_admin
def download
  authorize @organization, :download_documents?
  attachment = @organization.public_send(params[:document_type])
  redirect_to rails_blob_url(attachment, disposition: "inline", expires_in: 5.minutes)
end
```

### Model Validations

```ruby
# Core concerns
include Core::ReviewableModel   # polymorphic review workflow (Core::Review records)
include Core::AuditableModel    # pure audit trail (Core::AuditLog records)

# String-backed enum for queryable status (denormalized from Core::Review)
# This column is kept in sync by after_reviewable_action callbacks in the controller.
# Use Core::Review for the review process (feedback, reviewer identity, history).
# Use verification_status for fast queries, scopes, and filtering.
enum :verification_status, {
  unverified: "unverified",
  pending: "pending",
  verified: "verified",
  rejected: "rejected"
}

# Note: reviewable_context config lives on the CONTROLLER (not the model).
# The framework's context_config reads self.class.review_context_configs — i.e.,
# the controller's class, not the model's. Putting it on the model would be dead code.
# The controller includes VerificationCallbacks which holds the single source of truth.

# Override ReviewableModel's hardcoded "draft" fallback to return the
# denormalized verification_status for the :verification context.
# Without this, current_status_for(:verification) returns "draft" when
# no review exists, but verification_status column says "unverified".
def current_status_for(context = :default)
  return verification_status if context == :verification && reviews.with_context(:verification).empty?
  super
end

# Existing
validates :name, presence: true, uniqueness: true
validates :slug, presence: true, uniqueness: true
validates :events_count, numericality: { greater_than_or_equal_to: 0 }
validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

# New — required fields
validates :organizer_type, presence: true,
          inclusion: { in: %w[individual company ngo government collective] }
validates :category, presence: true,
          inclusion: { in: %w[music sports conference comedy theater festival workshop exhibition other] }

# New — optional fields
validates :estimated_audience,
          inclusion: { in: %w[under_100 100_500 500_1000 1000_5000 5000_plus] }, allow_nil: true
validates :event_frequency,
          inclusion: { in: %w[one_time monthly quarterly weekly seasonal] }, allow_nil: true

# New — verified_at ↔ verification_status coupling
validates :verified_at, presence: true, if: :verified?
validates :verified_at, absence: true, unless: :verified?

# New — last_rejection_feedback ↔ verification_status coupling
# Feedback persists across resubmit so the org owner can reference it while fixing issues.
validates :last_rejection_feedback, presence: true, if: :rejected?
validates :last_rejection_feedback, absence: true, if: :verified?
```

### Verification Status Lifecycle

```
Created → unverified (no Core::Review record yet)
  ↓ (documents uploaded — files only, no review created)
unverified (still no Core::Review)
  ↓ (POST /submit — auto-approve OR pending)
verified (Core::Review created with status: "approved")
  OR
pending (Core::Review created with status: "pending")
  ↓ (admin approves via ReviewableController)
verified (Core::Review updated to status: "approved")
  ↓ (admin rejects via ReviewableController)
rejected → (admin requests modification OR org resubmits) → pending
```

**Flow detail:** The `PATCH .../documents` endpoint only attaches files. The `POST /submit` endpoint creates a `Core::Review` record and transitions it to `pending` or `approved` based on auto-approve rules. The `draft` review state exists only as the `initial_status` in the reviewable context — it is never persisted in practice because submit immediately transitions to `pending` or `approved`.

The `verification_status` enum column is a **denormalized copy** of the review state, kept in sync by controller callbacks. The `Core::Review` record is the source of truth for the review process.

---

## 2. Membership Enhancements

### `organizations_memberships` — Updated

| Column | Type | Constraints | Notes |
|---|---|---|---|
| id | uuid | PK | unchanged |
| user_id | uuid | FK, not null | unchanged |
| organization_id | uuid | FK, not null | unchanged |
| role | string | not null, default `"staff"` | **updated**: `owner`, `admin`, `staff` |
| status | string | default `"active"`, not null | **new**: `active`, `suspended` |
| created_at | datetime | not null | |
| updated_at | datetime | not null | |

### Role Rename: `member` → `staff`

The previous `member` role becomes `staff` to match the architecture doc and distinguish it from the generic concept of "being a member."

**Scope of this rename** (ensure all are updated):
- `app/models/organizations/membership.rb` — enum definition
- Migration: integer → string conversion + data migration
- `MembershipPolicy` and `MembershipPolicy::Scope` — role checks
- `OwnerOrganizationsController#after_create_hook` — assigns default role
- `OwnerMembershipsController#destroy` — role-based deletion guard
- `OwnerMembershipsController` param validation — permitted role values
- All serializers referencing `membership.role` or `role` attribute
- `test/fixtures/organizations/memberships.yml` — fixture data
- `db/seeds.rb` — seed role values
- Partial unique index `WHERE role = 'owner'` (recreated in migration)
- `VerificationCallbacks#owner_enforcement_failed?` — `membership.staff?` check
- `ROLE_WEIGHT` hash in `MembershipPolicy` — `staff: 1`

### Enum Definitions

```ruby
# String-backed enums for readability in DB queries and API responses
enum :role, { owner: "owner", admin: "admin", staff: "staff" }
enum :status, { active: "active", suspended: "suspended" }
```

### Migration: Add `status` Column

The existing `organizations_memberships` table has no `status` column. A new migration adds it:

```ruby
class AddStatusToOrganizationsMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations_memberships, :status, :string, default: "active", null: false
    add_index :organizations_memberships, :status
  end
end
```

All existing memberships default to `active`. Pre-launch, no data migration needed.

### Migration: Convert `role` to String

The existing `organizations_memberships.role` column is `integer`. A migration converts it to `string`:

```ruby
class ConvertMembershipRoleToString < ActiveRecord::Migration[8.1]
  def up
    # Map existing integer values to string equivalents
    execute "UPDATE organizations_memberships SET role = 'owner' WHERE role = 0"
    execute "UPDATE organizations_memberships SET role = 'admin' WHERE role = 1"
    execute "UPDATE organizations_memberships SET role = 'staff' WHERE role = 2"

    # Change column type
    change_column :organizations_memberships, :role, :string, null: false, default: "staff"

    # Recreate the partial unique index with string value
    remove_index :organizations_memberships, name: "idx_one_owner_per_org"
    execute <<~SQL
      CREATE UNIQUE INDEX idx_one_owner_per_org
        ON organizations_memberships (organization_id)
        WHERE role = 'owner';
    SQL
  end

  def down
    remove_index :organizations_memberships, name: "idx_one_owner_per_org"

    execute "UPDATE organizations_memberships SET role = '0' WHERE role = 'owner'"
    execute "UPDATE organizations_memberships SET role = '1' WHERE role = 'admin'"
    execute "UPDATE organizations_memberships SET role = '2' WHERE role = 'staff'"

    change_column :organizations_memberships, :role, :integer, null: false, using: "role::integer"

    execute <<~SQL
      CREATE UNIQUE INDEX idx_one_owner_per_org
        ON organizations_memberships (organization_id)
        WHERE role = 0;
    SQL
  end
end
```

### Active Scope

```ruby
scope :active, -> { where(status: :active) }
```

### Model Validations

```ruby
validates :role, presence: true
validates :status, presence: true, inclusion: { in: %w[active suspended] }

# Note: The old `validates :role, uniqueness: { scope: :organization_id }, if: -> { owner? }`
# is REMOVED. The partial unique index idx_one_owner_per_org (recreated in the migration)
# enforces single-owner at the DB level. Model-level uniqueness is redundant and races.
```

### Role Permissions Matrix

| Capability | Owner | Admin | Staff |
|---|---|---|---|
| Create/edit events | Yes | Yes | Yes (limited) |
| Manage org settings | Yes | Yes | No |
| Manage memberships | Yes | Yes | No |
| View revenue/analytics | Yes | Yes | No |
| Scan QR codes | Yes | Yes | Yes |
| Delete org | Yes | No | No |
| Suspend members | Yes | Yes (not owner/admin) | No |

### Status Transitions

```
active ↔ suspended
```

Simple toggle. Only owner/admin can suspend. An owner cannot be suspended as the sole owner. With at least one other active owner, an owner can be suspended via the normal hierarchy rules (see §3.2).

---

## 3. Policy & Security Rules

### 3.1 Strict Role Hierarchy (Pundit Policy)

```ruby
# Organizations::MembershipPolicy
#
# Resolves the current user's membership in the target organization
# via the policy's `user` (the authenticated user from the controller).
# Called by Pundit as `authorize membership` in membership-related actions.

ROLE_WEIGHT = { owner: 3, admin: 2, staff: 1 }.freeze

def initialize(user, membership)
  @user = user
  @membership = membership  # the target membership being acted upon
end

def can_manage?
  return false unless current_membership # user has no membership in this org

  actor_weight = ROLE_WEIGHT[current_membership.role.to_sym]
  target_weight = ROLE_WEIGHT[@membership.role.to_sym]
  actor_weight > target_weight  # strictly greater — admin can't touch admin
end

private

# The acting user's membership in the same organization as the target.
# Memoized per-policy instance.
def current_membership
  @current_membership ||= Organizations::Membership.active
    .find_by(user_id: @user.id, organization_id: @membership.organization_id)
end
```

**Rule:** An actor can only mutate a target membership if their role weight is strictly greater than the target's.

### 3.2 Owner Abandonment Prevention

```ruby
# Membership model — two narrow callbacks instead of one broad one

# 1. Prevent status change to suspended for sole owner
before_update :prevent_sole_owner_suspension, if: :will_save_change_to_status?

# 2. Prevent role change away from owner for sole owner
before_update :prevent_sole_owner_demotion, if: :will_save_change_to_role?

# 3. Prevent removal of sole owner
before_destroy :prevent_sole_owner_removal, if: -> { owner? }

private

def prevent_sole_owner_suspension
  return unless status == "suspended" # only block suspension, not reactivation
  return if organization.memberships.active.owner.where.not(id: id).exists?

  errors.add(:base, "Cannot suspend the sole owner. Transfer ownership first.")
  throw :abort
end

def prevent_sole_owner_demotion
  return unless role_was == "owner" # only block demotion FROM owner
  return if organization.memberships.active.owner.where.not(id: id).exists?

  errors.add(:base, "Cannot demote the sole owner. Transfer ownership first.")
  throw :abort
end

def prevent_sole_owner_removal
  return unless active?
  return if organization.memberships.active.owner.where.not(id: id).exists?

  errors.add(:base, "Cannot remove the sole owner. Transfer ownership first.")
  throw :abort
end
```

**Rules:**
- An owner cannot be **suspended** unless at least one other active owner exists.
- An owner cannot be **demoted** to a lower role unless at least one other active owner exists.
- An owner cannot be **removed** unless at least one other active owner exists.
- Ownership **transfer** (owner → admin, another admin → owner) is a separate documented action handled by its own service method, not by these callbacks.

### 3.3 Ownership Transfer

A dedicated action that atomically swaps the owner role between two members.

**Preconditions:**
- The new owner **must already have an active membership** in the organization with role `admin` or `staff`.
- The transfer endpoint does **not** invite new users — invitation flow is deferred (§7).
- The current owner must be authenticated and must be the sole owner (or one of the owners) initiating the transfer.

```
POST /api/v1/organizations/owner/:organization_id/memberships/transfer
Body: { "to_user_id": "uuid" }

Response 200:
{
  "previous_owner": { "user_id": "uuid", "role": "admin" },
  "new_owner": { "user_id": "uuid", "role": "owner" }
}
```

The previous owner is **always demoted to `admin`**, regardless of their prior role. If they were the sole owner, they become admin. The new owner's prior role (admin or staff) is replaced by owner.

**Implementation:**

```ruby
# Organizations::OwnershipTransferService
def self.transfer(organization, current_owner_user, new_owner_user)
  new_membership = organization.memberships.active.find_by(user_id: new_owner_user.id)
  raise ActiveRecord::RecordNotFound, "New owner must be an active member of this organization" unless new_membership

  organization.transaction do
    old_membership = organization.memberships.active.find_by!(user_id: current_owner_user.id, role: :owner)

    old_membership.update!(role: :admin)   # owner → admin (always)
    new_membership.update!(role: :owner)   # staff/admin → owner
  end
end
```

The transaction ensures the partial unique index (`idx_one_owner_per_org WHERE role = 'owner'`) is never violated — both role changes happen atomically. The owner-abandonment callbacks are bypassed because a new owner exists before the old owner is demoted.

### 3.4 Suspended Status Runtime Enforcement

Authentication middleware evaluates membership status on every org-scoped request. Suspended members are excluded from JWT refresh tokens. For mid-session suspension, `ApplicationController` re-checks via DB lookup on org-scoped endpoints.

### 3.5 Database Constraints (carried forward)

```ruby
# Unique compound index (prevents duplicate memberships)
add_index :organizations_memberships, [:user_id, :organization_id], unique: true,
          name: "idx_org_memberships_on_user_and_org"

# Partial unique index (one owner per org at DB level)
CREATE UNIQUE INDEX idx_one_owner_per_org
  ON organizations_memberships (organization_id)
  WHERE role = 'owner';
```

### 3.6 Optimistic Locking (Deferred)

The spec does not include `lock_version` or optimistic locking for v1. Last-write-wins is acceptable for the initial launch. If concurrent admin edits become a real issue (two admins updating the same org simultaneously), add `lock_version` to `organizations_organizations` and `organizations_memberships` in a follow-up migration.

---

## 4. API Endpoints

### 4.1 Organization CRUD

```
POST   /api/v1/organizations/owner                                      # create
GET    /api/v1/organizations/owner                                      # index (my orgs)
GET    /api/v1/organizations/owner/:organization_id                     # show
PATCH  /api/v1/organizations/owner/:organization_id                     # update
DELETE /api/v1/organizations/owner/:organization_id                     # destroy
PATCH  /api/v1/organizations/owner/:organization_id/documents           # upload documents
```

**Route definition:**

```ruby
resources :owner_organizations, only: %i[index show create update destroy],
          path: "organizations/owner",
          param: :organization_id do
  member do
    patch :documents
    get 'documents/:document_type', to: 'owner_organizations#download', as: :download_document
  end
end
```

The `param: :organization_id` ensures `params[:organization_id]` in the controller — prevents confusion with user IDs.

### 4.2 Document Upload (Separate Endpoint)

```json
PATCH /api/v1/organizations/owner/:organization_id/documents
Content-Type: multipart/form-data

Body:
{
  "profile": <file>,
  "banner": <file>,
  "business_license": <file>,
  "tin_certificate": <file>
}

Response 200:
{
  "id": "uuid",
  "verification_status": "unverified",
  "documents": {
    "profile": { "url": "...", "filename": "logo.png" },
    "banner": { "url": "...", "filename": "cover.jpg" },
    "business_license": { "url": "...", "filename": "license.pdf" },
    "tin_certificate": { "url": "...", "filename": "tin.pdf" }
  }
}
```

The documents endpoint **only attaches files** — it does not create a review or trigger auto-approve. After uploading, the org owner calls `POST .../submit` (§4.3) which handles the review creation and auto-approve logic. `profile` and `banner` are public images. `business_license` and `tin_certificate` are sensitive — see Document Storage Security above.

### 4.3 Verification Actions (ReviewableController)

Verification uses `Core::ReviewableController` instead of custom service methods. Actions are split across two controllers by actor:

| Actor | Actions | Controller |
|---|---|---|
| Org owner/admin | `submit`, `resubmit` | `Organizations::VerificationsController` |
| Platform admin | `approve`, `reject`, `request_modification` | `Admin::VerificationsController` |

Both controllers include `Core::ReviewableController` and share the same `:verification` context from the model.

**Admin permission check:** The `ReviewableController`'s built-in `authorize_review_action!` calls `current_user.has_permission?("#{controller_name}.#{action_name}")` for every review action. Admin actions (approve/reject/request_modification) require the corresponding permission (e.g., `"verifications.approve"`) on the admin user. This permission must be seeded via the existing `Core::Permission` and `Core::RolePermission` tables.

**Routes:**

```ruby
# config/routes.rb

# Org-side: extend existing owner_organizations block (no duplicate resources declaration).
# submit/resubmit route to VerificationsController, not OwnerOrganizationsController.
scope module: :organizations do
  resources :owner_organizations, only: %i[index show create update destroy],
            path: "organizations/owner",
            param: :organization_id do
    resources :memberships, only: %i[index show create update destroy],
              controller: "owner_memberships"
    member do
      patch :documents
      get 'documents/:document_type', to: 'owner_organizations#download', as: :download_document
      # Verification workflow routes — explicit controller binding
      post :submit,     to: "verifications#submit"
      post :resubmit,   to: "verifications#resubmit"
    end
  end
end

# Admin verification workflow (approve / reject / modify)
# Added within existing admin namespace, explicit controller binding.
# Note: no param: :organization_id — existing Admin::OrganizationsController uses params[:id]
# via Core::Common. Admin::VerificationsController also uses params[:id] (framework default).
namespace :admin do
  resources :organizations, except: %i[new edit] do
    member do
      post :transfer_ownership
      # Verification workflow routes — explicit controller binding
      post :approve,              to: "verifications#approve"
      post :reject,               to: "verifications#reject"
      post :request_modification, to: "verifications#request_modification"
    end
    resources :memberships, only: %i[index show create update destroy]
  end
end
```

**Controllers:**

Both controllers share sync and audit callbacks. The authorization overrides differ by actor.

**Anti-double-logging:** `Admin::ApplicationController` and `Organizations::ApplicationController` do NOT include `Core::AuditableController`. Controllers that need generic audit (e.g., `Admin::OrganizationsController` for CRUD) include it explicitly. The verifications controllers don't — `after_reviewable_action` is their sole audit log entry point.

Shared callbacks extracted to a concern to avoid duplication:

```ruby
# app/controllers/concerns/verification_callbacks.rb
module VerificationCallbacks
  extend ActiveSupport::Concern

  # Single source of truth for the verification review workflow config.
  # Lives here (not the model) because the framework's context_config reads
  # self.class.review_context_configs — i.e., the controller's class, not the model's.
  # Both controllers spread this into reviewable_context :verification, **VERIFICATION_CONFIG.
  VERIFICATION_CONFIG = {
    statuses: %w[draft pending approved rejected modify],
    initial_status: "draft",
    transitions: {
      "draft"    => %w[pending approved],  # first submit (auto-approve → approved)
      "pending"  => %w[approved rejected modify],
      "rejected" => %w[pending],           # re-submit after rejection
      "modify"   => %w[pending]            # resubmit after modification requested
    },
    actions: {
      submit:               { status: "pending" },
      approve:              { status: "approved" },
      reject:               { status: "rejected",  require_feedback: true },
      request_modification: { status: "modify",    require_feedback: true },
      resubmit:             { status: "pending",   from: %w[rejected modify] }
    }
  }.freeze

  private

  # Called by Core::ReviewableController#after_review_action (instance method hook).
  # Runs inside the transaction, BEFORE render_success.
  def after_reviewable_action(review, resource, context)
    # Org-side: for auto-approved orgs, clear reviewed_by — the system auto-approved,
    # not the org owner who submitted. reviewed_by = nil indicates system approval.
    # Uses save!(validate: false) to update both DB AND in-memory object.
    # update_columns would leave review.reviewed_by stale, breaking the audit skip check.
    #
    # LOAD-BEARING: action_name == "submit" identifies the auto-approve path.
    # The submit override in Organizations::VerificationsController is the ONLY action
    # that can set status to "approved" directly (bypassing the pending state).
    # If submit is renamed, this check must be updated in lockstep.
    if review.status == "approved" && action_name == "submit"
      review.reviewed_by = nil
      review.save!(validate: false)
    end

    sync_verification_status!(review, resource, context)
    record_audit_trail!(review, resource, context)
  end

  def sync_verification_status!(review, resource, _context)
    case review.status
    when "approved"
      resource.update!(verification_status: :verified, verified_at: Time.current, last_rejection_feedback: nil)
    when "rejected"
      # review.feedback is jsonb (e.g., {"message": "TIN expired"}).
      # last_rejection_feedback is text — extract the message key.
      # Full jsonb is preserved in Core::AuditLog metadata for audit purposes.
      resource.update!(verification_status: :rejected, verified_at: nil, last_rejection_feedback: review.feedback["message"])
    when "modify"
      resource.update!(verification_status: :pending, last_rejection_feedback: review.feedback["message"])
    when "pending"
      resource.update!(verification_status: :pending)
      # last_rejection_feedback intentionally NOT cleared on resubmit —
      # persists so the org owner can reference it while fixing issues.
    end
  end

  # Skip audit log for auto-approve — it's a system action, not a user action.
  # The Core::Review record (reviewed_by: nil) is the audit trail for auto-approvals.
  def record_audit_trail!(review, resource, _context)
    return if review.reviewed_by.nil? && review.status == "approved"  # auto-approve

    resource.record_audit!(
      action_name,
      actor: current_user,
      metadata: {
        "review_id" => review.id,
        "review_status" => review.status,
        "feedback" => review.feedback
      }.compact
    )
  end
end
```

```ruby
# Admin::VerificationsController — admin actions (approve, reject, request_modification)
# Separate from Admin::OrganizationsController to isolate review workflow.
class Admin::VerificationsController < Admin::ApplicationController
  include Core::ReviewableController
  include VerificationCallbacks

  reviewable_model Organizations::Organization
  reviewable_context :verification, VerificationCallbacks::VERIFICATION_CONFIG

  private

  # Override: framework defaults to :default, but our workflow is registered as :verification.
  def current_review_context
    :verification
  end

  # Admin: no set_reviewable_resource override needed.
  # The admin route uses the default param: :id (no param: :organization_id override),
  # so the framework's default `model_class.find(params[:id])` works correctly.

  # Admin: always allowed to submit review actions
  def owner_enforcement_failed?
    false
  end

  # Admin: cannot review their own organization (conflict of interest)
  def self_review_attempt?
    membership = @reviewable_resource.memberships.active.find_by(user_id: current_user.id)
    membership.present?
  end
end
```

```ruby
# Organizations::VerificationsController — org-side actions (submit, resubmit)
class Organizations::VerificationsController < Organizations::ApplicationController
  include Core::ReviewableController
  include VerificationCallbacks

  reviewable_model Organizations::Organization
  reviewable_context :verification, VerificationCallbacks::VERIFICATION_CONFIG

  AUTO_APPROVE_AUDIENCE = %w[under_100 100_500].freeze

  # Override submit to handle auto-approve logic AND enforce initial-submission-only.
  # submit is strictly for first-time submission. resubmit is the only path after
  # rejection or modification request.
  def submit
    if reviewable_resource.current_review_for(:verification)
      return render_error(
        I18n.t("review.errors.already_submitted", default: "Already submitted; use resubmit after rejection or modification request"),
        status: :unprocessable_entity
      )
    end

    status = auto_approve?(reviewable_resource) ? "approved" : "pending"
    perform_review_action(status: status, require_submission_ready: true)
  end

  private

  def auto_approve?(organization)
    organization.estimated_audience.in?(AUTO_APPROVE_AUDIENCE)
  end

  # Override: framework defaults to :default, but our workflow is registered as :verification.
  def current_review_context
    :verification
  end

  # Override: framework uses params[:id], but our routes use param: :organization_id.
  def set_reviewable_resource
    @reviewable_resource = model_class.find(params[:organization_id])
  rescue ActiveRecord::RecordNotFound
    render_error("Organization not found", status: :not_found)
  rescue NameError => error
    render_error(I18n.t("review.errors.config_error", message: error.message), status: :internal_server_error)
  end

  # Override: require all documents attached before submission
  def submission_ready?(organization)
    organization.profile.attached? &&
      organization.banner.attached? &&
      organization.business_license.attached? &&
      organization.tin_certificate.attached?
  end

  # Org-side: only owner/admin can submit/resubmit (not staff)
  def owner_enforcement_failed?
    membership = @reviewable_resource.memberships.active.find_by(user_id: current_user.id)
    membership.nil? || membership.staff?
  end

  # Org-side: submitting your own org is expected (not a conflict)
  def self_review_attempt?
    false
  end

  # Org-side: authorization is membership-based, NOT permission-based.
  # The framework's default authorize_review_action! calls has_permission? first,
  # which blocks org owners (they have no platform permissions — only their
  # membership in the org matters). We override to skip the permission check
  # and rely on owner_enforcement_failed? (membership + role) for authorization.
  # Admin::VerificationsController keeps the framework default since admins
  # do hold platform permissions like "verifications.approve".
  def authorize_review_action!
    return render_error(:"review.errors.not_authorized", status: :forbidden, code: "not_authorized") if owner_enforcement_failed?
    skip_authorization
  end
end
```

**Note on `resubmit`:** The `resubmit` action does NOT go through auto-approve — it always sets status to `"pending"` regardless of audience size. This is intentional: if an org was previously rejected or asked to modify, a human admin should review the resubmission.

**Resubmit is a 2-step flow:** `resubmit` only changes the review status — it does NOT update model fields (no `update_model: true` in the action config). To fix issues flagged in a rejection:

1. `PATCH /organizations/owner/:organization_id` — update org fields (e.g., upload new documents via the documents endpoint)
2. `POST /organizations/owner/:organization_id/resubmit` — change review status to `pending`

This separation of concerns keeps field updates (CRUD) distinct from review state transitions.

**Reject:**
```
POST /api/v1/admin/organizations/:organization_id/reject
Authorization: Bearer <JWT> (super_admin required)
Body: { "review_feedback": "TIN certificate is expired" }
```

**Approve:**
```
POST /api/v1/admin/organizations/:organization_id/approve
Authorization: Bearer <JWT> (super_admin required)
```

**Request Modification:**
```
POST /api/v1/admin/organizations/:organization_id/request_modification
Body: { "review_feedback": "Please upload a clearer business license image" }
```

**Submit (org-side):**
```
POST /api/v1/organizations/owner/:organization_id/submit
Authorization: Bearer <JWT> (org owner/admin required)
# Transitions: draft → pending
```

**Resubmit (org-side):**
```
POST /api/v1/organizations/owner/:organization_id/resubmit
Authorization: Bearer <JWT> (org owner/admin required)
# Allowed from: rejected, modify
```

**Rejection feedback storage:** Feedback is stored on the `Core::Review` record (`feedback` attribute), which is the natural home for review feedback. The `after_reviewable_action` callback also writes an audit log entry for traceability.

**Feedback visibility:** The org owner retrieves rejection feedback via the organization show endpoint. The serializer reads from the denormalized `last_rejection_feedback` column on the org, which persists across resubmit (unlike `Core::Review.feedback`, which is overwritten on each state transition):

```ruby
# OrganizationSerializer — adds last_rejection_feedback attribute
def last_rejection_feedback
  object.last_rejection_feedback
end
```

**Note on review history:** The `Core::Review` record holds only the **current state** — there is at most one record per context per organization (status is updated in place, not duplicated). The `last_rejection_feedback` column on the org denormalizes the most recent rejection's feedback so it survives resubmit transitions. Full rejection history (who rejected, when, with what feedback) is available via `Core::AuditLog` records, queryable through the existing `record_audit!` mechanism.

### 4.4 Membership Management

```
PATCH /api/v1/organizations/owner/:organization_id/memberships/:id/suspend
PATCH /api/v1/organizations/owner/:organization_id/memberships/:id/activate
```

Owner/admin only. Hierarchy enforced — admin cannot suspend admin or owner.

### 4.5 Create Organization — Full Body

```json
{
  "organization": {
    "name": "Addis Live",
    "description": "Live music events in Addis Ababa",
    "organizer_type": "company",
    "category": "music",
    "contact_phone": "+251911234567",
    "contact_email": "info@addislive.com",
    "website_url": "https://addislive.com",
    "tin_number": "1234567890",
    "address_line1": "Bole Road, 3rd Floor",
    "city": "Addis Ababa",
    "region": "Addis Ababa",
    "estimated_audience": "1000_5000",
    "event_frequency": "monthly",
    "social_links": { "instagram": "@addislive", "telegram": "@addislive" }
  }
}
```

**Note:** The create endpoint is **JSON-only** (no file uploads). `profile`, `banner`, `business_license`, and `tin_certificate` are all uploaded via the separate `PATCH .../documents` endpoint after creation. This keeps the create request clean and avoids multipart/JSON mixing.

**`after_create_hook`** creates the owner membership (existing pattern):

```ruby
def after_create_hook(organization)
  organization.memberships.create!(user: current_user, role: :owner, status: :active)
end
```

### 4.6 Controller Permitted Params

```ruby
def model_params
  params.require(:organization).permit(
    :name, :description, :organizer_type, :category,
    :contact_phone, :contact_email, :website_url,
    :tin_number, :address_line1, :address_line2, :city, :region,
    :estimated_audience, :event_frequency,
    social_links: {}
  )
end

def document_params
  params.permit(:profile, :banner, :business_license, :tin_certificate)
end
```

### 4.7 Controller `set_object`

```ruby
def set_object
  @obj = @clazz.joins(:memberships)
               .where(organizations_memberships: { user_id: current_user.id, status: :active })
               .find_by!(organization_id: params[:organization_id])
end
```

---

## 5. Verification Workflow

### Architecture Overview

Verification uses three tools with clear separation:

| Tool | Purpose | Records |
|---|---|---|
| `Core::ReviewableModel` + `Core::Review` | Review state machine, feedback, transitions | `core_reviews` table |
| `Core::AuditableModel` + `Core::AuditLog` | Pure audit trail (who did what, when) | `core_audit_logs` table |
| `verification_status` enum column | Fast DB queries, scopes, filtering | Column on `organizations_organizations` |

### Document Upload (File Attachment Only)

The `PATCH .../documents` endpoint on `OwnerOrganizationsController` **only attaches files** — it does not create a `Core::Review` record or trigger auto-approve. After uploading documents, the org owner calls `POST .../submit` which handles the review creation and auto-approve logic.

```ruby
# OwnerOrganizationsController#documents (simplified)
def documents
  @obj.profile.attach(params[:profile]) if params[:profile]
  @obj.banner.attach(params[:banner]) if params[:banner]
  @obj.business_license.attach(params[:business_license]) if params[:business_license]
  @obj.tin_certificate.attach(params[:tin_certificate]) if params[:tin_certificate]
  render json: @obj
end
```

No separate `OrganizationVerificationService` is needed — the documents action handles attachment inline, and the review workflow is owned by the controller (§4.3).

### Auto-Approve Logic

Auto-approve logic lives in `Organizations::VerificationsController#submit` (§4.3) — the single source of truth. Both the initial submit and any future re-submission go through the same controller action.

**Auto-approve if:**
- `estimated_audience` is `"under_100"` or `"100_500"`
- This applies regardless of `organizer_type`, `category`, or `event_frequency`

**Manual review if:**
- `estimated_audience` is `"1000_5000"` or `"5000_plus"`
- `estimated_audience` is `nil` (org hasn't specified audience size yet)

The threshold constant `AUTO_APPROVE_AUDIENCE` in the controller is the single source of truth.

**Auto-approve review semantics:** For auto-approved orgs, `Core::Review.reviewed_by` is cleared to `nil` in the `after_reviewable_action` callback (the system auto-approved, not the org owner who submitted). The `reviewed_at` is set to the submission timestamp. This distinguishes system auto-approvals from admin approvals in the review history.

### verified_at Lifecycle

| Action | `verification_status` | `verified_at` | Core::Review status |
|---|---|---|---|
| Create org | `unverified` | `nil` | (no review yet) |
| Upload documents | `unverified` | `nil` | (no review yet) |
| Submit (auto-approve) | `verified` | `Time.current` | `approved` |
| Submit (manual review) | `pending` | `nil` | `pending` |
| Admin approves | `verified` | `Time.current` | `approved` |
| Admin rejects | `rejected` | `nil` | `rejected` |
| Admin requests modification | `pending` | `nil` | `modify` |
| Org resubmits | `pending` | `nil` | `pending` |

The `sync_verification_status!` callback in both verification controllers owns the enum sync. No other code should set `verification_status` or `verified_at` directly.

---

## 6. User Model Extensions

These associations and helpers **do not exist yet** on `Core::User`. They must be added:

```ruby
# Associations
has_many :memberships, class_name: "Organizations::Membership", dependent: :destroy
has_many :organizations, through: :memberships, source: :organization

# Helpers
def organizer?
  memberships.active.exists?
end

def member_of?(organization)
  memberships.active.where(organization: organization).exists?
end

def has_role_in?(organization, *roles)
  memberships.active.where(organization: organization, role: roles).exists?
end

# The role hierarchy is defined by explicit weights, not by enum ordering.
# String enums don't have a natural numeric order, so we use ROLE_WEIGHT.
ROLE_WEIGHT = { "owner" => 3, "admin" => 2, "staff" => 1 }.freeze

def most_privileged_role_in(organization)
  roles = memberships.active.where(organization: organization).pluck(:role)
  return nil if roles.empty?

  roles.max_by { |r| ROLE_WEIGHT[r] || 0 }
end
```

**Critical:** With string enums there is no natural numeric order. The `ROLE_WEIGHT` constant explicitly defines privilege levels. `most_privileged_role_in` picks the role with the highest weight, not `minimum`/`maximum` on the column.

---

## 7. Deferred Items

| Feature | Why Deferred | Notes for Future |
|---|---|---|
| **Invitation flow** | Needs SMS/email integration, shadow user creation, invitation tokens | Add `"invited"` to status enum, plus `invitation_token`, `invited_by_id` columns to memberships |
| **Scanner role** | Depends on QR scanning feature being built | Add `"scanner"` to role enum |
| **JWT org embedding** | Needs auth token refresh logic update | Add `organizations` array to JWT payload with org_id, role, status |

---

## 8. Counter Integrity

```ruby
# Organization model — counter cache declaration
# The Event model (when built) will declare:
#   belongs_to :organization, counter_cache: true
# This automatically increments/decrements events_count on create/destroy.
```

All counter columns enforce `default: 0, null: false` at the database level to prevent negative values from counter cache desynchronization:

```ruby
t.integer :events_count, default: 0, null: false
t.integer :followers_count, default: 0, null: false
```
