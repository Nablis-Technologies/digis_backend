# Organizations Domain — Design Spec

## Overview

Allow a user (with global `USER` role) to create and manage organizations. MVP supports solo organizers — one owner per org, no team management yet. The schema is designed to accommodate team memberships and org-level permissions in the future without migrations.

---

## Models & Schema

### `organizations_organizations`

| Column      | Type     | Constraints              |
|-------------|----------|--------------------------|
| id          | uuid     | PK, default `uuidv7()`   |
| name        | string   | not null                 |
| slug        | string   | not null, unique         |
| description | text     | nullable                 |
| created_at  | datetime | not null                 |
| updated_at  | datetime | not null                 |

- Includes `Core::AuditableModel`
- Includes `Core::Slugable` (source: `:name`, target: `:slug`)
- Has many `memberships` (class: `Organizations::Membership`, dependent: :destroy)
- Has one `owner_membership` -> `memberships` where role is owner (scope/association)
- Defines `owner` helper: `owner_membership&.user`
- Validates presence of `name`
- Validates uniqueness of `slug`

### `organizations_memberships`

| Column          | Type     | Constraints                       |
|-----------------|----------|------------------------------------|
| id              | uuid     | PK, default `uuidv7()`             |
| user_id         | uuid     | FK to `core_users`, not null       |
| organization_id | uuid     | FK to `organizations_organizations`, not null |
| role            | integer  | enum, not null                     |
| created_at      | datetime | not null                           |
| updated_at      | datetime | not null                           |

**Unique constraint**: `(user_id, organization_id)`

**Partial unique index** (enforces one owner per org at DB level):
```sql
CREATE UNIQUE INDEX idx_one_owner_per_org
  ON organizations_memberships (organization_id)
  WHERE role = 0;
```

**Validation** (enforces one owner per org at model level):
```ruby
validates :role, uniqueness: { scope: :organization_id, message: "already exists for this organization" },
         if: -> { owner? }
```

**Role enum**:
- `0` = `owner`
- `1` = `admin` (future)
- `2` = `member` (future)

- Belongs to `user` (Core::User)
- Belongs to `organization` (Organizations::Organization)
- Validates presence of `role`

### Future: `OrganizationPermission`

When granular access control is needed (custom roles, per-feature permissions within an org), add a join/permission table:

```
organizations_organization_permissions
  id (uuid)
  organization_id (uuid, FK)
  permission_code (string)  — e.g. "event.create", "member.invite"
  role (integer, enum matching Membership.role)
```

This allows mapping "admin role can create events in this org" without code changes. Not implemented in MVP.

---

## Authorization

### `Organizations::OrganizationPolicy`

| Action   | Owner | Super Admin | Other |
|----------|-------|-------------|-------|
| index    | yes   | yes         | no    |
| show     | yes   | yes         | no    |
| create   | any   | yes         | any   |
| update   | yes   | yes         | no    |
| destroy  | yes   | yes         | no    |

- `index?`: `true` for any authenticated user — the real filtering is in `Scope` (matches existing pattern, e.g., `Events::CategoryPolicy#index?` is also just `true`)
- `show?`: owner OR super_admin
- `create?`: any authenticated user
- `update?`/`destroy?`: owner OR super_admin

**Scope**: restricts to organizations where user has an owner membership; super_admin sees all.

### `Organizations::MembershipPolicy`

| Action   | Org Owner | Super Admin | Other |
|----------|-----------|-------------|-------|
| index    | yes       | yes         | no    |
| show     | yes       | yes         | no    |
| create   | yes       | yes         | no    |
| update   | yes       | yes         | no    |
| destroy  | yes       | yes         | no    |

All actions: org owner OR super_admin. For nested `index`, `Core::Common` builds a blank membership through `@parent` before authorizing, so `MembershipPolicy#index?` receives a record with `organization_id` set (see `Core::Common` improvements below). For other actions, the record is built/loaded through the parent and carries org context, so `record.organization.owner == user` works via the `Organization#owner` helper.

---

## API Endpoints

```
namespace :organizations do
  resources :organizations, except: %i[new edit] do
    resources :memberships, except: %i[new edit], controller: "memberships"
  end
end
```

### Organizations

| Method | Path                          | Action | Auth Required |
|--------|-------------------------------|--------|---------------|
| GET    | /organizations/organizations  | index  | yes           |
| GET    | /organizations/organizations/:id | show | yes         |
| POST   | /organizations/organizations  | create | yes           |
| PATCH  | /organizations/organizations/:id | update | yes        |
| DELETE | /organizations/organizations/:id | destroy | yes       |

### Memberships

| Method | Path                                                                 | Action | Auth Required |
|--------|----------------------------------------------------------------------|--------|---------------|
| GET    | /organizations/organizations/:organization_id/memberships            | index  | yes           |
| GET    | /organizations/organizations/:organization_id/memberships/:id        | show   | yes           |
| POST   | /organizations/organizations/:organization_id/memberships            | create | yes           |
| PATCH  | /organizations/organizations/:organization_id/memberships/:id        | update | yes           |
| DELETE | /organizations/organizations/:organization_id/memberships/:id        | destroy | yes           |

---

## Controller Patterns

### `Organizations::OrganizationsController`

- Includes `Core::Common` and `Core::AuditableController`
- `self.model_class = Organizations::Organization`
- Uses `after_create_hook` to create the owner membership on creation:

```ruby
module Organizations
  class OrganizationsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Organizations::Organization
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:organization).permit(:name, :description)
    end

    def after_create_hook(organization)
      organization.memberships.create!(user: current_user, role: :owner)
    end
  end
end
```

