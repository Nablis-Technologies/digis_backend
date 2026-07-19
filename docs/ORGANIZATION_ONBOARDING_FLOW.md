# Organization Onboarding & Verification Flow

## Overview

This document describes the complete flow for creating, managing, and verifying organizations. It covers both the owner-side (Org Owner) and admin-side (Digis Admin) endpoints, the role hierarchy, the verification state machine, and how to test each step via the included Postman collection.

---

## Files Changed / Created

### New Files

| File | Purpose |
|---|---|
| `app/controllers/organizations/verifications_controller.rb` | Owner submits/resubmits org for verification |
| `app/controllers/admin/verifications_controller.rb` | Admin approves/rejects/requests modification on verification |
| `app/controllers/concerns/verification_callbacks.rb` | Shared concern: syncs verification status to org record, records audit trail |
| `app/policies/admin/verification_policy.rb` | Pundit policy for admin verification actions |
| `app/policies/organizations/verification_policy.rb` | Pundit policy for owner verification actions |
| `app/services/organizations/ownership_transfer_service.rb` | Service object for transferring org ownership |
| `db/migrate/20260525200000_create_organizations_organizations.rb` | Extended: added organizer_type, category, contact fields, verification status, event frequency, estimated_audience, etc. |
| `db/migrate/20260525200001_create_organizations_memberships.rb` | Extended: added `status` column (active/suspended), string-based role enum, sole-owner DB constraint |

### Modified Files

| File | Changes |
|---|---|
| `app/controllers/organizations/owner_organizations_controller.rb` | Added `destroy`, `documents`, `download` actions; scoped `set_object` to active memberships only; added document attachment eager loading; expanded `model_params` and `serializer_profile` |
| `app/controllers/organizations/owner_memberships_controller.rb` | Added `suspend` and `activate` actions; `destroy` now blocks self-removal for sole owners |
| `app/controllers/admin/organizations_controller.rb` | Added `transfer_ownership` action; expanded `model_params` and `apply_index_scope` |
| `app/controllers/concerns/core/membership_management.rb` | Guards against assigning `owner` role via create/update |
| `app/models/core/user.rb` | Added `organizer?`, `member_of?`, `has_role_in?`, `most_privileged_role_in` helpers; `has_many :memberships` and `has_many :organizations` associations |
| `app/models/organizations/organization.rb` | Added banner, business_license, tin_certificate attachments; verification_status enum; organizer_type/category/contact fields; `events_count` counter; `current_status_for` override for review context; expanded ransackable attributes |
| `app/models/organizations/membership.rb` | String-based roles (owner/admin/staff); added `status` enum (active/suspended); sole-owner guardrails (prevent suspension, demotion, removal of last owner); `scope :active` |
| `app/policies/organizations/organization_policy.rb` | Added `download_documents?` method; updated `update?`/`destroy?` |
| `app/policies/organizations/membership_policy.rb` | Role-weight-based `can_manage?` (owner=3, admin=2, staff=1); added `suspend?`/`activate?`; broadened `index?` scope to any active membership |
| `config/routes.rb` | Added verification routes (admin + owner), documents/download routes, suspend/activate member routes |
| `db/seeds.rb` | Added verification permission seeds; updated seed data for new required fields |
| All serializer files | Expanded to include new fields and attachment URLs |

---

## Verification State Machine

Managed by `Core::ReviewableController` + `VerificationCallbacks`:

```
               ┌─────────┐
               │  draft  │  ← initial (auto-submitted on first submit)
               └────┬────┘
                    │ submit / auto-approve
                    ▼
              ┌──────────┐
         ┌────│ pending  │────┐
         │    └──────────┘    │
         │         │          │
         ▼         ▼          ▼
   ┌─────────┐ ┌────────┐ ┌──────┐
   │approved │ │rejected│ │modify│
   └─────────┘ └────────┘ └──────┘
                              │
                              │ resubmit
                              ▼
                         ┌──────────┐
                         │ pending  │
                         └──────────┘
```

