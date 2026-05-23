# JsonResponse Module Documentation

## Overview

The `Core::JsonResponse` module provides standardized JSON response helpers for API controllers. It ensures consistent response format across all endpoints with success/error handling, I18n message support, and serialization integration.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Success Responses](#success-responses)
- [Error Responses](#error-responses)
- [Response Format](#response-format)
- [I18n Integration](#i18n-integration)
- [Serialization](#serialization)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Basic Usage

The module is automatically included when using `Core::Common`. Helper methods are available in all controller actions:

```ruby
module Core
  class EventsController < Core::ApplicationController
    include Core::Common

    def custom_action
      render_success(data: { message: "Custom action" })
    end
  end
end
```

## Success Responses

### Basic Success Response

```ruby
render_success(data: { message: "Operation successful" })
```

**Response:**

```json
{
  "success": true,
  "message": "Operation successful",
  "data": { "message": "Operation successful" }
}
```

### Success with Custom Status

```ruby
render_success(data: @event, status: :created)
```

**HTTP Status:** 201 Created

### Success with Pagination Metadata

```ruby
render_success(
  data: @events,
  pagination: {
    current_page: 1,
    per_page: 10,
    total_count: 150,
    total_pages: 15,
    links: { first: "/events?page=1", prev: null, next: "/events?page=2", last: "/events?page=15" }
  }
)
```

**Response:**

```json
{
  "success": true,
  "message": "Events retrieved successfully",
  "data": [...],
  "pagination": {
    "current_page": 1,
    "per_page": 10,
    "total_count": 150,
    "total_pages": 15,
    "links": {
      "first": "/events?page=1",
      "prev": null,
      "next": "/events?page=2",
      "last": "/events?page=15"
    }
  }
}
```

### Success with Custom Message

```ruby
render_success(data: @event, message: "Event created successfully")
```

## Error Responses

### Basic Error Response

```ruby
render_error(error: "Something went wrong")
```

**Response:**

```json
{
  "success": false,
  "error": "Something went wrong"
}
```

**HTTP Status:** 400 Bad Request

### Error with Validation Messages

```ruby
render_error(errors: @event.errors.full_messages)
```

**Response:**

```json
{
  "success": false,
  "error": "Validation failed",
  "errors": ["Name can't be blank", "Starts at must be in the future"]
}
```

### Error with Custom Status

```ruby
render_error(error: "Not found", status: :not_found)
```

**HTTP Status:** 404 Not Found

### Error with Details

```ruby
render_error(
  error: "Failed to create event",
  errors: ["Name can't be blank"],
  status: :unprocessable_entity
)
```

**HTTP Status:** 422 Unprocessable Entity

## Response Format

### Success Response Structure

```json
{
  "success": true,
  "message": "Descriptive message",
  "data": { ... },
  "pagination": { ... }  // Optional
}
```

### Error Response Structure

```json
{
  "success": false,
  "error": "General error message",
  "errors": ["Specific error 1", "Specific error 2"]  // Optional
}
```

## I18n Integration

Messages are automatically resolved from I18n locale files:

```yaml
en:
  event:
    success:
      index: "Events retrieved successfully"
      show: "Event retrieved successfully"
      create: "Event created successfully"
      update: "Event updated successfully"
    errors:
      create: "Failed to create event"
      update: "Failed to update event"
```

### Message Resolution

The Common module automatically resolves messages based on the model name and action:

- `index` → `{model}.success.index`
- `show` → `{model}.success.show`
- `create` → `{model}.success.create`
- `update` → `{model}.success.update`

### Override I18n Messages

```ruby
render_success(data: @event, message: "Custom message")
```

## Serialization

### With Serializer Options

```ruby
render_success(
  data: @event,
  serializer_options: { include: [:ticket_types, :venue] }
)
```

### Action-Specific Profile

Define both attributes and includes per action in a single method:

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
      fields: %i[id name slug]
    }
  }
end
```

The `default` key provides shared config inherited by all actions. Per-action keys override per-key (whole-key, not deep merge). Resolution order:
- If action has `fields:` → use it; else fall back to `default[:fields]`
- If action has `include:` → use it; else fall back to `default[:include]`
- If neither action nor `default` has `fields:` → no attribute restriction (all pass through)

### Action-Specific Attribute Visibility

Attributes can be further restricted per role (policy). The controller's `fields:` declares the per-action attribute profile:

```ruby
def serializer_profile
  {
    index:  { fields: %i[id name slug] },
    show:   { fields: %i[id name description slug metadata active created_at updated_at] },
    create: { fields: %i[id name slug] },
    update: { fields: %i[id name slug] }
  }
end
```

The policy further narrows per role:

```ruby
# In the policy:
def visible_attributes_for(record:, action:)
  return %i[id name description slug metadata active] if action == :show && user.role_name == "attendee"
  nil  # nil = no restriction, fall through to controller's serializer_profile
end
```

`render_success` automatically resolves the intersection of both layers and passes it through AMS `instance_options`. The serializer must include `Core::AttributeVisibilitySerializer` for slicing to take effect:

```ruby
class Events::CategorySerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
end
```

When `visible_attributes` is nil in `instance_options`, all serializer attributes are returned — zero config for controllers that don't need visibility control.

## Best Practices

1. **Always use `render_success` and `render_error`** — Ensures consistent response format
2. **Use I18n for messages** — Supports localization and centralized message management
3. **Include pagination metadata** — Helps clients implement navigation
4. **Use appropriate HTTP status codes** — 200 for success, 201 for created, 400/422 for errors
5. **Provide detailed error messages** — Include validation errors in the `errors` array

## Troubleshooting

### Missing Message in Response

Ensure the I18n key exists in your locale file:

```yaml
en:
  event:
    success:
      index: "Events retrieved successfully"  # Add missing key
```

### Serialization Not Working

Check that the serializer exists and is properly named:

```ruby
# Model: Core::Event
# Serializer: Core::EventSerializer
```

### Incorrect HTTP Status

Specify the status explicitly:

```ruby
render_success(data: @event, status: :created)
render_error(error: "Not found", status: :not_found)
```
