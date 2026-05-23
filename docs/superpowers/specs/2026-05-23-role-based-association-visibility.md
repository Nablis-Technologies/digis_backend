# Role-Based Association Visibility

**Date:** 2026-05-23
**Status:** Draft

## Overview

Extend the `VISIBILITY` hash to control which associations render per-role. Currently only top-level attributes are per-role; associations are a single controller-declared list.

## V1 scope

Role-based **include** only (which associations render). Per-association field restriction (`association_fields`) is deferred — it requires AMS integration that needs prototyping. V1 solves the real problem: preventing N+1 and data exposure when different roles should see different associations.

## Problem

```ruby
# Controller — applies to all roles equally
def serializer_profile
  {
    show: { include: [:audit_logs] }
  }
end
```

Admin and attendee both see `audit_logs` on show. There's no way to hide associations per role.

## Proposed extension

Add an `include:` key to `VISIBILITY` entries. The pipeline intersects it with the controller's `serializer_profile[action][:include]` — only associations declared by both sides render.

```ruby
# app/policies/events/category_policy.rb
VISIBILITY = {
  show: {
    default: {
      fields: %i[id name description slug metadata active],
      include: []                                            # attendee sees no associations
    },
    admin: {
      include: [:audit_logs]                                 # admin sees audit_logs
    }
  }
}.freeze
```

`nil` for a role means "no restriction" — the controller's full include list passes through:

```ruby
admin: nil  # admin inherits controller's include: [:audit_logs]
```

### Policy methods encapsulate `VISIBILITY`

`Core::ApplicationPolicy` provides query methods. No caller accesses `VISIBILITY` directly:

```ruby
# app/policies/core/application_policy.rb
def included_associations_for(action:, default_includes:)
  config = resolve_visibility_entry(action)
  return nil unless config.is_a?(Hash)

  entry = config[:include]
  entry.nil? ? nil : entry.map(&:to_sym)
end

def association_fields_for(action:)
  config = resolve_visibility_entry(action)
  return {} unless config.is_a?(Hash)

  config[:association_fields] || {}
end

private

def resolve_visibility_entry(action)
  return nil unless self.class.const_defined?(:VISIBILITY, false)

  config = self.class::VISIBILITY[action.to_sym]
  return nil unless config

  entry = if config.key?(user_role_key)
    config[user_role_key]
  else
    config[:default]
  end

  entry if entry.is_a?(Hash) || entry.nil?
end
```

Domain policies only declare `VISIBILITY` — the lookup logic is inherited.

## Pipeline changes

### 1. Shared policy resolution helper

Both `Core::Common` (for includes) and `Core::JsonResponse` (for fields) need to resolve the policy from the target data. Extract a shared helper:

```ruby
# In Core::JsonResponse
def policy_for_data(data)
  return nil unless data.is_a?(ActiveRecord::Base) || data.is_a?(ActiveRecord::Relation)

  target = if data.is_a?(ActiveRecord::Relation)
    return nil unless @clazz
    @clazz.new
  else
    data
  end

  policy(target)
end
```

`Core::Common` includes `Core::JsonResponse`, so it inherits this method.

### 2. `eager_loaded_associations` becomes role-aware

```ruby
# In Core::Common
def eager_loaded_associations
  controller_includes = serializer_includes_for_action(action_name)
  pol = policy_for_data(policy_sample)
  return controller_includes unless pol&.respond_to?(:included_associations_for)

  policy_includes = pol.included_associations_for(
    action: action_name,
    default_includes: controller_includes
  )
  return controller_includes if policy_includes.nil?

  controller_includes & policy_includes
end

def policy_sample
  @obj || @clazz&.new
end
```

For `before_action :set_object`, `@obj` is nil so it falls back to `@clazz.new` — sufficient for policy resolution since `visible_attributes_for` and `included_associations_for` don't inspect record values on collections.

### 3. CRUD actions use `eager_loaded_associations` for `include:`

Replace direct `serializer_includes_for_action` with `eager_loaded_associations` in `serializer_options[:include]`:

```ruby
# Before (index):
serializer_options[:include] ||= serializer_includes_for_action(:index)

# After:
serializer_options[:include] ||= eager_loaded_associations
```

Same change for show, create, update. This keeps eager loading and the AMS `include:` in sync for the default path. If an action supplies custom `include:` via `resolve_block_result`, the `||=` preserves that override — the developer is responsible for keeping their custom include in sync with what's loaded.

