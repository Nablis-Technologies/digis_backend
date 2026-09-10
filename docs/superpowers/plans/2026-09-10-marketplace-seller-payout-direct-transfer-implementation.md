# Marketplace Seller Payout Direct-Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Marketplace seller payout tokenization with encrypted Chapa direct-transfer destinations, auditable manual verification, and verified-only seller payout dispatch for G-03 / Gap #26.

**Architecture:** Marketplace will persist Chapa beneficiary details using the same encrypted-account and keyed-digest pattern as `Finance::PayoutAccount`. Seller registration will validate routing data but remain pending unless a genuine provider verifier or explicitly guarded test fixture verifies the account; an admin command provides the production fallback. `DispatchSellerPayout` will pass the verified account's decrypted number, holder name, bank code, amount, currency, and idempotency reference through the existing shared Chapa transfer client while leaving seller-ledger reservation and reconciliation logic unchanged.

**Tech Stack:** Rails 8.1, PostgreSQL, Active Record Encryption, `Core::KeyedDigest`, Pundit, Minitest, ActiveJob, Chapa v1 `/transfers` and `/banks`, and the Postman collection contract.

**Current implementation status:** Local implementation and repository-wide verification are complete. Render preview verification remains deployment-gated because this branch is intentionally uncommitted; do not claim the preview gate until the tested code is deployed.

---

## Scope and guardrails

- Use `docs/superpowers/specs/2026-09-10-marketplace-seller-payout-direct-transfer-design.md` as the approved source of truth.
- Edit `db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb` in place. Do not create an alter-table follow-up migration.
- Regenerate `db/structure.sql` from a clean local/test database after the original migration changes; do not hand-edit the generated dump.
- Remove `account_token`, `destination_token`, and `tokenize_payout_account` from the Marketplace Chapa path. Do not retain compatibility aliases.
- Keep `Marketplace::BuildSellerPayout`, `Marketplace::SellerLedgerEntry`, `Marketplace::SellerPayoutAllocation`, reserve checks, and reconciliation behavior unchanged except for the account payload.
- Public seller requests may not set `verification_source`, `verified_by_id`, encrypted column names, or provider tokens.
- Never log or serialize raw account numbers, holder names, ciphertext, digests, or provider request bodies.
- Preserve the many unrelated dirty-worktree changes already present. Never stage or commit autonomously.

## File map

### Data and account lifecycle

- Modify `db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb`: direct fields, constraints, indexes, and foreign keys.
- Create `app/services/marketplace/seller_payout_accounts/payout_account_digest.rb`: seller-scoped keyed identity.
- Modify `app/services/core/audit/record.rb`: make audit-key collision recovery safe inside PostgreSQL transactions.
- Modify `app/models/marketplace/seller_payout_account.rb`: encryption, validations, lifecycle metadata, and default behavior.
- Modify `app/services/marketplace/verify_payout_account.rb`: direct registration and pending/provider verification behavior.
- Create `app/services/core/payout_command_support.rb`: shared provider-agnostic command idempotency/audit mechanics.
- Create `app/services/marketplace/seller_payout_accounts/command_support.rb`: command idempotency/audit identity.
- Create `app/services/marketplace/seller_payout_accounts/verify.rb`: admin/manual verification.
- Create `app/services/marketplace/seller_payout_accounts/set_default.rb`: seller default selection.

### Provider and dispatch

- Modify `app/services/marketplace/payout_providers/adapter.rb`: remove tokenization and add optional bank-list/provider-verification defaults.
- Modify `app/services/marketplace/payout_providers/chapa_adapter.rb`: direct transfer delegation and safe unsupported-verifier behavior.
- Modify `app/services/marketplace/payout_providers/registration.rb`: document the direct-beneficiary registration boundary.
- Modify `app/services/marketplace/dispatch_seller_payout.rb`: direct beneficiary payload.
- Inspect `app/services/marketplace/reconcile_seller_payout.rb`: change only if it contains a stale destination-token assumption.

### API, authorization, and contracts

- Modify `app/controllers/marketplace/seller_payout_accounts_controller.rb`.
- Create `app/controllers/admin/marketplace/seller_payout_accounts_controller.rb`.
- Modify `app/policies/marketplace/seller_payout_account_policy.rb`.
- Create `app/policies/admin/marketplace/seller_payout_account_policy.rb`.
- Modify `app/serializers/marketplace/seller_payout_account_serializer.rb`.
- Modify `config/routes.rb`, `db/seeds/base.rb`, and `config/locales/marketplace/resale.en.yml`.
- Modify `config/initializers/filter_parameter_logging.rb`.
- Modify `postman/Digis API_collection.json`.

