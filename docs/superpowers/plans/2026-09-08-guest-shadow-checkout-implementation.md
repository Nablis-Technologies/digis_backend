# Guest Shadow Checkout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an unverified phone-first buyer complete a paid checkout as a
shadow user, receive a usable ticket immediately after payment acceptance, and
upgrade that shadow identity to a normal account later.

**Architecture:** Guest checkout resolves one canonical `+251...` phone identity,
creates the existing registration/order records, and then uses the normal
payment inbox, transactional outbox, and credential-issuance pipeline. Payment
acceptance does not wait for OTP or SMS delivery: the existing fulfillment
handoff issues credentials immediately and the confirmation response returns a
no-store buyer-safe ticket projection. SMS is a convenience link to a signed,
read-only public ticket view. A later OTP plus password setup claims the shadow
identity and exposes the same historical orders, registrations, and tickets in
the authenticated wallet. No plaintext OTP, ticket secret, or provider
credential is persisted.

**Tech Stack:** Rails 8.1, PostgreSQL, ActiveJob, ActiveSupport message
signing, Minitest, existing Orders/Ticketing outbox workflows, and the
provider-neutral Messaging SMS adapter.

---

## Product decisions recorded

- Guest/shadow checkout is allowed when the buyer has no authenticated verified
  account.
- Checkout requires an explicit phone-number confirmation step before payment.
- Guest `full_name` is accepted as request context; durable attendee-name data
  remains the published registration-form answer until the separate profile
  name capability is implemented.
- Payment acceptance issues the ticket immediately; OTP is not an issuance gate.
- SMS delivery is convenience-only. The confirmation page is the authoritative
  immediate access path and displays the QR credential with `no-store` caching.
- Account upgrade requires a six-digit SMS OTP followed by password creation.
- Signed public ticket views expire at event end plus 30 days.
- Payment refunds and disputes use the existing payment/refund policies; there
  is no automatic 30-minute refund merely because an account remains unclaimed.
- OTP delivery is pluggable SMS with the deterministic test adapter in
  test/preview and a configured real SMS adapter in live environments.

## Implementation status

The first implementation slice is complete locally: guest registration and
phone-bound quote/order/payment routes, immediate fulfillment through the
existing payment/outbox path, signed public ticket views, OTP verification and
shadow-account claiming, post-issuance SMS handoff, and bounded challenge
expiry cleanup are implemented and covered by focused tests. Provider-specific
SMS configuration, production smoke evidence, and the remaining operational
metrics/documentation checks stay open until the live adapter is selected.

## Scope boundary

Do not change public event/product projections, Chapa payment payloads, payout
timing, resale policy, or the deferred CBE/Chapa-v2 decisions. Do not create a
second fulfillment, wallet, or identity system. Existing authenticated checkout
must remain behaviorally unchanged. Unified phone-first dashboard auth and OAuth
are intentionally out of scope and are tracked in the separate follow-up plan
`docs/superpowers/plans/2026-09-08-unified-auth-oauth-implementation.md`.

## File map

- Create `db/migrate/20260908090001_create_core_phone_verification_challenges.rb`
  and `app/models/core/phone_verification_challenge.rb` for expiring OTP
  evidence and attempt limits.
- Create `app/services/core/phone_verification/request.rb`,
  `app/services/core/phone_verification/verify.rb`, and
  `app/services/core/phone_verification/delivery.rb`.
- Create `app/services/orders/guest_quote_token.rb` and
  `app/services/orders/guest_checkout.rb`; these bind a quote/order to the
  canonical phone digest without weakening authenticated quote tokens.
- Create `app/controllers/orders/guest_order_quotes_controller.rb`,
  `app/controllers/orders/guest_orders_controller.rb`,
  `app/controllers/orders/guest_payment_attempts_controller.rb`, and
  `app/controllers/orders/guest_payment_refresh_controller.rb` for the
  phone-bound guest checkout and confirmation surfaces.
- Modify `app/services/ticketing/registrations/submit.rb` to support an explicit
  guest identity mode and the required phone-confirmation acknowledgement.
