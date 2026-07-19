# Spec: Owner Membership Endpoints

**Date**: 2026-06-03
**Status**: Draft
**Author**: opencode
**Depends On**: `2026-05-29-organizations-social-features.md`

---

## Overview

The owner organizations controller at `/organizations/owner` provides CRUD for organizations the current user is a member of, but has no way to manage that organization's members. This spec adds membership management endpoints under the owner path.

Currently, an org owner can manage memberships via `/organizations/:organization_id/memberships` (the public route under `resources :organizations`), which is already authorized by `Organizations::MembershipPolicy` to allow org owners. But there's no equivalent under the natural owner path `/organizations/owner/:id/memberships`, which is where owners intuitively expect to find member management.

---

## 1. Gap Analysis

| Endpoint | Exists? | Notes |
|----------|---------|-------|
| `GET    /organizations/owner/:owner_organization_id/memberships` | No | Owner cannot list members |
| `GET    /organizations/owner/:owner_organization_id/memberships/:id` | No | Owner cannot view member detail |
| `POST   /organizations/owner/:owner_organization_id/memberships` | No | Owner cannot invite members |
| `PATCH  /organizations/owner/:owner_organization_id/memberships/:id` | No | Owner cannot change roles |
| `DELETE /organizations/owner/:owner_organization_id/memberships/:id` | No | Owner cannot remove members |

The same operations exist at `/organizations/:organization_id/memberships` (authorized by `MembershipPolicy` — owner-gated), but the owner path is completely blind to them.

---

## 2. Design

### 2.1 Approach: Extract `Core::MembershipManagement` concern

The proposed owner controller and `Admin::MembershipsController` are nearly identical — same `model_class`, `parent_class`, `parent_association`, `auditable on:`, owner-role guards in create/update, `model_params`, `allowed_order_columns`, and `serializer_profile`. The only differences are `parent_param` (`:organization_id` vs `:owner_organization_id`) and the owner's self-destruction guard.

Extract a shared concern to eliminate duplication:

```ruby
# app/controllers/concerns/core/membership_management.rb
module Core
  module MembershipManagement
    extend ActiveSupport::Concern

    included do
      self.model_class = Organizations::Membership
      self.parent_class = Organizations::Organization
      self.parent_association = :memberships

      auditable on: %i[create update destroy]
    end

    def create
      return render_owner_role_guard if params.dig(:membership, :role) == "owner"
      super
    end

    def update
      return render_owner_role_guard if params.dig(:membership, :role) == "owner"
      super
    end

    private

    def render_owner_role_guard
      render_error(message: :"membership.errors.owner_role_assignment", status: :unprocessable_entity)
    end

    def model_params
      params.require(:membership).permit(:user_id, :role)
    end

    def allowed_order_columns
      %w[id role created_at updated_at]
    end

    def serializer_profile
      {
        default: { fields: %i[id role created_at updated_at], include: %i[user] },
        index:   { fields: %i[id role created_at updated_at], include: %i[user] },
        show:    { fields: %i[id role created_at updated_at], include: %i[user] },
        create:  { fields: %i[id role created_at updated_at], include: %i[user] },
        update:  { fields: %i[id role created_at updated_at], include: %i[user] }
      }
    end
  end
end
```

### 2.2 Controllers

Both `Admin::MembershipsController` and the new `Organizations::OwnerMembershipsController` become thin wrappers:

```ruby
# app/controllers/admin/memberships_controller.rb
module Admin
  class MembershipsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::MembershipManagement

    self.parent_param = :organization_id
  end
end
```

```ruby
# app/controllers/organizations/owner_memberships_controller.rb
module Organizations
  class OwnerMembershipsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::MembershipManagement

    self.parent_param = :owner_organization_id

    def destroy
      if @obj.role == "owner" && @obj.user_id == current_user.id
        return render_error(errors: ["Transfer ownership before leaving the organization"], status: :unprocessable_entity)
      end
      super
    end
  end
end
```

The concern does NOT include `Core::Common` or `Core::AuditableController` in its `included` block — they're included explicitly by each controller. This ensures the concern's method overrides (`model_params`, `allowed_order_columns`, `serializer_profile`) sit above `Core::Common` in the ancestor chain. The `included` block only sets class attributes (`model_class`, `parent_class`, `parent_association`, `auditable on:`).

The `destroy` override lives only in the owner controller — it prevents an owner from removing their own membership, which would leave the org orphaned. Admin doesn't need this guard (admins operate outside the ownership model).

**I18n**: The concern uses `render_error(message: :"membership.errors.owner_role_assignment", ...)` with a symbol key. `Core::JsonResponse#resolve_message` resolves symbols through `I18n.t()`. Add the key to `config/locales/organizations/membership.en.yml`:

```yaml
en:
  membership:
    errors:
      owner_role_assignment: "Cannot assign owner role through membership management"
```

The auto-resolved keys (`membership.errors.create`, `membership.errors.update`) handle standard CRUD failures — only the custom guard message needs its own key.

**How authorization works:**
- `Core::Common#set_parent` finds the organization via `Organizations::Organization.find(params[:owner_organization_id])` — no owner scope, just a lookup by ID
- `Organizations::MembershipPolicy` then authorizes the action: `record.organization&.owner == user || user.super_admin?`
- Result: 404 (org doesn't exist) vs 403 (exists but user isn't owner) vs 200 + data (authorized)

**Pre-existing info leak**: `Core::Common#set_parent` does a blind `find` before any authorization, so any authenticated user can probe org existence via 404 vs 403 on `/organizations/owner/:some_id/memberships`. Pre-existing in `Core::Common`, not introduced here.

### 2.3 Routes

Add nested memberships under the existing `owner_organizations` resource:

