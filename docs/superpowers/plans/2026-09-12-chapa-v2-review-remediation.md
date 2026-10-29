# Chapa V2 Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the confirmed security, contract, precision, and boundary defects identified during review of the Chapa V2 migration.

**Architecture:** Keep payment and payout clients domain-specific. Move only generic HTTP transport and exact JSON-number serialization into `Core`; keep canonical payment and payout result types separate. Defer bulk payout until its item-level result contract is modeled.

**Tech Stack:** Rails 8.1, Ruby 3.4, Minitest, Net::HTTP, ActiveSupport `Data`, Chapa V2 REST API.

---

### Task 1: Harden webhook verification

**Files:**
- Modify: `app/services/payments/providers/chapa_client.rb`
- Test: `test/services/payments/providers/chapa_client_test.rb`

- [x] **Step 1: Add a test for malformed unsigned input**

  Call `verify_webhook` with malformed JSON and an invalid signature. Assert it
  returns `false` and does not raise while checking `x-chapa-signature`.

- [x] **Step 2: Run the focused test and confirm it fails for the current ordering**

  Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/payments/providers/chapa_client_test.rb`.

- [x] **Step 3: Verify the raw signature before parsing mode**

  Calculate the expected HMAC over the exact payload bytes, constant-time
  compare it with the normalized header, return `false` on mismatch, and only
  then parse JSON and reject a mismatched mode.

- [x] **Step 4: Run the focused payment-client test again**

  Expected: all tests pass, including valid signatures, invalid signatures,
  malformed payloads, and wrong-mode payloads.

### Task 2: Preserve V2 direct-charge context and exact amounts

**Files:**
- Create: `app/lib/core/json_number.rb`
- Modify: `app/services/payments/providers/result.rb`
- Modify: `app/services/payments/providers/chapa_client.rb`
- Modify: `app/services/finance/payout_providers/chapa_payout_client.rb`
- Modify: `config/locales/orders/payments.en.yml`
- Modify: `config/locales/finance.en.yml`
- Test: `test/services/payments/providers/chapa_client_test.rb`
- Test: `test/services/finance/payout_providers/chapa_payout_client_test.rb`

- [x] **Step 1: Add failing assertions for `auth_type` and `request_id`**

  In the direct-charge test, assert the normalized result exposes the V2
  response values `auth_type: "ussd"` and `request_id: "request-1"`.

- [x] **Step 2: Add failing exact-wire amount assertions**

  Assert the request body contains JSON numeric literals such as `12.5` and
  `0.01`, without converting the minor-unit integer through a Ruby `Float`.

- [x] **Step 3: Extend the canonical payment result**

  Add optional `auth_type` and `request_id` fields to
  `Payments::Providers::Result`, preserve them in `from_provider_response`, and
  map them from V2 `data` in `ChapaClient#map_result`.

- [x] **Step 4: Serialize exact provider amount literals**

  Convert the integer minor-unit amount with `BigDecimal`, format it as a
  validated `Core::JsonNumber` so Rails serialization remains a normal string
  while `JSON.generate` emits an exact JSON number without binary
  floating-point arithmetic.

- [x] **Step 5: Remove the redundant direct-charge customer merge**

  Use `payment_payload(request).merge(payment_method: ...)`; the shared payload
  already includes the nested customer object.

- [x] **Step 6: Localize configuration errors and normalize blocked states**

  Route configuration errors through existing locale files, map payment
  `blocked` to canonical failure, treat blocked webhook events as failed
  payments, and leave pending/processing payout results without a failure code.

- [x] **Step 7: Run payment and payout provider tests**

  Run the two provider test files and expect all tests to pass.

### Task 3: Align V2 callback correlation

**Files:**
- Modify: `app/controllers/orders/payment_callbacks_controller.rb`
- Modify: `app/services/orders/record_payment_callback.rb`
- Modify: `app/services/orders/process_payment_event.rb`
- Test: `test/controllers/orders/payment_callbacks_controller_test.rb`
- Test: `test/services/orders/record_payment_callback_test.rb`
- Test: `test/services/orders/process_payment_event_test.rb`

