# serializer_profile — Unify serializer_fields & default_serializer_includes

**Date:** 2026-05-23
**Status:** Draft (pending review)

## Overview

Replace the two separate controller methods `serializer_fields` (attribute whitelist per action) and `default_serializer_includes` (association includes per action) with a single `serializer_profile` method. Both control what data appears in API responses — keeping them separate forces controllers to maintain two parallel data structures that often change together.

## Motivation

Current categories controller:

```ruby
def serializer_fields
  { index:  %i[id name slug],
    show:   %i[id name description slug metadata active created_at updated_at],
    create: %i[id name slug],
    update: %i[id name slug] }
end

def default_serializer_includes
  { index:  [],
    show:   [],
    create: [],
    update: [] }
end
```

The two methods mirror each other's structure (same action keys) — this is a signal they should be one. With `serializer_profile`:

```ruby
def serializer_profile
  {
    index: {
      fields: %i[id name slug]
    },
    show: {
      fields: %i[id name description slug metadata active created_at updated_at]
    },
    create: {
      fields: %i[id name slug]
    },
    update: {
      fields: %i[id name slug]
    }
  }
end
```

One method, one place to look, and `include:` only appears when it's actually needed.

### One DSL, Two Internal Consumers

`serializer_profile` is a **unified controller DSL** but feeds **two independent internal consumers** that run at different points in the request lifecycle:

| Consumer | Location | Reads | Purpose |
|----------|----------|-------|---------|
| `Core::Common` | CRUD action bodies (`common.rb`) | `profile[action][:include]` | Sets AMS `include:` for association side-loading |
| `Core::JsonResponse` | `resolved_visible_attributes` (`json_response.rb`) | `profile[action][:fields]` | Computes attr visibility, threads into AMS via `instance_options[:visible_attributes]` |

These are separate mechanisms — `include:` controls which associated resources are rendered (via AMS `include` directives, separate from query eager loading which is handled by `eager_loaded_associations`), `fields:` controls which attributes of the resource itself appear. They should never be collapsed into a single serializer-side mechanism because they interact with different parts of the stack (policy layer for fields, AMS include directives for includes).

## New API

### `serializer_profile` method

Defined on the controller. Returns a hash keyed by action name (symbol) plus an optional `default` key for shared config.

```ruby
def serializer_profile
  {
    default: {
      fields: %i[id name slug],
      include: [:ticket_types]
    },
    show: {
      fields: %i[id name description slug metadata active created_at updated_at],
      include: [:venue]
    },
    create: {
      include: [:ticket_types]
    }
  }
end
```

### Keys

| Key | Value | Purpose |
|-----|-------|---------|
| `default` | Hash with optional `fields:` / `include:` | Shared config inherited by all actions unless overridden per-action |
| Any action symbol (e.g., `:index`, `:show`) | Hash with optional `fields:` / `include:` | Per-action overrides |

### Resolution rules

1. **`default` is applied to every action** unless the action provides its own value for that key.
2. **Override is whole-key, not deep merge.** If `show` has `fields:`, it replaces `default`'s `fields` entirely — it does not merge arrays. Same for `include:`.
3. Both `fields:` and `include:` are optional per action and within `default`. If neither is specified for an action and `default` has neither, that action has no restriction (current behavior — all attributes pass through, no includes).

### Inheritance examples

```ruby
# All actions get fields + include from default:
def serializer_profile
  {
    default: {
      fields: %i[id name slug],
      include: [:ticket_types]
    }
  }
end

# All get default fields, show adds include, create overrides fields:
def serializer_profile
  {
    default: {
      fields: %i[id name slug]
    },
    show: {
      include: [:ticket_types, :venue]
    },
    create: {
      fields: %i[id name]
    }
  }
end

# No default — fully explicit per action:
def serializer_profile
  {
    index: {
      fields: %i[id name slug]
    },
    show: {
      fields: %i[id name description slug metadata active created_at updated_at],
      include: [:ticket_types, :venue]
    },
    create: {
      fields: %i[id name]
    }
  }
end
```

## Code Changes

### 1. `Core::JsonResponse`

**Remove:**
- `def serializer_fields` (returns nil) — old method
- Any reference to `serializer_fields` in `resolved_visible_attributes`

**Add:**
```ruby
def serializer_profile
  {}
end
```

**Update `resolved_visible_attributes`:**
```ruby
def resolved_visible_attributes(data)
  profile = serializer_profile
  action_sym = action_name.to_sym
  action_config = profile[action_sym] || {}
  default_conf = profile[:default] || {}
  controller_fields = action_config.key?(:fields) ? action_config[:fields] : default_conf[:fields]
  policy_fields = policy_visible_attributes_for(data)

  return nil if controller_fields.nil? && policy_fields.nil?
  return controller_fields.map(&:to_sym) if policy_fields.nil?
  return policy_fields.map(&:to_sym) if controller_fields.nil?

  controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
end
```

