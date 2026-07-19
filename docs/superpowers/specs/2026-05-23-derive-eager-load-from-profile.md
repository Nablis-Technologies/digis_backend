# Derive eager_loaded_associations from serializer_profile

**Date:** 2026-05-23
**Status:** Draft

## Overview

Currently `eager_loaded_associations` (query N+1 prevention) and `serializer_profile[action][:include]` (AMS rendering) are declared separately but almost always contain the same values. This spec proposes deriving `eager_loaded_associations` from the profile by default, keeping the method as an override hook.

## Motivation

Current pattern:

```ruby
# Two declarations that must stay in sync:
def serializer_profile
  {
    show: { fields: %i[...], include: [:ticket_types, :venue] }
  }
end

def eager_loaded_associations
  [:ticket_types, :venue]  # same as profile[:show][:include]
end
```

Every new includes requires updating both methods. The derived default eliminates this.

## Design

### Default derivation

```ruby
# app/controllers/concerns/core/common.rb
def eager_loaded_associations
  serializer_includes_for_action(action_name)
end
```

This returns whatever the profile declares for the current action (or `default[:include]`, or `[]`).

### Override stays

Controllers that need deeper preloading than what the response renders override as before:

```ruby
def eager_loaded_associations
  super + [{ ticket_types: :prices }]
end
```

### Call sites become unconditional

The `.present?` guard on eager loading calls is no longer needed since `includes([])` is a no-op in AR:

```ruby
# Before:
data = data.includes(eager_loaded_associations) if eager_loaded_associations.present?

# After:
data = data.includes(eager_loaded_associations)
```

This applies to `index`, `show`, `create`, `update`, and `set_object`.

## Design constraint

If a controller supplies dynamic serializer `include:` options outside `serializer_profile` (via `resolve_block_result`), it must also override `eager_loaded_associations` if it wants matching preload behavior. The profile is the single source of truth for default eager loading — dynamic includes that aren't in the profile won't be preloaded unless the controller explicitly overrides.

## Scenarios

| Scenario | Profile `include:` | `eager_loaded_associations` | Works? |
|----------|-------------------|---------------------------|--------|
| Flat symbols (common) | `[:ticket_types]` | `[:ticket_types]` | ✓ AR+AMS |
| Empty (no includes) | `[]` | `[]` | ✓ includes([]) no-op |
| Nested preload needed | `[:ticket_types]` | `super + [{ ticket_types: :prices }]` | ✓ override |
| Preload without render | `[]` | `[:ticket_types]` | ✓ override |
| No profile at all | `[]` (default) | `[]` | ✓ includes([]) no-op |

## Edge cases

- **Partial updates** (`set_object`): `action_name` is available during `before_action`, so `serializer_includes_for_action(action_name)` returns the right includes. `includes([])` replaces the current `if eager_loaded_associations.present?` guard safely.

- **Lambda/block includes**: If a controller passes `include:` through `resolve_block_result`, the `||=` guard means the profile doesn't overwrite it. But `eager_loaded_associations` reads the profile directly — if the block added extra includes, they won't be eager loaded unless the controller also overrides `eager_loaded_associations`. This is by design: the profile is the single source of truth for default preloading. See the [Design constraint](#design-constraint) section.

## Rollout

1. Change `eager_loaded_associations` default in `Core::Common`
2. Remove `.present?` guards at all 5 call sites
3. Remove `eager_loaded_associations` override from `CategoriesController` (it returns `[]` — same as new default)
4. Run tests
5. Update docs