### Tests and operational evidence

- Create/update Marketplace model, lifecycle, controller, provider, dispatch, admin, security, and integration tests.
- Modify `test/support/marketplace/seller_payout_test_helpers.rb` and all tests that construct tokenized seller accounts.
- Modify `test/config/marketplace_payout_providers_configuration_test.rb` and `test/integration/security/response_visibility_test.rb`.
- Modify `docs/guides/chapa-integration.md` and `docs/operations/frontend-backend-gap-tracker-2026-09-08.md` only after verification.

## Task 1: Establish the failing direct-account contract

**Files:**

- Create: `test/models/marketplace/seller_payout_account_test.rb`
- Modify: `test/support/marketplace/seller_payout_test_helpers.rb`
- Modify: `test/services/marketplace/verify_payout_account_test.rb`
- Modify: `test/services/marketplace/dispatch_seller_payout_test.rb`

- [x] **Step 1: Write model tests first.**

Use the Finance model test as the pattern. Build an account with `type: "bank"`, `provider: "chapa"`, `bank_code: 128`, `account_number: "1000000000001"`, the new digest service, `holder_name: "Seller Holder"`, and an account label.

The tests must prove:

1. `SellerPayoutAccount.inheritance_column` is blank and `type` remains `"bank"`.
2. Account number and holder name round-trip through Active Record Encryption.
3. SQL ciphertext differs from both plaintext values.
4. Nonpositive bank code and unknown status are invalid.
5. Verified rows require `verified_at` and `verification_source`.
6. Manual verified rows require `verified_by`.
7. Non-verified rows reject verification metadata.
8. A default row must be verified.
9. The digest and encrypted fields are absent from `ransackable_attributes`.

- [x] **Step 2: Convert the shared payout fixture helper.**

Replace the tokenized Telebirr fixture in `test/support/marketplace/seller_payout_test_helpers.rb` with a Chapa bank fixture:

~~~ruby
number = "1000000000001"
SellerPayoutAccount.create!(
  user: @seller,
  type: "bank",
  provider: "chapa",
  bank_code: 128,
  account_number: number,
  account_number_digest: Core::PayoutAccountDigest.call(
    namespace: @seller.id, account_number: number
  ),
  account_label: "Seller bank account",
  holder_name: "Seller Holder",
  status: status,
  verification_source: status == "verified" ? "test_fixture" : nil,
  verified_at:,
  is_default: false
)
~~~

Do not leave `account_token` or `telebirr` in this shared Chapa seller-payout context.

- [x] **Step 3: Update the existing dispatch test's request assertions.**

Replace the destination-token assertion with:

~~~ruby
request = @adapter.payout_requests.fetch(0)
assert_equal @account.account_number, request.fetch(:account_number)
assert_equal @account.holder_name, request.fetch(:account_name)
assert_equal @account.bank_code, request.fetch(:bank_code)
assert_equal @payout.idempotency_key, request.fetch(:idempotency_key)
assert_equal @payout.id, request.fetch(:payout_id)
refute request.key?(:destination_token)
refute request.key?(:account_token)
~~~

- [x] **Step 4: Run the focused tests and confirm the failures are contract failures.**

Run:

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/marketplace/seller_payout_account_test.rb test/services/marketplace/verify_payout_account_test.rb test/services/marketplace/dispatch_seller_payout_test.rb
~~~

Expected: failures because the current schema/model still require `account_token` and do not define the direct fields or digest service. Isolate unrelated fixture/database failures before continuing.

## Task 2: Replace the original account migration and add the digest service

**Files:**

- Modify: `db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb`
- Create: `app/services/marketplace/seller_payout_accounts/payout_account_digest.rb`
- Regenerate: `db/structure.sql`
- Test: `test/models/marketplace/seller_payout_account_test.rb`

- [x] **Step 1: Replace the token column in the original migration.**

The table must contain these direct fields:

~~~ruby
t.uuid :user_id, null: false
t.string :type, null: false
t.string :provider, null: false
t.integer :bank_code, null: false
t.text :account_number_ciphertext, null: false
t.string :account_number_digest, limit: 64, null: false
t.text :account_label_ciphertext
t.text :holder_name_ciphertext, null: false
t.string :verification_source
t.uuid :verified_by_id
t.boolean :is_default, null: false, default: false
t.string :status, null: false, default: "pending_verification"
t.timestamptz :verified_at
t.timestamptz :last_used_at
~~~

