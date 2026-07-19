# Admin Organizations Platform Surface

**Date:** 2026-05-31
**Status:** Draft
**Author:** AI-assisted design

## Overview

Add a true platform backoffice surface under `Admin::` for managing organizations without collapsing tenant ownership and platform authority into the same namespace.

The repo already has:
- public organization read endpoints under `Organizations::OrganizationsController`
- tenant-owned organization CRUD under `Organizations::OwnerOrganizationsController`
- organization memberships with `owner`, `admin`, and `member` roles

This spec adds a separate `/admin/organizations` surface for platform staff. Platform access is controlled by platform roles plus explicit permissions, while tenant access continues to be controlled by organization memberships.

The design goal is:
- keep tenant authority and platform authority separate
- let platform staff help when needed
- reserve destructive and high-risk powers for `SUPER_ADMIN`
- audit every admin write

---

## 1. Role Model

There are now three distinct access layers:

### 1a. Public

Unauthenticated or general authenticated users can consume public organization listing and detail endpoints.

This remains the responsibility of the existing public organization controllers/serializers.

### 1b. Organization Roles

These roles live in `Organizations::Membership` and govern tenant-side authority inside a specific organization:
- `owner`
- `admin`
- `member`

These roles do **not** grant access to `/admin/organizations`.

### 1c. Platform Roles

These roles govern platform backoffice authority:
- `SUPPORT`
- `CORE_ADMIN`
- `SUPER_ADMIN`

Platform authority is permission-driven. `SUPER_ADMIN` remains the ultimate override, but `SUPPORT` and `CORE_ADMIN` only receive the actions explicitly seeded for them.

Important naming rule:
- organization `admin` is a tenant membership role
- `CORE_ADMIN` is a platform role

They must never be treated as interchangeable in policies, serializers, or tests.

---

## 2. Namespace And Routing

Keep the current split and extend it:

- `/organizations/...` remains tenant-facing
- `/admin/organizations/...` becomes platform-facing

Add to `config/routes.rb`:

```ruby
namespace :admin do
  resources :organizations, except: %i[new edit] do
    member do
      post :transfer_ownership
    end

    resources :memberships, only: %i[index create update destroy],
              controller: "organization_memberships"
  end
end
```

Rationale:
- `transfer_ownership` is a high-risk domain action and should be explicit
- nested membership management keeps admin-side team operations inside the admin namespace
- tenant membership management remains separate from platform membership management even if they operate on the same underlying model

---

## 3. Controller Architecture

### 3a. `Admin::OrganizationsController`

Add a new controller following the existing admin CRUD pattern:

```ruby
module Admin
  class OrganizationsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Organization

    auditable on: %i[create update destroy transfer_ownership]
  end
end
```

Responsibilities:
- `index`, `show`, `create`, `update`, `destroy`
- `transfer_ownership`
- admin-focused ordering, filtering, and serialization

Recommended controller behavior:
- `allowed_order_columns` should include `name` and `slug` so the admin list can sort consistently with the existing owner/admin organization surfaces
- `apply_index_scope` should use `with_attached_profile` and preload owner data for the admin list, preferably via `includes(owner_membership: :user)`; if the index response later includes full membership collections, expand that preload intentionally rather than defaulting to a broad `includes(:memberships)`
- `model_params` should permit the same current organization attributes as tenant-side management: `name`, `description`, `profile`, and `social_links`
- use an admin serializer rather than reusing the public serializer contract

### 3b. `Admin::OrganizationMembershipsController`

Add a nested admin controller for organization membership operations:

```ruby
module Admin
  class OrganizationMembershipsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Membership
    self.parent_class = Organizations::Organization
    self.parent_param = :organization_id
    self.parent_association = :memberships

    auditable on: %i[create update destroy]
  end
end
```

Responsibilities:
- list memberships for an organization
- add `admin` and `member` memberships
- update non-owner membership roles when allowed
- remove memberships when allowed

Important constraint:
- this controller must **not** be used to promote someone to `owner`
- ownership transfer is handled only by `Admin::OrganizationsController#transfer_ownership`

That separation keeps the single-owner rule explicit and easier to audit.

---

## 4. Permission Model

Add these permission codes:

| Code | Purpose |
|---|---|
| `organization.index` | List organizations in admin |
| `organization.show` | View organization details in admin |
| `organization.create` | Create organizations from admin |
| `organization.update` | Edit organizations from admin |
| `organization.destroy` | Delete organizations from admin |
| `organization.manage_memberships` | Manage org memberships from admin |
| `organization.transfer_ownership` | Transfer org ownership from admin |

### Recommended role matrix

