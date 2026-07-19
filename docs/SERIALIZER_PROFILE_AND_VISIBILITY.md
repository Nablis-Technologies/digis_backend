# Serializer Profile & Visibility System

## Overview

Two independent concerns that were conflated into a single `include:` key:

| Layer | What it does | Controlled by | Policy-gated? |
|-------|-------------|---------------|---------------|
| **SQL preloading** | `ActiveRecord.includes(...)` — prevents N+1 | `eager_load_config` (controller) | No |
| **AMS rendering** | Which `has_many`/`has_one`/`belongs_to` associations appear in JSON | `serializer_profile[:include]` | Yes |

Every attribute in `fields:` is still intersected with the policy's `VISIBILITY` constant.

## Table of Contents

- [The Problem](#the-problem)
- [The Two Layers](#the-two-layers)
- [How the Flow Works](#how-the-flow-works)
- [Policy VISIBILITY Integration](#policy-visibility-integration)
- [Complete Call Flow](#complete-call-flow)
- [Concrete Examples](#concrete-examples)
- [Cookbook: Common Patterns](#cookbook-common-patterns)
- [Best Practices](#best-practices)
- [Configuration Reference](#configuration-reference)

## The Problem

Before, a single `include:` key did double duty:

```ruby
{ include: %i[memberships reviews] }
```

This fed **both** `ActiveRecord.includes(:memberships, :reviews)` (SQL eager loading) **and** AMS `include:` (which associations appear in JSON via `has_many`/`has_one`).

This caused two issues:

1. **You couldn't eager-load an association without rendering it.** Computed attributes like `memberships_count` or `verified?` need the association loaded in memory but shouldn't render as a nested JSON object.

2. **You couldn't render an association without eager-loading it.** The admin `OrganizationSerializer` has `has_one :owner`, but `:owner` shouldn't be in `ActiveRecord.includes()` because `owner` is already loaded through a custom join (`owner_membership: :user`).

The fix was to separate the two concerns:
- `eager_load_config` → SQL preloading **only** (no policy gate — preloading unused associations is a performance choice, not a security concern)
- `serializer_profile[:include]` → AMS rendering **only** (policy-gated — what data the user sees)

## The Two Layers

### `fields:` — Attribute visibility

Controls which flat attributes appear in the JSON response. Uses `Core::AttributeVisibilitySerializer` to slice the serializer's output.

```ruby
fields: %i[id name slug description profile_url city region]
```

- Intersected with policy `VISIBILITY[:action][:fields]`
- If a controller asks for a field the policy doesn't allow, the policy wins

### `serializer_profile[:include]` — AMS rendering

Controls which `has_many`/`has_one`/`belongs_to` associations render as nested objects in JSON via AMS.

```ruby
serializer_profile
  index: { include: %i[owner] },
}
```

- Intersected with policy `VISIBILITY[:action][:include]`
- Only associations declared with `has_many`/`has_one`/`belongs_to` in the serializer class are affected
- The `Attributes` adapter treats AMS `include:` as a whitelist — omitted associations are silently dropped from JSON

### `eager_load_config` — SQL preloading

Controls which ActiveRecord associations get `.includes()` — SQL eager loading to prevent N+1 queries.

```ruby
def eager_load_config
  { default: [:memberships, :reviews, { profile_attachment: :blob }] }
end
```

- **Not** intersected with policy — preloading is a performance concern, not a security concern
- Supports nested AR preloads like `{ owner_membership: :user }` and `{ profile_attachment: :blob }`
- Per-action with `:default` fallback:
  - If the action key exists in the config, uses that
  - If `:default` key exists, uses that
  - Otherwise returns `[]` (no preloading)
- `serializer_profile[:include]` is **never** used as a fallback for SQL preloading — they're fully independent

## How the Flow Works

```
          serializer_profile                    eager_load_config
                    │                                   │
         ┌──────────┼──────────┐                        │
         │          │          │                        │
      fields:    include:      │                   per-action hash
         │       (AMS only)    │                        │
         │          │          │                        │
         ▼          ▼          │                        ▼
┌────────────┐ ┌──────────┐   │              ┌──────────────────┐
│ visible_    │ │ renderable│   │              │ eager_loaded_    │
│ attributes  │ │ associations│  │              │ associations     │
└─────┬──────┘ └─────┬────┘   │              └────────┬─────────┘
      │              │        │                       │
      ▼              ▼        │                       ▼
┌────────────┐ ┌──────────┐   │              ┌──────────────────┐
│ Policy     │ │ Policy   │   │              │ ActiveRecord     │
│ VISIBILITY │ │ VISIBILITY│  │              │ .includes(...)   │
│ .fields    │ │ .include │   │              │ (no policy       │
│ intersect  │ │ intersect│   │              │  intersection)   │
└─────┬──────┘ └─────┬────┘   │              └────────┬─────────┘
      │              │        │                       │
      ▼              ▼        │                       ▼
┌────────────┐ ┌──────────┐   │              ┌──────────────────┐
│ AMS options │ │ AMS      │   │              │ set_object /     │
│ [:visible_  │ │ options  │   │              │ index / create / │
│ attributes] │ │ [:include]│   │              │ update / show    │
└────────────┘ └──────────┘   │              └──────────────────┘
```

## Policy VISIBILITY Integration

The policy has the final say on what's rendered. `eager_load_config` bypasses the policy entirely — it only affects SQL.

### Policy VISIBILITY structure

```ruby
VISIBILITY = {
  index: {
    admin:   { fields: %i[...], include: %i[...] },
    default: { fields: %i[...], include: %i[...] }
  },
  show: {
    admin:   { fields: %i[...], include: %i[...] },
    default: { fields: %i[...], include: %i[...] }
  }
}
```

- Role key (`:admin` or `:default`) is determined by `ApplicationPolicy#user_role_key`
- `const_defined?(:VISIBILITY, false)` — only checks the current class, not ancestors. Each policy must define its own VISIBILITY explicitly; no silent inheritance.
- **`:all` sentinel**: `include: :all` or `fields: :all` means pass through (returns `nil`, letting the controller's value through unchanged). This is the only way to express "allow everything" for a role.
- **Absent keys resolve to `[]` (block all)**: If a VISIBILITY hash entry lacks `:include` or `:fields`, the policy returns `[]`, not `nil`. Backward compatibility was removed — `nil` is no longer a pass-through for absent keys. Only `:all` provides pass-through.
- **Policy-level absence** (no VISIBILITY constant at all) still returns `nil` — this is the one remaining nil path. Every policy should define explicit VISIBILITY.
- Policy `include:` only affects the **render path** (`renderable_associations`). The SQL path reads `eager_load_config` directly with no policy intersection.

### Field intersection

```ruby
# Controller says
fields: %i[id email phone verified_at deactivated_at deactivated_reason]

# Policy says (for default role)
fields: %i[id email phone verified_at deactivated_at]

# Result — intersection
%i[id email phone verified_at deactivated_at]
```

The `deactivated_reason` field is stripped for non-admin users.

### AMS include intersection

```ruby
# Controller says (in serializer_profile)
include: %i[permissions roles]

# Policy says (for default role)
include: %i[permissions]

# Result — AMS renders only :permissions
%i[permissions]
```

The `roles` association is still SQL-preloaded (if `eager_load_config` includes it), but it's stripped from the AMS output by the policy intersection.

## Complete Call Flow

When a request hits `Core::Common#index`:

### Step 1: Build `eager_loaded_associations`

```ruby
def eager_loaded_associations
  config = eager_load_config
  action_key = action_name.to_sym
  if config.key?(action_key)
    config[action_key]
  elsif config.key?(:default)
    config[:default]
  else
    []
  end
end
```

Reads from `eager_load_config` directly — no policy intersection, no fallback to `serializer_profile[:include]`.

### Step 2: Apply `.includes()` to the relation

```ruby
data = data.includes(eager_loaded_associations)
# → ActiveRecord::Relation.includes(:memberships, :reviews)
```

### Step 3: Build `renderable_associations`

```ruby
def renderable_associations
  controller_includes = serializer_includes_for_action(action_name)
  # → reads profile[:index][:include] → %i[owner]

  pol = policy_for_data(policy_sample)
  return controller_includes unless pol&.respond_to?(:included_associations_for)

  policy_includes = pol.included_associations_for(
    action: action_name,
    default_includes: controller_includes
  )
  return controller_includes if policy_includes.nil?

  controller_includes & policy_includes
end
```

Reads from `serializer_profile[:include]` — policy-gated.

### Step 4: Set `serializer_options[:include]`

```ruby
serializer_options[:include] ||= renderable_associations
# → serializer_options[:include] = %i[owner]
```

### Step 5: AMS renders only those associations

The `Attributes` adapter treats `include:` as a whitelist — omitted associations are silently dropped.

## Concrete Examples

### Example A: Admin::OrganizationsController — separate SQL and AMS

The admin serializer has `has_one :owner`. The owner is loaded via a custom join, not through a simple `include:`.

```ruby
# Controller
def eager_load_config
  { default: [:memberships, :reviews,
              { owner_membership: :user,
                profile_attachment: :blob,
                banner_attachment: :blob,
                business_license_attachment: :blob,
                tin_certificate_attachment: :blob }] }
end

def serializer_profile
  {
    index:  { include: %i[owner] },
    show:   { include: %i[owner] },
    create: { include: %i[owner] },
    update: { include: %i[owner] }
  }
end
```

| Key | Value | Purpose |
|-----|-------|---------|
| `eager_load_config` | `[:memberships, :reviews, ...]` | SQL `.includes()` for computed attrs (`verified?`, `memberships.size`) + attachment blobs |
| `serializer_profile[:include]` | `%i[owner]` | AMS whitelist — renders `has_one :owner` |

Note: `:owner` is in `serializer_profile[:include]` but **not** in `eager_load_config` for its simple name — it's already loaded through `owner_membership: :user` in the nested hash.

### Example B: OwnerOrganizationsController — computed attributes only

The owner serializer has **no** `has_many`/`has_one` declarations. All associations are loaded purely for computed attributes.

```ruby
def eager_load_config
  { default: [:memberships, :reviews, :follows,
              { profile_attachment: :blob,
                banner_attachment: :blob,
                business_license_attachment: :blob,
                tin_certificate_attachment: :blob }] }
end

def serializer_profile
  {
    index:  { fields: %i[id name ... memberships_count verified ...] },
    show:   { fields: %i[id name ... verified is_following ...] },
    create: { fields: %i[id name slug description created_at] },
    update: { fields: %i[id name slug description created_at] }
  }
end
```

| Association | Why it's loaded via `eager_load_config` |
|-------------|----------------------------------------|
| `memberships` | `memberships.size` for `memberships_count` |
| `reviews` | `reviews.any? { \|r\| r.context == "verification" && r.status == "approved" }` for `verified?` |
| `follows` | `follows.any? { \|f\| f.user_id == current_user.id }` for `is_following` |

No `serializer_profile[:include]` is needed — the serializer has no `has_many`/`has_one` declarations, so AMS wouldn't render anything even if `include:` were set.

### Example C: Admin::RolesController — matching SQL and AMS

```ruby
def eager_load_config
  { default: [:permissions] }
end

def serializer_profile
  {
    index:  { fields: %i[id code name description active], include: %i[permissions] },
    show:   { fields: %i[id code name description active created_at updated_at], include: %i[permissions] },
    create: { fields: %i[id code name active], include: %i[permissions] },
    update: { fields: %i[id code name active], include: %i[permissions] }
  }
end
```

Serializer: `has_many :permissions`

The `:permissions` association appears in both `eager_load_config` (SQL) and `serializer_profile[:include]` (AMS). They happen to match, but they serve separate purposes.

### Example D: Admin::PermissionsController — no associations

```ruby
def serializer_profile
  {
    index:  { fields: %i[id code name description resource] },
    show:   { fields: %i[id code name description resource created_at updated_at] },
    create: { fields: %i[id code name description resource] },
    update: { fields: %i[id code name description resource] }
  }
end
```

No `eager_load_config` (falls through to `[]`), no `serializer_profile[:include]`. The serializer has no `has_many`/`has_one`. Nothing is preloaded, nothing is rendered.

### Example E: Admin::UserRolesController — nested resource

```ruby
def eager_load_config
  { default: [:role] }
end

def serializer_profile
  {
    index:  { fields: %i[id role_id], include: %i[role] },
    create: { fields: %i[id role_id], include: %i[role] }
  }
end
```

Serializer: `belongs_to :role`

The `:role` association is both SQL-preloaded and AMS-rendered.

### Example F: MembershipManagement concern — belongs_to

```ruby
def eager_load_config
  { default: [:user] }
end

def serializer_profile
  {
    default: { fields: %i[id role status created_at updated_at], include: %i[user] },
    index:   { fields: %i[id role status created_at updated_at], include: %i[user] },
    show:    { fields: %i[id role status created_at updated_at], include: %i[user] },
    create:  { fields: %i[id role status created_at updated_at], include: %i[user] },
    update:  { fields: %i[id role status created_at updated_at], include: %i[user] }
  }
end
```

Serializer: `belongs_to :user`

The `:user` association is both SQL-preloaded and AMS-rendered.

## Cookbook: Common Patterns

### Pattern 1: Eager-load for computed attributes only

The association is needed in memory for `size`, `any?`, `count`, etc. — but must **not** appear as a nested JSON object.

```ruby
def eager_load_config
  { default: [:reviews] }
end

# No include: in serializer_profile for reviews
serializer_profile
  index: { fields: %i[name slug verified] }
end

# Serializer
attribute :verified
def verified
  object.verified?
end
```

### Pattern 2: Render an association without adding it to SQL preloading

The association is already loaded through a custom scope or join — don't double-load it.

```ruby
def eager_load_config
  { default: [:memberships] }  # no :owner here
end

def serializer_profile
  {
    index: { include: %i[owner] }  # :owner in AMS only
  }
end

def apply_index_scope(scope)
  scope.includes(owner_membership: :user)  # :owner loaded via custom scope
end
```

### Pattern 3: Both — SQL preloaded and AMS rendered

```ruby
def eager_load_config
  { default: [:permissions] }
end

def serializer_profile
  {
    index: { include: %i[permissions] }
  }
end
```

### Pattern 4: Policy restricts AMS rendering for certain roles

```ruby
def eager_load_config
  { default: [:roles] }  # SQL preloads roles regardless
end

def serializer_profile
  {
    index: { include: %i[roles] }
  }
end

# Policy
VISIBILITY = {
  index: {
    admin:   { include: %i[roles] },
    default: { include: %i[] }
  }
}

# Result for non-admin: renderable_associations = %i[roles] & %i[] = %i[]
# Roles association is still preloaded in SQL (eager_load_config is not policy-gated),
# but it's stripped from AMS output by the policy intersection.
```

### Pattern 5: Policy `:all` sentinel — pass through everything for a given role

The explicit way to say "no restrictions" for a role. Replaces the old implicit `admin: {}` pattern.

```ruby
VISIBILITY = {
  index: {
    admin:   { include: :all, fields: :all },  # admin sees everything
    default: { fields: %i[id name slug description] }
  },
  show: {
    admin:   { include: :all, fields: :all },
    default: { include: %i[], fields: %i[id name description] }
  }
}
```

- `:all` is the **only** way to express pass-through. Absent keys or empty arrays block.
- `include: :all` → `included_associations_for` returns `nil` → the controller's `include:` passes through unchanged
- `fields: :all` → `visible_attributes_for` returns `nil` → the controller's `fields:` passes through unchanged
- The serializer's full `has_many`/`has_one`/`belongs_to` set is available to the role

## Best Practices

1. **Add `eager_load_config` to every controller that renders associations or uses computed attributes** that iterate over associations. Otherwise you'll get N+1 queries.

2. **Keep `eager_load_config`'s `:default` key simple.** Use per-action overrides only when an action genuinely loads different associations. Most controllers only need `:default`.

3. **`serializer_profile[:include]` is purely for AMS rendering.** Don't add associations there just to prevent N+1 — that's what `eager_load_config` is for.

4. **When `eager_load_config` and `serializer_profile[:include]` are identical** (e.g., both have `:permissions`), that's fine — it's explicit and clear.

5. **Don't put associations in `eager_load_config` that you don't use.** Every unnecessary `.includes()` adds a SQL JOIN or separate query.

6. **Don't define a serializer `has_many`/`has_one` for every possible association.** Only declare what you actually render in `serializer_profile[:include]`.

7. **Policy VISIBILITY's `include:` only affects AMS rendering now**, not SQL preloading. The policy controls what the user **sees**, not what's loaded in memory.

## Configuration Reference

### `serializer_profile` in the controller

| Key | Values | Purpose | Intersection |
|-----|--------|---------|--------------|
| `fields:` | Array of symbols | Which flat attributes appear in JSON | Policy `VISIBILITY[:fields]` |
| `include:` | Array of symbols (serializer `has_many`/`has_one`/`belongs_to` names) | Which associations render via AMS | Policy `VISIBILITY[:include]` |

### `eager_load_config` in the controller

A per-action hash controlling SQL preloading. **Not** policy-gated.

| Method | Returns | Source |
|--------|---------|--------|
| `eager_load_config` | Hash `{ action: [:assocs], default: [:assocs] }` or `{}` | Override in each controller |
| `eager_loaded_associations` | Resolved array for current action | `app/controllers/concerns/core/common.rb:171` |

Example with per-action overrides:

```ruby
def eager_load_config
  {
    index:  [:memberships, :reviews],
    show:   [:memberships, :reviews, :follows],
    default: [:memberships]
  }
end
```

### `Core::Common` methods

| Method | Returns | Source |
|--------|---------|--------|
| `eager_loaded_associations` | Config value for current action (or `[]`) | `app/controllers/concerns/core/common.rb:175` |
| `renderable_associations` | Controller `include:` ∩ policy `include:` | `app/controllers/concerns/core/common.rb:207` |
| `serializer_includes_for_action(action)` | Controller's `include:` for the action | `app/controllers/concerns/core/common.rb:199` |

### `ApplicationPolicy` methods

| Method | Returns | Source |
|--------|---------|--------|
| `included_associations_for(action:, default_includes:)` | `nil` when `:all` sentinel, `[]` when absent/empty key, otherwise array of symbols | `app/policies/core/application_policy.rb:39` |
| `visible_attributes_for(record:, action:)` | `nil` when `:all` sentinel, `[]` when absent/empty key, otherwise array of symbols | `app/policies/core/application_policy.rb:30` |
| `resolve_visibility_entry(action)` | The role-specific hash entry from VISIBILITY, or `nil` if no VISIBILITY constant exists | `app/policies/core/application_policy.rb:61` |
| `user_role_key` | `:admin` or `:default` based on user roles | `app/policies/core/application_policy.rb:54` |

Note: `resolve_visibility_entry` uses `const_defined?(:VISIBILITY, false)` — only checks the current class, not ancestors. Each policy must define its own VISIBILITY explicitly. If VISIBILITY is absent, it returns `nil` — the one remaining nil pass-through path. Every policy should define explicit VISIBILITY.
