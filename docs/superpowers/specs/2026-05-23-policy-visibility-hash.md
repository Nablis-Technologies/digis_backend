# Policy `VISIBILITY` Hash for Per-Role Attribute Control

**Date:** 2026-05-23
**Status:** Implemented — 2026-05-23

## Overview

Replace the current `visible_attributes_for` method pattern (multiple early returns with `nil` checks) with a declarative `VISIBILITY` hash constant. Makes per-role, per-action attribute visibility readable, scalable, and self-documenting.

## Current pattern

```ruby
def visible_attributes_for(record:, action:)
  return nil unless action.to_sym == :show
  return nil if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
  %i[id name description slug metadata active]
end
```

Problems:
- Each new action/role adds more early returns
- Hard to see all restrictions at a glance
- Developer must trace every `nil` to understand "restricted or unrestricted?"
- Scales poorly beyond 1 action + 1 role

## Proposed `VISIBILITY` hash

The policy only declares restrictions when a role needs **less** than what the controller already allows. Don't restate the controller's `serializer_profile`.

```ruby
VISIBILITY = {
  show: {
    default: %i[id name description slug metadata active],
    admin: nil
  }
}.freeze
```

If `index`/`create`/`update` don't appear here, they're unrestricted (`nil`) — the controller's `serializer_profile` is the sole authority for those actions.

### Semantics

| Value | Meaning |
|-------|---------|
| `%i[id name]` | This role sees **only** these attributes |
| `nil` | This role sees **everything** the serializer declares (no restriction) |
| Missing key | Falls through to `:default` for that action |

### `:default` key

`default` is the **fallback role** — applies to any role not explicitly listed. Only define it for actions where a non-admin role needs restriction.

### `nil` for admin

`admin: nil` means "admin sees all fields the serializer has." This is the most common case — privileged roles are unrestricted. `nil` = "gate is open," not "empty set."

## Lookup method

The lookup logic lives in `Core::ApplicationPolicy` — shared plumbing inherited by all domain policies:

```ruby
# app/policies/core/application_policy.rb
def visible_attributes_for(record:, action:)
  config = self.class::VISIBILITY[action.to_sym]
  return nil unless config

  if config.key?(user_role_key)
    config[user_role_key]
  else
    config[:default]
  end
end

def user_role_key
  return :admin if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
  :default
end
```

Domain policies only declare what's unique:

```ruby
# app/policies/events/category_policy.rb
VISIBILITY = {
  show: {
    default: %i[id name description slug metadata active],
    admin: nil
  }
}.freeze

def index?   = true
def show?    = true
def create?  = admin?
def update?  = admin?
def destroy? = user.has_role?("SUPER_ADMIN")
```

### Resolution logic

| Scenario | `key?` check | Returns |
|----------|-------------|---------|
| Action not in `VISIBILITY` | — | `nil` (unrestricted) |
| Role key is `:admin`, config has `admin: nil` | `true` → `config[:admin]` | `nil` (unrestricted) |
| Role key is `:default`, config has `default: %i[...]` | `true` → `config[:default]` | The array (restricted) |
| Role key is `:reviewer`, config has no `:reviewer` key | `false` → `config[:default]` | `:default` value (restricted) |

## Interaction with `serializer_profile`

The two systems are independent and intersect at render time:

```
visible_attributes = controller_fields ∩ policy_fields
```

| Controller `serializer_profile` | Policy `VISIBILITY` | Result |
|---------------------------|---------------------|--------|
| `show: { fields: %i[id name description ...] }` | `default: %i[id name description slug meta active]` | Intersection — non-admin sees both |
| `show: { fields: %i[id name description ...] }` | `admin: nil` | Controller's full list (admin unrestricted) |
| Action not in `VISIBILITY` (e.g., index) | Returns `nil` | Controller's fields pass through untouched |

The controller says "what's appropriate for this action." The policy says "what's this role allowed to see." They're different questions.

## Examples

### Adding a new role to a domain policy

Domain policies add role-specific keys to `VISIBILITY` and override `user_role_key` via `super`:

```ruby
# app/policies/ticketing/ticket_policy.rb
VISIBILITY = {
  show: {
    default: %i[id name price status],
    box_office: nil,
    admin: nil
  }
}.freeze

def user_role_key
  return :box_office if user.has_role?("BOX_OFFICE")
  super  # falls back to admin checks, then :default
end
```

Order `user_role_key` from most permissive to least. `super` ensures global admin roles work without duplication.

### Adding a new action when roles diverge

If `archive` has no role-based differences, don't add it to `VISIBILITY`. Only add when a role gets less:

```ruby
VISIBILITY = {
  show: {
    default: %i[id name description slug metadata active],
    admin: nil
  },
  archive: {
    default: %i[id name archived_at archived_by],
    admin: nil
  }
}
```

An action not in `VISIBILITY` is unrestricted — the controller's `serializer_profile` decides alone.

## Architecture

| Component | File | Responsibility |
|-----------|------|---------------|
| Lookup method + `user_role_key` | `Core::ApplicationPolicy` | Shared plumbing, global admin roles |
| `VISIBILITY` constant | Domain policy (e.g., `Events::CategoryPolicy`) | Per-role per-action field restrictions |
| `user_role_key` override | Domain policy | Domain-specific role mapping (optional, via `super`) |

## Current state (implemented)

- `visible_attributes_for` + `user_role_key` live in `Core::ApplicationPolicy`
- `VISIBILITY` constant lives in `Events::CategoryPolicy`
- Domain policies override `user_role_key` via `super` when they add domain-specific roles
- Pipeline intersection: `controller.serializer_profile[action][:fields] ∩ policy.visible_attributes_for`