| Code | SUPPORT | CORE_ADMIN | SUPER_ADMIN |
|---|---|---|---|
| `organization.index` | ✓ | ✓ | ✓ |
| `organization.show` | ✓ | ✓ | ✓ |
| `organization.create` |  | ✓ | ✓ |
| `organization.update` |  | ✓ | ✓ |
| `organization.destroy` |  |  | ✓ |
| `organization.manage_memberships` |  | ✓ | ✓ |
| `organization.transfer_ownership` |  |  | ✓ |

Rules:
- `SUPPORT` is read-only on organizations
- `CORE_ADMIN` can help operate organizations but cannot perform irreversible or ownership-level actions
- `SUPER_ADMIN` gets full override

This keeps platform support useful without turning every staff role into a global owner.

---

## 5. Policy Design

### 5a. `Admin::OrganizationPolicy`

Add a dedicated admin policy instead of extending `Organizations::OrganizationPolicy`.

Suggested behavior:

```ruby
module Admin
  class OrganizationPolicy < Core::ApplicationPolicy
    def index? = allowed?(:index)
    def show? = allowed?(:show)
    def create? = allowed?(:create)
    def update? = allowed?(:update)
    def destroy? = allowed?(:destroy)

    def transfer_ownership?
      allowed?(:transfer_ownership)
    end
  end
end
```

Reason:
- tenant policy semantics answer "can this member act in their org?"
- admin policy semantics answer "can this platform user intervene globally?"

Those are different questions and should not live in one policy class.

### 5b. `Admin::OrganizationMembershipPolicy`

Add a dedicated admin membership policy mapped to `Organizations::Membership` inside the admin namespace.

Suggested behavior:
- `index?`: require `organization.show` or `organization.manage_memberships`
- `create?`, `update?`, `destroy?`: require `organization.manage_memberships`
- reject owner-role mutations in the ordinary CRUD actions

### 5c. Scope behavior

`Admin::OrganizationPolicy::Scope` should resolve as follows:
- `SUPER_ADMIN`: `scope.all`
- users with `organization.index` or `organization.show`: `scope.all`
- everyone else: `scope.none`

This mirrors the pattern already used in `Admin::UserPolicy`, where read-capable platform users can access the full admin collection while users without admin permission see nothing.

### 5d. Visibility

Create an admin-specific serializer contract and policy visibility map.

Recommended admin-visible fields:
- `id`
- `name`
- `slug`
- `description`
- `social_links`
- `followers_count`
- `created_at`
- `updated_at`
- `owner`
- `memberships_count`

If profile attachments or owner details are included, make that inclusion explicit in the serializer/profile contract rather than relying on public serializer behavior.

---

## 6. Ownership And Membership Rules

These rules should be explicit in the implementation and tests.

### 6a. Admin-side organization creation

When a platform admin creates an organization, the request must include an initial owner.

Recommended API shape:

```json
{
  "organization": {
    "name": "Example Org",
    "description": "Backoffice-created org",
    "owner_id": "uuid-of-existing-user"
  }
}
```

Behavior:
- create the organization
- create the owner membership in the same transaction
- fail with `422` if `owner_id` is missing or invalid

This avoids orphaned organizations and keeps ownership explicit from day one.

Implementation note:
- plain `Core::Common#create` does not know about `owner_id`
- use the existing repo pattern from `Organizations::OwnerOrganizationsController`: create the organization first, then create the owner membership in `after_create_hook`
- because `after_create_hook` runs inside the `Core::Common#create` transaction, this still keeps organization creation and owner assignment atomic

### 6b. Membership management

Admin-side membership CRUD may manage:
- `admin`
- `member`

It may not:
- create a second owner via normal membership create/update
- remove the only owner
- demote the current owner through generic membership update

Those transitions belong only in the dedicated ownership-transfer action.

### 6c. Ownership transfer

`transfer_ownership` must be a dedicated, transactional operation available only to `SUPER_ADMIN`.

Recommended request shape:

```json
{
  "organization": {
    "new_owner_id": "uuid-of-existing-user"
  }
}
```

Behavior:
- lock the organization and relevant memberships
- ensure `new_owner_id` is an existing user
- convert the existing owner membership to `admin`
- convert or create the target membership as `owner`
- preserve the invariant that exactly one owner exists at the end of the transaction

If the target user is already a member, upgrade that membership to `owner`.
If the target user is not a member, create a new owner membership.

### 6d. Destruction

`destroy` should stay restricted to `SUPER_ADMIN`.

Current recommendation:
- use existing destroy semantics for now
- if organizations become more heavily referenced later, reassess whether destroy should become a soft-delete/archive operation instead

That soft-delete decision is intentionally out of scope for this spec.

---

## 7. Audit Requirements

All admin writes must be auditable.

Minimum audited actions:
- `organization.create`
- `organization.update`
- `organization.destroy`
- `organization.transfer_ownership`
- membership `create`
- membership `update`
- membership `destroy`

