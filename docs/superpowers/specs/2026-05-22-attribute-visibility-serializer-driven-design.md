# Serializer-Driven Attribute Visibility Design

**Date**: May 22, 2026
**Status**: Draft
**Purpose**: Companion to `2026-05-22-per-action-attributes-design.md`

---

## Why This Document Exists

This document does **not** replace the original per-action attributes draft.

It captures a second approach to the same problem:

- keep the original idea of **per-action** response shape
- keep the original idea of **per-role** attribute visibility
- implement both through the **serializer/render pipeline**
- avoid “serialize everything, then slice hashes in controllers”

This version is designed to fit the current codebase more naturally because serialization currently flows through:

- `Core::Common`
- `Core::JsonResponse`
- `ActiveModelSerializers::SerializableResource`

---

## Problem

We want API responses to support two kinds of attribute visibility:

1. **Per-action visibility**
   `index` should usually be lighter than `show`

2. **Per-role visibility**
   different roles may see different fields for the same action

Example:

- `GET /events/categories`
  returns only `id`, `name`, `slug`
- `GET /events/categories/:id`
  returns the full record for admins
- `GET /events/categories/:id`
  hides `created_at` and `updated_at` for attendees

---

## Current Pipeline

Today the flow is:

```text
Controller action
  -> Core::Common prepares the record/relation
  -> render_success(data: ...)
  -> Core::JsonResponse#serialize
  -> ActiveModelSerializers renders the object
  -> JSON response returned
```

Relevant code:

- [app/controllers/concerns/core/common.rb](/Users/adoniyas/Documents/Projects/Rails/digis_backend/app/controllers/concerns/core/common.rb)
- [app/controllers/concerns/core/json_response.rb](/Users/adoniyas/Documents/Projects/Rails/digis_backend/app/controllers/concerns/core/json_response.rb)
- [app/serializers/events/category_serializer.rb](/Users/adoniyas/Documents/Projects/Rails/digis_backend/app/serializers/events/category_serializer.rb)

That means attribute visibility is most naturally applied:

- before serialization as serializer options
- or inside serializers while building the payload

Not after the fact in each CRUD action.

---

## Recommendation

Use a **serializer-driven visibility model**.

### Core idea

- Controllers declare a **field profile per action**
- Policies may further restrict those fields per role
- `Core::JsonResponse` resolves the final fieldset
- The serializer receives `visible_attributes`
- The serializer returns only those attributes

This keeps responsibilities clean:

- controller decides response shape by endpoint
- policy decides what the viewer is allowed to see
- serializer decides how to render data

---

## Why This Is Better Than Hash-Slicing In `Core::Common`

### 1. It matches the real rendering boundary

`Core::Common` currently passes model objects to `render_success`.
Actual JSON generation happens later in `Core::JsonResponse`.

So “filter the serialized hash in `Core::Common`” adds awkward coupling.

### 2. It uses serializer truth, not database truth

A serializer may expose:

- computed fields
- renamed keys
- associations
- selected model columns only

So the serializer, not `model_class.column_names`, should define the response contract.

### 3. It is easier to extend later

If later you want:

- nested visibility
- association visibility
- different serializer profiles per action

the serializer path scales better than controller-side hash surgery.

---

## Proposed Architecture

## Layer 1: Controller Declares Action Field Profiles

Each CRUD controller can optionally define:

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

If omitted:

```ruby
def serializer_fields
  nil
end
```

Meaning:

- no controller restriction
- serializer renders its normal full payload

### Example

```ruby
module Events
  class CategoriesController < Events::ApplicationController
    include Core::Common

    private

    def serializer_fields
      {
        index:  %i[id name slug],
        show:   %i[id name description slug metadata active created_at updated_at],
        create: %i[id name slug],
        update: %i[id name slug]
      }
    end
  end
end
```

---

## Layer 2: Policy Restricts Visible Fields By Role

Each policy can optionally define:

```ruby
def visible_attributes_for(record:, action:)
  nil
end
```

If it returns `nil`, there is no policy-level restriction.

If it returns a list, that list becomes a restriction layer.

### Example

```ruby
module Events
  class CategoryPolicy < Core::ApplicationPolicy
    def visible_attributes_for(record:, action:)
      return nil unless action.to_sym == :show
      return nil if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")

      %i[id name description slug metadata active]
    end
  end
end
```

This means:

- admins see the controller’s full `show` profile
- attendees see a reduced subset

### Important design rule

For v1, `visible_attributes_for` should depend on:

