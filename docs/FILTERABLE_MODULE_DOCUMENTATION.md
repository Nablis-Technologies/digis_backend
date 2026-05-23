# Filterable Module Documentation

## Overview

The `Core::Filterable` module provides Ransack-based filtering with SQL injection protection, dynamic query building, and seamless integration with the Common and Pagination modules.

## Table of Contents

- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Filter Parameters](#filter-parameters)
- [Common Filter Operators](#common-filter-operators)
- [Association Filtering](#association-filtering)
- [Model Configuration](#model-configuration)
- [API Examples](#api-examples)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Installation

The Filterable module is automatically included when you use `Core::Common`. No additional setup is required.

## Basic Usage

### Simple Filtering

```
GET /events?q[name_cont]=concert
GET /events?q[status_eq]=published
GET /events?q[starts_at_gteq]=2026-01-01
```

### Multiple Filters

```
GET /events?q[name_cont]=concert&status_eq]=published
```

### Sorting with Filtering

```
GET /events?q[name_cont]=concert&order_by=created_at&order_direction=desc
```

## Filter Parameters

| Parameter | Description |
|-----------|-------------|
| `q` | Ransack query hash |
| `q[attribute_operator]` | Filter on attribute with operator |
| `q[s]` | Sort string (e.g., "name asc", "created_at desc") |

## Common Filter Operators

### String Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `cont` | Contains | `q[name_cont]=concert` |
| `not_cont` | Does not contain | `q[name_not_cont]=cancelled` |
| `eq` | Equals | `q[status_eq]=published` |
| `not_eq` | Not equals | `q[status_not_eq]=draft` |
| `start` | Starts with | `q[name_start]=Summer` |
| `end` | Ends with | `q[name_end]=Festival` |
| `matches` | SQL LIKE | `q[name_matches]=%concert%` |

### Date/Time Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `gteq` | Greater than or equal | `q[starts_at_gteq]=2026-01-01` |
| `lteq` | Less than or equal | `q[ends_at_lteq]=2026-12-31` |
| `gt` | Greater than | `q[starts_at_gt]=2026-01-01` |
| `lt` | Less than | `q[ends_at_lt]=2026-12-31` |

### Numeric Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `eq` | Equals | `q[price_eq]=100` |
| `gteq` | Greater than or equal | `q[price_gteq]=50` |
| `lteq` | Less than or equal | `q[price_lteq]=200` |
| `in` | In array | `q[price_in]=50,100,150` |

### Boolean Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `eq` | Equals | `q[is_active_eq]=true` |
| `not_eq` | Not equals | `q[is_active_not_eq]=true` |

## Association Filtering

### Filter by Associated Model

```
GET /tickets?q[event_name_cont]=concert
GET /orders?q[user_phone_cont]=+251
```

### Filter by Multiple Associations

```
GET /orders?q[event_name_cont]=concert&q[user_verified_at_not_null]=1
```

## Model Configuration

### Required Methods

All models must implement these methods for Ransack security:

```ruby
module Core
  class Event < Core::ApplicationRecord
    def self.ransackable_attributes(_auth_object = nil)
      %w[id name description status starts_at ends_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket_types venue organizer]
    end
  end
end
```

### Association Model Configuration

```ruby
module Core
  class TicketType < Core::ApplicationRecord
    def self.ransackable_attributes(_auth_object = nil)
      %w[id name price quantity available event_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event]
    end
  end
end
```

## API Examples

### Filter Events by Name and Date Range

```
GET /events?q[name_cont]=festival&q[starts_at_gteq]=2026-06-01&q[ends_at_lteq]=2026-08-31
```

**Response:**

```json
{
  "success": true,
  "message": "Events retrieved successfully",
  "data": [
    {
      "id": 1,
      "name": "Summer Music Festival",
      "starts_at": "2026-06-15T18:00:00Z",
      "ends_at": "2026-06-15T23:00:00Z"
    }
  ],
  "pagination": {
    "current_page": 1,
    "per_page": 10,
    "total_count": 1,
    "total_pages": 1
  }
}
```

### Filter Orders by User Phone and Status

```
GET /orders?q[user_phone_cont]=+251&q[status_eq]=completed
```

### Filter Tickets by Event Name and Ticket Type

```
GET /tickets?q[event_name_cont]=concert&q[ticket_type_name_eq]=VIP
```

## Best Practices

1. **Always implement `ransackable_attributes` and `ransackable_associations`** — Required for filtering
2. **Whitelist only safe attributes** — Never include sensitive fields like `password_digest`
3. **Use association filtering sparingly** — Can cause N+1 queries if not careful
4. **Combine with pagination** — Always use `page` and `per_page` with filters
5. **Use `order_by` and `order_direction`** — Control sort order explicitly

## Troubleshooting

### "Attribute not whitelisted" Error

Add the attribute to `ransackable_attributes`:

```ruby
def self.ransackable_attributes(_auth_object = nil)
  %w[id name description status starts_at ends_at created_at updated_at]  # Add missing attribute
end
```

### "Association not whitelisted" Error

Add the association to `ransackable_associations`:

```ruby
def self.ransackable_associations(_auth_object = nil)
  %w[ticket_types venue organizer]  # Add missing association
end
```

### "Invalid filter parameter" Error

Check the operator is valid. Common operators: `cont`, `eq`, `gteq`, `lteq`, `start`, `end`, `in`.

### Slow Query Performance

- Add database indexes on filtered columns
- Use `eager_loaded_associations` to prevent N+1 queries
- Limit the number of association filters
