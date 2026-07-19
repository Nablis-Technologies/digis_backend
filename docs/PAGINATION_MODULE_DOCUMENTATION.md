# Pagination Module Documentation

## Overview

The `Core::Pagination` module provides page-based pagination with sorting, HATEOAS links, and metadata. It is automatically included when using `Core::Common` and integrates seamlessly with the filtering system.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Query Parameters](#query-parameters)
- [Response Format](#response-format)
- [HATEOAS Links](#hateoas-links)
- [Sorting](#sorting)
- [Configuration](#configuration)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Basic Usage

Pagination is automatically applied when the `page` parameter is present in the request:

```
GET /events?page=2&per_page=25
```

No additional controller code is required beyond including `Core::Common`.

## Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `page` | Integer | 1 | Page number (1-indexed) |
| `per_page` | Integer | 10 | Items per page |
| `order_by` | String | `id` | Column to sort by |
| `order_direction` | String | `asc` | Sort direction (`asc` or `desc`) |

### Examples

```
GET /events?page=1
GET /events?page=2&per_page=25
GET /events?order_by=created_at&order_direction=desc
GET /events?page=3&per_page=50&order_by=name&order_direction=asc
```

## Response Format

### Paginated Response

```json
{
  "success": true,
  "message": "Events retrieved successfully",
  "data": [
    { "id": 1, "name": "Event 1" },
    { "id": 2, "name": "Event 2" }
  ],
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

### Non-Paginated Response

When `page` parameter is absent:

```json
{
  "success": true,
  "message": "Events retrieved successfully",
  "data": [
    { "id": 1, "name": "Event 1" },
    { "id": 2, "name": "Event 2" }
  ]
}
```

## HATEOAS Links

The `links` object provides navigation URLs:

| Link | Description |
|------|-------------|
| `first` | URL to the first page |
| `prev` | URL to the previous page (null if on first page) |
| `next` | URL to the next page (null if on last page) |
| `last` | URL to the last page |

### Link Generation

Links preserve all query parameters including filters:

```
GET /events?q[name_cont]=festival&page=2&order_by=created_at&order_direction=desc
```

Response links:

```json
{
  "links": {
    "first": "/events?q[name_cont]=festival&page=1&order_by=created_at&order_direction=desc",
    "prev": "/events?q[name_cont]=festival&page=1&order_by=created_at&order_direction=desc",
    "next": "/events?q[name_cont]=festival&page=3&order_by=created_at&order_direction=desc",
    "last": "/events?q[name_cont]=festival&page=15&order_by=created_at&order_direction=desc"
  }
}
```

## Sorting

### Allowed Columns

Sorting is restricted to columns defined in `allowed_order_columns`:

```ruby
def allowed_order_columns
  %w[id name starts_at ends_at created_at updated_at]
end
```

### Invalid Column Handling

Requesting an invalid column returns an error:

```
GET /events?order_by=password_digest
```

Response:

```json
{
  "success": false,
  "error": "Column 'password_digest' is not allowed for sorting"
}
```

**HTTP Status:** 400 Bad Request

### Sort Direction

Valid values: `asc`, `desc` (case-insensitive)

Invalid values default to `asc`:

```
GET /events?order_direction=invalid  # Defaults to asc
```

## Configuration

### Default Page Size

Override the default page size:

```ruby
def default_per_page
  25
end
```

### Maximum Page Size

Enforce a maximum page size:

```ruby
def max_per_page
  100
end
```

Requests with `per_page` exceeding the maximum are capped:

```
GET /events?per_page=500  # Capped to max_per_page
```

## Best Practices

1. **Always implement `allowed_order_columns`** — Prevents SQL injection via sorting
2. **Use reasonable `per_page` limits** — Default 10, max 100
3. **Combine with filtering** — Pagination works seamlessly with `Core::Filterable`
4. **Use HATEOAS links for navigation** — Don't construct pagination URLs manually
5. **Index sorted columns** — Add database indexes on frequently sorted columns

## Troubleshooting

### "Column not allowed for sorting" Error

Add the column to `allowed_order_columns`:

```ruby
def allowed_order_columns
  %w[id name starts_at ends_at created_at updated_at]  # Add missing column
end
```

### Missing Pagination Metadata

Ensure the `page` parameter is present in the request:

```
GET /events?page=1  # Pagination metadata included
GET /events         # No pagination metadata
```

### Slow Pagination Performance

- Add database indexes on sorted columns
- Use `eager_loaded_associations` to prevent N+1 queries
- Consider cursor-based pagination for very large datasets
