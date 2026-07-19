# Core Auditing

## Scope

The audit extraction intentionally keeps the runtime small and explicit.

Extracted pieces:

- `Core::AuditLog`
- `Core::AuditableModel`
- `Core::AuditLoggerJob`
- `Core::AuditLogSerializer`

## Design Choice

The old engine had a large controller-driven diffing concern. That was not copied in this first slice.

Instead, the new foundation expects calling code to decide:

- what action is being recorded
- what changed
- which actor performed it
- whether the audit should be written inline or via job

This keeps the audit layer easier to reason about and better suited to explicit ticketing workflows such as:

- organizer approval
- role assignment changes
- ticket transfer overrides
- refund decisions
- offline sync reconciliation

## Usage

Inline:

```ruby
role.record_audit!(
  "role.permissions_updated",
  audited_changes: { "permission_count" => { old: 2, new: 3 } },
  actor: current_user
)
```

Async:

```ruby
role.record_audit_later!(
  "role.permissions_updated",
  audited_changes: { "permission_count" => { old: 2, new: 3 } },
  actor: current_user
)
```

## Deferred Work

If the event app later needs reusable request/controller-level audit automation, it should be rebuilt against explicit ticketing workflows instead of copying the old DSL wholesale.
