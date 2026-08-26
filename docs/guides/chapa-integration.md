# Chapa Integration Guide

This guide explains how Digis integrates with Chapa, how a payment moves
through the system, and how to test the integration locally and on Render.

The provider-specific design is documented in
[the Chapa design specification](../superpowers/specs/2026-08-19-chapa-payment-provider-design.md).
For outages and recovery, see the
[payment-provider outage runbook](../runbooks/payment-provider-outage.md).

## 1. The most important rule

The browser redirect, callback query string, and customer-visible checkout
receipt are not payment proof.

Digis follows this sequence:

1. Chapa initializes a hosted checkout.
2. Digis returns the buyer-safe `checkout_url` and keeps the payment
   `processing`.
3. Chapa redirects or notifies Digis after the payment attempt.
4. Digis verifies the transaction with Chapa.
5. Only the verified result becomes an `Orders::PaymentEvent`.
6. Solid Queue processes that event and moves the order to its final state.

Therefore, a caller cannot make an unpaid order successful by sending
`status=success` to the callback endpoint.

## 2. Components

| Component | Responsibility |
| --- | --- |
| `Payments::Providers::ChapaClient` | Chapa HTTP, authentication, payload conversion, result mapping, test/live key validation, and webhook HMAC verification |
| `Payments::Providers::ChapaAdapter` | Provider-neutral adapter used by Orders |
| `Payments::Providers::Registration` | Registers Chapa only when enabled and validates preview mode |
| `Orders::StartPaymentAttempt` | Creates a durable payment attempt and calls the provider |
| `Orders::PaymentCallbacksController` | Receives the unauthenticated GET redirect |
| `Orders::RecordPaymentCallback` | Verifies the transaction and records a normalized event |
| `Orders::PaymentWebhooksController` | Receives the separate unauthenticated POST webhook |
| `Orders::RecordPaymentEvent` | Verifies the webhook signature and records the event |
| `Orders::ProcessPaymentEventJob` | Applies the verified event to payment/order fulfillment |
| `Core::ProcessOutboxJob` | Publishes payment-event processing work reliably |

Chapa payloads stay behind the provider adapter. Digis persists normalized
payment evidence, not API keys, signatures, or unfiltered provider responses.

## 3. Payment lifecycle

```text
Quote -> Order -> Payment attempt -> Chapa hosted checkout
                                      |
                 +--------------------+--------------------+
                 |                                         |
        GET callback                              POST signed webhook
                 |                                         |
                 +------ server-side Chapa verification ---+
                                      |
                          PaymentEvent inbox row
                                      |
                              Outbox and job
                                      |
                      payment/order/fulfillment state
```

### Initialization

The client sends Chapa:

- `amount` as a major-unit decimal string converted from integer minor units;
- uppercase ISO currency such as `ETB`;
- the durable payment idempotency key as `tx_ref`;
- buyer email and normalized phone;
- configured callback and return URLs when present.

Digis accepts canonical Ethiopian numbers such as `+251900123456`, then
normalizes the provider payload to Chapa's local format, such as
`0900123456`. The stored Digis phone remains in `+251...` format.

When Chapa returns a hosted checkout URL, Digis stores the canonical result as
`processing` with `raw_status: initialized`. A successful initialization or
the existence of a checkout URL does not mean the customer paid.

### Verification and acceptance

| Verified provider result | Normalized event | Effect |
| --- | --- | --- |
| success | `payment.succeeded` | Payment may be accepted and the order fulfilled |
| failed/declined | `payment.failed` | Payment remains unpaid |
| cancelled | `payment.cancelled` | Payment remains unpaid |
| unknown/pending/timeout | `payment.pending` | Payment remains unresolved for reconciliation |

Unknown outcomes never become success. Replayed callbacks and webhooks are
deduplicated by durable provider-event identity.

## 4. Callback, webhook, and return URL

These are different endpoints and must not be combined.

### Callback URL

Set `CHAPA_CALLBACK_URL` to:

```text
GET https://<digis-host>/payments/chapa/callback
```

Chapa may send `trx_ref`, `ref_id`, and `status`. Digis uses them for
lookup and diagnostics, then verifies the transaction with Chapa before
creating the durable event.

### Webhook URL

Configure this separately in the Chapa dashboard:

```text
POST https://<digis-host>/payments/chapa/webhook
```

The webhook is signed and handled independently. Keep both endpoints: the
callback supports the browser redirect flow, while the webhook provides a
server-to-server notification path.

