# Payout hold and reconciliation

## Operating boundary

- Owner: Finance for organizer payouts; Marketplace Finance for seller payouts.
- Severity: SEV-2 for one payout; SEV-1 for a systemic provider or reserve
  problem.
- Authority: Finance approves reserve changes and release decisions. Organizers
  and sellers cannot bypass payout verification.

## Detect

Watch `processing` payouts, provider verification failures, reserve-monitor
observations, failed dispatch jobs, and reconciliation audit transitions.

## Immediate action

1. Preserve the payout intent, allocation, idempotency key, provider reference,
   and immutable ledger facts.
2. Confirm provider status using the provider's verification channel.
3. Leave an unknown payout in `processing`; do not submit it again.
4. For a reserve breach, pause discretionary payout dispatch while refunds and
   provider verification are evaluated by Finance.

## Prohibited action

- Never delete or recreate a payout to bypass its idempotency key.
- Never change ledger entries or payout allocations directly.
- Never infer provider success from an HTTP timeout.

## Diagnostics

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
puts Finance::Payout.where(status: "processing").order(:requested_at).limit(100)
  .pluck(:id, :organization_id, :provider, :provider_reference, :amount_minor,
         :currency, :idempotency_key).inspect
puts Marketplace::SellerPayout.where(status: "processing").order(:requested_at).limit(100)
  .pluck(:id, :seller_user_id, :provider, :provider_reference, :amount_minor,
         :currency, :idempotency_key).inspect
puts Finance::ProviderReservePolicy.order(:provider, :currency)
  .pluck(:provider, :currency, :target_minor).inspect
'
```

## Recovery

Organizer payout:

```bash
PAYOUT_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Finance::ReconcilePayoutJob.perform_now(ENV.fetch("PAYOUT_ID"))'
```

Resale seller payout:

```bash
SELLER_PAYOUT_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Marketplace::ReconcileSellerPayoutJob.perform_now(ENV.fetch("SELLER_PAYOUT_ID"))'
```

The reconciliation command verifies the provider and delegates the state
transition to the owning Finance or Marketplace service. Run the slow
reconciliation supervisor after a broad incident:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Reconciliation::SupervisorJob.perform_now("slow")'
```

Chapa organizer transfers use the separate Finance transfer client. A
transport timeout or ambiguous Chapa response remains processing; reconcile
with GET /v1/transfers/verify/<tx_ref> before taking any further action. Do
not retry the transfer merely because the HTTP request timed out.

## Communication and verification

Finance owns organizer/seller messaging and Support owns attendee impact when a
reserve or refund dependency is involved. Verify provider reference, final
payout state, allocation release/consumption, ledger immutability, and one
reconciliation audit observation.

## Staging drill

Make the fake payout provider return unknown, run reconciliation, then return a
verified result and run it again. Confirm no second transfer request, one final
payout transition, preserved ledger facts, and correct organizer/seller
communication status. Chapa transport tests use injected responses for the same
success, failure, pending, and timeout cases. Live organizer dispatch remains
blocked until the destination is verified; the provider adapter alone must not
be treated as beneficiary verification.