### Audit data expectations

For ordinary updates, the existing `Core::AuditableController` snapshot/diff flow is sufficient.

For high-risk actions, enrich the audit payload or action labeling with:
- actor id
- organization id
- previous owner id
- new owner id
- membership changes applied
- key field diffs

Recommended audit action names:
- `"admin.organization.create"`
- `"admin.organization.update"`
- `"admin.organization.destroy"`
- `"admin.organization.transfer_ownership"`
- `"admin.organization_membership.create"`
- `"admin.organization_membership.update"`
- `"admin.organization_membership.destroy"`

The goal is for audit logs to make platform intervention obvious and reviewable after the fact.

---

## 8. Error Handling

Use the same response semantics as the rest of the platform:

- `401` when unauthenticated
- `403` when authenticated but missing permission
- `404` when the organization or membership cannot be found
- `422` when the request violates business rules or validations

Examples of `422` cases:
- admin create without `owner_id`
- transfer ownership to a nonexistent user
- attempting to assign a second owner through membership CRUD
- attempting to remove the only owner

Do not hide authorization failures inside generic validation responses.
Permission denials should stay clear `403`s.

---

## 9. Serialization

Add `Admin::OrganizationSerializer` under the existing `app/serializers/admin/` namespace.

Do not reuse:
- `Organizations::Public::OrganizationListSerializer`
- `Organizations::Public::OrganizationDetailSerializer`
- tenant-facing `Organizations::OrganizationSerializer` as the long-term admin contract

Reason:
- admin responses will diverge from public responses
- admin payloads often need owner/membership context
- the repo already uses `app/serializers/admin/` for `UserSerializer`, `RoleSerializer`, and `PermissionSerializer`, so organization admin serialization should follow that convention
- keeping a separate serializer reduces accidental contract drift

Suggested fields:
- `id`
- `name`
- `slug`
- `description`
- `social_links`
- `followers_count`
- `created_at`
- `updated_at`
- `profile_url`
- `owner`

Optional included associations:
- `memberships`

For `index`, keep payloads light by default.
For `show`, include the owner and memberships so backoffice staff can inspect org state without additional follow-up queries.

---

## 10. Testing Strategy

Add targeted tests in the admin namespace.

### 10a. Integration tests

Add:
- `test/integration/admin/organizations_test.rb`
- `test/integration/admin/organization_memberships_test.rb`

Cover:
- authentication required
- permission matrix for `SUPPORT`, `CORE_ADMIN`, `SUPER_ADMIN`
- `SUPPORT` read-only behavior
- `CORE_ADMIN` allowed create/update/membership management
- `CORE_ADMIN` forbidden destroy/ownership transfer
- `SUPER_ADMIN` full access
- owner assignment on admin create
- transfer ownership happy path and failure cases
- membership CRUD refusal for owner-role mutations
- audit creation on every write action

### 10b. Policy tests

Add:
- policy scope coverage for `Admin::OrganizationPolicy`
- action matrix coverage for `Admin::OrganizationPolicy`
- action matrix coverage for `Admin::OrganizationMembershipPolicy`

Use the existing policy testing helpers/patterns already present in the repo.

### 10c. Regression tests

Verify tenant and platform boundaries remain separate:
- an organization owner without platform permissions cannot access `/admin/organizations`
- a platform admin without membership in an org can still access the admin surface if permitted
- public organization endpoints continue to work unchanged
- tenant owner flows continue to work unchanged

---

## 11. Implementation Notes

This feature should build on existing shared foundations rather than invent new controller infrastructure.

Use:
- `Admin::ApplicationController` for policy resolution
- `Core::Common` for CRUD scaffolding and nested resource support
- `Core::AuditableController` for audit capture

Do not:
- merge platform and tenant policies
- treat organization membership roles as platform permissions
- allow owner transitions through generic membership CRUD
- bypass audit logging for admin write paths

---

## 12. Recommended Build Order

1. Seed permissions for organization admin actions.
2. Add `Admin::OrganizationPolicy` and `Admin::OrganizationMembershipPolicy`.
3. Add routes for `/admin/organizations` and nested admin memberships.
4. Implement `Admin::OrganizationsController`.
5. Implement `Admin::OrganizationMembershipsController`.
6. Add `Admin::OrganizationSerializer`.
7. Add `transfer_ownership` transactional logic.
8. Add integration and policy tests.
9. Verify audit records for each write path.

---

## Final Recommendation

Implement organization management as a true dual-surface system:
- tenant-side ownership under `Organizations::`
- platform-side intervention under `Admin::`

Keep destructive and ownership-level powers narrow, permission-driven, and heavily audited. `SUPER_ADMIN` is the only universal override. `CORE_ADMIN` is operationally helpful but intentionally limited. `SUPPORT` remains read-only.