### Return URL

Set `CHAPA_RETURN_URL` to the customer-facing frontend destination. It is
not a payment confirmation endpoint. A dummy HTML page is optional for backend
testing; server-side verification does not depend on it.

## 5. Environment configuration

Set these values in Render or another secret manager, never in Git, seeds, or
Postman variables containing secrets:

| Variable | Required | Preview meaning |
| --- | --- | --- |
| `CHAPA_PAYOUT_ENABLED` | yes for transfer testing | `true` registers the Finance Chapa transfer adapter |
| `CHAPA_ENABLED` | yes | `true` registers Chapa |
| `CHAPA_MODE` | yes | `test` for Render preview |
| `CHAPA_SECRET_KEY` | yes | Chapa `CHASECK_TEST-...` key |
| `CHAPA_WEBHOOK_SECRET` | yes | Secret used for raw-body HMAC verification |
| `CHAPA_API_BASE_URL` | no | Defaults to `https://api.chapa.co/v1` |
| `CHAPA_CALLBACK_URL` | recommended | `https://<digis-host>/payments/chapa/callback` |
| `CHAPA_RETURN_URL` | recommended | Frontend or test return page |

Preview safety:

- CHAPA_PAYOUT_ENABLED is independent from checkout registration; keep it
  disabled until transfer credentials and an approved payout-destination
  workflow are available.

- `RENDER_PREVIEW=true` requires `CHAPA_MODE=test`.
- Preview requires a `CHASECK_TEST-...` key.
- Live `CHASECK-...` keys must not be used in preview.
- Restart/redeploy after changing environment variables.

Render's Blueprint marks secret fields with `sync: false`; enter their
values manually in the service environment. Merge updates instead of
replacing the full environment-variable set.

## 6. Seeded test data

The preview seed includes a Chapa-specific buyer because Chapa validates email
values and test phone numbers independently of Digis authentication:

```text
Phone:    +251900123456
Email:    chapa.test@gmail.com
Password: password123
```

Use Chapa's documented test number:

```text
0900123456
```

Run the preview profile only in a testing environment:

```bash
DIGIS_SEED_PROFILE=preview bin/rails db:seed
```

The same user is available through the `dev` profile. The default
`bin/rails db:seed` command loads only the production-safe base profile. Never
use these credentials or test keys in production.

## 7. Local verification

### Focused automated tests

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/payments/providers/chapa_client_test.rb \
  test/services/finance/payout_providers/chapa_transfer_client_test.rb \
  test/config/finance_payout_providers_configuration_test.rb \
  test/services/orders/record_payment_callback_test.rb \
  test/controllers/orders/payment_callbacks_controller_test.rb \
  test/controllers/orders/payment_webhooks_controller_test.rb \
  test/services/orders/process_payment_event_test.rb
