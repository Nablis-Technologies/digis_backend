# Core Review Workflow

## Scope

Reusable review primitives copied and adapted from `dscf-core`:

- `Core::Review` model (`core_reviews`)
- `Core::ReviewableModel` concern
- `Core::ReviewableController` concern

This is a generic approval engine for moderation-style workflows.

## Default Status Flow

- `draft -> pending`
- `pending -> approved | rejected | modify`
- `modify -> pending`

Default actions:

- `submit`
- `approve`
- `reject`
- `request_modification`
- `resubmit`

## Model Layer

Any model including `Core::ReviewableModel` gets:

- `reviews`
- `current_review_for(context)`
- `current_status_for(context)`
- helper predicates (`draft?`, `pending?`, `approved?`, etc.)

## Controller Layer

`Core::ReviewableController` can auto-generate action methods and supports:

- per-context statuses/transitions
- custom action maps
- `before_reviewable_action` / `after_reviewable_action` hooks
- optional model updates during `resubmit`

Authorization behavior:

- checks `current_user.has_permission?("#{controller_name}.#{action_name}")`
- enforces owner rules for `submit`/`resubmit`
- blocks self-review for `approve`/`reject`/`request_modification`

## Event-Ticketing Fit

Use this for approval-like flows only, such as:

- event publication review
- organizer verification
- refund exception approvals
- transfer dispute moderation

Do not force it into checkout, scan, or sync flows that need explicit transactional logic.