```ruby
scope module: :organizations do
  resources :owner_organizations, only: %i[index show create update destroy],
            path: "organizations/owner" do
    resources :memberships, only: %i[index show create update destroy],
              controller: "owner_memberships"
  end
  # ...
end
```

**Generated routes:**

| Method | URL | Controller#action | Helper |
|--------|-----|-------------------|--------|
| GET | `/organizations/owner/:owner_organization_id/memberships` | `organizations/owner_memberships#index` | `owner_organization_memberships_path(org_id)` |
| GET | `/organizations/owner/:owner_organization_id/memberships/:id` | `organizations/owner_memberships#show` | `owner_organization_membership_path(org_id, id)` |
| POST | `/organizations/owner/:owner_organization_id/memberships` | `organizations/owner_memberships#create` | `owner_organization_memberships_path(org_id)` |
| PATCH | `/organizations/owner/:owner_organization_id/memberships/:id` | `organizations/owner_memberships#update` | `owner_organization_membership_path(org_id, id)` |
| DELETE | `/organizations/owner/:owner_organization_id/memberships/:id` | `organizations/owner_memberships#destroy` | `owner_organization_membership_path(org_id, id)` |

`PUT` routes are also generated for update (Rails default).

**Note on param naming:** The nested route used `owner_organization_id` (from the parent `owner_organizations` resource). The controller's `self.parent_param = :owner_organization_id` aligns with this.

### 2.4 Existing `set_object` in OwnerOrganizationsController

The `OwnerOrganizationsController` has a custom `set_object` that scopes to memberships:

```ruby
def set_object
  @obj = @clazz.joins(:memberships)
               .where(organizations_memberships: { user_id: current_user.id })
               .includes(eager_loaded_associations)
               .find_by!(self.class.resource_param => params[self.class.resource_param])
end
```

This is unrelated to the membership endpoints. The `OwnerMembershipsController` will use `Core::Common`'s default `set_object` (via parent) — no override needed, since the `MembershipPolicy::Scope` and Pundit authorization handle the ownership check.

### 2.5 No new policy needed

`Organizations::MembershipPolicy` already:
- `index?` — allows super_admin or if user has `role: :owner` membership on the org
- `show?` — owner or super_admin
- `create?` — owner or super_admin
- `update?` — owner or super_admin
- `destroy?` — owner or super_admin
- `Scope` — scopes to memberships in orgs where user has `role: :owner`

Reuse as-is.

### 2.6 Ownership guard in create/update

The `"owner"` role guard prevents escalation through membership management (same pattern as `Admin::MembershipsController`). The owner role can only be assigned via:
- `OwnerOrganizationsController#after_create_hook` (auto-assigns to creator)
- Direct database manipulation (admin only)

---

## 3. Route verification

After adding routes, verify with:

```
rails routes | grep -E "owner.*membership|owner_organization.*member"
```

Should produce:

```
owner_organization_memberships  GET|POST  /organizations/owner/:owner_organization_id/memberships
 owner_organization_membership  GET|PATCH|PUT|DELETE  /organizations/owner/:owner_organization_id/memberships/:id
```

---

## 4. Implementation Order

1. Create `app/controllers/concerns/core/membership_management.rb` (extract shared logic)
2. Update `app/controllers/admin/memberships_controller.rb` to include the concern (replace inline code)
3. Create `app/controllers/organizations/owner_memberships_controller.rb` (thin wrapper with concern)
4. Update routes to nest `memberships` under `owner_organizations`
5. Write integration tests in `test/integration/organizations/owner_memberships_test.rb`
   - Unauthenticated: all actions return 401
   - Non-owner authenticated: index returns 403, show/create/update/destroy return 403
   - Owner authenticated: full CRUD succeeds
   - Create with `role: "owner"`: returns 422
   - Update to `role: "owner"`: returns 422
   - Destroy own membership when role is `owner`: returns 422 with "Transfer ownership before leaving the organization"
   - Destroy own membership when role is NOT `owner`: succeeds
   - Block self-removal of last owner: prevents orphan orgs
6. Run full test suite

---

## 5. File Structure

```
app/controllers/
  concerns/
    core/
      membership_management.rb         (new — shared concern)
  admin/
    memberships_controller.rb          (updated — include concern)
  organizations/
    owner_memberships_controller.rb    (new — thin wrapper)
test/integration/organizations/
  owner_memberships_test.rb            (new)
config/routes.rb                       (updated: nested memberships)
```

---

## 6. Existing Workaround

The existing endpoint at `/organizations/:organization_id/memberships` already works for org owners via `MembershipPolicy`. This spec adds a parallel path at `/organizations/owner/:owner_organization_id/memberships` for URL consistency — everything owner-related lives under `/organizations/owner/...`. Owners still need the org ID (obtained from `GET /organizations/owner`), same as the public path. The benefit is discoverability and convention, not eliminating the ID.

---

## 7. Key Design Decisions

1. **Shared concern, not duplicate controller** — `Admin::MembershipsController` and `Organizations::OwnerMembershipsController` share ~95% of their code. Extracting `Core::MembershipManagement` eliminates duplication while keeping both controllers focused on their single difference (`parent_param`).
2. **Owner role guard** — prevents escalation through membership API (same pattern as Admin). Lives in the shared concern.
3. **Self-destruction guard on owner only** — the `destroy` override in `OwnerMembershipsController` prevents orphan orgs. Admin doesn't need this guard.
4. **Auditable** — membership changes are logged (included via concern).
5. **Serializes `user`** — members index/show include user info (name, email), matching Admin behavior rather than the bare public resource.
6. **Reuses `MembershipPolicy`** — no new authorization surface.
7. **Existing `Admin::MembershipsController` is refactored** — inline code replaced with `include Core::MembershipManagement`. No behavioral change, verified by existing tests.