```

These tests cover request shape, phone and amount conversion, hosted-checkout
pending behavior, result mapping, signature verification, callback
verification-before-persistence, deduplication, and event processing.

Before merging provider changes:

```bash
N_PLUS_ONE=1 bundle exec rails test
bundle exec rubocop
bin/rails zeitwerk:check
jq empty 'postman/Digis API_collection.json'
```

### Local API smoke test

Load secrets from a local secret manager or uncommitted environment file. Do
not paste keys into shell history or logs.

```bash
CHAPA_ENABLED=true \
CHAPA_PAYOUT_ENABLED=true \
CHAPA_MODE=test \
CHAPA_SECRET_KEY='CHASECK_TEST-...' \
CHAPA_WEBHOOK_SECRET='local-test-webhook-secret' \
CHAPA_CALLBACK_URL='http://localhost:3000/payments/chapa/callback' \
CHAPA_RETURN_URL='http://localhost:3000/payment-test-return' \
bin/rails server
```

Then:

1. `POST /auth/login` with the seeded Chapa user.
2. Build a quote for the seeded Chapa event/product.
3. Create an order with the quote token and an `Idempotency-Key`.
4. Start a `chapa` payment attempt.
5. Confirm the response contains `checkout_url` and payment status
   `processing`.
6. Complete the hosted test checkout with `0900123456`.
7. Confirm the callback or webhook is verified and the event processor
   fulfills the order once.

## 8. Chapa transfer testing

Finance uses a separate Finance::PayoutProviders::ChapaTransferClient for
Chapa POST /transfers, GET /transfers/verify/:reference, and balance
endpoints. It does not reuse the checkout/refund client. Automated tests inject
the HTTP transport and return deterministic success, failed, pending, and
timeout responses; this keeps the test suite independent of provider timing.
Chapa's test mode may also expose provider-controlled transfer outcomes, but
the application never treats a requested status as proof of settlement.

Organizer payout destinations are organization-scoped and encrypted at rest.
Registration performs provider-first verification when available; unsupported
provider verification leaves the destination pending. Preview fixtures may use
an explicit synthetic test destination. Every mutating destination request
requires an `Idempotency-Key`; replaying the same key with different request
data returns `idempotency_conflict`.

The payout-account endpoints are:

```text
GET  /finance/organizations/:organization_id/payout_accounts
POST /finance/organizations/:organization_id/payout_accounts
POST /finance/organizations/:organization_id/payout_accounts/:id/verify
POST /finance/organizations/:organization_id/payout_accounts/:id/set_default
POST /finance/organizations/:organization_id/payout_accounts/:id/suspend
POST /finance/organizations/:organization_id/payout_accounts/:id/close
```

Account numbers and holder names are never returned by the API. A payout
snapshots the verified destination ID, then passes decrypted details only to
the Chapa transfer adapter. A timeout remains processing and is reconciled;
the transfer is never blindly submitted a second time.

## 9. Render preview end-to-end test

Always use a fresh checkout. Old hosted checkouts can expire before testing
finishes.

```bash
BASE_URL='https://<digis-host>'
curl -sS -X POST "$BASE_URL/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"+251900123456","password":"password123"}'
```

Use the returned access token with the requests in
[the Postman collection](../../postman/Digis%20API_collection.json):

```text
POST /events/:event_id/order_quotes
POST /events/:event_id/orders
POST /orders/:order_id/payment_attempts
GET  /payments/chapa/callback?trx_ref=<transaction-reference>&status=success
POST /payments/chapa/webhook
```

### Exact request sequence

The frontend or Postman must carry these values forward:

| Value | Produced by | Used by |
| --- | --- | --- |
| `access_token` | Login | Bearer authentication on quote/order/payment requests |
| `quote_token` | Quote response | Order creation |
| `order_id` | Order response | Payment-attempt creation |
| `checkout_url` | Payment-attempt response | Browser navigation to Chapa |
| `tx_ref` / transaction reference | Payment response or database payment row | Callback verification |

#### 1. Login

```http
POST /auth/login
Content-Type: application/json

{
  "identifier": "+251900123456",
  "password": "password123"
}
```

Read `data.access_token` from the response. Do not log or commit it.

#### 2. Build the quote

```http
POST /events/<event_id>/order_quotes
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "charge_currency": "ETB",
  "items": [
    {
      "event_product_id": "<event_product_id>",
      "quantity": 1
    }
  ]
}
```

Read `data.quote_token`. The quote response also contains the immutable
display totals and its expiration time.

#### 3. Create the order

```http
POST /events/<event_id>/orders
Authorization: Bearer <access_token>
Content-Type: application/json
Idempotency-Key: <new-unique-key>

{
  "order": {
    "quote_token": "<quote_token>"
  }
}
```

Read `data.id` as `order_id`. If the request times out, retry with the same
quote token and the same `Idempotency-Key`; do not generate a new key for an
ambiguous retry.

#### 4. Start the Chapa payment attempt

```http
POST /orders/<order_id>/payment_attempts
Authorization: Bearer <access_token>
Content-Type: application/json
Idempotency-Key: <new-payment-attempt-key>

{
  "payment_attempt": {
    "provider": "chapa",
    "payment_method": "telebirr"
  }
}
```

The buyer-safe response contains `data.checkout_url`. Open that URL in the
browser. The payment remains `processing` until a verified provider result is
processed. The frontend must not mark the order paid based on the URL or on a
browser redirect.

Chapa's customer identity fields are optional in the initialize contract. Digis
sends each optional field when the buyer has a value for it and omits that field
when it is blank. Phone-first or shadow accounts therefore send the phone
number without requiring names or email.

#### 5. Provider callback

Chapa calls the unauthenticated callback after checkout:

```http
GET /payments/chapa/callback?trx_ref=<transaction-reference>&ref_id=<provider-reference>&status=success
```

The application verifies `trx_ref` with Chapa. A successful HTTP response
means that a durable payment event was accepted for asynchronous processing;
it does not mean the frontend should skip checking the order result.

#### 6. Provider webhook

The separate signed webhook has no bearer token:

```http
POST /payments/chapa/webhook
Content-Type: application/json
X-Chapa-Signature: <hmac-of-the-exact-raw-body>