### 2. `Core::Common`

**Remove:**
- `def default_serializer_includes` (returns `{}`)
- `def serializer_includes_for_action(action)` — the wrapper method

**Add** a new internal method:
```ruby
def serializer_includes_for_action(action)
  profile = serializer_profile
  action_sym = action.to_sym
  action_config = profile[action_sym] || {}
  default_conf = profile[:default] || {}
  action_config.key?(:include) ? action_config[:include] : default_conf[:include] || []
end
```

No changes needed in CRUD action bodies — they already call `serializer_includes_for_action(:index)` etc., which now reads from the unified profile.

### 3. `Core::ResourceTest`

The `Metadata` class currently detects attributes via:
```ruby
controller_instance.send(:serializer_fields) if controller_instance.respond_to?(:serializer_fields)
```

Change to resolve `default` inheritance by iterating over the controller's known actions — not the raw profile keys. If a controller defines only `default: { fields: ... }` with no per-action entries, all controller actions still inherit the default:

```ruby
profile = controller_instance.send(:serializer_profile)
default_fields = profile[:default]&.dig(:fields)
action_fields = @actions.each_with_object({}) do |action, hash|
  action_config = profile[action]
  if action_config&.key?(:fields)
    hash[action] = action_config[:fields]
  elsif default_fields
    hash[action] = default_fields
  end
end
```

**Inheritance is resolved at detection time.** For each action:
- If the action has explicit `fields:`, use them.
- If not, use `default[:fields]` (may be nil).
- If neither action nor `default` has `fields:`, the action has no attribute restriction — skip absence tests for it.

Presence tests: generated for whatever `action_fields[action]` returns.
Absence tests: derived from the serializer's full `_attributes` minus `action_fields[action]`. Only generated when `action_fields[action]` is present (non-nil).

The `:default` key itself is never treated as an action — it only exists to be inherited.

### 4. Controllers to update

Only one controller defines these methods:

- `app/controllers/events/categories_controller.rb` — replace `serializer_fields` and `default_serializer_includes` with `serializer_profile`. No includes needed currently (all empty arrays), but the unified method is simpler:

```ruby
def serializer_profile
  {
    index: {
      fields: %i[id name slug]
    },
    show: {
      fields: %i[id name description slug metadata active created_at updated_at]
    },
    create: {
      fields: %i[id name slug]
    },
    update: {
      fields: %i[id name slug]
    }
  }
end
```

### 5. Docs to update

- `docs/TEST_HELPERS_GUIDE.md` — update auto-detection table (replace `serializer_fields` references with `serializer_profile`)
- `docs/JSON_RESPONSE_MODULE_DOCUMENTATION.md` — replace `serializer_fields` examples with `serializer_profile`
- `docs/platform/api-responses-and-serialization.md` — update attribute visibility pipeline section
- `docs/COMMON_MODULE_DOCUMENTATION.md` — replace `serializer_fields` and `default_serializer_includes` sections with unified `serializer_profile` section
- `docs/AUTHORIZABLE_MODULE_DOCUMENTATION.md` — update controller example to use `serializer_profile`

### 6. Specs/plans to create

- `docs/superpowers/specs/2026-05-23-serializer-profile-unification.md` — this document
- `docs/superpowers/plans/2026-05-23-serializer-profile-unification.md` — implementation plan (generated next)

## Rollout Plan

| Step | Change | Risk |
|------|--------|------|
| 1 | Add `serializer_profile` default to `Core::JsonResponse`, remove `serializer_fields` default | Low — only one consumer |
| 2 | Update `resolved_visible_attributes` to read from `serializer_profile` | Low — same logic, different source |
| 3 | Remove `default_serializer_includes` and update `serializer_includes_for_action` in `Core::Common` | Low — same logic, different source |
| 4 | Update `Events::CategoriesController` to use `serializer_profile` | Low — single file, no includes |
| 5 | Update `Core::ResourceTest` to detect fields from `serializer_profile` | Medium — test infrastructure |
| 6 | Update all docs | Low |
| 7 | Run full test suite | — |

## Out of Scope

- Changing the policy-side API. `visible_attributes_for(record:, action:)` stays as-is — it intersects with `profile[action][:fields]` the same way it intersected with `serializer_fields[action]`.
- Changing the `AttributeVisibilitySerializer` concern — it continues to read `instance_options[:visible_attributes]`.
- Changing `eager_loaded_associations` — that's a separate concern (query N+1 prevention, not serialization config).

## Open Questions

*(None — all design decisions resolved above.)*
