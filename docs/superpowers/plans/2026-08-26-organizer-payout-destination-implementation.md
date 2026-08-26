# Organizer Payout Destination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add encrypted organization payout destinations with provider-first verification, payout snapshots, safe APIs, and Chapa transfer integration.

**Architecture:** Finance::PayoutAccount is organization-owned and stores encrypted beneficiary data plus a keyed digest. Provider verification is optional and preferred; unsupported verification leaves the account pending, while preview fixtures may use an explicit test source. Every new payout snapshots the selected verified account, and dispatch decrypts beneficiary fields only inside the provider adapter call.

**Tech Stack:** Rails 8.1, PostgreSQL, UUIDv7, Active Record Encryption, Pundit, ActiveModel Serializers, Minitest, Chapa Transfer API, Core idempotency/audit services.

---

## File map

- Create db/migrate/20260812090099_create_finance_payout_accounts.rb.
- Modify db/migrate/20260813090005_create_finance_payouts.rb.
- Create app/models/finance/payout_account.rb.
- Modify app/models/finance/payout.rb and app/models/organizations/organization.rb.
- Create the five Finance payout-account lifecycle services under app/services/finance/payout_accounts/.
- Modify the Finance payout-provider adapter files for optional verification.
- Create app/controllers/finance/payout_accounts_controller.rb.
- Create app/policies/finance/payout_account_policy.rb.
- Create app/serializers/finance/payout_account_serializer.rb.
- Modify app/serializers/finance/payout_serializer.rb, routes, locales, Postman,
  preview/dev seeds, and Finance payout orchestration.
- Add matching model, command, controller, serializer, policy, concurrency,
  seed, and payout integration tests.
- Update the database design, Chapa guide, payout runbook, and approved spec.

### Task 1: Create the encrypted payout-account schema and model

**Files:**
- Create db/migrate/20260812090099_create_finance_payout_accounts.rb.
- Modify db/migrate/20260813090005_create_finance_payouts.rb.
- Create app/models/finance/payout_account.rb.
- Modify app/models/finance/payout.rb and app/models/organizations/organization.rb.
- Test test/models/finance/payout_account_test.rb and test/models/finance/payout_test.rb.

- [x] Write model tests for encrypted account accessors, type/provider/status
  validation, default-only-when-verified, verification metadata, keyed digest
  uniqueness, and organization ownership.
- [x] Run the model tests and confirm RED because the table/model is absent.
- [x] Create the one-table migration with UUIDv7, encrypted ciphertext columns,
  keyed digest, bank code, status/source metadata, default flag, verification
  timestamps, indexes, checks, and restrict foreign keys.
- [x] Edit the original payout migration to add payout_account_id as a required
  foreign key and update the payout model association/validation.
- [x] Implement encryption and normalization using Core::KeyedDigest and the
  existing Active Record Encryption conventions.
- [x] Run the model tests with N_PLUS_ONE=1; expected GREEN.
- [x] Reset the local database after the edited original migration is loaded;
  do not create a compatibility migration for the existing payout table.

Migration shape:

```ruby
create_table :finance_payout_accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
  t.uuid :organization_id, null: false
  t.string :type, null: false
  t.string :provider, null: false
  t.integer :bank_code, null: false
  t.text :account_number_ciphertext, null: false
  t.string :account_number_digest, limit: 64, null: false
  t.text :account_name_ciphertext, null: false
  t.text :account_label_ciphertext
  t.string :status, null: false, default: "pending_verification"
  t.string :verification_source
  t.uuid :verified_by_id
  t.boolean :is_default, null: false, default: false
  t.timestamptz :verified_at
  t.timestamptz :last_used_at
  t.timestamps
end
```

### Task 2: Add provider-first verification and lifecycle commands

**Files:**
- Modify app/services/finance/payout_providers/adapter.rb and chapa_adapter.rb.
- Create the five services under app/services/finance/payout_accounts/.
- Tests under test/services/finance/payout_accounts/.

- [x] Write RED tests for registration idempotency, encrypted persistence,
  provider-verification success, unsupported-provider pending state,
  test-fixture verification, manual verification authorization, default
  selection, suspension, and close rules.
- [x] Run the service tests and confirm failures are caused by missing commands.
- [x] Add an optional verify_payout_account adapter method that returns an
  unsupported result by default; Chapa delegates only if its client exposes a
  documented verification operation.
- [x] Implement Register with normalized fields, keyed digest, request-bound
  idempotency conflicts, provider-first verification, and no plaintext audit
  metadata.
- [x] Implement Verify with Finance authorization, reason/evidence capture,
  provider, test_fixture, or manual source, and idempotent audit.
- [x] Implement SetDefault with deterministic organization/destination locks and
  one-default enforcement; implement Suspend and Close as audited commands.
