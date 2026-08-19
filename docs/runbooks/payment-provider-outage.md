# Payment-provider outage

## Operating boundary

- Owner: Payments on-call, with Finance for settlement and refund decisions.
- Severity: SEV-1 when new payments or verification are broadly unavailable;
  SEV-2 when one provider or a small event scope is affected.
- Authority: Payments on-call may pause provider traffic. Finance must approve
  customer-facing money decisions.

## Detect

Look for provider adapter errors, growing `processing` payment attempts,
expired settlement-grace rows, webhook inbox failures, and readiness failures
reported by application telemetry. The readiness endpoint intentionally does
not probe providers; provider availability is a reconciliation concern.

## Immediate action

1. Confirm the provider incident and record the start time, provider, affected
   currency/method, and incident owner.
2. Stop blind retries or new provider traffic at the approved provider/router
   control if the incident is confirmed.
3. Leave uncertain attempts in their durable `processing` state. Do not mark an
   order paid, fulfilled, failed, or refunded from a timeout alone.
4. Keep the outbox and payment-event inbox running; they preserve recovery
   evidence while the provider is unavailable.

## Prohibited action

- Never resubmit an unknown payment manually.
- Never update payment, order, inventory, or ledger status directly in SQL.
- Never delete provider events or outbox rows to make dashboards look clean.

## Diagnostics

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
puts Orders::Payment.where(status: "processing")
  .order(:settlement_grace_expires_at).limit(100)
  .pluck(:id, :order_id, :provider, :provider_reference, :settlement_grace_expires_at).inspect
puts Orders::PaymentEvent.where(status: %w[received processing failed])
  .order(:received_at).limit(100)
  .pluck(:id, :provider, :provider_event_id, :status, :attempts_count).inspect
'
```

## Recovery

After the provider confirms verification and submission are safe:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Reconciliation::SupervisorJob.perform_now("fast")'
```

For one durable payment event, use its recorded ID:

```bash
PAYMENT_EVENT_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Orders::ProcessPaymentEventJob.perform_now(ENV.fetch("PAYMENT_EVENT_ID"))'
```

The reconciliation command verifies provider outcomes before accepting,
reversing, or releasing state. It does not invent a provider result.

## Communication and verification

Support owns attendee messaging; the organizer-success owner communicates
event-specific checkout impact. Verify that accepted payment, fulfillment,
inventory, and ledger rows reconcile exactly once, and attach provider status
evidence plus reconciliation audit IDs to the incident.

## Staging drill

Use a provider fake that returns an unknown result, advance settlement grace,
run the fast reconciliation supervisor, restore provider verification, and
confirm one final payment outcome with no duplicate fulfillment or ledger row.
