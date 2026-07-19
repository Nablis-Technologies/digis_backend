# Per-Action & Per-Role Attribute Visibility Design

**Date:** 2026-05-22
**Status:** Draft (pending review)

## Overview

Add two layers of attribute filtering to API responses:

1. **Per-action** — controller declares which attributes appear per endpoint (e.g., index is lightweight, show is full detail).
2. **Per-role** — policy restricts which attributes a role can see (e.g., attendees don't see `created_at`/`updated_at` on show).

Implementation is serializer-driven — the visibility decision flows through `Core::JsonResponse` into `ActiveModelSerializers`, rather than post-hoc hash-slicing in controllers.

## Current Pipeline

```
Controller action
  -> Core::Common prepares the record/relation
  -> render_success(data: ...)
  -> Core::JsonResponse#serialize
  -> ActiveModelSerializers::SerializableResource
  -> JSON response
```

Attribute visibility is most naturally applied:
- before serialization as serializer options
- or inside serializers while building the payload

Not after the fact in each CRUD action.

## Architecture

### Layer 1: Controller Declares `serializer_fields`

Each CRUD controller defines per-action field profiles:

```ruby
def serializer_fields
  {
    index:  %i[id name slug],
    show:   %i[id name description slug metadata active created_at updated_at],
    create: %i[id name slug],
    update: %i[id name slug]
  }
end
```

Default in `Core::JsonResponse` returns `nil` — no restriction, full serializer output. CRUD controllers that include `Core::Common` inherit this through the include chain. Controllers like `AuthController` that include `JsonResponse` directly also get the default without change.

### Layer 2: Policy Declares `visible_attributes_for(record:, action:)`

The policy restricts what roles see for a given action:

```ruby
# Core::ApplicationPolicy — default, no restriction
def visible_attributes_for(record:, action:)
  nil
end
```

```ruby
# Events::CategoryPolicy
def visible_attributes_for(record:, action:)
  return nil unless action.to_sym == :show
  return nil if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
  %i[id name description slug metadata active]
end
```

Design rules:
- No `rescue nil` — if a policy method is broken, fail loud
- No silent fallback — explicit `nil` checks at each step
- `visible_attributes_for` depends on user, action, and broad record type — not row-specific values for collections
- For singleton actions (show/update/destroy): `record:` is the actual record instance
- For collection actions (index): `record:` is a new (unsaved) instance, since there's no single "current record". Visibility must be uniform across the collection. This is a v1 constraint.

### Layer 3: Core::JsonResponse Resolves the Final Fieldset

`Core::JsonResponse` provides the default `serializer_fields` (returns nil) and the resolution logic. `resolved_visible_attributes` computes the intersection of controller fields and policy fields, then passes `visible_attributes` into AMS via `serializer_options`:

Controllers that override `serializer_fields` get per-action filtering. Controllers using the default (nil) get full serializer output — no change in behavior.

```ruby
def resolved_visible_attributes(data)
  controller_fields = serializer_fields&.dig(action_name.to_sym)
  policy_fields = policy_visible_attributes_for(data)

  return nil if controller_fields.nil? && policy_fields.nil?
  return controller_fields.map(&:to_sym) if policy_fields.nil?
  return policy_fields.map(&:to_sym) if controller_fields.nil?

  controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
end
```

Where `policy_visible_attributes_for` fetches the policy for the given data:

```ruby
def policy_visible_attributes_for(data)
  return nil unless data.is_a?(ActiveRecord::Base) || data.is_a?(ActiveRecord::Relation)

  target = data.is_a?(ActiveRecord::Relation) ? @clazz&.new : data
  return nil unless target

  pol = policy(target)
  return nil unless pol&.respond_to?(:visible_attributes_for)

  pol.visible_attributes_for(record: target, action: action_name)
end
```

For collections (index), the fieldset is computed once and applied uniformly to all items. No row-by-row variance in v1. The `record:` parameter receives a new (unsaved) instance for collection actions — this is a v1 constraint. Attribute visibility for collections is based on user role and action, not record-specific values. If a future policy needs row-level visibility, that's a separate extension.

### Layer 4: Serializer Applies visible_attributes

A concern trims serializer output based on `instance_options[:visible_attributes]`:

```ruby
module Core
  module AttributeVisibilitySerializer
    def attributes(*args)
      data = super
      allowed = instance_options[:visible_attributes]
      return data if allowed.blank?

      allowed_keys = allowed.map(&:to_sym)
      data.slice(*allowed_keys)
    end
  end
end
```

Serializers include it and declare their full schema (unchanged):

```ruby
module Events
  class CategorySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
    has_many :audit_logs, serializer: Core::AuditLogSerializer
  end
end
```

The concern overrides `attributes` to slice after the parent call. This only controls attribute-level keys (`id`, `name`, `slug`, etc.) — `has_many`/`has_one` associations are rendered separately by AMS and are **not** affected by the fieldset. Associations remain controlled by the existing `default_serializer_includes` mechanism. Nested visibility (some fields inside the associated object) is out of scope for v1.

### Changes Summary

**Core::JsonResponse** — default `serializer_fields` (returns nil) + main resolution logic:

```ruby
def serializer_fields
  nil
end
```

```ruby
render_success(
  data: data,
  serializer_options: serializer_options.merge(
    visible_attributes: resolved_visible_attributes(data)
  )
)
```

**Core::ApplicationPolicy** — safe default:

```ruby
def visible_attributes_for(record:, action:)
  nil
end
```

**Core::AttributeVisibilitySerializer** — new concern.

## resource_test Integration

### Attribute presence/absence tests

Generated for any action with `serializer_fields` defined. Tests use the **serializer's declared attributes** as the "full set", not `column_names`.

```ruby
test "index returns only the lightweight field profile" do
  get meta.path, headers: admin_headers, as: :json
  assert_response :success
  data = JSON.parse(response.body).fetch("data")
  data.each { |item| assert_equal %w[id name slug].sort, item.keys.sort }
end
```

```ruby
test "show hides timestamps for attendee" do
  get "#{meta.path}/#{record.id}", headers: attendee_headers, as: :json
  assert_response :success
  data = JSON.parse(response.body).fetch("data")
  assert_not data.key?("created_at")
  assert_not data.key?("updated_at")
end
```

Auto-detection in `Metadata` reads:

1. Controller's `serializer_fields` for the per-action profile
2. Serializer's `_attributes` list (via `serializer_class._attributes` in AMS) for the full set
3. Policy's `visible_attributes_for` per fixture key for role-based restrictions

### Scope tests

Test that `Policy::Scope` correctly filters records per role. Option-driven:

```ruby
resource_test(
  scope: {
    attendee:    { excludes: [:inactive_category] },
    super_admin: { includes: :all }
  }
)
```

Auto-detect: reads fixture records with `active: false`/`deleted_at: present`, cross-references with `Policy::Scope` for each fixture role.

### No auto-generation on day one

First controller with this feature gets **explicit request tests** for attribute visibility. Only after the pattern is proven clean does `resource_test` get the auto-detection helpers. This avoids encoding design mistakes into the macro.

## End-to-End Example

```
GET /events/categories
Authorization: Bearer <attendee_token>
```

Controller: `serializer_fields[:index] = %i[id name slug]`  
Policy: `visible_attributes_for → nil` (no role restriction on index)

Response:

```json
{
  "data": [
    { "id": "uuid-1", "name": "Music", "slug": "music" },
    { "id": "uuid-2", "name": "Sports", "slug": "sports" }
  ]
}
```

```
GET /events/categories/:id
Authorization: Bearer <attendee_token>
```

Controller: `serializer_fields[:show] = %i[id name description slug metadata active created_at updated_at]`  
Policy: `visible_attributes_for → %i[id name description slug metadata active]` (attendee)  
Final: `intersection = %i[id name description slug metadata active]`

Response:

```json
{
  "data": {
    "id": "uuid-1",
    "name": "Music",
    "description": "Category for music events",
    "slug": "music",
    "metadata": { "icon": "note" },
    "active": true
  }
}
```

For admin/super_admin on the same action, `visible_attributes_for` returns `nil` — so only the controller profile applies, and the full show payload including `created_at`/`updated_at` is returned.

## Rollout Plan

1. Add `serializer_fields` default (returns nil) to `Core::JsonResponse`
2. Add `visible_attributes_for(record:, action:)` default (returns nil) to `Core::ApplicationPolicy`
3. Create `Core::AttributeVisibilitySerializer` concern
4. Update `Core::JsonResponse#serialize` to resolve and pass `visible_attributes`
5. Add `serializer_fields` to `Events::CategoriesController` — lightweight index, full show, summary create/update
6. Add `visible_attributes_for` override to `Events::CategoryPolicy` — attendees see limited show
7. Write explicit integration tests for the categories controller — per-action and per-role visibility
8. Extend `resource_test` with `check_attributes` presence/absence generation
9. Extend `resource_test` with scope testing
10. Update `docs/TEST_HELPERS_GUIDE.md`
11. Run full test suite

## Open Questions

- Should `create`/`update` responses include the full record or just a summary? (Proposed: summary — id, name, slug — to keep create/update responses compact and predictable.)
- Should `serializer_fields` use symbols or strings? (Proposed: symbols — consistent with AMS convention.)
- Associations are out of scope for v1. They remain controlled by `default_serializer_includes` / `serializer_includes_for_action`.
