# Common Module Documentation

## Overview

The `Core::Common` module provides standardized CRUD operations with automatic model resolution, eager loading, serialization, and error handling. It is the foundation for all API controllers in the Digis Backend platform.

## Table of Contents

- [Installation](#installation)
- [CRUD Actions](#crud-actions)
- [Yield Block Customization](#yield-block-customization)
- [Required Methods](#required-methods)
- [API Response Format](#api-response-format)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Installation

Include the Common module in your controller:

```ruby
module Core
  class YourController < Core::ApplicationController
    include Core::Common

    private

    def model_params
      params.require(:your_model).permit(:field1, :field2)
    end

    def allowed_order_columns
      %w[id field1 field2 created_at updated_at]
    end

    def serializer_profile
      {
        default: {
          fields: %i[id name slug],
          include: [:association1]
        },
        show: {
          fields: %i[id name description slug active],
          include: [:association1, :association2]
        }
      }
    end
  end
end
```

## CRUD Actions

The Common module provides four main actions that work out of the box:

### `index` — List Resources

**Basic Usage:**

```ruby
def index
  # Uses default behavior — returns all records with pagination if requested
end
```

> **Message Resolution**: Automatically uses `{model}.success.index` for success messages.

**With Custom Logic:**

```ruby
def index
  # Return custom data
  custom_data = YourModel.where(active: true)
  yield custom_data
end

def index
  # Return data with custom serializer options
  yield { include: [:associations], meta: { custom: "data" } }
end

def index
  # Return both custom data and options
  custom_data = YourModel.includes(:associations)
  options = { include: [:associations] }
  yield [custom_data, options]
end
```

### `show` — Get Single Resource

**Basic Usage:**

```ruby
def show
  # Uses default behavior — finds record by ID with eager loading
end
```

> **Message Resolution**: Automatically uses `{model}.success.show` for success messages.

**With Custom Logic:**

```ruby
def show
  custom_record = find_record_with_special_logic
  yield custom_record
end
```

### `create` — Create New Resource

**Basic Usage:**

```ruby
def create
  # Uses model_params and default validation
end
```

> **Message Resolution**: Automatically uses `{model}.success.create` for success messages.

**With Custom Logic:**

```ruby
def create
  super do
    resource = @clazz.new(model_params)
    # Add custom logic before save
    resource.created_by = current_user
    resource
  end
end
```

### `update` — Update Existing Resource

**Basic Usage:**

```ruby
def update
  # Uses model_params and default validation
end
```

> **Message Resolution**: Automatically uses `{model}.success.update` for success messages.

**With Custom Logic:**

```ruby
def update
  super do
    # Add custom logic before save
    @obj.updated_by = current_user
    @obj
  end
end
```

## Yield Block Customization

The Common module supports three yield patterns:

### Pattern 1: Custom Data Only

```ruby
def index
  super do
    User.active.verified  # Return custom ActiveRecord::Relation
  end
end
```

### Pattern 2: Custom Data with Options

```ruby
def show
  super do
    options = {
      include: [:profile, :roles],
      meta: { last_login: @obj.last_login_at }
    }
    [@obj, options]  # Return [data, serializer_options]
  end
end
```

### Pattern 3: Hash Options Only (Uses Default Data)

```ruby
def index
  super do
    { include: [:profile], meta: { total: User.count } }
  end
end
```

## Required Methods

All controllers using `Core::Common` must implement:

### `model_params`

Strong parameters for the model:

```ruby
def model_params
  params.require(:event).permit(:name, :description, :starts_at, :ends_at)
end
```

### `eager_loaded_associations` (Optional)

Derives from `serializer_profile` by default — any association in the action's `include:` list is automatically preloaded:

```ruby
def eager_loaded_associations
  serializer_includes_for_action(action_name)
end
```

Override when you need to preload associations not rendered in the response (e.g., for computed serializer methods, or deeper nesting than what AMS receives):

```ruby
def eager_loaded_associations
  super + [{ ticket_types: :prices }]
end
```

### `allowed_order_columns` (Optional)

Whitelisted columns for sorting (security):

```ruby
def allowed_order_columns
  %w[id name starts_at ends_at created_at updated_at]
end
```

### `serializer_profile` (Optional)

Defines which attributes and associations to expose per action in a single declaration. Returns a hash with action symbols as keys, plus an optional `default` key for shared config inherited by all actions.

```ruby
def serializer_profile
  {
    default: {
      fields: %i[id name slug],
      include: [:ticket_types]
    },
    show: {
      fields: %i[id name description slug metadata active created_at updated_at],
      include: [:ticket_types, :venue, :organizer]
    },
    create: {
      fields: %i[id name slug]
    },
    update: {
      fields: %i[id name slug],
      include: [:ticket_types, :venue]
    }
  }
end
```

**Resolution rules:**
- `default` is inherited by all actions unless overridden per-action.
- Override is whole-key — if an action has `fields:`, it replaces `default`'s `fields` entirely. Same for `include:`.
- `fields:` controls which resource attributes appear in the response (requires `Core::AttributeVisibilitySerializer` in the serializer). Per-role restrictions are handled by `visible_attributes_for` in the policy.
- `include:` controls which associations are side-loaded via AMS.
- If neither action nor `default` has `fields:` → all serializer attributes returned (default behavior).
- If neither action nor `default` has `include:` → no associations side-loaded.

## API Response Format

### Success Response

```json
{
  "success": true,
  "message": "Events retrieved successfully",
  "data": { ... },
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

### Error Response

```json
{
  "success": false,
  "error": "Failed to create event",
  "errors": ["Name can't be blank"]
}
```

## Pagination Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `page` | 1 | Page number |
| `per_page` | 10 | Items per page |
| `order_by` | `id` | Column to sort by (must be in `allowed_order_columns`) |
| `order_direction` | `asc` | Sort direction (`asc` or `desc`) |

### Example Requests

```
GET /events?page=2&per_page=25
GET /events?order_by=created_at&order_direction=desc
GET /events?q[name_cont]=concert&q[starts_at_gteq]=2026-01-01
```

## Best Practices

1. **Always implement `model_params`** — Required for create/update operations
2. **Always implement `allowed_order_columns`** — Prevents SQL injection via sorting
3. **Always implement `ransackable_attributes` and `ransackable_associations`** on models — Required for filtering
4. **Use yield blocks for custom logic** — Don't override entire actions when you only need to customize data
5. **Use `serializer_profile` for includes** — `eager_loaded_associations` derives from it automatically. Override only when you need different preload depth.
6. **Use `serializer_profile`** — Controls which attributes and associations are returned per action in a single declaration. Use `default` key for shared config.

## Troubleshooting

### "Model not found" Error

The Common module resolves models automatically based on controller namespace. If your model isn't found:

- Controller `Core::EventsController` → Model `Core::Event`
- Ensure the model exists and is properly namespaced

### "Unpermitted parameters" Error

Check your `model_params` method includes all fields you're trying to save:

```ruby
def model_params
  params.require(:event).permit(:name, :description)  # Add missing fields here
end
```

### "Column not allowed for sorting" Error

Add the column to `allowed_order_columns`:

```ruby
def allowed_order_columns
  %w[id name starts_at ends_at created_at updated_at]  # Add missing column here
end
```
