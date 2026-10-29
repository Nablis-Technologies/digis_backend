# Chapa Integration Guide

This guide explains how Digis integrates with Chapa, how a payment moves
through the system, and how to test the integration locally and on Render.

The provider-specific design is documented in
[the Chapa V2 design specification](../superpowers/specs/2026-09-12-chapa-v2-core-migration-design.md).
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

- `amount` as an exact JSON integer minor-unit value;
- uppercase ISO currency such as `ETB`;
- a deterministic provider-safe `merchant_reference` no longer than 20
  characters, plus the full client idempotency key in the native
  `Idempotency-Key` header. The client key remains the local replay identity;
- buyer email and normalized phone;
- configured `callback_url` and `return_url` for hosted checkout when enabled.
  Both point to the deployed `/payments/chapa/callback` endpoint.

Chapa V2 expects the `amount` field as an integer minor-unit value. Digis
continues to store and calculate exact integer minor units and sends that value
unchanged at the provider boundary. For example, `513` means `5.13 ETB` and
must be sent as JSON `513`; it must not be divided by 100 or rounded.

Hosted initialization intentionally omits `preferred_payment_methods`. Chapa
documents that field as optional but does not publish its request shape, and
the V2 endpoint rejected the string-array form during the Render test drill.
The hosted page remains responsible for selecting an enabled payment method;
Direct Charge continues to receive one explicit method.

Digis accepts canonical Ethiopian numbers such as `+251900123456` and sends
the provider payload in E.164 format. The stored Digis phone remains in
`+251...` format.

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

## 4. Webhook and redirect handling

The V2 hosted request includes the configured callback and return URLs. The
official documentation describes redirects as optional, and a short-reference
request also succeeds without them; the current deployment sends both for
redirect UX and callback compatibility. Configure the Chapa webhook in the
dashboard and use it as the authoritative server-to-server signal.

### Webhook URL

Configure this in the Chapa dashboard:

```text
POST https://<digis-host>/payments/chapa/webhook
```

The webhook is signed and handled independently. Digis verifies the exact raw
body before parsing it, then records the event for idempotent processing.

### Optional callback route

The backend retains the callback route for provider redirect signals and test
fixtures:

```text
GET https://<digis-host>/payments/chapa/callback
```

It is not sent in the current hosted initialization request and is never a
payment confirmation endpoint. Always verify through the V2 API or webhook.

## 5. Environment configuration

Set these values in Render or another secret manager, never in Git, seeds, or
Postman variables containing secrets:

| Variable | Required | Preview meaning |
| --- | --- | --- |
| `CHAPA_PAYOUT_ENABLED` | yes for transfer testing | `true` registers the Finance Chapa transfer adapter |
| `CHAPA_ENABLED` | yes | `true` registers Chapa |
| `CHAPA_MODE` | yes | `test` for Render preview |
| `CHAPA_SECRET_KEY` | yes | Chapa `CHAPA_TEST_...` key |
| `CHAPA_WEBHOOK_SECRET` | yes | Secret used for raw-body HMAC verification |
| `CHAPA_CALLBACK_URL` | recommended for hosted checkout | Deployed callback endpoint |
| `CHAPA_RETURN_URL` | recommended for hosted checkout | Deployed callback endpoint |
| `CHAPA_API_BASE_URL` | no | Defaults to `https://api.chapa.global` |

Preview safety:

- CHAPA_PAYOUT_ENABLED is independent from checkout registration; keep it
  disabled by default. Organizer and Marketplace payout destinations are
  encrypted and remain pending until provider or authorized manual
  verification; enabling transfer dispatch requires an explicit test-mode
  drill with approved credentials.

- `RENDER_PREVIEW=true` requires `CHAPA_MODE=test`.
- Preview requires a `CHAPA_TEST_...` key.
- Live `CHAPA_LIVE_...` keys must not be used in preview.
- Restart/redeploy after changing environment variables.

Render's Blueprint marks secret fields with `sync: false`; enter their
values manually in the service environment. Merge updates instead of
replacing the full environment-variable set.

## 6. Marketplace seller payouts

Marketplace resale sellers use the same direct payout transport as Finance
organizer payouts. The seller account endpoint accepts `bank_slug`,
`account_number`, `holder_name`, and an optional account label, encrypts the
beneficiary values, and returns `pending_verification` when Chapa has no
preflight beneficiary verifier.

