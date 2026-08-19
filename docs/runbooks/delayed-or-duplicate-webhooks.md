# Delayed or duplicate webhooks

## Operating boundary

- Owner: Payments on-call.
- Severity: SEV-2 unless delayed callbacks affect a large event or settlement
  window.
- Authority: Payments on-call may replay durable jobs; Finance approves manual
  customer decisions.

## Detect

Inspect payment events stuck in `received`, `processing`, or `failed`,
unpublished outbox rows, provider delivery timestamps, and duplicate provider
event IDs. A duplicate is expected to map to one `(provider,
provider_event_id)` inbox row.

## Immediate action

1. Record the provider event ID and delivery order exactly as received.
2. Confirm the provider signature was verified before treating the event as
   trustworthy.
3. Run the outbox sweep if the inbox row exists but processing was not queued.
4. Allow the durable payment-event job to retry; do not create a second event.

## Prohibited action

- Do not insert a second inbox row with a modified provider event ID.
- Do not process callbacks by copying their payload into a console command.
- Do not mark a payment accepted because a webhook says `paid` without the
  owning payment command validating amount, currency, order, and state.

## Diagnostics

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
puts Orders::PaymentEvent.where(provider: ENV.fetch("PROVIDER"),
  provider_event_id: ENV.fetch("PROVIDER_EVENT_ID"))
  .pluck(:id, :status, :attempts_count, :received_at, :processed_at).inspect
puts Core::OutboxEvent.where(event_type: "orders.payment_event.received",
  aggregate_id: ENV.fetch("PAYMENT_EVENT_ID"))
  .pluck(:id, :published_at, :attempts, :available_at, :last_error_code).inspect
' PROVIDER=chapa PROVIDER_EVENT_ID="..." PAYMENT_EVENT_ID="..."
```

## Recovery

Run the bounded outbox sweep, then replay only the durable IDs:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Core::ProcessOutboxJob.perform_now'

OUTBOX_EVENT_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Core::DispatchOutboxEventJob.perform_now(ENV.fetch("OUTBOX_EVENT_ID"))'

PAYMENT_EVENT_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Orders::ProcessPaymentEventJob.perform_now(ENV.fetch("PAYMENT_EVENT_ID"))'
```

All three operations are idempotent. Out-of-order callbacks remain durable
events; the owning payment processor decides whether the current payment state
can accept them.

## Communication and verification

Support owns attendee messaging. Verify one inbox row, one accepted payment at
most, one fulfillment effect, and one matching audit/outbox transition. Record
the provider delivery log and the final inbox/outbox IDs.

## Staging drill

Send a reverse-ordered batch followed by duplicate deliveries. Confirm all
unique provider identities are retained once, every duplicate is acknowledged
without a second business effect, and the outbox replay reaches the same final
state.
