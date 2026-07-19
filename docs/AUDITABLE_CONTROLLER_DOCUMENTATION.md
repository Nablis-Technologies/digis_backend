# AuditableController Module Documentation

## Overview

The `Core::AuditableController` module provides automatic audit logging for controller actions. It captures request metadata, user context, and resource changes, then queues an `AuditLoggerJob` for asynchronous processing.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Configuration](#configuration)
- [Audit Events](#audit-events)
- [Custom Metadata](#custom-metadata)
- [Associated Auditing](#associated-auditing)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Basic Usage

Include the AuditableController module and configure which actions to audit:

```ruby
module Core
  class EventsController < Core::ApplicationController
    include Core::Common
    include Core::AuditableController

    auditable on: %i[create update destroy]

    def create
      super  # Audit log is created automatically
    end
  end
end
```

## Configuration

### Audit Specific Actions

```ruby
auditable on: %i[create update destroy]
```

### Audit All Actions

```ruby
auditable on: :all
```

### Audit with Custom Metadata

```ruby
auditable on: %i[create update], metadata: -> { { organizer_id: @event&.organizer_id } }
```

### Conditional Auditing

```ruby
auditable on: %i[update], if: -> { @obj&.significant_change? }
```

## Audit Events

### Captured Data

Each audit log entry includes:

| Field | Description |
|-------|-------------|
| `user_id` | ID of the authenticated user |
| `action` | Controller action (create, update, destroy) |
| `resource_type` | Model class name |
| `resource_id` | Record ID |
| `changes` | JSONB hash of changed attributes |
| `metadata` | Custom metadata hash |
| `ip_address` | Request IP address |
| `user_agent` | Request user agent |
| `created_at` | Timestamp |

### Example Audit Log

```json
{
  "user_id": "user-uuid",
  "action": "update",
  "resource_type": "Core::Event",
  "resource_id": "event-uuid",
  "changes": {
    "name": ["Old Name", "New Name"],
    "starts_at": ["2026-06-01T18:00:00Z", "2026-06-15T18:00:00Z"]
  },
  "metadata": {
    "organizer_id": "org-uuid"
  },
  "ip_address": "192.168.1.1",
  "user_agent": "Mozilla/5.0...",
  "created_at": "2026-05-21T10:30:00Z"
}
```

## Custom Metadata

### Static Metadata

```ruby
auditable on: %i[create], metadata: { source: "api" }
```

### Dynamic Metadata

```ruby
auditable on: %i[create update], metadata: -> {
  {
    organizer_id: current_user&.organization_id,
    ip_address: request.remote_ip
  }
}
```

### Conditional Metadata

```ruby
auditable on: %i[update], metadata: -> {
  if @obj&.significant_change?
    { significant: true, reason: "Major update detected" }
  else
    {}
  end
}
```

## Associated Auditing

Audit changes to associated records:

```ruby
auditable associated: :ticket_types, only: [:name, :price], on: %i[create update destroy]
```

### Multiple Associations

```ruby
auditable associated: [:ticket_types, :venue], on: %i[update]
```

## Best Practices

1. **Audit sensitive actions** — Always audit create, update, and destroy actions
2. **Include custom metadata** — Add context like organization ID, source, etc.
3. **Use asynchronous logging** — AuditLoggerJob prevents audit logging from impacting response times
4. **Audit associated changes** — Track changes to important associations
5. **Review audit logs regularly** — Monitor for suspicious activity

## Troubleshooting

### Missing Audit Logs

Ensure the `auditable` configuration includes the action:

```ruby
auditable on: %i[create update destroy]  # Add missing action
```

### Audit Job Failures

Check the job queue for failed `AuditLoggerJob` instances:

```bash
bin/rails jobs:work  # Process pending jobs
```

### Missing Metadata

Ensure the metadata lambda returns a hash:

```ruby
auditable on: %i[create], metadata: -> { { key: "value" } }  # Must return hash
```