Keep the UUIDv7 primary key and timestamps. Remove `account_token`.

- [x] **Step 2: Add direct-account indexes.**

Remove the provider/token index and add:

~~~ruby
add_index :marketplace_seller_payout_accounts,
  %i[user_id provider account_number_digest],
  unique: true,
  name: "idx_marketplace_payout_accounts_on_user_provider_account_digest"
add_index :marketplace_seller_payout_accounts, %i[user_id status],
  name: "idx_marketplace_payout_accounts_on_user_and_status"
add_index :marketplace_seller_payout_accounts, %i[user_id provider],
  unique: true,
  where: "is_default",
  name: "idx_marketplace_payout_accounts_on_default_user_provider"
~~~

- [x] **Step 3: Add database checks and verifier foreign key.**

Use these rules:

~~~sql
type IN ('bank')
provider IN ('chapa')
bank_code > 0
account_number_digest ~ '^[0-9a-f]{64}$'
status IN ('pending_verification','verified','suspended','closed')
verification_source IS NULL OR verification_source IN ('provider','test_fixture','manual')
(NOT is_default OR status = 'verified')
~~~

Add the full verification metadata constraint:

~~~sql
((status = 'verified' AND verified_at IS NOT NULL AND verification_source IS NOT NULL AND
  (verification_source <> 'manual' OR verified_by_id IS NOT NULL)) OR
 (status <> 'verified' AND verified_at IS NULL AND verification_source IS NULL AND verified_by_id IS NULL))
~~~

Keep the `user_id -> core_users` foreign key and add `verified_by_id -> core_users` with `on_delete: :restrict`.

- [x] **Step 4: Add the shared digest service.**

Create `Core::PayoutAccountDigest` with this exact contract so Finance and
Marketplace use one keyed-digest implementation while each caller supplies its
own ownership namespace:

~~~ruby
module Core
  class PayoutAccountDigest
    def self.call(namespace:, account_number:)
      Core::KeyedDigest.digest(namespace:, value: account_number)
    end
  end
end
~~~

The service is side-effect free. Callers strip whitespace but never coerce the account number to an integer.

- [x] **Step 5: Recreate the local schema and regenerate the SQL dump.**

On an isolated local database only, recreate the database, run migrations, and dump the structure:

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:drop db:create db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:schema:dump
rg -n "marketplace_seller_payout_accounts|account_number_ciphertext|account_number_digest|verified_by_id|default_user_provider|account_token" db/structure.sql
~~~

Expected: direct fields/checks/indexes are present, `account_token` is absent, and only the generated schema dump changes. Never run the drop command against a shared or production database.

- [x] **Step 6: Run model tests.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/marketplace/seller_payout_account_test.rb
~~~

Expected: PASS.

## Task 3: Implement the encrypted account model

**Files:**

- Modify: `app/models/marketplace/seller_payout_account.rb`
- Test: `test/models/marketplace/seller_payout_account_test.rb`

- [x] **Step 1: Define direct-transfer constants and associations.**

Use `TYPES = %w[bank].freeze`, `PROVIDERS = %w[chapa].freeze`, the existing lifecycle statuses, and `VERIFICATION_SOURCES = %w[provider test_fixture manual].freeze`. Keep the seller association and add:

~~~ruby
belongs_to :verified_by, class_name: "Core::User", optional: true
~~~

- [x] **Step 2: Add encrypted aliases and lifecycle predicates.**

Use:

~~~ruby
encrypts :account_number_ciphertext, :account_label_ciphertext, :holder_name_ciphertext

def account_number = account_number_ciphertext
def account_number=(value) = self.account_number_ciphertext = value.to_s.strip.presence
def account_label = account_label_ciphertext
def account_label=(value) = self.account_label_ciphertext = value.to_s.strip.presence
def holder_name = holder_name_ciphertext
def holder_name=(value) = self.holder_name_ciphertext = value.to_s.strip.presence
def verified? = status == "verified"
def suspended? = status == "suspended"
def closed? = status == "closed"
~~~

- [x] **Step 3: Add model validation matching the database rules.**

Validate owner, direct-transfer type/provider, positive bank code, account number, digest, holder name, status, and verification source. Add:

~~~ruby
validate :default_requires_verified
validate :verification_metadata
~~~

Verified rows require `verified_at` and `verification_source`; manual verified rows require `verified_by`; all non-verified rows reject verification metadata.