- [x] **Step 1: Add V2 callback and webhook correlation tests**

  Cover `merchant_reference` as the Digis payment reference and
  `chapa_reference` as the provider reference.

- [x] **Step 2: Accept V2 names while retaining captured redirect aliases**

  Use V2 names first in the callback controller, verify with the provider
  reference when available, and preserve the existing legacy aliases for
  previously captured test redirects.

- [x] **Step 3: Locate webhook payments by `merchant_reference`**

  Include V2 `merchant_reference` and `chapa_reference` in the payment-event
  correlation candidates without removing existing event payload support.

- [x] **Step 4: Run callback and event-processing tests**

  Expected: all V2 and legacy callback/event tests pass.

### Task 4: Move shared transport to Core and remove duplicate coverage

**Files:**
- Create: `app/services/core/http_transport.rb`
- Delete: `app/services/payments/providers/chapa_http_transport.rb`
- Modify: `app/services/payments/providers/chapa_client.rb`
- Modify: `app/services/finance/payout_providers/chapa_payout_client.rb`
- Delete: `test/services/payments/providers/chapa_v2_client_contract_test.rb`
- Modify: `test/services/payments/providers/chapa_client_test.rb`

- [x] **Step 1: Add a Core transport boot/contract test**

  Instantiate `Core::HttpTransport` with an injected HTTP boundary or
  assert the two provider clients reference the Core transport constant.

- [x] **Step 2: Run the new transport test and confirm the old namespace is still referenced**

  Run the focused provider tests and confirm the test fails until both clients
  use `Core::HttpTransport`.

- [x] **Step 3: Move the Net::HTTP implementation without changing behavior**

  Preserve timeout settings, JSON parsing, response status/body shape, and
  injectable transport behavior under the Core namespace.

- [x] **Step 4: Merge unique V2 assertions into the canonical payment test**

  Retain nested customer, direct-charge, provider-reference, and key-prefix
  assertions in `chapa_client_test.rb`, then remove the duplicate contract test.

- [x] **Step 5: Run the provider suite and search for stale references**

  Run `rg -n "Payments::Providers::ChapaHttpTransport|ChapaV2ClientContractTest" app test` and expect no matches.

### Task 5: Remove the lossy bulk payout capability

**Files:**
- Modify: `app/services/finance/payout_providers/chapa_payout_client.rb`
- Modify: `app/services/finance/payout_providers/chapa_adapter.rb`
- Modify: `test/services/finance/payout_providers/chapa_payout_client_test.rb`

- [x] **Step 1: Add a failing capability assertion**

  Assert the configured Chapa payout capabilities do not advertise bulk payout
  while the client returns only the scalar `Finance::PayoutProviders::Result`.

- [x] **Step 2: Remove the public bulk operation and capability flag**

  Delete `bulk_payout` from the client and adapter and set the payout
  capability to single-payout support only. Keep the V2 endpoint out of the
  core contract until a typed batch result tracks batch and item references.

- [x] **Step 3: Run payout adapter and client tests**

  Expected: no code path claims item-level bulk support and all single-payout
  tests pass.

### Task 6: Final verification

**Files:**
- Modify: `docs/superpowers/plans/2026-09-12-chapa-v2-review-remediation.md`

- [x] **Step 1: Run focused payment, payout, and adapter tests**

  Run the provider, adapter, and payout dispatch test paths.

- [x] **Step 2: Run RuboCop and JSON/schema checks**

  Run `RUBOCOP_CACHE_ROOT=/tmp/digis-rubocop-cache PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop`, `git diff --check`, and the Postman JSON parser.

- [x] **Step 3: Run the broader scoped suite and record unrelated failures separately**

  Do not claim the full suite is green if the pre-existing fixture foreign-key
  or PostgreSQL deadlock failures recur; report them separately from V2 results.
