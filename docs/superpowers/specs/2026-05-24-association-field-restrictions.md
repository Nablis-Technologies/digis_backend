# Association Field Restrictions

**Date:** 2026-05-24
**Status:** Implemented

## Overview

Restrict which fields render within included associations, per-role. Extends the `VISIBILITY` hash with `association_fields:`. V1 of role-based visibility only controls *which* associations render (`include:`); this implements *what fields within each association*.

## Problem

```ruby
VISIBILITY = {
  show: {
    admin: { include: [:audit_logs] },
    default: { include: [] }
  }
}
```

Admin sees `audit_logs` on show, attendee doesn't. But when admin sees them, all serializer fields on `AuditLogSerializer` are returned — including internal fields like `ip_address`, `request_uuid`. There's no way to restrict which audit log fields admin sees.

## Design

### `VISIBILITY` declaration

```ruby
VISIBILITY = {
  show: {
    admin: {
      include: [:audit_logs],
      association_fields: {
        audit_logs: { fields: %i[id action created_at] }
      }
    },
    default: { include: [] }
  }
}.freeze
```

### Nested depth

```ruby
VISIBILITY = {
  show: {
    admin: {
      include: [:audit_logs],
      association_fields: {
        audit_logs: {
          fields: %i[id action created_at],
          user: { fields: %i[id email name] }
        }
      }
    }
  }
}
```

### Policy method

`association_fields_for(action:)` in `Core::ApplicationPolicy`:

```ruby
def association_fields_for(action:)
  config = resolve_visibility_entry(action)
  return {} unless config.is_a?(Hash)

  config[:association_fields] || {}
end
```

## Pipeline approach

AMS does not have a built-in hook for per-association option propagation. The `serialize_options` instance method does not exist in AMS. Attempting to use `instance_options` propagation requires the child serializer to know its own association name — which it doesn't have access to in standard AMS.

The pragmatic solution: **post-process the AMS JSON output** to strip restricted fields from association data.

**Caveat**: Nested recursion depends on `reflection.options[:serializer]` (explicitly declared child serializer). AMS `HasManyReflection` does not expose `klass` or a `serializer` auto-detection method. If the child serializer isn't explicitly declared, recursion stops at that depth — current-level field restrictions still apply.

### `Core::AssociationFieldFilter`

```ruby
module Core
  class AssociationFieldFilter
    def self.apply!(json, association_fields, serializer_class)
      return json unless json.is_a?(Hash) && association_fields.present?

      serializer_class._reflections.each do |name, reflection|
        config = association_fields[name.to_sym]
        next if config.nil?

        json_key = find_json_key(json, reflection)
        next if json_key.nil? || json[json_key].nil?

        if config[:fields].present?
          allowed = config[:fields].map(&:to_sym)
          case json[json_key]
          when Array
            json[json_key].each { |item| item.slice!(*allowed) }
          when Hash
            json[json_key].slice!(*allowed)
          end
        end

        if config[:association_fields].present?
          child_serializer = reflection.options[:serializer]
          next unless child_serializer

          items = Array.wrap(json[json_key])
          items.each { |item| apply!(item, config[:association_fields], child_serializer) }
        end
      end

      json
    end

    def self.find_json_key(json, reflection)
      raw = reflection.options[:key] || reflection.name
      sym = raw.to_sym
      str = raw.to_s
      return sym if json.key?(sym)
      return str if json.key?(str)
      nil
    end
  end
end
```

Key notes:
- `reflection.options[:key] || reflection.name` resolves the JSON key (AMS `HasManyReflection` has no `.key` method)
- `find_json_key` checks both symbol and string variants — AMS in this app returns symbol-keyed hashes
- Field names use symbols for `slice!`
- Child serializer uses `reflection.options[:serializer]` only (AMS `HasManyReflection` has no `klass`)
- `reflection.options[:key]` is nil when no `key:` is declared on the `has_many`

### Integration into `serialize`

```ruby
# In Core::JsonResponse
def serialize(data, options = {})
  case data
  when ActiveRecord::Base
    serialize_record(data, options)
  when ActiveRecord::Relation
    serialize_relation(data, options)
  when Hash
    serialize_hash(data, options)
  when Array
    data.map { |value| serialize(value, options) }
  else
    data
  end
end

def serialize_record(data, options = {})
  assoc_fields = options.delete(:association_fields)
  serializer_class = options[:serializer] || ActiveModelSerializers::SerializableResource.new(data).serializer
  result = ActiveModelSerializers::SerializableResource.new(data, options).as_json

  if assoc_fields.present? && serializer_class
    Core::AssociationFieldFilter.apply!(result, assoc_fields, serializer_class)
  end

  result
end

def serialize_relation(data, options = {})
  assoc_fields = options.delete(:association_fields)
  result = ActiveModelSerializers::SerializableResource.new(data, options).as_json

  if assoc_fields.present? && result.is_a?(Array) && result.first.is_a?(Hash)
    serializer_class = options[:serializer] || \
      (data.respond_to?(:klass) && ActiveModelSerializers::SerializableResource.new(data.klass.new).serializer)
    result.each { |item| Core::AssociationFieldFilter.apply!(item, assoc_fields, serializer_class) } if serializer_class
  end

  result
end
```

