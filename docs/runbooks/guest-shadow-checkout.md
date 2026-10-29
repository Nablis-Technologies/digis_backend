# Guest shadow checkout runbook

Guest checkout is phone-first and does not require account setup before
payment. The buyer confirms the phone number, submits the registration, creates
an order, and starts payment using the guest-bound quote token. Accepted
payment follows the normal `AcceptPayment` → `FulfillOrder` → ticketing outbox
chain; OTP and SMS are never issuance gates.

## Public API sequence

1. `POST /guest/ticket_types/:ticket_type_id/registrations` with
   `phone_confirmation: true` and a fresh `Idempotency-Key`.
2. `POST /guest/events/:event_id/order_quotes` with the same canonical phone,
   confirmation flag, and product/registration selection. Store the opaque
   `data.quote_token` only in the client session.
3. `POST /guest/events/:event_id/orders` with `{ order: { phone, quote_token } }`
   and a fresh idempotency key.
4. `POST /guest/orders/:order_id/payment_attempts` with the phone-bound quote
   token, provider, and payment method.
5. Poll `POST /guest/payments/:payment_id/refresh` with the same phone and quote
   token. The response is `state: "pending"` until the fulfillment outbox has
   issued credentials, then `state: "ready"` with the buyer-safe ticket wallet
   projection. Every response is `Cache-Control: no-store`.

The client must reuse an idempotency key only for the exact same request. A
different phone, event, or quote under the same key is rejected. A verified or
password-bearing phone must use the authenticated checkout instead of guest
checkout.

`full_name` may be sent as checkout context and is included in the guest
request fingerprint. When an event needs a durable attendee name (for example,
for QR-plus-ID admission), the published registration form answer remains the
source of truth in this slice; the core user record intentionally has no
separate profile-name column yet.

## Ticket access and account claim

The ready response or the post-issuance SMS contains a signed public ticket
view URL. `GET /public/tickets/:ticket_id?view_token=...` returns event/date,
product, and active QR data only; it never returns owner, payment, consent, or
account-control fields. The token expires at the latest ticket access end plus
30 days and is invalid after credential-generation replacement or event
cancellation.

Branded ticket links use the configured `SHORT_LINKS_HOST` (for example,
`localhost` during local testing, a Render hostname in preview, or `dig.is` in
production). When branded links are disabled, delivery falls back to the
signed direct URL under `PUBLIC_APP_URL`; no DNS record is required for local or
Render testing.

To claim the shadow identity:

- `POST /public/ticket_views/:token/request_otp` with the confirmed phone and an
  idempotency key;
- `POST /phone_verifications/:id/verify` with the six-digit code and an
  idempotency key;
- `POST /registrations/:id/claim_guest` with the phone, signed verification
  proof, password, password confirmation, and an idempotency key.

The OTP code is delivered only through the configured
`Rails.application.config.x.phone_verification_sender` seam and is never
stored or logged. If delivery fails, the challenge is marked `delivery_failed`
and the same idempotency key will return that failure; request a new key for a
new code. After claim, normal `GET /tickets` wallet authorization shows the
historical guest tickets because ownership stayed on the same user row.

## Operations and failure handling

- Missing or invalid phone confirmation is rejected before a shadow user is
  created.
- Payment/provider failures remain in the existing Orders reconciliation path;
  SMS failure only retries `Ticketing::GuestTicketDeliveryJob`.
- `Core::ExpirePhoneVerificationChallengesJob` marks expired pending or
  delivery-failed OTP challenges in bounded batches. It does not mutate orders
  or tickets.
- Do not treat a free-tier cold start or delayed SMS as a payment or issuance
  failure. Verify the payment refresh state and fulfillment outbox separately.
- Configure a real SMS sender before enabling account claim in production; the
  deterministic test sender is for local/test/preview only.
- For a private Render preview only, set `RENDER_PREVIEW=true` and
  `DIGIS_PREVIEW_DEBUG_LOGGING=true` to register the preview OTP sender and log
  the challenge ID plus OTP, and to log preview SMS bodies without recipient
  phone numbers. Disable this flag immediately after frontend testing and never
  set it on a live production service.