- [x] Run the lifecycle service tests with N_PLUS_ONE=1; expected GREEN.

### Task 3: Add safe Finance API surfaces

**Files:**
- Create app/controllers/finance/payout_accounts_controller.rb.
- Create app/policies/finance/payout_account_policy.rb.
- Create app/serializers/finance/payout_account_serializer.rb.
- Modify app/serializers/finance/payout_serializer.rb, config/routes.rb,
  config/locales/finance.en.yml, and postman/Digis API_collection.json.
- Tests under test/controllers/finance, test/policies/finance, and
  test/serializers/finance.

- [x] Write RED integration tests for list/create/verify/set-default/suspend/
  close, missing idempotency keys, organization isolation, owner/admin access,
  Finance verification access, and forbidden sensitive fields.
- [x] Run the controller/policy/serializer tests and confirm the expected RED.
- [x] Add organization-scoped routes under the existing Finance scope.
- [x] Keep account number, ciphertext, digest, and provider secrets out of
  serializers and Postman examples.
- [x] Use locale keys for every API error and the shared command response/
  authorization conventions.
- [x] Update Postman with non-sensitive placeholder account values.
- [x] Run focused API tests with N_PLUS_ONE=1; expected GREEN.

### Task 4: Require and snapshot destinations in payout construction/dispatch

**Files:**
- Modify app/services/finance/build_payout.rb, dispatch_payout.rb, and
  payout_support.rb only for shared loading/verification checks.
- Modify Finance payout tests and helpers.

- [x] Write RED tests proving payout construction rejects missing verified
  defaults, snapshots the selected account, and remains unchanged when the
  organization later changes its default.
- [x] Write RED dispatch tests for suspended/closed destinations, encrypted
  field access, exact Chapa transfer payload, success, failure, and timeout
  reconciliation.
- [x] Require a verified default account while building a payout and persist
  its ID.
- [x] Lock the payout, allocations, and destination in deterministic order
  before dispatch; reject any destination no longer verified.
- [x] Pass decrypted beneficiary data only to the provider adapter and update
  last_used_at after a submitted transfer without logging the values.
- [x] Run Finance payout, reconciliation, and concurrency tests with
  N_PLUS_ONE=1; expected GREEN.

### Task 5: Add preview/dev fixtures and documentation

**Files:**
- Modify db/seeds/preview.rb and db/seeds/dev.rb.
- Modify docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md,
  docs/guides/chapa-integration.md, docs/runbooks/payout-hold-and-reconciliation.md,
  and the approved destination spec.
- Add seed and documentation tests.

- [x] Write RED seed tests for production-safe base seeds and synthetic preview/
  dev verified destinations.
- [x] Add only synthetic encrypted test values to preview/dev; never add real
  bank data to Git or production-safe base seeds.
- [x] Document provider-first verification, pending fallback, test fixtures,
  destination snapshots, and the disposable preview reset.
- [x] Keep CHAPA_PAYOUT_ENABLED enabled only in the explicit test environment
  where the destination fixture exists.
- [x] Run seed/profile tests and documentation/config checks.

### Task 6: Full verification and deployment drill

- [x] Run the focused suite:
```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/models/finance/payout_account_test.rb \
  test/services/finance/payout_accounts \
  test/controllers/finance/payout_accounts_controller_test.rb \
  test/services/finance/build_payout_test.rb \
  test/services/finance/dispatch_payout_test.rb \
  test/integration/finance/concurrent_payout_build_test.rb
```
- [x] Run the Finance regression suite and relevant payment-provider tests with
  N_PLUS_ONE=1.
- [x] Run full RuboCop, Zeitwerk, Ruby syntax, YAML, route, and Postman checks.
- [ ] Reset the disposable Render preview database only after explicit
  confirmation, then redeploy and verify readiness.
- [ ] Exercise test-mode automatic fixture verification, create/select a
  destination, build a matured payout, and verify that provider timeout remains
  processing without duplicate transfer submission.
- [ ] Review the final diff and leave commits/staging to the user.

No automatic commit or push is part of this plan.

Verification to date: the consolidated payout-account/Finance/Chapa/seed
suite passes 74 tests and 394 assertions with N_PLUS_ONE=1. Full RuboCop
passes 1,563 files, Zeitwerk passes, Ruby syntax checks pass, the Postman
collection parses, Render YAML parses, and all payout-account routes load.
The full repository suite currently reports 2,825 tests, 11,823 assertions,
and 7 failures in pre-existing Ticketing credential-claim/transfer fixture
identity tests; no Finance or payout-account failures were reported. Render
preview reset/redeployment and a live payout request remain pending until the
user authorizes the disposable reset and a test transfer destination.