### In `render_success`

```ruby
def render_success(message = nil, data: nil, ...)
  visible = resolved_visible_attributes(data)
  assoc_fields = build_association_options(resolved_association_fields(data, action_name))

  response[:data] = serialize(data, serializer_options.merge(
    visible_attributes: visible,
    association_fields: assoc_fields
  )) unless data.nil?

  # ... rest unchanged
end
```

### `resolved_association_fields`

```ruby
# In Core::JsonResponse
def resolved_association_fields(data, action)
  pol = policy_for_data(data)
  return {} unless pol&.respond_to?(:association_fields_for)

  pol.association_fields_for(action:)
end
```

### `build_association_options`

```ruby
# In Core::JsonResponse (private)
def build_association_options(fields)
  return {} if fields.blank?

  fields.each_with_object({}) do |(key, value), opts|
    next if value.nil?

    entry = {}
    entry[:fields] = value[:fields].map(&:to_sym) if value[:fields].present?
    if value[:association_fields].present?
      entry[:association_fields] = build_association_options(value[:association_fields])
    end
    opts[key.to_sym] = entry.presence
  end.compact
end
```

## How it works

1. `render_success` calls `resolved_association_fields(data, action)` which reads from policy's `VISIBILITY[action][role_key][:association_fields]`
2. `build_association_options` normalizes the tree (symbol keys, symbolized field arrays)
3. `serialize_record` / `serialize_relation` first runs normal AMS serialization, then applies the filter
4. `AssociationFieldFilter.apply!` walks the AMS JSON output and uses `_reflections` on the serializer class to match association names to JSON keys
5. At each depth, it `slice!`s the allowed fields and recurses for nested restrictions

## What you can do

| Capability | Supported? | Example |
|------------|-----------|---------|
| Restrict fields on a `has_many` association | Yes | `audit_logs: { fields: %i[id action] }` |
| Restrict fields on a `has_one` association | Yes | Same syntax, uses Hash branch in `slice!` |
| Custom JSON keys (`has_many :audit_logs, key: :audit_entries`) | Yes | `reflection.options[:key]` is checked first |
| Symbol-keyed JSON output | Yes | `find_json_key` checks both `to_sym` and `to_s` |
| Nested recursion (association within association) | Best-effort | Only when child serializer is explicitly declared via `reflection.options[:serializer]` |
| String-keyed JSON output | Yes | `find_json_key` checks both variants |
| Array-form `VISIBILITY` entries (backward compat) | Yes | `resolve_visibility_entry` handles both |

## What you can't do (yet)

| Limitation | Why |
|------------|-----|
| Expensive serializer methods behind hidden fields still run | Post-processing — fields are computed, then stripped |
| `perform_enqueued_jobs` context needed in tests for audited associations | Audit logs are created async |
| Controller-level `serializer_profile` must declare the `include:` for the assocation | Filter can't add associations — only restricts fields on ones already included |
| Nested recursion without explicit `serializer:` on the `has_many` declaration | AMS `HasManyReflection` has no `klass` method |
| Polymorphic association recursion | Child serializer varies per type; filter assumes one serializer from reflection |
| Mixed-type collection recursion | Same issue — serializer is detected from first element |
| `each_serializer` adapter-level overrides | `serialize_relation` resolves serializer independently |

## Files involved

| File | Change |
|------|--------|
| `app/lib/core/association_field_filter.rb` | New — post-processing filter |
| `app/controllers/concerns/core/json_response.rb` | Split `serialize` into record/relation paths; added `resolved_association_fields`, `build_association_options`; updated `render_success` |
| `app/policies/core/application_policy.rb` | Added `association_fields_for` method |
| `app/policies/events/category_policy.rb` | Added `association_fields: { audit_logs: { fields: %i[id action created_at] } }` to admin role |
| `app/controllers/events/categories_controller.rb` | Added `include: [:audit_logs]` to show action's `serializer_profile` |
| `test/integration/events/categories_test.rb` | Two new tests: admin show restricted fields, default user no audit_logs |

## Verification

- **75 tests, 183 assertions, 0 failures** (full suite)
- Admin show: returns `audit_logs` with only `id`, `action`, `created_at`
- Admin show: `ip_address`, `request_uuid` are filtered out
- Default user show: `audit_logs` absent entirely (policy `include: []`)
- Index: `audit_logs` absent (not in controller profile)
- All existing authorization, CRUD, audit, pagination tests still pass