`GET /v2/payouts/banks?country=ET` is only a supported-bank and routing-code lookup. It is not
ownership verification. An authorized operator verifies a pending seller
destination through:

```text
POST /admin/marketplace/seller_payout_accounts/:id/verify
```

with a reason, evidence reference, and idempotency key. Only verified seller
accounts can be selected as default or used by the seller payout dispatch.
The dispatch sends `account_number`, `account_name`, `bank_slug`, `amount`,
`currency`, and `merchant_reference` to `POST /v2/payouts` with the native
`Idempotency-Key` header. Payout amounts use the same integer minor-unit
contract: a seller balance of `513` minor units is sent as JSON `513`.

Chapa subaccounts remain out of scope for resale payouts. They are split-
payment resources used during customer checkout, while resale proceeds are
settled later from the Marketplace seller ledger.

## 7. Seeded test data

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
CHAPA_SECRET_KEY='CHAPA_TEST_...' \
CHAPA_WEBHOOK_SECRET='local-test-webhook-secret' \
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

## 8. Chapa payout testing

Finance uses a separate Finance::PayoutProviders::ChapaPayoutClient for
Chapa POST /v2/payouts, GET /v2/payouts/:reference/verify, and bank-list
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

Event completion is automatic after ended dates become terminal. Authorized
organizers and platform administrators may retry the same guarded transition
with `POST /events/:event_id/complete` and an `Idempotency-Key`; this does not
make funds payout-eligible before the seven-day maturity buffer.

A proposed faster organizer-release policy is paused in
`docs/superpowers/specs/2026-08-31-fast-organizer-payout-reserve-policy-design.md`.
Until its reserve and compliance decisions are implemented, this seven-day
guard remains the production-shaped behavior.

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
GET  /payments/chapa/callback?merchant_reference=<transaction-reference>&status=success
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
| `merchant_reference` / transaction reference | Payment response or database payment row | Callback verification |

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
GET /payments/chapa/callback?merchant_reference=<transaction-reference>&chapa_reference=<provider-reference>&status=success
```

The application verifies the provider's `chapa_reference` with Chapa and uses
`merchant_reference` to locate the Digis payment. A successful HTTP response
means that a durable payment event was accepted for asynchronous processing;
it does not mean the frontend should skip checking the order result.

#### 6. Provider webhook

The separate signed webhook has no bearer token:

```http
POST /payments/chapa/webhook
Content-Type: application/json
X-Chapa-Signature: <hmac-of-the-exact-raw-body>

{
  "webhook_type": "payment",
  "event": "payment.success",
  "mode": "test",
  "status": "success",
  "chapa_reference": "<chapa-reference>",
  "merchant_reference": "<transaction-reference>"
}
```

The application maps Chapa's `chapa_reference` to the durable provider-event
identity and uses `merchant_reference` to locate the Digis payment. The Postman request is a shape example; its
signature must be generated from the exact raw body with the configured
webhook secret, so it is not a substitute for a real Chapa-signed delivery.
The endpoint acknowledges a verified receipt with HTTP 200; processing remains
asynchronous through the payment-event inbox and outbox.

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
The application accepts Chapa's documented `x-chapa-signature` header and
never logs the body or secret.

For local automated tests:

```ruby
raw_body = '{"event":"payment.success","mode":"test","merchant_reference":"attempt-1"}'
signature = OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, raw_body)
```

The signature secret must match `CHAPA_WEBHOOK_SECRET`. Never log the raw
webhook body, secret, or authorization header.

## 11. Troubleshooting

### Initialization returns failed

Check:

1. `CHAPA_ENABLED=true` and the application restarted.
2. `CHAPA_MODE` matches the key prefix.
3. Preview uses `CHAPA_TEST_...`.
4. The buyer email is accepted by Chapa.
5. The phone is a supported test number.
6. The amount is a positive integer minor-unit value. Chapa V2 receives that
   exact integer; `513` represents `5.13 ETB`.
7. Render logs show the safe provider status and failure code.

### Callback returns payment_not_found

Use the exact provider merchant reference stored in
`orders_payments.provider_merchant_reference` to locate the payment, and pass
Chapa's `chapa_reference` to verification. Chapa V2 `/verify` accepts the
provider reference returned by Chapa, not the merchant reference. Do not use
the client `idempotency_key` or hosted checkout URL token as either reference.

### Callback is accepted but the order remains pending

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