- [x] **Step 4: Restrict searchable fields.**

Return:

~~~ruby
%w[id user_id type provider bank_code status verification_source is_default
   verified_at last_used_at created_at updated_at]
~~~

from `ransackable_attributes`. Do not include account number, ciphertext, digest, holder name, or verifier ID.

- [x] **Step 5: Run model tests again.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/marketplace/seller_payout_account_test.rb
~~~

Expected: PASS.

## Task 4: Replace Marketplace registration and remove tokenization

**Files:**

- Modify: `app/services/marketplace/verify_payout_account.rb`
- Modify: `app/services/marketplace/payout_providers/adapter.rb`
- Modify: `app/services/marketplace/payout_providers/chapa_adapter.rb`
- Modify: `app/services/marketplace/payout_providers/registration.rb`
- Modify: `test/services/marketplace/verify_payout_account_test.rb`
- Modify: `test/config/marketplace_payout_providers_configuration_test.rb`

- [x] **Step 1: Change registration inputs from an opaque hash to direct fields.**

Replace `account_details:` with `bank_code:` and `account_number:`. Normalize strings and strip the account number without numeric coercion. The controller call must use:

~~~ruby
Marketplace::VerifyPayoutAccount.call(
  user: current_user,
  type:,
  provider:,
  bank_code:,
  account_number:,
  account_label:,
  holder_name:,
  adapter:,
  idempotency_key:
)
~~~

- [x] **Step 2: Validate the bank code without treating it as ownership proof.**

Call:

~~~ruby
banks = adapter.available_banks
return failure(bank_error) if banks && !banks.include?(bank_code)
~~~

When `banks` is `nil`, continue to the provider-verification result and safe pending persistence. Never mark an account verified from a bank-list response.

- [x] **Step 3: Persist encrypted details under a seller/provider/digest lock.**

Compute:

~~~ruby
digest = Core::PayoutAccountDigest.call(
  namespace: user.id, account_number:
)
~~~

After the provider result is known, acquire `Core::Database::AdvisoryLock.acquire!("marketplace-payout-account", user_id, provider, digest)`, lock the matching seller/provider/digest row, return a matching concurrent idempotent replay, return `payout_account_conflict` for conflicting identity, and otherwise persist with `verification_attributes(verification)`:

~~~ruby
SellerPayoutAccount.new(
  user:,
  type:,
  provider:,
  bank_code:,
  account_number:,
  account_number_digest: digest,
  account_label:,
  holder_name:,
  status: "verified", # provider/test_fixture success; unknown/timeout uses pending_verification
  verification_source: "provider", # test_fixture remains environment-gated
  verified_by: nil,
  verified_at: at,
  is_default: false
)
~~~

Audit metadata contains only account ID, provider, verification source, idempotency key, and request digest.

- [x] **Step 4: Preserve optional provider verification.**

Before persistence, call:

~~~ruby
adapter.verify_payout_account(
  account_number:, account_name: holder_name, bank_code:, type:, provider:,
  idempotency_key: key.to_s
)
~~~

Provider success persists a verified row with `verification_source: "provider"`. Unknown/timeout persists and returns a successful pending account result. A definite provider failure returns `payout_account_verification_failed` without persisting a destination. Verified provider and test-fixture registrations both write the registration and verification audit events. Rescue `Core::Audit::Record::ReplayConflict` as `idempotency_conflict`; this is the actual exception class defined by the audit recorder.

The internal `test_fixture` path remains allowed only in test, development, or `RENDER_PREVIEW=true`; it is never accepted from public request parameters and never allowed in production.

- [x] **Step 5: Remove tokenization from the Marketplace adapter base.**

Change the required operations to:

~~~ruby
%i[payout verify_payout available_balance capabilities]
~~~

Add these optional defaults:

~~~ruby
def available_banks(**) = nil
def verify_payout_account(**) = Result.unknown(raw_status: "unsupported")
~~~

Delete `normalize_tokenization`, `token_error`, and all `tokenize_payout_account` declarations.

- [x] **Step 6: Update the Chapa adapter.**

Keep direct payout, payout verification, balance, and capabilities delegation. Add `available_banks` delegation. Make `verify_payout_account` return `Result.unknown(raw_status: "unsupported")` when the shared Chapa transfer client lacks a preflight verifier. Delete the Chapa tokenization method and its token-specific error path.

Update configuration tests to assert direct payout capability and registration prerequisites, without asserting tokenization capability.