**Valid transitions:**
- `draft → pending` (submit)
- `draft → approved` (auto-approve for small audiences)
- `pending → approved` (admin approve)
- `pending → rejected` (admin reject)
- `pending → modify` (admin request modification)
- `rejected → pending` (resubmit)
- `modify → pending` (resubmit)

---

## Role Hierarchy

```
owner  (weight 3) — full control
admin  (weight 2) — can manage staff members
staff  (weight 1) — can view org, cannot manage members
```

**Enforced by:** `MembershipPolicy#can_manage?` — actor's weight must be **greater than** target's weight.

| Actor | Can manage |
|---|---|
| owner | admin, staff |
| admin | staff |
| staff | none |

---

##  Flows: Step by Step

### Flow A: Organization Creation (Owner)

```
POST /organizations/owner
Authorization: Bearer <owner_token>
Content-Type: application/json

{
  "organization": {
    "name": "My Event Co",
    "organizer_type": "company",
    "category": "music"
  }
}
```

**Response:** `201 Created`
```json
{
  "success": true,
  "data": {
    "id": "...",
    "name": "My Event Co",
    "slug": "my-event-co",
    "description": null,
    "created_at": "..."
  }
}
```

**What happens:**
1. Controller creates `Organizations::Organization` with provided params
2. `after_create_hook` auto-creates an **owner membership** for the current user
3. Returns the new org with a subset of fields (index profile)

**Notes:**
- `organizer_type` and `category` are **required** (validated on model)
- Any authenticated user can create an org (policy allows all)
- The creator always becomes the **owner** (auto-membership)

---

### Flow B: Upload Documents

```
PATCH /organizations/owner/:organization_id/documents
Authorization: Bearer <owner_token>
Content-Type: multipart/form-data

profile: <file>
banner: <file>
business_license: <file>
tin_certificate: <file>
```

**Response:** `200 OK` with full organization data (including attachment URLs)

**Authorization:** Only `owner` or `super_admin` (checks `update?` on `OrganizationPolicy`)

**Notes:**
- All four fields are optional — send only what you want to upload/replace
- Returns error if any attachment fails (e.g., invalid file type)
- Use this before submitting for verification (all 4 docs required)

---

### Flow C: Manage Memberships (Owner)

```
# List members
GET /organizations/owner/:organization_id/memberships?page=1&per_page=10

# Create a member (only owner/admin can create below their level)
POST /organizations/owner/:organization_id/memberships
{
  "membership": { "user_id": "<uuid>", "role": "staff" }
}

# Update a member's role
PATCH /organizations/owner/:organization_id/memberships/:id
{
  "membership": { "role": "admin" }
}

# Remove a member
DELETE /organizations/owner/:organization_id/memberships/:id

# Suspend / Activate
PATCH /organizations/owner/:organization_id/memberships/:id/suspend
PATCH /organizations/owner/:organization_id/memberships/:id/activate
```

**Authorization rules (via `MembershipPolicy#can_manage?`):**

| Operation | Allowed for |
|---|---|
| Create | owner → admin/staff; admin → staff |
| Update | owner → admin/staff; admin → staff (same level or below) |
| Destroy | owner → admin/staff; admin → staff |
| Suspend | owner → admin/staff; admin → staff |
| Activate | owner → admin/staff; admin → staff |

**Sole-owner protection (model-level callbacks):**
- Cannot **suspend** the last active owner
- Cannot **demote** the last active owner
- Cannot **destroy** the last active owner membership (must transfer ownership first)

**Owner cannot remove themselves** (controller-level guard in `destroy`).

**`owner` role cannot be assigned via create/update** (blocked by `MembershipManagement` concern; use admin `transfer_ownership` instead).

---

### Flow D: Submit for Verification (Owner)

**Prerequisites:** All 4 documents must be attached (profile, banner, business_license, tin_certificate).