- `after_create_hook` runs inside `Core::Common#create`'s transaction, so the organization and owner membership are created atomically.

### `Organizations::MembershipsController`

Uses `Core::Common` with `parent_class` for nested resource support:

```ruby
module Organizations
  class MembershipsController < Organizations::ApplicationController
    include Core::Common
    self.model_class = Organizations::Membership
    self.parent_class = Organizations::Organization
    # parent_param and parent_association use defaults:
    #   parent_param → :organization_id (from parent_class.model_name.singular)
    #   parent_association → :memberships (from @clazz.model_name.plural)

    private

    def model_params
      params.require(:membership).permit(:user_id, :role)
    end
  end
end
```

No custom actions needed — `Core::Common` handles CRUD with parent scoping (see `Core::Common` improvements below).

---

## `Core::Common` Improvements for Nested Resources

A new class attribute `parent_class` (plus optional `parent_param` and `parent_association`) enables nested resource mode:

```ruby
class_attribute :parent_class, default: nil       # e.g. Organizations::Organization
class_attribute :parent_param, default: nil       # e.g. :organization_id (derived if nil)
class_attribute :parent_association, default: nil # e.g. :memberships (derived if nil)
```

When set (e.g., `self.parent_class = Organizations::Organization`), the concern's behavior changes:

### Parent loading (new `before_action`)
```ruby
before_action :set_clazz
before_action :set_parent
before_action :set_object, only: %i[show update destroy]

def set_parent
  return unless self.class.parent_class

  param_name = self.class.parent_param || :"#{self.class.parent_class.model_name.singular}_id"
  @parent = self.class.parent_class.find(params[param_name])
end
```
Runs before `set_object` so `@parent` is available for scoped loading. Returns early when `parent_class` is not set (existing controllers unaffected). `parent_param` defaults to the standard Rails convention (e.g., `:organization_id`).

### `set_object` — scoped loading with eager loading
```ruby
def set_object
  if self.class.parent_class
    @obj = @parent.public_send(child_association)
            .includes(eager_loaded_associations)
            .find(params[:id])
  else
    @obj = @clazz.includes(eager_loaded_associations).find(params[:id])
  end
end

def child_association
  self.class.parent_association || @clazz.model_name.plural.to_sym
end
```
Existing top-level controllers are unaffected since `parent_class` defaults to `nil`. `parent_association` defaults to the model's plural (works for standard names, overridable for irregular ones).

### `create` — build through parent, then authorize

The current `Core::Common#create` authorizes `@clazz.new` (a blank record) before building the object. In nested mode the object must be built first so the foreign key is set, then authorized:

```ruby
def create
  object = if self.class.parent_class
    @parent.public_send(child_association).new(model_params)
  else
    @clazz.new(model_params)
  end

  authorize object unless skip_authorization_for_action?

  # ... rest of create (saves inside transaction, renders response)
end
```

Building through `@parent.memberships.new(...)` sets `organization_id` on the record, so `MembershipPolicy#create?` receives a record with org context.

### `index` — authorize child with parent context, scope through parent

In nested mode the `index` action builds a blank child record through `@parent` first (setting the foreign key), then authorizes with `MembershipPolicy#index?`. Non-owners receive 403 because the policy checks `record.organization_id` for ownership:

```ruby
def index
  if self.class.parent_class
    authorize @parent.public_send(child_association).new, :index?
  else
    authorize @clazz.new, :index? unless skip_authorization_for_action?
  end

  data = if self.class.parent_class
    policy_scope(@parent.public_send(child_association))
  else
    policy_scope(@clazz)
  end
  # ...
end
```

### Authorization flow for nested resources

- **`index`**: builds `@parent.memberships.new` (blank record with `organization_id` set), then `authorize(record, :index?)` → `MembershipPolicy#index?` checks `record.organization_id` for ownership
- **`create`**: builds `@parent.memberships.new(params)` first (record gets `organization_id`), THEN `authorize(record)` — `MembershipPolicy#create?` sees org context
- **`show`/`update`/`destroy`**: `@parent.memberships.find(id)` → record has `organization_id` → `authorize(record)` with org context

All existing controllers (`Events::EventsController`, etc.) continue using top-level mode with no changes.

---

## Serializers

### `Organizations::OrganizationSerializer`

Attributes: `name`, `slug`, `description`, `created_at`

Includes: `memberships` (when appropriate for the action/role)

### `Organizations::MembershipSerializer`

Attributes: `role`, `created_at`

Belongs to: `user`

Both serializers include `Core::AttributeVisibilitySerializer` for per-role field visibility.

---

## Testing

- Generated via `Core::ResourceTest` concern for standard CRUD + permission tests
- Two fixture roles: one organization, one membership linking a user as owner
- Additional test verifying `after_create_hook` creates the owner membership on organization creation
- Visibility test: membership.user details visible to org owner, hidden to others

---

## Future Extensions

1. **Team memberships**: Add `:admin` and `:member` values to the role enum. Policies evolve to check membership role levels. No schema migrations needed.

2. **Granular org permissions**: Add `OrganizationPermission` model (see schema above) to map roles to specific permission codes within an org. This allows creating custom org roles without code changes.

3. **Multi-org support**: A user can belong to multiple organizations with different roles in each. No schema changes needed — the unique constraint on `(user_id, organization_id)` already handles this.

4. **Org-scoped data models**: Future domain modules (e.g., `Organizations::Event`) can belong to an organization and use the membership system for authorization.