- [x] **Step 7: Run registration/provider tests.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/verify_payout_account_test.rb test/config/marketplace_payout_providers_configuration_test.rb test/services/finance/payout_providers/chapa_transfer_client_test.rb
~~~

Expected: Chapa seller registration returns service success with `pending_verification` when no preflight verifier exists; it no longer returns `payout_account_provider_unavailable` merely because tokenization is unsupported.

## Task 5: Add audited manual verification and default selection

**Files:**

- Create: `app/services/marketplace/seller_payout_accounts/command_support.rb`
- Create: `app/services/marketplace/seller_payout_accounts/verify.rb`
- Create: `app/services/marketplace/seller_payout_accounts/set_default.rb`
- Create: `app/services/core/payout_command_support.rb`
- Create: `test/services/marketplace/seller_payout_accounts/verify_test.rb`
- Create: `test/services/marketplace/seller_payout_accounts/set_default_test.rb`
- Create: `test/services/core/payout_command_support_test.rb`

- [x] **Step 1: Create shared Core and Marketplace command identity support.**

Create `Core::PayoutCommandSupport` for the idempotency key, domain-configured audit key, canonical actor/request digest, matching replay, conflict replay, and canonicalization. Keep the Finance and Marketplace modules as thin domain adapters that provide their audit prefixes, digest namespaces, error translations, and account lookup. Use the Marketplace prefix:

~~~ruby
def command_audit_key(operation, key)
  "marketplace-seller-payout-account-#{operation}-#{key.digest}"
end
~~~

Use `Core::KeyedDigest` for canonical request identity. Never place encrypted beneficiary values in audit metadata or request identity.

- [x] **Step 2: Implement manual verification.**

Create `Marketplace::SellerPayoutAccounts::Verify` with:

~~~ruby
def initialize(account:, actor:, reason:, evidence_reference:, idempotency_key:, at: Time.current)
~~~

The command must require `marketplace.seller_payout_account.verify`, require nonblank reason/evidence, lock the account, return a successful no-op for an already verified account, allow only `pending_verification` to transition, set `status: "verified"`, `verification_source: "manual"`, `verified_by: actor`, `verified_at: at`, and `is_default: false`, then record `marketplace.seller_payout_account.verified` without raw details.

Use `assert_audit_idempotent` in the service test to prove one audit transition for a replay. Add forbidden, missing-evidence, already-verified no-op, wrong-status, and successful-transition cases.

- [x] **Step 3: Implement seller default selection.**

Create `Marketplace::SellerPayoutAccounts::SetDefault` with:

~~~ruby
def initialize(account:, actor:, idempotency_key:)
~~~

Require account ownership or platform-admin access, require verified status, lock seller/provider scope, clear other defaults, set the selected account, and audit `marketplace.seller_payout_account.default_selected`. Existing seller payouts remain bound to their explicit account ID.

Test non-owner forbidden, pending rejection, previous-default clearing, idempotent replay, conflicting-key rejection, and database uniqueness under the seller lock.

- [x] **Step 4: Run lifecycle tests.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/seller_payout_accounts/verify_test.rb test/services/marketplace/seller_payout_accounts/set_default_test.rb
~~~

Expected: PASS.

## Task 6: Wire public/admin APIs, policies, routes, permissions, and serializers

**Files:**

- Modify: `app/controllers/marketplace/seller_payout_accounts_controller.rb`
- Create: `app/controllers/admin/marketplace/seller_payout_accounts_controller.rb`
- Modify: `app/policies/marketplace/seller_payout_account_policy.rb`
- Create: `app/policies/admin/marketplace/seller_payout_account_policy.rb`
- Modify: `app/serializers/marketplace/seller_payout_account_serializer.rb`
- Modify: `config/routes.rb`
- Modify: `db/seeds/base.rb`
- Modify: `config/locales/marketplace/resale.en.yml`
- Modify: `test/controllers/marketplace/seller_payout_accounts_controller_test.rb`
- Create: `test/controllers/admin/marketplace/seller_payout_accounts_controller_test.rb`

- [x] **Step 1: Update public seller create.**

Permit only:

~~~ruby
params.require(:payout_account).permit(
  :type, :provider, :bank_code, :account_number, :account_label, :holder_name
)
~~~

Pass direct fields to `Marketplace::VerifyPayoutAccount`. Keep `ensure_idempotency_key_present`. Chapa without a preflight verifier must return HTTP 201 with safe `pending_verification` metadata.

- [x] **Step 2: Add public `set_default`.**

