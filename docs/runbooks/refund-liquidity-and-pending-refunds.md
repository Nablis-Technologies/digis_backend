# Refund liquidity and pending refunds

## Operating boundary

- Owner: Finance on-call, with Payments for provider verification and Support
  for attendee communication.
- Severity: SEV-1 for a broad liquidity shortfall; SEV-2 for a bounded event or
  provider/currency scope.
- Authority: Finance approves reserve changes, top-ups, and any customer
  remedy outside the existing refund policy.

## Detect

Watch `Orders::Refund` rows in `pending_funds` or `processing`, provider reserve
monitor observations, retry deadlines, and the unresolved refund count on the
affected currency.

## Immediate action

1. Keep the refund obligation durable and visible.
2. Confirm whether the provider balance, platform reserve, or organizer
   balance is the limiting boundary.
3. Communicate that the refund is pending when policy requires it; do not call
   it paid until provider verification succeeds.
4. Leave the original refund idempotency key unchanged.

## Prohibited action

- Never reduce the refund amount to fit available liquidity.
- Never create a second refund obligation for the same payment/item.
- Never mark `succeeded` or write a ledger correction directly in SQL.

## Diagnostics

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
puts Orders::Refund.where(status: %w[pending_funds processing])
  .order(:next_retry_at).limit(100)
  .pluck(:id, :payment_id, :status, :amount_minor, :currency,
         :idempotency_key, :next_retry_at).inspect
puts Finance::ProviderReservePolicy.where(provider: ENV.fetch("PROVIDER"),
  currency: ENV.fetch("CURRENCY"))
  .pluck(:provider, :currency, :target_minor).inspect
' PROVIDER=chapa CURRENCY=ETB
```

## Recovery

After liquidity or provider verification is restored, resume the bounded refund
supervisor:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Reconciliation::SupervisorJob.perform_now("fast")'
```

For one known refund, use the durable job:

```bash
REFUND_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Orders::ReconcileRefundJob.perform_now(ENV.fetch("REFUND_ID"))'
```

Processing refunds use provider verification. Liquidity-blocked refunds use
the normal submission command with the original idempotency key.

## Communication and verification

Support owns attendee communication; Finance owns organizer/platform balance
communication. Verify provider reference, refund amount/currency, refund state,
payment state, and any ledger reversal. Attach the provider response and audit
transition to the incident.

## Staging drill

Configure the fake provider with insufficient balance, create a refundable
obligation, run the refund supervisor, then restore liquidity and run it again.
Confirm the refund remains pending without amount mutation and resolves once,
with no duplicate provider request or ledger effect.
