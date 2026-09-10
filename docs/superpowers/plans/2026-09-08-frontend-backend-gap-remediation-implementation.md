# Frontend–Backend Gap Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Close only the ten unequivocally true backend gaps recorded as G-01 through G-10 in the frontend–backend gap tracker.

**Architecture:** Extend existing registration, payment, payout, authentication, serializer, and marketplace boundaries in place. No parallel checkout, notification, payout, or identity systems will be introduced. Every mutation keeps the repository’s idempotency, audit, policy, and database-invariant conventions.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest, ActiveModel Serializers, Pundit, Rails cache, Chapa v1 adapters.

---

## Scope boundary

Implement only G-01 through G-10:

- G-01 paid registration confirmation
- G-02 buyer release of abandoned pending registrations
- G-03 marketplace payout-provider registration
- G-04 server-side signup validation
- G-05 authentication throttling
- G-06 public event-list minimum price
- G-07 public `requires_ticket` projection
- G-08 public registration schema
- G-09 seller “my listings” discovery
- G-10 owner wallet resale-policy projection

Do not implement the deferred guest/OTP, CBE enum, public-setting expansion,
profile-name/editing, repeat-registration, slug, or Chapa-v2 decisions here.

## File map

- Modify `app/services/orders/accept_payment.rb` and create
  `app/services/ticketing/registrations/confirm_paid.rb` for G-01.
- Create `app/services/ticketing/registrations/release_pending.rb`, modify
  `app/controllers/ticketing/registrations_controller.rb` and
  `app/policies/ticketing/registration_policy.rb`, and extend ticketing locales
  for G-02.
- Create `app/services/marketplace/payout_providers/registration.rb` and
  `config/initializers/marketplace_payout_providers.rb` for G-03.
- Modify `app/models/concerns/core/user_authenticatable.rb` and
  `config/locales/core/user.en.yml` for G-04.
- Create `app/services/core/auth_throttle.rb`, add the authentication concern to
  `app/controllers/core/auth_controller.rb`, and extend auth locales for G-05.
- Modify `app/serializers/events/public/event_list_serializer.rb` and
  `app/controllers/events/public_events_controller.rb`; create
  `app/services/catalog/public/price_window.rb` for G-06.
- Modify `app/serializers/catalog/public/event_product_serializer.rb` for G-07.
- Create `app/serializers/ticketing/public/registration_schema_serializer.rb`,
  `app/controllers/ticketing/public_registration_schemas_controller.rb`, add
  the public route, and extend ticketing locales for G-08.
- Modify `app/controllers/marketplace/resale_listings_controller.rb` and add a
  seller-safe serializer/profile for G-09.
- Modify `app/serializers/ticketing/ticket_wallet_serializer.rb` for G-10.
- Add focused model/service/integration tests for every changed contract and
  update `postman/Digis API_collection.json` for new routes.

## Tasks

### Task 1: Confirm paid registrations (G-01)

- [x] Write a failing service test proving an accepted paid order transitions
  each linked `pending_payment` registration to `confirmed`, sets
  `confirmed_at`, and writes one idempotent audit row.
- [x] Run the focused test and verify it fails because the transition is absent.
- [x] Implement `Ticketing::Registrations::ConfirmPaid` as a transaction-safe
  lock/update command. Use an audit key derived from payment ID and registration
  ID; allow a replay to return the already-confirmed registration.
- [x] Invoke the command from `Orders::AcceptPayment` inside its existing order
  transaction before fulfillment completes. A failure must roll back payment,
  registration, and fulfillment together.
- [x] Run registration/payment tests and the concurrency payment suite.

### Task 2: Release abandoned pending registrations (G-02)

- [x] Write service and integration tests for buyer-owned `pending_payment`
  registration release, missing key `400`, non-owner `404/403`, idempotent replay,
  and rejection after confirmation or active payment acceptance.
- [x] Implement `Ticketing::Registrations::ReleasePending` with a registration
  row lock, buyer ownership check, hold/purchase-limit release through existing
  commands, `status: "cancelled"`, `cancelled_at`, and an auditable idempotency
  key. Preserve form/consent evidence; do not delete the registration.
- [x] Add `POST /registrations/:id/release` with authentication, required
  `Idempotency-Key`, policy authorization, and stable localized errors.
- [x] Run the focused registration/order integration suite.

### Task 3: Register marketplace payout adapter (G-03)

- [x] Add a boot/configuration test proving `Marketplace::PayoutProviders::Registry`
  contains Chapa only when `CHAPA_ENABLED=true`, `CHAPA_PAYOUT_ENABLED=true`, and
  the mode is safe for the environment.
