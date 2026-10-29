# Chapa V2 Core Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Digis's Chapa V1 payment and payout provider implementation with a clean V2 contract while preserving domain-level payment, resale, credit, and ledger interfaces.

**Architecture:** Keep payment and payout as separate deep provider clients behind the existing adapters. Normalize V2's asynchronous statuses and references at the provider seam; keep Digis's encrypted payout destinations, immutable ledgers, webhook inbox, and fulfillment gates unchanged. Defer split-payment subaccounts and virtual accounts until their test-mode contracts are proven.

**Tech Stack:** Rails 8.1, Ruby 3.4, Minitest, Net::HTTP transport, ActiveSupport `Data`, Chapa V2 REST API, Render preview, Postman collection.

---

### Task 1: Freeze the V2 contract and test fixtures

**Files:**
- Modify: `test/services/payments/providers/chapa_client_test.rb`
- Modify: `test/services/finance/payout_providers/chapa_payout_client_test.rb`

- [ ] **Step 1: Write failing hosted-payment contract tests**

  Assert that the client sends `POST /v2/payments/hosted`, nests customer
  fields, sends `merchant_reference`, sends the V2 idempotency header, and maps
  `data.checkout_url` to a pending canonical payment result.

- [ ] **Step 2: Write failing payout contract tests**

  Assert `POST /v2/payouts`, V2 account fields (`bank_slug`, `bank_name`),
  `merchant_reference`, V2 idempotency header, and `data.chapa_reference`/
  `data.status` mapping.

- [ ] **Step 3: Write failing status/webhook fixture tests**

  Cover payment `auth_needed`, `blocked`, `incomplete`, refund completion,
  payout `processing`, `success`, `failed`, `blocked`, and `reversed`.

- [ ] **Step 4: Run the focused tests and confirm contract failures**

  Run:

  ```bash
  PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
    test/services/payments/providers/chapa_v2_contract_test.rb \
    test/services/finance/payout_providers/chapa_v2_contract_test.rb
  ```

  Expected: failures on V1 paths/payloads/status assumptions.

### Task 2: Replace the payment client with the V2 contract

**Files:**
- Modify: `app/services/payments/providers/chapa_client.rb`
- Create: `app/services/core/chapa/http_transport.rb`
- Delete: `app/services/payments/providers/chapa_http_transport.rb`
- Modify: `app/services/payments/providers/result.rb`
- Modify: `app/services/payments/providers/registration.rb`
- Test: `test/services/payments/providers/chapa_client_test.rb`
- Test: `test/services/payments/providers/adapter_contract_test.rb`

- [ ] **Step 1: Change configuration validation**

  Set the default base URL to `https://api.chapa.global`, validate
  `CHAPA_TEST_...` in test mode and `CHAPA_LIVE_...` in live mode, and remove
  V1 `CHASECK_*` validation.

- [ ] **Step 2: Implement V2 hosted payment mapping**

  Map Digis minor units to provider major units, send
  `POST /v2/payments/hosted`, use `merchant_reference`, nested `customer`,
  `meta`, and the `Idempotency-Key` header, and map `data.checkout_url`.

- [ ] **Step 3: Add direct-charge capability**

  Add a client operation for `POST /v2/payments/direct` that accepts an
  explicit payment method and phone number, returning `auth_type`, request
  reference, Chapa reference, and pending status without changing hosted
  checkout callers.

- [ ] **Step 4: Replace verification and refund paths**

  Use `GET /v2/payments/{reference}/verify`, `POST /v2/refunds`, and
  `GET /v2/refunds/{reference}/verify`. Preserve Digis's canonical result
  interface and refund idempotency.

- [ ] **Step 5: Expand canonical payment statuses**

  Preserve provider-specific raw status while mapping auth-needed, blocked,
  incomplete, processing, reversed, and pending states without treating them as
  success or a final failure.

- [ ] **Step 6: Run payment tests and the existing order/payment suites**

  Run:

  ```bash
  PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
    test/services/payments/providers \
    test/controllers/orders/payment_attempts_controller_test.rb \
    test/services/orders/payment_refresh_test.rb
  ```

  Expected: all V2 contract and existing domain tests pass.

### Task 3: Align payout destinations with V2 bank slugs

