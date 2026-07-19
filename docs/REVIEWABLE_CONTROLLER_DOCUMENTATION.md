# ReviewableController Module Documentation

## Overview

The `Core::ReviewableController` module provides an approval workflow system for resources. It enables draft → submit → review → approve/reject/modification-request → resubmit lifecycle management with full audit trail integration.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Review Lifecycle](#review-lifecycle)
- [Controller Actions](#controller-actions)
- [Review Statuses](#review-statuses)
- [Configuration](#configuration)
- [Error Responses](#error-responses)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Basic Usage

Include the ReviewableController module in your controller:

```ruby
module Core
  class EventsController < Core::ApplicationController
    include Core::Common
    include Core::ReviewableController

    reviewable on: %i[approve reject request_modification resubmit]

    def create
      super do
        resource = @clazz.new(model_params)
        resource.reviews.build(status: "draft", context: "default")
        resource
      end
    end
  end
end
```

## Review Lifecycle

### Status Flow

```
draft → submitted → under_review → approved
                          ↓
                    rejected → resubmitted → under_review → approved
                          ↓
              modification_requested → resubmitted → under_review → approved
```

### Status Descriptions

| Status | Description |
|--------|-------------|
| `draft` | Resource is being created/edited, not yet submitted |
| `submitted` | Resource submitted for review |
| `under_review` | Reviewer is actively reviewing |
| `approved` | Resource approved and published |
| `rejected` | Resource rejected, cannot be resubmitted |
| `modification_requested` | Reviewer requested changes, can resubmit |
| `resubmitted` | Resource resubmitted after modification request |

## Controller Actions

### Submit for Review

```ruby
def submit
  @event = Event.find(params[:id])
  authorize @event, :submit?
  @event.submit_for_review!
  render_success(data: @event, message: "Event submitted for review")
end
```

### Approve

```ruby
def approve
  @event = Event.find(params[:id])
  authorize @event, :approve?
  @event.approve!(reviewed_by: current_user, notes: params[:notes])
  render_success(data: @event, message: "Event approved")
end
```

### Reject

```ruby
def reject
  @event = Event.find(params[:id])
  authorize @event, :reject?
  @event.reject!(reviewed_by: current_user, notes: params[:notes])
  render_success(data: @event, message: "Event rejected")
end
```

### Request Modification

```ruby
def request_modification
  @event = Event.find(params[:id])
  authorize @event, :request_modification?
  @event.request_modification!(reviewed_by: current_user, notes: params[:notes])
  render_success(data: @event, message: "Modification requested")
end
```

### Resubmit

```ruby
def resubmit
  @event = Event.find(params[:id])
  authorize @event, :resubmit?
  @event.resubmit!
  render_success(data: @event, message: "Event resubmitted")
end
```

## Review Statuses

### Check Status

```ruby
@event.review_status
# => "draft", "submitted", "approved", etc.
```

### Status Methods

```ruby
@event.draft?
@event.submitted?
@event.under_review?
@event.approved?
@event.rejected?
@event.modification_requested?
@event.resubmitted?
```

### Editable Check

```ruby
def update
  unless @event.editable?
    return render_error(
      errors: ["Cannot update event after submission. Use modification request workflow."],
      status: :unprocessable_entity
    )
  end
  super
end
```

## Configuration

### Custom Review Contexts

```ruby
reviewable on: %i[approve reject], context: "content_review"
```

### Required Reviewer Roles

```ruby
reviewable on: %i[approve reject], required_role: :admin
```

### Auto-Submit on Create

```ruby
def create
  super do
    resource = @clazz.new(model_params)
    resource.reviews.build(status: "submitted", context: "default")
    resource
  end
end
```

## Error Responses

### Invalid Status Transition

```json
{
  "success": false,
  "error": "Cannot approve event in draft status"
}
```

**HTTP Status:** 400 Bad Request

### Not Authorized

```json
{
  "success": false,
  "error": "Not authorized to approve events"
}
```

**HTTP Status:** 403 Forbidden

### Already Reviewed

```json
{
  "success": false,
  "error": "Event has already been approved"
}
```

**HTTP Status:** 409 Conflict

## Best Practices

1. **Always check `editable?` before updates** — Prevents modifying submitted/approved resources
2. **Use review notes** — Provide context for approvals/rejections
3. **Authorize review actions** — Only admins/reviewers can approve/reject
4. **Log review actions** — Integrate with AuditableController for full audit trail
5. **Handle status transitions gracefully** — Return clear error messages for invalid transitions

## Troubleshooting

### "Cannot update after submission" Error

Check the resource status:

```ruby
@event.editable?  # Returns false if submitted/approved
```

Use the modification request workflow:

```ruby
@event.request_modification!(reviewed_by: current_user, notes: "Please update the description")
@event.resubmit!
```

### "Invalid status transition" Error

Check the current status and allowed transitions:

```ruby
@event.review_status  # Current status
@event.can_approve?   # Check if approve is allowed
@event.can_reject?    # Check if reject is allowed
```

### "Not authorized" Error

Ensure the user has the required role:

```ruby
current_user.has_role?(:admin) || current_user.has_role?(:reviewer)
```
