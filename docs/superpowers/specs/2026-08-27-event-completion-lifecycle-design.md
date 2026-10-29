# Event Completion Lifecycle Design

## Goal

Make event completion automatic for ordinary ended events while retaining an
authorized manual retry surface. Completion must remain an auditable domain
transition and must never bypass refund, cancellation, or payout-maturity
guards.

## Existing boundary

`Finance::CompleteEvent` already owns the locked event-completion transition,
the `event.completed` audit/outbox evidence, and the enqueue of
`Finance::MatureEventFundsJob`. `Events::EventDate` already models
`scheduled`, `postponed`, `cancelled`, and `completed` states, but ordinary API
updates intentionally cannot mutate the date lifecycle. There is currently no
automatic completion job and no public completion endpoint.

## Decision

### Automatic path

Add a bounded recurring `Finance::CompleteDueEventsJob` that runs every minute
and invokes `Finance::CompleteEvent` for published events with at least one
scheduled date whose `ends_at` has passed.

Inside the locked completion command, ended scheduled dates may transition to
`completed`. Postponed and cancelled dates are never rewritten. A future
scheduled date still prevents event completion. The command then requires every
materialized date to be `completed` or `cancelled` before changing the event.

The scheduler invocation uses a fixed internal source marker and a deterministic
idempotency key. It does not accept source or authorization parameters from an
HTTP request. Scheduler-originated audits use a nil actor plus explicit source
metadata; manual requests retain the authenticated actor.

### Manual path

Add:

```text
POST /events/:id/complete
```

The route requires `Idempotency-Key`, authorizes an organization owner/admin or
platform administrator, and calls the existing `Finance::CompleteEvent`
command exactly once. It performs the same date, cancellation, refund, and
state checks as the scheduler. It is a retry/operations surface, not an early
payout or override endpoint.

### Maturity and payout

Event completion continues to enqueue `Finance::MatureEventFundsJob`. Positive
ledger entries remain unavailable until the configured seven-day safety buffer
has elapsed. Payout construction and dispatch retain their existing verified
destination, reserve, and reconciliation gates.

## Failure and retry behavior

- A postponed, cancelled, or future date leaves the event published and
  produces a typed `event_dates_incomplete` result when completion is attempted.
- A scheduler retry reuses its deterministic key and produces no duplicate
  date/event audit or maturity job.
- A manual retry with the same key replays the original result; a different
  event, actor, or request identity returns `idempotency_conflict`.
- No direct SQL status mutation, preview-only environment flag, or payout
  bypass is introduced.

## Verification

Tests will cover ended-date automatic completion, postponed/future-date refusal,
manual authorization, missing idempotency keys, scheduler replay, manual replay,
audit/outbox evidence, one maturity-job enqueue, and unchanged payout maturity
behavior. The live preview drill will verify the endpoint and scheduler wiring;
provider timeout behavior remains transport-stubbed and deterministic in the
test suite.

## Scope exclusions

This change does not redesign event cancellation, refund orchestration, ledger
allocation, provider transfers, or the seven-day buffer. It also does not add a
public event-date status-edit endpoint.