**Files:**
- Modify: `db/migrate/20260812090099_create_finance_payout_accounts.rb`
- Modify: `db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb`
- Modify: `app/models/finance/payout_account.rb`
- Modify: `app/models/marketplace/seller_payout_account.rb`
- Modify: `app/services/finance/payout_accounts/register.rb`
- Modify: `app/services/marketplace/verify_payout_account.rb`
- Modify: `app/controllers/finance/payout_accounts_controller.rb`
- Modify: `app/controllers/marketplace/seller_payout_accounts_controller.rb`
- Modify: `app/serializers/finance/payout_account_serializer.rb`
- Modify: `app/serializers/marketplace/seller_payout_account_serializer.rb`
- Modify: `app/serializers/finance/payout_serializer.rb`
- Modify: `app/policies/finance/payout_account_policy.rb`
- Modify: `app/policies/marketplace/seller_payout_account_policy.rb`
- Modify: `app/policies/admin/marketplace/seller_payout_account_policy.rb`
- Modify: `db/seeds/preview.rb`
- Modify: `postman/Digis API_collection.json`
- Test: all payout-account model/controller/service fixtures containing `bank_code`

- [ ] **Step 1: Replace the original migration column and constraint**

  Change `bank_code` to non-empty `bank_slug` text in the original Finance and
  Marketplace migrations. Replace numeric checks with a lowercase slug format
  check, then reset the development/preview schema as an explicit operator
  step; do not create compatibility columns or a follow-up migration.

- [ ] **Step 2: Update model, command, serializer, policy, seed, and Postman contracts**

  Validate and normalize `bank_slug`, pass it to provider verification and
  payout dispatch, and expose only the safe `bank_slug`/`bank_name` metadata.
  Use `cbe` in the seeded ETB fixture and update all tests from numeric bank
  codes to V2 slugs.

- [ ] **Step 3: Run payout destination tests**

  Run:

  ```bash
  PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
    test/models/finance/payout_account_test.rb \
    test/models/marketplace/seller_payout_account_test.rb \
    test/controllers/finance/payout_accounts_controller_test.rb \
    test/controllers/marketplace/seller_payout_accounts_controller_test.rb \
    test/services/finance/payout_accounts \
    test/services/marketplace/verify_payout_account_test.rb
  ```

### Task 4: Replace the payout client with V2 single payouts

**Files:**
- Create: `app/services/finance/payout_providers/chapa_payout_client.rb`
- Modify: `app/services/finance/payout_providers/registration.rb`
- Modify: `app/services/finance/payout_providers/chapa_adapter.rb`
- Modify: `app/services/marketplace/payout_providers/registration.rb`
- Modify: `app/services/marketplace/payout_providers/chapa_adapter.rb`
- Delete: `app/services/finance/payout_providers/chapa_transfer_client.rb`
- Test: `test/services/finance/payout_providers/chapa_payout_client_test.rb`
- Test: `test/services/finance/payout_providers/adapter_contract_test.rb`
- Test: `test/services/marketplace/payout_providers/chapa_adapter_test.rb`

- [x] **Step 1: Write the V2 payout client behind the Core injectable transport**

  Implement single payout, payout verification, and available bank/capability
  lookup. All mutating calls must forward the Digis idempotency key in
  `Idempotency-Key`; defer bulk payout until a typed batch result and item
  reconciliation model exist.

- [x] **Step 2: Map V2 payout lifecycle**

  Preserve `merchant_reference`, `chapa_reference`, `processor_reference`,
  account metadata, and raw status. Map pending/processing/blocked/auth-needed/
  otp-needed/reversed to a reconciliation-safe unknown/processing result rather
  than success.

- [x] **Step 3: Update payout registrations and adapters**

  Register the new client for Finance and Marketplace. Keep Marketplace's
  encrypted account decryption and direct beneficiary payload; do not implement
  subaccount tokenization as part of this cutover.

- [x] **Step 4: Run payout and marketplace suites**

  Run:

  ```bash
  PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
    test/services/finance/payout_providers \
    test/services/marketplace/payout_providers \
    test/services/marketplace
  ```

### Task 4: Upgrade webhook ingestion and reconciliation evidence

