# Core API Responses And Serialization

## Purpose

The `Core::JsonResponse` concern now standardizes all API envelopes and uses ActiveModelSerializers for record serialization.

## Envelope Contract

Success responses:

- `success: true`
- optional `message`
- optional `data`
- optional `pagination`
- optional `meta`

Error responses:

- `success: false`
- optional `error`
- optional `errors`
- optional `code`
- optional `meta`

## Serialization Rules

- ActiveRecord records and relations are serialized through AMS.
- Hash payloads support nested serializer options per key.
- Primitive values are passed through unchanged.

Example:

```ruby
render_success(
  "Login successful",
  data: { user: user, access_token: token },
  serializer_options: {
    user: { serializer: Core::UserAuthSerializer }
  }
)
```

## I18n Behavior

- If a symbol is passed as message/error, it is translated when a matching key exists.
- If no message is passed, the concern checks contextual keys:
  - success: `model.success.action`
  - error: `model.errors.action`

## Current Core Serializers

- `Core::UserAuthSerializer`
- `Core::RoleSerializer`
- `Core::PermissionSerializer`
- `Core::AuditLogSerializer`
- `Core::ReviewSerializer`

## Attribute Visibility Pipeline

Responses can be filtered per-action (controller) and per-role (policy). The pipeline:

```
controller.serializer_profile[action][:fields]
  ∩ policy.visible_attributes_for(record:, action:)
    → resolved_visible_attributes
      → AMS instance_options[:visible_attributes]
        → Core::AttributeVisibilitySerializer slices #attributes
```

### Controller layer (`serializer_profile`)

Per-action attribute profiles via `fields:` key. An optional `default` key provides shared config. `include:` controls association side-loading (separate mechanism).

```ruby
def serializer_profile
  {
    default: { fields: %i[id name slug], include: [:ticket_types] },
    show:    { fields: %i[id name description slug metadata active created_at updated_at], include: [:venue] }
  }
end
```

### Policy layer (`visible_attributes_for`)

Per-role restriction using a `VISIBILITY` hash. **Every policy must define `VISIBILITY`** — even if no role-based field restriction is needed, the hash documents the policy's access model explicitly:

```ruby
# Minimal: all users who pass the policy see everything
VISIBILITY = {
  show: { default: nil, admin: nil }
}.freeze

# Restricted: non-admin users see limited fields
VISIBILITY = {
  show: {
    default: %i[id name],
    admin: nil
  }
}.freeze
```

Only declare actions in `VISIBILITY` where roles diverge — unlisted actions are unrestricted.

```ruby
VISIBILITY = {
  show: {
    default: %i[id name description slug metadata active],
    admin: nil
  }
}.freeze

def visible_attributes_for(record:, action:)
  config = VISIBILITY[action.to_sym]
  return nil unless config

  if config.key?(user_role_key)
    config[user_role_key]
  else
    config[:default]
  end
end
```

`nil` = unrestricted (admin sees all). `:default` = fallback role. New roles slot in as additional keys.

### Serializer layer (`AttributeVisibilitySerializer`)

AMS concern that slices output. Must be included in serializers that support visibility.

```ruby
class Events::CategorySerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
end
```

### Resolution rules

- If both layers return nil: all serializer attributes returned.
- If one returns nil, the other passes through unchanged.
- If both return arrays: their intersection is used (controller restricts → policy further restricts).
- Non-AR payloads (hashes, arrays, scalars): policy layer is skipped entirely (no resolution attempt).
- Associations are controlled by `serializer_profile[action][:include]`, not attribute visibility.