Load through `policy_scope(SellerPayoutAccount)`, authorize `:set_default?`, require the idempotency key, call `Marketplace::SellerPayoutAccounts::SetDefault`, and render the safe serializer.

- [x] **Step 3: Update public policy and serializer fields.**

Use:

~~~ruby
%i[id user_id type provider bank_code account_label status verification_source
   is_default verified_at last_used_at created_at updated_at]
~~~

Add `set_default?` and explicit visibility for the action. Exclude account number, ciphertext, digest, holder name, verifier ID, and token fields from every public response.

- [x] **Step 4: Create the admin account controller.**

Create `Admin::Marketplace::SellerPayoutAccountsController` with index/show/verify. The verify action must follow this shape:

~~~ruby
before_action :ensure_idempotency_key_present, only: :verify
before_action :load_account, only: %i[show verify]

def verify
  authorize @account, :verify?,
    policy_class: ::Admin::Marketplace::SellerPayoutAccountPolicy
  result = ::Marketplace::SellerPayoutAccounts::Verify.call(
    account: @account,
    actor: current_user,
    reason: params[:reason],
    evidence_reference: params[:evidence_reference],
    idempotency_key:
  )
  render_service_result(result, serializer_options: {
    serializer: ::Marketplace::SellerPayoutAccountSerializer
  })
end
~~~

The admin policy must require `marketplace.seller_payout_account.verify` for index/show/verify, allow super-admin bypass, and expose only safe fields.

- [x] **Step 5: Seed the exact permission and locale strings.**

Add to `db/seeds/base.rb`:

~~~ruby
{
  resource: "marketplace.seller_payout_account",
  action: "verify",
  namespace: "marketplace",
  description: I18n.t("marketplace.permissions.seller_payout_account_verify")
}
~~~

Add `marketplace.permissions.seller_payout_account_verify` plus the typed errors `payout_account_not_verifiable`, `payout_account_verification_required`, and `payout_account_not_found` to `config/locales/marketplace/resale.en.yml`.

Confirm the existing seed mapping grants the new permission to `ADMIN` and `SUPER_ADMIN`, but not `CORE_ADMIN`, `SUPPORT`, or seller roles.

- [x] **Step 6: Add routes.**

The public resource must expose:

~~~ruby
resources :payout_accounts, only: %i[index create],
          controller: "marketplace/seller_payout_accounts" do
  post :set_default, on: :member
end
~~~

Inside the existing admin marketplace namespace add:

~~~ruby
resources :seller_payout_accounts, only: %i[index show], controller: "seller_payout_accounts" do
  post :verify, on: :member
end
~~~

Expected paths:

~~~text
GET  /marketplace/seller/payout_accounts
POST /marketplace/seller/payout_accounts
POST /marketplace/seller/payout_accounts/:id/set_default
GET  /admin/marketplace/seller_payout_accounts
GET  /admin/marketplace/seller_payout_accounts/:id
POST /admin/marketplace/seller_payout_accounts/:id/verify
~~~

- [x] **Step 7: Update API tests.**

Prove public direct create, pending response, safe output, owner-only default selection, missing idempotency failure, admin verification, missing evidence, regular-attendee 403, and manual verification replay with one audit row.

- [x] **Step 8: Run route/controller/permission tests.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/marketplace/seller_payout_accounts_controller_test.rb test/controllers/admin/marketplace/seller_payout_accounts_controller_test.rb test/integration/admin/permissions_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails routes | rg "seller/payout_accounts|admin/marketplace/seller_payout_accounts"
~~~

Expected: tests pass and all six expected route entries exist.

## Task 7: Switch seller dispatch to direct Chapa fields

**Files:**

- Modify: `app/services/marketplace/dispatch_seller_payout.rb`
- Inspect/modify: `app/services/marketplace/reconcile_seller_payout.rb`
- Modify: `test/services/marketplace/dispatch_seller_payout_test.rb`
- Modify: `test/jobs/marketplace/seller_payout_jobs_test.rb` if it constructs tokens
- Modify: `test/integration/marketplace/concurrent_seller_payout_test.rb` if it constructs tokens

- [x] **Step 1: Change the provider payload.**

Use:

~~~ruby
account = SellerPayoutAccount.find(payout.seller_payout_account_id)
result = normalize_provider_result(adapter.payout(
  amount_minor: payout.amount_minor,
  currency: payout.currency,
  idempotency_key: payout.idempotency_key,
  payout_id: payout.id,
  account_number: account.account_number,
  account_name: account.holder_name,
  bank_code: account.bank_code
))
~~~

