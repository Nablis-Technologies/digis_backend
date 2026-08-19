# Event cancellation

## Operating boundary

- Owner: Events operations with Orders/Payments and Finance.
- Severity: SEV-1 for a live or paid event; SEV-2 for an early event with no
  accepted payments.
- Authority: The authorized event manager initiates cancellation; Finance and
  Support own money and attendee communications.

## Detect

Use the event cancellation status, payment snapshot counters, refund states,
and cancellation job schedule. A cancellation is not complete until every
captured payment snapshot is resolved or the incident is explicitly marked
partially failed.

## Immediate action

1. Confirm the event, cancellation reason, authority, and attendee message.
2. Initiate cancellation through the authenticated API with the required
   idempotency key.
3. Let `PrepareBatch` create durable payment snapshots and let the batch job
   claim them with `SKIP LOCKED`.
4. Suspend new sales and preserve ticket/financial history while refunds run.

## Prohibited action

- Do not delete the event, orders, payments, tickets, or ledger rows.
- Do not issue refunds manually outside the cancellation snapshot.
- Do not mark the cancellation completed while unresolved snapshots remain.

## Diagnostics

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
cancellation = Events::EventCancellation.find(ENV.fetch("CANCELLATION_ID"))
puts cancellation.attributes.slice("id", "event_id", "status", "total_payments_count",
  "resolved_payments_count", "failed_payments_count").inspect
puts cancellation.payment_snapshots.order(:id)
  .pluck(:id, :payment_id, :status, :attempts, :next_retry_at, :last_error).inspect
puts Orders::Refund.where(event_cancellation_id: cancellation.id)
  .pluck(:id, :payment_id, :status, :amount_minor, :currency).inspect
'
```

## Recovery

```bash
CANCELLATION_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Events::ProcessCancellationBatchJob.perform_now(ENV.fetch("CANCELLATION_ID"))'
```

The job schedules the next bounded batch from durable retry timestamps. Pending
funds and provider-unknown refunds are handled through the refund recovery
boundary; no second cancellation obligation is created on replay.

## Communication and verification

Support owns attendee messaging, the organizer-success owner communicates the
event outcome, and Finance communicates unresolved refund timing. Verify every
payment snapshot, refund, ticket credential revocation, cancellation counter,
and audit/outbox event before closing the incident.

## Staging drill

Create an event with accepted, pending, and failed provider outcomes. Cancel it,
replay the batch job, interrupt one worker, and resume it. Confirm no duplicate
refunds, no reactivated credentials, and correct `completed` or
`partially_failed` status.