**Files:**
- Modify: `app/controllers/orders/payment_webhooks_controller.rb`
- Modify: `app/services/orders/record_payment_event.rb`
- Modify: `app/services/payments/providers/chapa_client.rb`
- Modify: `app/models/orders/payment_event.rb`
- Modify: `app/services/marketplace/apply_seller_payout_result.rb`
- Modify: `app/services/finance/apply_payout_result.rb`
- Test: `test/controllers/orders/payment_webhooks_controller_test.rb`
- Test: `test/services/orders/record_payment_callback_test.rb`
- Create: `test/services/orders/record_payment_event_v2_test.rb`
- Create: `test/services/marketplace/apply_seller_payout_result_test.rb`

- [ ] **Step 1: Verify V2 raw-body signatures before parsing**

  Use `x-chapa-signature` HMAC-SHA256 over `request.raw_post`, constant-time
  comparison, and the configured mode-specific webhook secret.

- [ ] **Step 2: Normalize V2 event identity**

  Use `webhook_type`, `event`, `chapa_reference`, `merchant_reference`, and
  `mode` to build a durable deduplication key. Preserve raw JSON bytes only in
  the existing retention-safe event boundary.

- [ ] **Step 3: Add payout reversal and partial-refund handling**

  Ensure payout `reversed` releases/resolves allocations correctly and payment
  partial/full refund events continue through existing reversal/credit logic.

- [ ] **Step 4: Test duplicate and out-of-order events**

  Assert duplicate V2 deliveries are acknowledged without duplicate effects and
  older `updated_at` events cannot regress a newer state.

### Task 5: Update configuration, Postman, and deployment contracts

**Files:**
- Modify: `render.yaml`
- Modify: `test/deployment/render_preview_configuration_test.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/runbooks/payment-provider-outage.md`
- Create: `docs/runbooks/chapa-v2-test-mode-drill.md`

- [ ] **Step 1: Replace V1 configuration names and defaults**

  Set the V2 base URL and document `CHAPA_TEST_...`/`CHAPA_LIVE_...` keys. Do
  not add secret values to the repository.

- [ ] **Step 2: Synchronize Postman request bodies and endpoints**

  Update hosted payment, verification, refunds, single payout, and webhook examples;
  retain resale and credit-top-up domain requests unchanged.

- [ ] **Step 3: Add a manual V2 smoke runbook**

  Include key entry in Render, bank-list validation, hosted/direct payment
  checks, single payout checks, webhook URL/secret configuration, and safe
  rollback guidance.

- [ ] **Step 4: Run deployment configuration and JSON validation**

  Run:

  ```bash
  PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/deployment/render_preview_configuration_test.rb
  ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "valid JSON"'
  ```

### Task 6: V2 test-key smoke and cutover

**Files:**
- Test-only artifacts under `/tmp/chapa-v2-smoke/`
- No secrets committed

- [ ] **Step 1: Have the operator add V2 test credentials**

  Add `CHAPA_SECRET_KEY`, `CHAPA_WEBHOOK_SECRET`, `CHAPA_MODE=test`, and the
  V2 base URL to Render/local secret storage. Never paste values into chat or
  commit them.

- [ ] **Step 2: Exercise V2 hosted/direct payment states**

  Verify success, failed, cancelled, incomplete, blocked, auth-needed, webhook
  duplicate, server verification, and idempotent retry.

- [ ] **Step 3: Exercise V2 payout states**

  Verify bank list, single payout initialization, same-key replay, verify
  endpoint, payout webhook success/failure/reversal, and reconciliation.

- [ ] **Step 4: Confirm deferred capability boundaries**

  Record subaccount and virtual-account test results separately. Do not make
  them required for core migration if the test key cannot exercise them.

- [ ] **Step 5: Remove V1 implementation and run the full suite**

  Search for V1 endpoint strings and V1 key-prefix validation, then run:

  ```bash
  rg -n "api\.chapa\.co/v1|transaction/initialize|transaction/verify|/transfers|CHASECK_TEST|CHASECK-" app config render.yaml test postman
  PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
  RUBOCOP_CACHE_ROOT=/tmp/digis-rubocop-cache PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop
  ```

  Expected: no runtime V1 references, full tests green, and no changed-file
  RuboCop offenses.