Do not change the processing-intent transaction, scope checks, reserve checks, result transitions, or allocation behavior.

- [x] **Step 2: Confirm reconciliation stays reference-based.**

`Marketplace::ReconcileSellerPayout` may call only `adapter.verify_payout` with idempotency key, payout ID, and provider reference. Remove a stale destination-token argument if present; never resubmit beneficiary details after an unknown transfer.

- [x] **Step 3: Preserve all payout outcome tests and add privacy assertions.**

Retain success, failure/cancellation, timeout/reconciliation, reserve breach, processing-before-provider, allocation, and no-blind-retry assertions. Add checks that account-use audit metadata contains only account/payout identifiers and timestamps.

- [x] **Step 4: Run the seller payout suite.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/build_seller_payout_test.rb test/services/marketplace/dispatch_seller_payout_test.rb test/integration/marketplace/concurrent_seller_payout_test.rb test/jobs/marketplace/seller_payout_jobs_test.rb
~~~

Expected: PASS with unchanged ledger/reservation outcomes.

## Task 8: Synchronize visibility, Postman, and integration contracts

**Files:**

- Modify: `test/integration/security/response_visibility_test.rb`
- Modify: `test/services/core/audit/record_test.rb`
- Modify: `test/integration/security/sensitive_logging_test.rb`
- Modify: `test/config/active_record_encryption_test.rb`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/guides/chapa-integration.md`

- [x] **Step 1: Update the security serializer contract.**

The forbidden Marketplace fields must include:

~~~ruby
%i[
  account_number account_number_ciphertext account_number_digest
  holder_name holder_name_ciphertext account_token verified_by_id
]
~~~

The allowed projection must include bank code, account label, status, verification source, default flag, timestamps, and no sensitive value.

- [x] **Step 2: Update Postman seller items.**

Rename the old create item to `Add Seller Payout Account` and use:

~~~json
{
  "payout_account": {
    "type": "bank",
    "provider": "chapa",
    "bank_code": 128,
    "account_number": "1000000000001",
    "holder_name": "Seller Holder",
    "account_label": "Primary bank account"
  }
}
~~~

Keep the JSON content type and `{{idempotencyKey}}`. Add items for public set-default, admin list/show, and admin verify at the exact routes from Task 6. The verify body is:

~~~json
{
  "reason": "Verified against seller-provided bank evidence",
  "evidence_reference": "case-2026-09-10-001"
}
~~~

Descriptions must state that creation can return `pending_verification`, bank lookup is routing validation only, and raw beneficiary values are never returned.

- [x] **Step 3: Update the Chapa guide.**

Document shared direct `/v1/transfers`, encrypted pending seller destinations, manual verification, `/v1/banks` as a routing lookup only, subaccounts as out-of-scope split-payment resources, and preview's default `CHAPA_PAYOUT_ENABLED=false`.

- [x] **Step 4: Run contract checks.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/security/response_visibility_test.rb
python3 -m json.tool "postman/Digis API_collection.json" >/dev/null
~~~

Expected: PASS and valid JSON.

## Task 9: Update G-03 evidence and verify the guarded preview path

**Files:**

- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`
- Inspect: `render.yaml`, `bin/docker-entrypoint`, `db/seeds/preview.rb`
- Test: `test/deployment/render_preview_configuration_test.rb`

- [x] **Step 1: Update the tracker after implementation evidence exists.**

Change G-03 to implemented only after encrypted pending creation, admin verification, direct payload dispatch, unchanged ledger/reconciliation tests, and preview verification all pass. State that Chapa subaccounts remain intentionally out of scope.

- [x] **Step 2: Verify preview safety.**

~~~bash
rg -n "CHAPA_PAYOUT_ENABLED|CHAPA_MODE|RENDER_PREVIEW|DIGIS_RESET_DATABASE" render.yaml bin/docker-entrypoint config/database.yml
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/deployment/render_preview_configuration_test.rb
~~~

Expected: preview requires test mode, reset remains URL-guarded, and payout dispatch remains disabled by default.

- [x] **Step 3: Run the local seeded smoke sequence.**

Prove:

~~~text
POST /marketplace/seller/payout_accounts
  -> 201 pending_verification, safe metadata only
POST /admin/marketplace/seller_payout_accounts/:id/verify
  -> 200 verified, manual audit evidence present
POST /marketplace/seller/payout_accounts/:id/set_default
  -> 200 is_default=true