{
  "event": "charge.success",
  "type": "API",
  "status": "success",
  "reference": "<chapa-reference>",
  "tx_ref": "<transaction-reference>"
}
```

The application maps Chapa's `reference` to the durable provider-event identity
and uses `tx_ref` to locate the Digis payment when the provider reference was
not present during initialization. The Postman request is a shape example; its
signature must be generated from the exact raw body with the configured
webhook secret, so it is not a substitute for a real Chapa-signed delivery.

### Frontend behavior

The frontend should:

1. Keep the order in a pending/payment-processing screen after receiving
   `checkout_url`.
2. Open `checkout_url` in the same tab, a new tab, or an in-app browser.
3. Treat the return page as presentation only.
4. Refresh the order/payment projection through the application's normal
   authenticated read surface after returning.
5. Display success only after the backend reports the accepted payment/order
   state, not merely after the redirect.

There is currently no separate public payment-status GET route. If a frontend
needs polling, it should use the existing authorized order/payment read surface
or a future explicitly designed status endpoint; do not expose a new provider
verification endpoint from the frontend.

After completing the hosted test checkout, the expected database sequence is:

```text
orders_payments.status           processing -> succeeded
orders_payment_events.event_type payment.succeeded
orders_payment_events.status     received -> processed
core_outbox_events.published_at  populated
orders_orders.status             pending_payment -> fulfilled
orders_orders.paid_at            populated
```

If Chapa reports pending, the correct result is a pending event followed by
reconciliation. If the order expired, create a new quote, order, and payment
attempt; do not revive the old order with SQL.

## 10. Webhook testing

The webhook requires an HMAC-SHA256 signature over the exact raw request body.
The application accepts Chapa's documented `chapa-signature` and
`x-chapa-signature` headers and never logs the body or secret.

For local automated tests:

```ruby
raw_body = '{"event":"charge.success","tx_ref":"attempt-1"}'
signature = OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, raw_body)
```

The signature secret must match `CHAPA_WEBHOOK_SECRET`. Never log the raw
webhook body, secret, or authorization header.

## 11. Troubleshooting

### Initialization returns failed

Check:

1. `CHAPA_ENABLED=true` and the application restarted.
2. `CHAPA_MODE` matches the key prefix.
3. Preview uses `CHASECK_TEST-...`.
4. The buyer email is accepted by Chapa.
5. The phone is a supported test number.
6. The amount is a nonnegative integer minor-unit value.
7. Render logs show the safe provider status and failure code.

### Callback returns payment_not_found

Use the exact transaction reference stored in
`orders_payments.idempotency_key` (`tx_ref`). Do not use the hosted checkout
URL token or receipt reference unless it is stored as the provider reference.

### Callback returns 202 but the order remains pending

This may be correct while the event is queued or Chapa reports pending. Check
`orders_payment_events`, `core_outbox_events`, and Solid Queue. Do not
update payment or order state directly in SQL.

### Webhook reports invalid signature

Confirm the dashboard secret matches `CHAPA_WEBHOOK_SECRET`, and calculate
the HMAC over the exact raw body.

## 12. Security and operations

- Never commit Chapa keys, webhook secrets, access tokens, or provider payloads.
- Never trust redirects, callback parameters, or frontend success pages.
- Never mark payments, orders, tickets, inventory, ledger rows, or payouts
  complete with direct SQL.
- Keep uncertain outcomes in `processing`/`pending` and reconcile them.
- Use Chapa test mode for the real hosted-checkout path and the deterministic
  provider fake for forced timeout and liquidity drills.
- Follow the [payment-provider outage runbook](../runbooks/payment-provider-outage.md)
  when provider availability is uncertain.

## 13. Official references

- [Chapa accept payments](https://developer.chapa.co/integrations/accept-payments)
- [Chapa test mobile payments](https://developer.chapa.co/test/testing-mobile)
- [Chapa responses](https://developer.chapa.co/integrations/responses)
- [Chapa payment verification](https://developer.chapa.co/integrations/verify-payments)
- [Chapa design specification](../superpowers/specs/2026-08-19-chapa-payment-provider-design.md)
- [Payment-provider outage runbook](../runbooks/payment-provider-outage.md)
- [Postman API collection](../../postman/Digis%20API_collection.json)