### 4. `policy_visible_attributes_for` uses the shared helper

```ruby
# In Core::JsonResponse — replaces old implementation
def policy_visible_attributes_for(data)
  pol = policy_for_data(data)
  return nil unless pol&.respond_to?(:visible_attributes_for)

  target = data.is_a?(ActiveRecord::Relation) ? @clazz&.new : data
  pol.visible_attributes_for(record: target, action: action_name)
end
```

One helper (`policy_for_data`), two consumers (`policy_visible_attributes_for` for fields, `eager_loaded_associations` for includes). No drift.

### 5. `render_success` — association_fields deferred

```ruby
def render_success(message = nil, data: nil, ...)
  visible = resolved_visible_attributes(data)

  response[:data] = serialize(data, serializer_options.merge(
    visible_attributes: visible
  ))
end
```

No change needed for V1. The `include:` is already set in `serializer_options` by `Core::Common` before `render_success` is called.

## Resolution flow

```
serializer_profile[action][:include]       controller's max set
  ∩ pol.included_associations_for          per-role restriction
  = final_include                          drives both eager loading + AMS include
```

| Scenario | Controller include | Policy include | Result |
|----------|-------------------|----------------|--------|
| Admin show | `[:audit_logs]` | `[:audit_logs]` or `nil` | `[:audit_logs]` |
| Attendee show | `[:audit_logs]` | `[]` | `[]` |
| Action not in VISIBILITY | `[:audit_logs]` | `nil` (no policy) | `[:audit_logs]` (pass through) |
| Role not in VISIBILITY (reviewer) | `[:audit_logs]` | Missing from hash → `default` value | Depends on default |

## `user_role_key` resolution

Defined in `Core::ApplicationPolicy` with overrides in domain policies:

```ruby
# app/policies/core/application_policy.rb
def user_role_key
  return :admin if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
  :default
end

# app/policies/ticketing/ticket_policy.rb
def user_role_key
  return :box_office if user.has_role?("BOX_OFFICE")
  super
end
```

## Examples

### Adding a new role to a domain policy

```ruby
# app/policies/ticketing/ticket_policy.rb
VISIBILITY = {
  show: {
    default: { fields: %i[id name price status], include: [] },
    box_office: { include: [:purchaser, :scan_history] },
    admin: nil
  }
}.freeze

def user_role_key
  return :box_office if user.has_role?("BOX_OFFICE")
  super
end
```

### Adding a new action when roles diverge

```ruby
VISIBILITY = {
  show: {
    default: { fields: %i[id name], include: [] },
    admin: nil
  },
  archive: {
    default: { fields: %i[id name archived_at], include: [] },
    admin: nil
  }
}
```

An action not in `VISIBILITY` is unrestricted — the controller's `serializer_profile` decides alone.

## Future work

Per-association field restriction (`association_fields`) is **implemented** via post-processing (`Core::AssociationFieldFilter`). See the detailed spec:

`docs/superpowers/specs/2026-05-24-association-field-restrictions.md`

Syntax:
```ruby
VISIBILITY = {
  show: {
    admin: {
      include: [:audit_logs],
      association_fields: {
        audit_logs: { fields: %i[id action created_at] }
      }
    }
  }
}
```

Limitations:
- Post-processing means hidden fields still compute before being stripped
- Nested recursion requires explicit `serializer:` on the `has_many` declaration
- Polymorphic associations won't recurse correctly

## Architecture summary

| Responsibility | Location | Method |
|---------------|----------|--------|
| Policy resolution from data | `Core::JsonResponse` | `policy_for_data(data)` |
| Per-role field restriction | `Core::ApplicationPolicy` | `visible_attributes_for(record:, action:)` |
| Per-role association inclusion | `Core::ApplicationPolicy` | `included_associations_for(action:, default_includes:)` |
| VISIBILITY entry lookup | `Core::ApplicationPolicy` | `resolve_visibility_entry(action)` (private) |
| Role-based eager loading | `Core::Common` | `eager_loaded_associations` (overridden) |
| Role-based AMS include | `Core::Common` | `serializer_options[:include] ||= eager_loaded_associations` |
| VISIBILITY declaration | Domain policies | Constant + optional `user_role_key` override |
