# Core Concerns Documentation

## Overview

The `Core` namespace provides a set of reusable controller concerns that standardize CRUD operations, authentication, authorization, pagination, filtering, audit logging, review workflows, and JSON response formatting across the Digis Backend event ticketing platform.

## Available Concerns

| Concern | File | Purpose |
|---------|------|---------|
| `Core::Common` | `app/controllers/concerns/core/common.rb` | Standardized CRUD operations |
| `Core::Pagination` | `app/controllers/concerns/core/pagination.rb` | Page-based pagination with HATEOAS links |
| `Core::JsonResponse` | `app/controllers/concerns/core/json_response.rb` | Standardized JSON response format |
| `Core::Filterable` | `app/controllers/concerns/core/filterable.rb` | Ransack-based filtering |
| `Core::Authenticatable` | `app/controllers/concerns/core/authenticatable.rb` | JWT Bearer token authentication |
| `Core::Authorizable` | `app/controllers/concerns/core/authorizable.rb` | RBAC authorization (Pundit) |
| `Core::AuditableController` | `app/controllers/concerns/core/auditable_controller.rb` | Automatic audit logging |
| `Core::ReviewableController` | `app/controllers/concerns/core/reviewable_controller.rb` | Approval workflow system |
| `Core::TokenAuthenticatable` | `app/controllers/concerns/core/token_authenticatable.rb` | Token generation helpers |

## Quick Start

### Minimal Controller

```ruby
module Core
  class EventsController < Core::ApplicationController
    include Core::Common

    private

    def model_params
      params.require(:event).permit(:name, :description, :starts_at, :ends_at)
    end

    def allowed_order_columns
      %w[id name starts_at ends_at created_at updated_at]
    end

    def serializer_profile
      {
        default: {
          fields: %i[id name slug],
          include: [:ticket_types]
        },
        show: {
          fields: %i[id name description slug active],
          include: [:ticket_types, :venue, :organizer]
        },
        create: {
          include: [:ticket_types]
        },
        update: {
          include: [:ticket_types]
        }
      }
    end
  end
end
```

### Full-Featured Controller

```ruby
module Core
  class EventsController < Core::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::ReviewableController

    auditable on: %i[create update]
    auditable associated: :reviews, only: [:status], on: %i[approve reject request_modification resubmit]

    # Override create to set initial review status
    def create
      super do
        resource = @clazz.new(model_params)
        resource.reviews.build(status: "draft", context: "default")
        resource
      end
    end

    # Override update for draft-only editing
    def update
      unless @obj.editable?
        return render_error(
          errors: ["Cannot update event after submission. Use modification request workflow."],
          status: :unprocessable_entity
        )
      end
      super
    end

    private

    def model_params
      params.require(:event).permit(:name, :description, :starts_at, :ends_at, :venue_id)
    end

    def eager_loaded_associations
      super + [{ reviews: { reviewed_by: :user_profile } }]
    end

    def allowed_order_columns
      %w[id name starts_at ends_at created_at updated_at]
    end

    def serializer_profile
      {
        default: {
          fields: %i[id name slug],
          include: [:ticket_types, :venue]
        },
        show: {
          fields: %i[id name description slug active created_at updated_at],
          include: [:ticket_types, :venue, :organizer, reviews: { reviewed_by: :user_profile }]
        },
        create: {
          include: [:reviews]
        },
        update: {
          include: [:ticket_types, :venue, reviews: { reviewed_by: :user_profile }]
        }
      }
    end
  end
end
```

## Model Requirements

All models used with these concerns must implement:

```ruby
module Core
  class Event < Core::ApplicationRecord
    # Ransack security whitelists (REQUIRED)
    def self.ransackable_attributes(_auth_object = nil)
      %w[id name description starts_at ends_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket_types venue organizer]
    end
  end
end
```

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
  "errors": ["Name can't be blank", "Starts at must be in the future"]
}
```

## I18n Message Configuration

Define messages in `config/locales/en.yml`:

```yaml
en:
  event:
    success:
      index: "Events retrieved successfully"
      show: "Event details retrieved successfully"
      create: "Event created successfully"
      update: "Event updated successfully"
      submit: "Event submitted for review successfully"
      approve: "Event approved successfully"
      reject: "Event rejected successfully"
      request_modification: "Modification requested for event successfully"
      resubmit: "Event resubmitted successfully"
    errors:
      create: "Failed to create event"
      update: "Failed to update event"
      submit: "Failed to submit event for review"
      approve: "Failed to approve event"
      reject: "Failed to reject event"
      request_modification: "Failed to request modification for event"
      resubmit: "Failed to resubmit event"
```

## Key Commands

```bash
# Run tests
bin/rails test

# Run a specific test file
bin/rails test test/controllers/core/events_controller_test.rb

# Run RuboCop
bundle exec rubocop

# Run RuboCop with auto-fix
bundle exec rubocop -A
```