- `user`
- `action`
- optionally broad record type

It should **not** depend on row-specific values for collection actions.

That keeps index responses consistent.

If you later need row-by-row field visibility inside collections, that should be a second feature.

---

## Layer 3: `Core::JsonResponse` Resolves The Final Fieldset

`Core::JsonResponse#serialize` should accept visibility options and pass them into AMS.

### Proposed flow

```ruby
controller_fields = serializer_fields&.dig(action_name.to_sym)
policy_fields = visible_attributes_from_policy(data)
final_fields = intersect_fieldsets(controller_fields, policy_fields)
```

Rules:

- if both are `nil`: show normal serializer output
- if only controller fields exist: use them
- if only policy fields exist: use them
- if both exist: intersect them

### Example helper

```ruby
def resolved_visible_attributes(data)
  controller_fields = serializer_fields&.dig(action_name.to_sym)
  policy_fields = policy_visible_attributes_for(data)

  return nil if controller_fields.nil? && policy_fields.nil?
  return controller_fields if policy_fields.nil?
  return policy_fields if controller_fields.nil?

  controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
end
```

---

## Layer 4: Serializer Applies The Final Fieldset

Instead of annotating every field with custom conditionals, use a serializer helper that slices the serializer output.

### Proposed concern

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

### Example serializer

```ruby
module Events
  class CategorySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
  end
end
```

This is the key shift:

- AMS still builds the normal serializer payload
- the serializer itself trims the output based on `instance_options[:visible_attributes]`

That keeps the decision inside the serializer layer, not in each controller action.

---

## End-To-End Examples

## Example 1: `index`

Controller:

```ruby
def serializer_fields
  {
    index: %i[id name slug]
  }
end
```

Policy:

```ruby
def visible_attributes_for(record:, action:)
  nil
end
```

Request:

```http
GET /events/categories
Authorization: Bearer <token>
```

Response:

```json
{
  "success": true,
  "data": [
    {
      "id": "uuid-1",
      "name": "Music",
      "slug": "music"
    },
    {
      "id": "uuid-2",
      "name": "Sports",
      "slug": "sports"
    }
  ]
}
```

No `description`, `metadata`, `created_at`, or `updated_at`.

---

## Example 2: `show` for admin

Controller:

```ruby
def serializer_fields
  {
    show: %i[id name description slug metadata active created_at updated_at]
  }
end
```

Policy:

```ruby
def visible_attributes_for(record:, action:)
  return nil if user.has_role?("ADMIN") || user.has_role?("SUPER_ADMIN")
end
```

Response:

```json
{
  "success": true,
  "data": {
    "id": "uuid-1",
    "name": "Music",
    "description": "Category for music events",
    "slug": "music",
    "metadata": {
      "icon": "note"
    },
    "active": true,
    "created_at": "2026-05-21T10:00:00Z",
    "updated_at": "2026-05-22T09:30:00Z"
  }
}
```

---

## Example 3: `show` for attendee

Same controller profile.

Policy:

```ruby
def visible_attributes_for(record:, action:)
  return nil unless action.to_sym == :show
  return nil if user.has_role?("ADMIN") || user.has_role?("SUPER_ADMIN")

  %i[id name description slug metadata active]
end
```

Final intersection:

```ruby
controller_fields = %i[id name description slug metadata active created_at updated_at]
policy_fields = %i[id name description slug metadata active]

final_fields = controller_fields & policy_fields
# => %i[id name description slug metadata active]
```

Response:

```json
{
  "success": true,
  "data": {
    "id": "uuid-1",
    "name": "Music",
    "description": "Category for music events",
    "slug": "music",
    "metadata": {
      "icon": "note"
    },
    "active": true
  }
}
```

---

## Example 4: `create`

Controller:

```ruby
def serializer_fields
  {
    create: %i[id name slug]
  }
end
```

Response:

```json
{
  "success": true,
  "data": {
    "id": "uuid-9",
    "name": "Theater",
    "slug": "theater"
  }
}
```

This keeps create/update responses compact and predictable.

---

## Associations

This design should treat associations as a separate concern.

### V1 recommendation

For the first version:

- field visibility controls **top-level serializer attributes**
- do not introduce per-association attribute visibility yet

Example:

If a serializer includes:

```ruby
has_many :audit_logs
```

Then v1 should only support:

- include `audit_logs`
- or do not include `audit_logs`

It should **not** try to support:

- include `audit_logs`, but only hide `ip_address`

That can be a later feature if you need nested visibility rules.

---

## `Core::Common` Changes