```
POST /organizations/owner/:organization_id/verification/submit
Authorization: Bearer <owner_token>
```

**Response:** `200 OK`
```json
{
  "success": true,
  "data": {
    "id": "...",
    "verification_status": "pending",
    ...
  }
}
```

**Auto-approval:** If `estimated_audience` is `under_100` or `100_500`, the submission is automatically approved (status → `approved`, `verified_at` set). No admin intervention needed.

**Full approval required:** For larger audience sizes, status becomes `pending` and awaits admin review.

**Cannot submit twice:** Returns `422` if already submitted (must wait for rejection/modification request, then use `resubmit`).

```
POST /organizations/owner/:organization_id/verification/resubmit
Authorization: Bearer <owner_token>
```

Only allowed when current status is `rejected` or `modify`.

**Authorization:** User must have an active, non-staff membership in the org (owner or admin). Also enforced via `Organizations::VerificationPolicy`.

---

### Flow E: Review Verification (Admin)

```
POST /admin/organizations/:id/verification/approve
Authorization: Bearer <admin_token>
Content-Type: application/json
{
  "review_feedback": { "message": "Looks good!" }
}
```

```
POST /admin/organizations/:id/verification/reject
Authorization: Bearer <admin_token>
Content-Type: application/json
{
  "review_feedback": { "message": "Missing required documents" }
}
```

```
POST /admin/organizations/:id/verification/request_modification
Authorization: Bearer <admin_token>
Content-Type: application/json
{
  "review_feedback": { "message": "Please upload a clearer business license" }
}
```

**Notes:**
- `approve` does not require feedback
- `reject` and `request_modification` **require** `review_feedback.message`
- Admin cannot self-review (if admin is also an org member, the request is blocked)
- Approval sets `verification_status = "verified"` and `verified_at`
- Rejection sets `verification_status = "rejected"` and stores the feedback message
- Modification request sets `verification_status = "pending"` and stores the feedback message
- All actions are audited

**Authorization:** `Admin::VerificationPolicy` checks `super_admin?` or `has_permission?("verifications.*")`.

---

### Flow F: Transfer Ownership (Admin)

```
POST /admin/organizations/:id/transfer_ownership
Authorization: Bearer <admin_token>
{
  "organization": { "new_owner_id": "<uuid>" }
}
```

**What happens:**
1. Current owner is demoted to `admin` (via `update_column` to bypass sole-owner callback)
2. Target user is promoted to `owner`
3. If target has no membership, one is created (with race-condition handling)

**Authorization:** `Admin::OrganizationPolicy#transfer_ownership?` — requires `admin.organization.transfer_ownership` permission.

---

## Testing with Postman

### Setup

1. Import `postman/Digis API_collection.json` into Postman
2. Set `baseUrl` variable (e.g., `http://localhost:3000`)
3. Run **Signup** or **Login** to get a token (stored automatically in the collection variable `auth_token`)

### Prerequisites: Two User Types

You'll need two users:

| User | Role | Purpose |
|---|---|---|
| `owner@test.com` | Regular user | Creates org, uploads docs, submits for verification |
| `admin@test.com` | Admin/Super Admin | Reviews verification |

1. **Signup both users** via `POST /auth/signup`
2. **Assign admin role** to `admin@test.com` via `POST /admin/users/:id/roles`
3. Login as each user to get their token (Postman will auto-save)

### Test Flow

**Step 1: Owner creates an organization**

Postman: **My Account > My Organizations > Create Organization (Owner)**

```
POST {{baseUrl}}/organizations/owner
{
  "organization": {
    "name": "My Event Co {{$randomUUID}}",
    "organizer_type": "company",
    "category": "music",
    "estimated_audience": "under_100"
  }
}
```

Copy the returned `id` — this is your `organization_id`.

**Step 2: Owner uploads documents**

Postman: **My Account > My Organizations > Upload Documents**