- Keep `app/services/orders/accept_payment.rb` and the existing fulfillment
  outbox as the issuance path; add only the guest-safe confirmation projection
  and delivery handoff needed after the existing ticket is created.
- Create `app/services/ticketing/guest_ticket_view_token.rb` and
  `app/controllers/ticketing/public_ticket_views_controller.rb` for the signed
  public QR view.
- Create `app/serializers/ticketing/public_ticket_view_serializer.rb` and
  `app/jobs/ticketing/guest_ticket_delivery_job.rb` for the no-store public
  projection and post-issuance SMS convenience link.
- Modify `app/services/links/target_resolver.rb` to resolve ticket short links
  to the public ticket-view route with a signed view token; the short-link slug
  alone must never authorize access.
- Create `app/services/ticketing/registrations/claim_guest.rb` to verify the
  phone, set the password, issue JWTs, and reuse the existing wallet scope.
- Create `app/controllers/core/phone_verifications_controller.rb` and
  `app/jobs/core/expire_phone_verification_challenges_job.rb`; the OTP code is
  never persisted and the claim proof is signed and short-lived.
- Create `app/controllers/ticketing/guest_registrations_controller.rb` and
  `app/controllers/core/phone_verifications_controller.rb`; add explicit guest
  checkout, OTP, claim, and public-ticket routes.
- Add policies/serializers for guest confirmation, OTP status, and public ticket
  views. They may expose only event/product/date display data and the active QR
  credential; never OTP digests, raw phone/email fields, or payment internals.
- Add bounded jobs/tests for SMS delivery retry and public-token expiry. Do not
  add an unclaimed-order refund sweeper.
- Update Postman, the guest-checkout runbook, and the G-11 tracker only after
  the focused suite passes.

## Tasks

### Task 1: Canonical guest identity and registration entrypoint

- [x] Write failing integration tests for an unauthenticated request containing
  `phone`, `full_name`, optional `email`, form answers, and
  `phone_confirmation: true`; assert one canonical `+251...` shadow user, one
  pending-payment registration, no JWT, and no raw phone duplication.
- [x] Add model/service tests proving `+251...`, `09...`, and `9...` spellings
  resolve to the same existing user and that a missing phone confirmation is a
  typed `400` failure before any registration is written.
- [x] Implement the explicit guest branch in `Ticketing::Registrations::Submit`
  through `Core::PhoneIdentity::ResolveOrCreate` with the existing registration
  form, consent, audience, and idempotency rules. Authenticated requests keep
  the current verified-identity path.
- [x] Add `POST /guest/ticket_types/:ticket_type_id/registrations` with abuse
  throttling and generic registration-state output; the guest-bound quote
  token is issued by the subsequent guest quote endpoint.
- [x] Run the guest identity, registration, and privacy tests.

### Task 2: Guest quote, checkout, and immediate issuance

- [x] Write failing tests for guest quote creation and checkout replay. The
  quote/order identity must bind to the canonical phone digest and event/ticket
  type; a different phone or payload under the same key must conflict.
- [x] Implement `Orders::GuestQuoteToken` as an encrypted, short-lived token
  containing only quote identity and the phone digest. Do not reuse an
  authenticated user-bound token with a nil user.
- [x] Implement `Orders::GuestCheckout` by delegating to `CreateCheckout` with
  the shadow user as buyer; preserve inventory, purchase-limit, promotion, and
  commercial snapshots.
- [x] Add `POST /guest/orders` (with an event-scoped alias if useful) and
  `POST /guest/orders/:id/payment_attempts`
  with the normal Chapa/Telebirr/CBE provider boundary and required
  `Idempotency-Key` headers.
- [x] Write payment tests proving accepted guest payment runs the existing
  `AcceptPayment` → `FulfillOrder` → `orders.payment.fulfilled` chain and creates
  one ticket/credential set without waiting for OTP or SMS delivery.
- [x] Run guest checkout, payment-race, fulfillment, and credential-generation
  suites.

### Task 3: Immediate confirmation and signed public ticket view