`Core::Common` should stay thin.

Its role is:

- determine the action
- determine serializer includes
- provide field-profile metadata to `render_success`

It should not manually slice response hashes per action.

### Small addition

Add:

```ruby
def serializer_fields
  nil
end
```

Then pass visibility options along with `serializer_options`.

---

## `Core::JsonResponse` Changes

This is the better place for the main integration.

### Responsibilities

- resolve final visible attributes
- pass them to serializers through `instance_options`
- keep response formatting unchanged

### Suggested shape

```ruby
render_success(
  data: object,
  serializer_options: serializer_options.merge(
    visible_attributes: resolved_visible_attributes(object)
  )
)
```

For collections:

- compute one fieldset for the action/user combination
- pass the same `visible_attributes` into the collection serializer

That keeps index output consistent for every row.

---

## Policy Contract

Add a safe default in `Core::ApplicationPolicy`:

```ruby
def visible_attributes_for(record:, action:)
  nil
end
```

### Important rule

Do **not** use `rescue nil` around this call.

If a policy implementation is broken, we want:

- test to fail
- development to fail loudly

Silent fallback would risk accidentally exposing more data than intended.

---

## Testing Strategy

## 1. Attribute visibility tests

These should be driven by the serializer contract, not model columns.

### Good source of truth

- `serializer_fields` from controller for expected per-action profile
- serializer-defined attributes for “full payload” shape

### Avoid

```ruby
model_class.column_names
```

That is not the response contract.

### Example generated tests

For `index`:

- expected fields are present
- fields omitted by controller profile are absent

For `show` as attendee:

- restricted fields are absent

For `show` as admin:

- full show profile is present

### Example assertions

```ruby
test "index returns only the lightweight field profile" do
  get "/events/categories", headers: attendee_headers, as: :json
  assert_response :success

  data = JSON.parse(response.body).fetch("data")
  data.each do |item|
    assert_equal %w[id name slug].sort, item.keys.sort
  end
end
```

```ruby
test "show hides audit timestamps for attendee" do
  get "/events/categories/#{events_categories(:music).id}", headers: attendee_headers, as: :json
  assert_response :success

  data = JSON.parse(response.body).fetch("data")
  assert_not data.key?("created_at")
  assert_not data.key?("updated_at")
end
```

```ruby
test "show includes audit timestamps for admin" do
  get "/events/categories/#{events_categories(:music).id}", headers: admin_headers, as: :json
  assert_response :success

  data = JSON.parse(response.body).fetch("data")
  assert data.key?("created_at")
  assert data.key?("updated_at")
end
```

## 2. Scope tests

Keep record-level scope testing separate from field visibility testing.

These are different concerns:

- scope testing answers: “which records can you see?”
- field visibility answers: “which fields of those records can you see?”

That separation will make `resource_test` easier to reason about.

---

## Rollout Plan

1. Add `serializer_fields` default to `Core::Common`
2. Add `visible_attributes_for(record:, action:)` default to `Core::ApplicationPolicy`
3. Add `Core::AttributeVisibilitySerializer`
4. Update `Core::JsonResponse` to pass `visible_attributes` into AMS
5. Add the first real usage in `Events::CategoriesController`
6. Add role-based override in `Events::CategoryPolicy`
7. Add explicit request tests for attendee/admin field visibility
8. Extend `resource_test` only after the manual version is proven clean

---

## Recommendation On `resource_test`

Do not make `resource_test` fully automatic on day one.

Start with explicit tests in the first controller using this feature.

Why:

- the API contract is still evolving
- automatic generation too early will hide design mistakes
- role-based field visibility needs clearer test semantics first

After the first controller works well, add `resource_test` helpers for:

- expected fields present
- expected fields absent
- role-specific visibility cases

---

## Tradeoffs

### Strengths

- fits the current AMS pipeline
- keeps controllers slimmer
- keeps policy logic explicit
- uses serializer schema as the response contract
- easier to extend than controller-side slicing

### Weaknesses

- adds one more layer of serializer options
- top-level only in v1
- role-based field visibility in collections must stay action-wide, not row-specific

---

## Final Recommendation

Build this as a **serializer-driven visibility system**, not as a “serialize first, then slice hashes in `Core::Common`” system.

That means:

- controller defines endpoint field profiles
- policy can restrict fields for a role
- `JsonResponse` computes the final fieldset
- serializer applies the fieldset

This gives you the same product behavior as the original draft, but with cleaner boundaries and a much better fit for the current Rails + AMS architecture.