```
PATCH {{baseUrl}}/organizations/owner/:organization_id/documents
```
Select the org and attach 4 files (profile image, banner image, business_license PDF, tin_certificate PDF).

**Step 3: Owner submits for verification**

Postman: **My Account > My Organizations > Verification > Submit for Verification**

```
POST {{baseUrl}}/organizations/owner/:organization_id/verification/submit
```

If `estimated_audience` was `under_100` or `100_500`, this auto-approves. Check the response — `verification_status` will be `"verified"`. Done!

For larger audiences, it goes to `"pending"` — continue to Step 4.

**Step 4 (if pending): Admin reviews**

Switch to admin token. Postman: **Admin > Organizations > Verification > Approve Verification**

```
POST {{baseUrl}}/admin/organizations/:id/verification/approve
```

**Step 5 (optional): Admin rejects or requests modification**

```
POST {{baseUrl}}/admin/organizations/:id/verification/reject
{
  "review_feedback": { "message": "Business license is unclear" }
}
```

Owner can then **resubmit** (after fixing the issue).

**Step 6: Test role hierarchy**

Postman: **My Account > My Organizations > Memberships > Create Owner Membership**

As the owner, create a member:
```json
{ "membership": { "user_id": "<other_user_id>", "role": "admin" } }
```

Try creating an `owner` role — should return `422`. Try deleting the owner's own membership — should return `422`.

---

##  API Reference (Owner Routes)

| Method | Path | Description | Auth |
|---|---|---|---|
| `GET` | `/organizations/owner` | List my organizations | Owner token |
| `GET` | `/organizations/owner/:organization_id` | Get my org details | Owner token |
| `POST` | `/organizations/owner` | Create organization | Any authenticated |
| `PATCH` | `/organizations/owner/:organization_id` | Update organization | Owner/Admin member |
| `DELETE` | `/organizations/owner/:organization_id` | Delete organization | Owner/SuperAdmin |
| `PATCH` | `/organizations/owner/:organization_id/documents` | Upload documents | Owner/SuperAdmin |
| `GET` | `/organizations/owner/:organization_id/documents/:document_type` | Download document | Owner/SuperAdmin |
| `GET` | `/organizations/owner/:organization_id/memberships` | List members | Active member |
| `POST` | `/organizations/owner/:organization_id/memberships` | Create member | Owner/Admin |
| `PATCH` | `/organizations/owner/:organization_id/memberships/:id` | Update member | Owner/Admin |
| `DELETE` | `/organizations/owner/:organization_id/memberships/:id` | Remove member | Owner/Admin |
| `PATCH` | `/organizations/owner/:organization_id/memberships/:id/suspend` | Suspend member | Owner/Admin |
| `PATCH` | `/organizations/owner/:organization_id/memberships/:id/activate` | Activate member | Owner/Admin |
| `POST` | `/organizations/owner/:organization_id/verification/submit` | Submit for verification | Owner/Admin member |
| `POST` | `/organizations/owner/:organization_id/verification/resubmit` | Resubmit after rejection/modify | Owner/Admin member |

##  API Reference (Admin Routes)

| Method | Path | Description | Auth |
|---|---|---|---|
| `GET` | `/admin/organizations` | List all orgs | Admin |
| `POST` | `/admin/organizations` | Create org (with owner_id) | Admin |
| `PATCH` | `/admin/organizations/:id` | Update any org | Admin |
| `DELETE` | `/admin/organizations/:id` | Delete any org | Admin |
| `POST` | `/admin/organizations/:id/transfer_ownership` | Transfer org ownership | Admin |
| `POST` | `/admin/organizations/:id/verification/approve` | Approve verification | Admin |
| `POST` | `/admin/organizations/:id/verification/reject` | Reject verification | Admin |
| `POST` | `/admin/organizations/:id/verification/request_modification` | Request modification | Admin |
| `GET` | `/admin/organizations/:id/memberships` | List all memberships | Admin |
| `POST` | `/admin/organizations/:id/memberships` | Create membership | Admin |
| `PATCH` | `/admin/organizations/:id/memberships/:id` | Update membership | Admin |
| `DELETE` | `/admin/organizations/:id/memberships/:id` | Delete membership | Admin |