- [x] Implement a marketplace registration service that builds the existing
  `Marketplace::PayoutProviders::ChapaAdapter` around the existing transfer
  client, without duplicating Finance payout transport code.
- [x] Add an initializer with the same preview/live guard used by Finance and
  preserve fail-closed behavior when configuration or Chapa destination
  tokenization is absent.
- [x] Add an integration test proving a configured marketplace Chapa adapter is
  resolved from the registry and account registration fails closed with the
  provider-unavailable contract when Chapa lacks destination tokenization.

### Task 4: Enforce signup identity/password rules (G-04)

- [x] Write model and integration tests for password minimum length,
  confirmation mismatch, malformed phone rejection, canonical Ethiopian phone
  acceptance, and existing email/phone uniqueness behavior.
- [x] Add model-level validations to `Core::UserAuthenticatable`; keep password
  hashing unchanged, persist every accepted phone in one `+251...` form, and
  return existing typed validation errors through the signup controller.
- [x] Run auth model/integration tests and the full auth policy suite.

### Task 5: Add authentication throttling (G-05)

- [x] Write tests proving login attempts are atomically limited per IP and per
  identifier digest, counters expire, successful authentication does not leak
  identity details, and signup/refresh share the configured boundary.
- [x] Implement a small `Core::AuthThrottle` around `Rails.cache.write(...,
  unless_exist: true)`/increment semantics with HMAC/digest identifier keys;
  record only failed authentication attempts and do not store raw identifiers.
- [x] Call it from `Core::AuthController` before login/signup/refresh and return
  localized `429 rate_limited` through the existing JSON response contract.
- [x] Run auth throttle and controller tests, then Brakeman.

### Task 6: Add public price and product requirement projections (G-06/G-07)

- [x] Write serializer/integration tests asserting `price_from_minor` is the
  minimum currently active price across event products, is integer minor units,
  and is `null` when no active price exists.
- [x] Add bounded `event_products: :prices` eager loading to the public event
  list and expose only the computed `price_from_minor` attribute.
- [x] Write a public-product test asserting `requires_ticket` is exposed as a
  boolean while unrelated metadata remains absent.
- [x] Add the dedicated `requires_ticket` projection and preserve existing
  price/availability serialization and privacy boundaries.
- [x] Run public event/catalog integration and N+1 performance tests.

### Task 7: Expose the public registration schema (G-08)

- [x] Write an integration test for a published event/ticket type returning
  current form version, question keys, types, response scopes, required flags,
  validation rules, and consent metadata without answer values or private fields.
- [x] Implement a public schema query using the existing
  `Ticketing::Forms::ApplicableSchema` service and a dedicated serializer;
  return `404` for unknown/unpublished event or ticket type.
- [x] Add `GET /public/events/:event_slug/ticket_types/:ticket_type_id/registration_schema`
  with no authentication and no organizer policy bypass beyond the explicit
  public projection.
- [x] Update Postman with the request and safe response example.

### Task 8: Add seller “my listings” discovery (G-09)

- [x] Write integration tests proving the public listing index remains seller-
  private while an authenticated seller can request only their own active rows
  through an explicit filter/profile, with no cross-user leakage.
- [x] Add a controller-owned `mine` filter (or equivalent explicit seller
  action) that uses `policy_scope` and a seller-safe serializer; do not infer
  ownership from the public serializer or issue one query per row.
- [x] Preserve buyer index behavior and update Postman documentation.

### Task 9: Include resale policy in owner wallet (G-10)

- [x] Write wallet integration tests for the five fields:
  `resale_enabled`, cap type/value/currency, cutoff seconds, and maximum
  completed resales; assert they are absent from buyer/public serializers.
- [x] Add the fields to the owner-only `TicketWalletSerializer#ticket_type`
  projection and ensure its eager-loaded product/ticket-type path remains
  bounded.
- [x] Run wallet, resale-policy, and serializer visibility tests.

### Task 10: Cross-cutting verification and handoff

- [x] Run all focused suites for G-01 through G-10, including N+1 coverage.
- [x] Run `RUBOCOP_CACHE_ROOT=/private/tmp/digis-rubocop-cache bundle exec rubocop`
  on every changed Ruby file.
- [x] Run `bin/brakeman`, `bundle exec rails zeitwerk:check`, Postman JSON
  validation, `git diff --check`, and the full Rails suite.
- [x] Update the gap tracker states only after tests verify each gap; leave all
  G-11 through G-19 deferred.