BuildSellerPayout + DispatchSellerPayout with a fake Chapa adapter
  -> direct account_number/account_name/bank_code payload and succeeded payout
~~~

Use shared idempotency assertions and inspect only redacted response/audit data.

- [ ] **Step 4: Run the controlled Render non-money gate.**

With the preview database and service deployed:

~~~text
GET /up -> HTTP 200
POST seller account -> 201 pending_verification
POST admin verify -> 200 verified
GET admin account -> safe fields only
~~~

Do not enable real-money payout dispatch merely to prove account persistence. A Chapa test-mode transfer is a separate explicit gate requiring approved credentials and `CHAPA_PAYOUT_ENABLED=true`; restore the flag to false afterward.

This step remains open until this uncommitted branch is explicitly committed
and deployed to the Render preview; no deployment or credential change is
performed by this implementation turn.

## Task 10: Full verification and review handoff

**Files:** Review all changed implementation, test, contract, and documentation files while preserving unrelated worktree changes.

- [x] **Step 1: Run the complete targeted suite.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/marketplace/seller_payout_account_test.rb test/services/marketplace/seller_payout_accounts/verify_test.rb test/services/marketplace/seller_payout_accounts/set_default_test.rb test/services/marketplace/verify_payout_account_test.rb test/services/marketplace/build_seller_payout_test.rb test/services/marketplace/dispatch_seller_payout_test.rb test/controllers/marketplace/seller_payout_accounts_controller_test.rb test/controllers/admin/marketplace/seller_payout_accounts_controller_test.rb test/integration/marketplace/concurrent_seller_payout_test.rb test/integration/security/response_visibility_test.rb test/config/marketplace_payout_providers_configuration_test.rb
~~~

Expected: PASS.

- [x] **Step 2: Run repository-wide quality gates.**

~~~bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails zeitwerk:check
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman --no-pager
git diff --check
~~~

Expected: all commands pass with no new changed-file offenses or warnings. Record exact unrelated baseline failures separately.

- [x] **Step 3: Review the exact delta.**

~~~bash
git diff -- db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb db/structure.sql app/models/marketplace/seller_payout_account.rb app/services/marketplace app/controllers/marketplace/seller_payout_accounts_controller.rb app/controllers/admin/marketplace/seller_payout_accounts_controller.rb app/policies/marketplace/seller_payout_account_policy.rb app/policies/admin/marketplace/seller_payout_account_policy.rb app/serializers/marketplace/seller_payout_account_serializer.rb config/routes.rb db/seeds/base.rb config/locales/marketplace/resale.en.yml test postman docs/guides/chapa-integration.md docs/operations/frontend-backend-gap-tracker-2026-09-08.md
git status --short
~~~

Confirm no tokenization/destination-token path, plaintext credential logging, or sensitive serializer field remains. Confirm unrelated dirty files are untouched.

- [ ] **Step 4: Prepare grouped staging commands without executing them.**

The repository requires explicit user authorization before staging/committing. Report grouped commands only:

~~~bash
# Group 1: data/domain/provider
git add db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb db/structure.sql app/models/marketplace/seller_payout_account.rb app/services/marketplace

# Group 2: API/auth/contracts
git add app/controllers/marketplace/seller_payout_accounts_controller.rb app/controllers/admin/marketplace/seller_payout_accounts_controller.rb app/policies/marketplace/seller_payout_account_policy.rb app/policies/admin/marketplace/seller_payout_account_policy.rb app/serializers/marketplace/seller_payout_account_serializer.rb config/routes.rb db/seeds/base.rb config/locales/marketplace/resale.en.yml postman/Digis\ API_collection.json

# Group 3: tests and operational documentation
git add test docs/guides/chapa-integration.md docs/operations/frontend-backend-gap-tracker-2026-09-08.md
~~~

Do not run these commands or create commits without explicit user permission.

## Completion criteria

The implementation is complete when:

- the original Marketplace account migration contains no token storage;
- direct beneficiary values are encrypted and digest-indexed;
- public seller creation safely returns pending metadata when Chapa cannot preflight-verify;
- manual verification and seller default selection are permissioned, idempotent, and audited;
- seller dispatch sends the exact direct Chapa payload through the shared Finance transport;
- no Marketplace Chapa tokenization/destination-token path remains;
- routes, policies, serializers, permissions, locales, Postman, and operational docs match;
- targeted tests, full Rails tests, RuboCop, Zeitwerk, Brakeman, and diff checks pass; and
- G-03 is updated with evidence only after the guarded preview check succeeds.