##  Public Routes

| Method | Path | Description | Auth |
|---|---|---|---|
| `GET` | `/organizations` | List verified organizations | None |
| `GET` | `/organizations/:id` | Get public org details | None |

---

## Key Model Validations

### Organization

| Field | Rules |
|---|---|
| `name` | Required, unique |
| `slug` | Required, unique (auto-generated from name) |
| `organizer_type` | Required, one of: `individual`, `company`, `ngo`, `government`, `collective` |
| `category` | Required, one of: `music`, `sports`, `conference`, `comedy`, `theater`, `festival`, `workshop`, `exhibition`, `other` |
| `estimated_audience` | Optional, one of: `under_100`, `100_500`, `500_1000`, `1000_5000`, `5000_plus` |
| `event_frequency` | Optional, one of: `one_time`, `monthly`, `quarterly`, `weekly`, `seasonal` |
| `verification_status` | Enum: `unverified`, `pending`, `verified`, `rejected` |
| `verified_at` | Required if verified, absent otherwise |
| `last_rejection_feedback` | Required if rejected, absent if verified |

### Membership

| Field | Rules |
|---|---|
| `role` | Required, one of: `owner`, `admin`, `staff`. Only one `owner` per org (DB constraint). |
| `status` | Required, one of: `active`, `suspended` |
| `user_id` + `organization_id` | Unique together |

### Sole-Owner Guardrails (model-level callbacks)

- `prevent_sole_owner_suspension` — cannot suspend the last active owner
- `prevent_sole_owner_demotion` — cannot demote the last active owner from owner role
- `prevent_sole_owner_removal` — cannot destroy the last active owner membership

---

## Security Model

### Authorization Layers

Each request goes through up to 3 checks:

1. **Authentication** — JWT token required (except public routes)
2. **Pundit Policy** — record-level authorization per action
3. **Custom Authorization** — additional guards (e.g., `self_review_attempt?`, `owner_enforcement_failed?`)

### Policy Files

| Policy | Used By | Key Methods |
|---|---|---|
| `Organizations::OrganizationPolicy` | Owner org controller | `index?`, `show?`, `create?` (all true), `update?`, `destroy?`, `download_documents?` (owner/super_admin) |
| `Organizations::MembershipPolicy` | Owner membership controller | `index?` (active member), `create?`/`update?`/`destroy?`/`suspend?`/`activate?` via `can_manage?` |
| `Organizations::VerificationPolicy` | Owner verification controller | `submit?`, `resubmit?` (owner/admin member) |
| `Admin::OrganizationPolicy` | Admin org controller | Delegates to `allowed?(:action)` permission check |
| `Admin::MembershipPolicy` | Admin membership controller | Delegates to permission checks |
| `Admin::VerificationPolicy` | Admin verification controller | `approve?`, `reject?`, `request_modification?` via `verifications.*` permissions |

### Roles vs Permissions

- **Admin roles** (`SUPER_ADMIN`, `ADMIN`, `SUPPORT`) control access to admin endpoints via permissions
- **Org roles** (`owner`, `admin`, `staff`) control access within an organization via `MembershipPolicy#can_manage?`
- These are **independent** — an admin user may have no org memberships, and an org owner may have no admin permissions

---

## Running Tests

```bash
rails test
```

Expected: `715 tests, 1478 assertions, 0 failures, 0 errors`

Relevant test files:
- `test/integration/organizations/owner_organizations_test.rb`
- `test/integration/organizations/owner_memberships_test.rb`
- `test/integration/admin/organizations_test.rb`
- `test/integration/admin/organization_memberships_test.rb`
- `test/models/organizations/organization_test.rb`
- `test/models/organizations/membership_test.rb`