- [x] Write failing tests for a paid guest confirmation returning `pending`
  until the existing outbox has issued credentials, then `ready` with active
  ticket QR data and `Cache-Control: no-store`. Replaying the same key must not
  issue another ticket.
- [x] Implement `Ticketing::GuestTicketViewToken` using a signed payload bound
  to ticket ID, current credential-generation version, and expiry at event end
  plus 30 days. Reject tampering, stale generations, canceled events, and
  expired tokens.
- [x] Add `GET /public/tickets/:ticket_id?view_token=...` with no authentication.
  The serializer may include event/date/product display data and the active QR
  credential required for admission, but no owner identity, payment data,
  scanner secrets, or account controls.
- [x] Update `Links::TargetResolver` so a `ticket` short link redirects to the
  signed public view URL. Add tests proving `/tickets/:id` remains an
  authenticated wallet route and an un-tokenized public request is rejected.
- [x] Add the post-issuance SMS delivery handoff through the existing Messaging
  adapter. Provider timeout must not fail payment, fulfillment, or confirmation.
- [x] Run public-ticket, short-link, credential-privacy, and no-store tests.

### Task 4: Later OTP/account claim

- [x] Write failing tests for requesting an OTP from the signed ticket view,
  verifying the six-digit code once, setting a password, stamping `verified_at`,
  issuing JWTs, and showing all historical shadow-user tickets in `GET /tickets`.
- [ ] Write authorization tests for a different phone, ticket, event, or claim
  token; wrong/exhausted/expired codes; password mismatch; and replayed claim
  keys. No test may observe a persisted plaintext OTP.
- [ ] Implement `Core::PhoneVerification::Request` and `Verify` with a
  ten-minute challenge, five-attempt maximum, keyed idempotency, failure-only
  throttling, and provider-neutral SMS delivery.
- [x] Implement `Ticketing::Registrations::ClaimGuest` with user/registration
  locks, challenge verification, idempotent audit evidence, password hashing,
  and the existing token service. Do not copy wallet or credential-generation
  code.
- [x] Add `POST /auth/phone_verifications`,
  `POST /public/ticket_views/:token/request_otp`,
  `POST /phone_verifications/:id/verify`, and
  `POST /registrations/:id/claim_guest` with generic responses and abuse limits.
- [x] Run OTP, claim, auth, wallet, and credential-generation suites.

### Task 5: Failure, expiry, and reconciliation behavior

- [ ] Write tests for delayed outbox fulfillment, delayed SMS, failed payment,
  accepted payment with a later refund, canceled events, stale credential
  generations, and public-view expiry at event end plus 30 days.
- [ ] Ensure payment acceptance never waits on SMS and never issues duplicate
  tickets when confirmation polling, webhook processing, and outbox delivery
  race.
- [x] Add a bounded challenge-expiry job that marks pending or delivery-failed
  OTP challenges expired;
  payment/order/ticket state remains owned by existing reconciliation and refund
  services.
- [ ] Add operational metrics for guest checkout conversion, time-to-ticket,
  OTP verification, public-view access, and SMS delivery outcomes without
  logging phone numbers, tokens, QR values, or message bodies.
- [ ] Run refund, reconciliation, payment-race, and concurrency suites.

### Task 6: API documentation and final verification

- [x] Add Postman request/response examples for guest registration, guest order,
  payment confirmation, signed public ticket view, OTP request/verify, and
  account claim. Include `no-store` and bearer-link warnings.
- [x] Update `docs/operations/frontend-backend-gap-tracker-2026-09-08.md` to
  record G-11’s chosen contract and leave G-12 through G-19 deferred.
- [ ] Run focused guest/OTP tests with `N_PLUS_ONE=1`, all auth/payment/
  registration/credential suites, RuboCop, Brakeman, Zeitwerk, Postman JSON
  validation, `git diff --check`, and the full Rails suite.
- [ ] Record the live smoke evidence separately from free-tier cold-start delay;
  do not treat SMS latency as payment or ticket-issuance failure.
