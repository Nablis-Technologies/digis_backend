# Authorizable Module Documentation

## Overview

The `Core::Authorizable` module provides RBAC (Role-Based Access Control) authorization using Pundit. It integrates with the `Core::User`, `Core::Role`, `Core::Permission`, and `Core::UserRole` models to enforce fine-grained access control across API endpoints.

## Table of Contents

- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Authorization Methods](#authorization-methods)
- [Policy Classes](#policy-classes)
- [Permission Checks](#permission-checks)
- [Error Responses](#error-responses)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Installation

Include the Authorizable module in your controller:

```ruby
module Core
  class SecuredController < Core::ApplicationController
    include Core::Authenticatable
    include Core::Authorizable

    before_action :authenticate_user!
    before_action :authorize_request

    def index
      # Authorized access
    end
  end
end
```

## Basic Usage

### Require Authorization

```ruby
before_action :authorize_request
```

This ensures all actions in the controller require the user to have the appropriate permissions.

### Action-Specific Authorization

```ruby
before_action :authorize_request, only: [:create, :update, :destroy]
```

Only specific actions require authorization.

### Skip Authorization

```ruby
skip_before_action :authorize_request, only: [:index, :show]
```

Public endpoints skip authorization.

## Authorization Methods

### `authorize_request`

Checks if the current user has permission to perform the action. Uses Pundit policies under the hood.

```ruby
before_action :authorize_request
```

### `authorize`

Manually authorize a specific action on a resource:

```ruby
def update
  @event = Event.find(params[:id])
  authorize @event, :update?
  # ...
end
```

### `policy`

Get the policy instance for a resource:

```ruby
def create
  @event = Event.new(event_params)
  policy(@event).create?
  # ...
end
```

### `policy_scope`

Scope records based on user permissions:

```ruby
def index
  @events = policy_scope(Event)
  render_success(data: @events)
end
```

## Policy Classes

### Basic Policy

```ruby
module Core
  class EventPolicy < ApplicationPolicy
    def index?
      user.has_permission?("event.index")
    end

    def show?
      user.has_permission?("event.index") || record.owner_id == user.id
    end

    def create?
      user.has_permission?("event.create")
    end

    def update?
      user.has_permission?("event.update") || record.owner_id == user.id
    end

    def destroy?
      user.has_permission?("event.destroy") || record.owner_id == user.id
    end
  end
end
```

### Application Policy

All policies inherit from `ApplicationPolicy`:

```ruby
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def update?
    false
  end

  def destroy?
    false
  end

  # Override to restrict visible attributes per role.
  # Returns an array of allowed attribute names, or nil for no restriction.
  # Singleton actions (show/update/destroy) receive the actual record.
  # Collection actions (index) receive an unsaved instance — visibility must be uniform.
  def visible_attributes_for(record:, action:)
    nil
  end
end
```

### Per-Role Attribute Visibility

Policies can restrict which attributes each role sees by overriding `visible_attributes_for`. The method receives the action being performed and the record (actual instance for singleton actions, unsaved for collections).

```ruby
module Events
  class CategoryPolicy < ApplicationPolicy
    def index?
      user.has_permission?("events.category.index")
    end

    def show?
      user.has_permission?("events.category.show")
    end

    def create?
      user.has_permission?("events.category.create")
    end

    def update?
      user.has_permission?("events.category.update")
    end

    def destroy?
      user.has_permission?("events.category.destroy")
    end

    def visible_attributes_for(record:, action:)
      config = self.class::VISIBILITY[action.to_sym]
      return nil unless config

      if config.key?(user_role_key)
        config[user_role_key]
      else
        config[:default]
      end
    end

    private

    def user_role_key
      return :admin if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
      :default
    end

    VISIBILITY = {
      show: {
        default: %i[id name description slug metadata active],
        admin: nil
      }
    }.freeze
  end
end
```

The resolved visible attributes are the intersection of:
- `controller.serializer_profile[action][:fields]` (per-action profile)
- `policy.visible_attributes_for(record:, action:)` (per-role restriction)

If either returns nil, the other passes through unchanged. The result is passed to AMS via `instance_options[:visible_attributes]`, and the serializer slices output using `Core::AttributeVisibilitySerializer`.

```ruby
class Events::CategorySerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
end
```

Only `attributes` are controlled by this system — associations remain managed by `serializer_profile[action][:include]`.

## Permission Checks

### Check Specific Permission

```ruby
def create
  if current_user.has_permission?("event.create")
    @event = Event.new(event_params)
    if @event.save
      render_success(data: @event, status: :created)
    else
      render_error(errors: @event.errors.full_messages)
    end
  else
    render_error(error: "Forbidden", status: :forbidden)
  end
end
```

### Check Multiple Permissions

```ruby
def update
  if current_user.has_any_permission?(["event.update", "event.admin"])
    # ...
  end
end
```

### Check All Permissions

```ruby
def destroy
  if current_user.has_all_permissions?(["event.destroy", "event.admin"])
    # ...
  end
end
```

## Error Responses

### Forbidden

```json
{
  "success": false,
  "error": "Forbidden"
}
```

**HTTP Status:** 403 Forbidden

### Unauthorized

```json
{
  "success": false,
  "error": "Not authorized"
}
```

**HTTP Status:** 401 Unauthorized

## Best Practices

1. **Always use `before_action :authorize_request`** — Protect all secured endpoints
2. **Define granular permissions** — Use specific permission names like `event.create`, `event.update`
3. **Use policy scopes** — Filter records based on user permissions
4. **Combine with Authenticatable** — Authentication before authorization
5. **Test policies thoroughly** — Write policy specs for all permission checks

## Troubleshooting

### "Forbidden" Error

Ensure the user has the required permission:

```ruby
current_user.has_permission?("event.create")
```

### "Policy not found" Error

Ensure the policy class exists and is properly namespaced:

```ruby
# app/policies/core/event_policy.rb
module Core
  class EventPolicy < ApplicationPolicy
    # ...
  end
end
```

### "User not authenticated" Error

Ensure `authenticate_user!` runs before `authorize_request`:

```ruby
before_action :authenticate_user!
before_action :authorize_request
```
