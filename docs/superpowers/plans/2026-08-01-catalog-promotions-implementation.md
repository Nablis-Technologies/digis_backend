# Catalog Promotions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement immutable catalog promotion versions, event-scoped encrypted codes, scoped one-promotion quotes, organizer APIs, and development/API documentation.

**Architecture:** Promotion writes are command-based and transactional. Drafts may be updated or discarded; published and disabled versions are immutable, and material changes create a superseding draft version. Codes use promotion-local uppercase normalization plus event-keyed digests and Rails encryption. Quotes validate product scope and current windows, convert monetary rules through a shared pricing converter, and return immutable evidence while Orders later owns redemption counting.

**Tech Stack:** Rails 8.1, Ruby 3.4, PostgreSQL, Active Record encryption, Pundit, ActiveModel Serializers, Minitest, `Core::BaseService`, `Core::Audit::Record`, `Core::IdempotencyKey`, and `Core::Database::AdvisoryLock`.

**Constraints:** One table per migration. Every user-facing error comes from a locale. API changes update `postman/Digis API_collection.json`. Model/data changes update `db/seeds/dev.rb`. Run promotion tests with `N_PLUS_ONE=1`. Do not commit; leave grouped staging/commit commands for the user.

---

## File Map

### Currency conversion

- Create: `app/services/catalog/pricing/currency_converter.rb`
- Modify: `app/services/catalog/pricing/quote.rb`
- Create: `test/services/catalog/pricing/currency_converter_test.rb`
- Modify: `test/services/catalog/pricing/quote_test.rb`

### Database and models

- Create: `db/migrate/20260801010001_create_catalog_promotions.rb`
- Create: `db/migrate/20260801010002_create_catalog_promotion_codes.rb`
- Create: `db/migrate/20260801010003_create_catalog_promotion_products.rb`
- Create: `app/models/catalog/promotion.rb`
- Create: `app/models/catalog/promotion_code.rb`
- Create: `app/models/catalog/promotion_product.rb`
- Create: `test/models/catalog/promotion_test.rb`
- Create: `test/models/catalog/promotion_code_test.rb`
- Create: `test/models/catalog/promotion_product_test.rb`

### Commands and values

- Create: `app/values/catalog/promotion_quote.rb`
- Create: `app/services/catalog/promotions/create.rb`
- Create: `app/services/catalog/promotions/update.rb`
- Create: `app/services/catalog/promotions/delete_draft.rb`
- Create: `app/services/catalog/promotions/create_code.rb`
- Create: `app/services/catalog/promotions/reveal_code.rb`
- Create: `app/services/catalog/promotions/publish_version.rb`
- Create: `app/services/catalog/promotions/disable.rb`
- Create: `app/services/catalog/promotions/quote.rb`
- Create: `test/services/catalog/promotions/create_test.rb`
- Create: `test/services/catalog/promotions/update_test.rb`
- Create: `test/services/catalog/promotions/delete_draft_test.rb`
- Create: `test/services/catalog/promotions/create_code_test.rb`
- Create: `test/services/catalog/promotions/reveal_code_test.rb`
- Create: `test/services/catalog/promotions/lifecycle_test.rb`
- Create: `test/services/catalog/promotions/quote_test.rb`

### HTTP surface

- Create: `app/controllers/catalog/promotions_controller.rb`
- Create: `app/controllers/catalog/promotion_codes_controller.rb`
- Create: `app/policies/catalog/promotion_policy.rb`
- Create: `app/policies/catalog/promotion_code_policy.rb`
- Create: `app/serializers/catalog/promotion_serializer.rb`
- Create: `app/serializers/catalog/promotion_code_serializer.rb`
- Create: `app/serializers/catalog/promotion_quote_serializer.rb`
- Create: `test/integration/catalog/promotions_test.rb`
- Modify: `config/routes.rb`

### Documentation/data

- Create: `config/locales/catalog/promotion.en.yml`
- Create: `config/locales/catalog/promotion_code.en.yml`
- Create: `config/locales/catalog/promotion_quote.en.yml`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Modify: `db/seeds/dev.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`
- Modify: `docs/superpowers/specs/2026-08-01-catalog-promotions-design.md`

---

## Task 1: Extract Shared Currency Conversion

### Step 1: Write the failing converter tests

Create the three locale files listed in the file map before running any RED
test. Start with the converter keys in
`config/locales/catalog/promotion_quote.en.yml`; add model and command keys as
their tests are written. This keeps missing translations from obscuring the
intended failures.

Create `test/services/catalog/pricing/currency_converter_test.rb` covering:

```ruby
test "converts using a database rate with currency-specific minor units" do
  rate = Catalog::ExchangeRate.create!(
    from_currency: "EUR", to_currency: "JPY", rate: 130.0,
    effective_from: 2.days.ago
  )

  result = CurrencyConverter.call(
    amount_minor: 1_000,
    from_currency: "EUR",
    to_currency: "JPY",
    at: Time.current
  )

  assert result.success?, result.error&.message
  assert_equal 1_300, result.value.amount_minor
  assert_equal rate.id, result.value.exchange_rate_id
end

test "validates supplied FX evidence against the stored rate" do
  rate = Catalog::ExchangeRate.create!(
    from_currency: "ETB", to_currency: "USD", rate: 0.018,
    effective_from: 2.days.ago
  )

  evidence = Catalog::PriceQuote.new(
    product_id: SecureRandom.uuid,
    charge_currency: "USD",
    amount_minor: 1,
    source_type: "exchange",
    from_currency: "ETB",
    exchange_rate_id: rate.id,
    exchange_rate_value: rate.rate,
    at: Time.current
  )

  result = CurrencyConverter.call(
    amount_minor: 10_000,
    from_currency: "ETB",
    to_currency: "USD",
    at: Time.current,
    fx_quote: evidence
  )

  assert result.success?, result.error&.message
  assert_equal 18, result.value.amount_minor
end

test "rejects mismatched or tampered FX evidence" do
  result = CurrencyConverter.call(
    amount_minor: 10_000,
    from_currency: "ETB",
    to_currency: "USD",
    at: Time.current,
    fx_quote: { exchange_rate_id: SecureRandom.uuid, exchange_rate_value: 99 }
  )

  assert result.failure?
  assert_equal I18n.t("catalog.promotion_quote.errors.invalid_fx_quote"), result.error.message
end
```

### Step 2: Run the RED converter tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/pricing/currency_converter_test.rb
```

Expected: fail because `Catalog::Pricing::CurrencyConverter` does not exist.

### Step 3: Implement the converter

Create a `Catalog::Pricing::CurrencyConverter < Core::BaseService` with:

```ruby
Conversion = Data.define(
  :amount_minor, :from_currency, :to_currency,
  :exchange_rate_id, :exchange_rate_value
)
```

The constructor accepts `amount_minor:, from_currency:, to_currency:, at:, fx_quote: nil`.

- Normalize currencies to uppercase.
- Return the original amount and nil FX evidence when currencies match.
- When `fx_quote` is absent, resolve `Catalog::ExchangeRate.rate_for` at `at`.
- When `fx_quote` is present, read either the `Catalog::PriceQuote` methods or
  symbol/string hash keys, then verify rate ID, from currency, to currency, and
  exact stored rate value before converting.
- Use the existing minor-unit table and `BigDecimal::ROUND_HALF_UP` behavior.
- Return locale-backed failures for unsupported currency and invalid evidence.

### Step 4: Move product pricing to the converter without changing behavior

Replace the private conversion and minor-unit logic in
`app/services/catalog/pricing/quote.rb` with `CurrencyConverter.call` and map
the conversion result into the existing `Catalog::PriceQuote` fields. Do not
pass `fx_quote` from product pricing; its public behavior remains DB-rate-only.

Add an assertion to `test/services/catalog/pricing/quote_test.rb` that the
existing base-price conversion still returns the same amount, source, rate ID,
and currency evidence.

### Step 5: Verify the converter slice

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/pricing/currency_converter_test.rb test/services/catalog/pricing/quote_test.rb
bundle exec rubocop app/services/catalog/pricing/currency_converter.rb app/services/catalog/pricing/quote.rb test/services/catalog/pricing/currency_converter_test.rb test/services/catalog/pricing/quote_test.rb
```

Expected: all converter and existing pricing tests pass with no offenses.

---

## Task 2: Create Promotion Tables and Models

### Step 1: Write model tests before migrations

Create model tests for:

- STI disabled on `Catalog::Promotion` and `Catalog::PromotionCode`.
- `percentage` requires basis points and rejects fixed amount.
- `fixed` requires fixed amount and rejects percentage basis points.
- Basis points are between 1 and 10,000.
- Money fields are integer/nonnegative; maximum discount is positive.
- Limits are positive when present; `per_user_limit` defaults to 1.
- `ends_at` must be after `starts_at` for promotions and codes.
- Status/type allowlists are enforced.
- Code normalization is `strip.upcase` and does not mutate `Core::KeyedDigest`.
- Code ciphertext decrypts to the canonical value and is not equal to the
  plaintext database column value.
- Promotion code digest is unique globally and differs across event IDs.
- Promotion-product pair is unique.
- Promotion-product validation rejects a product from another event.
- Ransackable attributes exclude ciphertext, digest, and plaintext code.

Use locale assertions such as:

```ruby
assert_includes promotion.errors[:type], I18n.t("catalog.promotion.errors.calculation_exclusive")
```

### Step 2: Run the RED model tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/promotion_test.rb test/models/catalog/promotion_code_test.rb test/models/catalog/promotion_product_test.rb
```

Expected: fail because the tables and model constants do not exist.

### Step 3: Add one-table-per-migration schema

Create `20260801010001_create_catalog_promotions.rb` with one
`create_table :catalog_promotions`, UUIDv7 primary key, the fields in the
approved spec, foreign keys to `events_events` and the self-reference, indexes
on event/status/version, and checks for:

```sql
type IN ('percentage', 'fixed')
status IN ('draft', 'active', 'disabled')
((type = 'percentage' AND percentage_basis_points IS NOT NULL AND fixed_amount_minor IS NULL)
 OR (type = 'fixed' AND fixed_amount_minor IS NOT NULL AND percentage_basis_points IS NULL))
(percentage_basis_points BETWEEN 1 AND 10000 OR percentage_basis_points IS NULL)
(fixed_amount_minor >= 0 OR fixed_amount_minor IS NULL)
(minimum_subtotal_minor >= 0 OR minimum_subtotal_minor IS NULL)
(maximum_discount_minor > 0 OR maximum_discount_minor IS NULL)
(redemption_limit > 0 OR redemption_limit IS NULL)
per_user_limit > 0
(ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
```

Create `20260801010002_create_catalog_promotion_codes.rb` with one
`create_table :catalog_promotion_codes`, UUIDv7 ID, `code_digest`,
`code_ciphertext`, label, code-level limit/window, active flag, timestamps,
foreign key to promotions, a globally unique digest index, promotion lookup
indexes, and positive/window checks.

Create `20260801010003_create_catalog_promotion_products.rb` with one
`create_table :catalog_promotion_products`, UUIDv7 ID, promotion/product
foreign keys, timestamps, the unique pair index, and lookup indexes.

### Step 4: Implement the models

Implement the model constants, associations, validations, scopes, and Ransack
allowlists. `Catalog::Promotion` must set
`self.inheritance_column = nil`. `Catalog::PromotionCode` must use:

```ruby
encrypts :code_ciphertext

def self.normalize_code(value)
  value.to_s.strip.upcase
end

def self.code_digest_for(event_id:, code:)
  Core::KeyedDigest.digest(namespace: event_id, value: normalize_code(code))
end

def code
  code_ciphertext
end

def code=(value)
  self.code_ciphertext = self.class.normalize_code(value)
end
```

Keep `Core::KeyedDigest.normalize` unchanged. Add a model-level promotion
product event validation, while commands also validate cross-event ownership
inside their transaction.

### Step 5: Run model tests and schema checks

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/promotion_test.rb test/models/catalog/promotion_code_test.rb test/models/catalog/promotion_product_test.rb
bundle exec rubocop app/models/catalog/promotion.rb app/models/catalog/promotion_code.rb app/models/catalog/promotion_product.rb test/models/catalog/promotion_test.rb test/models/catalog/promotion_code_test.rb test/models/catalog/promotion_product_test.rb
```

Expected: model tests pass, RuboCop reports no offenses, and the schema has
three promotion tables with separate migration files.

---

## Task 3: Implement Draft Creation, Update, Deletion, and Codes

### Step 1: Write failing command tests

Create service tests covering:

- `Create` creates version 1 draft with an empty or supplied product scope.
- `Create` rejects a product from another event.
- `Create` with `supersedes_promotion_id` requires same event and sets exactly
  predecessor version plus one.
- `Create` with a stale version lineage fails without inserting rows.
- `Update` changes only drafts, validates the full candidate, and replaces
  product scope atomically.
- `Update` rejects active and disabled promotions without mutation.
- `DeleteDraft` deletes a draft and dependent code/scope rows, rejects active
  and disabled versions, and is idempotent under replay.
- `CreateCode` canonicalizes input, stores digest/ciphertext, rejects duplicate
  event-scoped code, rejects a code for a disabled promotion, and returns the
  plaintext only in its result object.
- `RevealCode` returns canonical plaintext, writes one audit row, excludes
  plaintext from the audit payload, and is idempotent for a replay key.
- Same idempotency key plus same canonical payload returns the original record;
  same key plus a different payload returns a localized conflict.

Each command test passes an explicit `idempotency_key:` and uses
`assert_idempotent` or `assert_audit_idempotent` rather than a hand-rolled
counter comparison.

### Step 2: Run the RED command tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/create_test.rb test/services/catalog/promotions/update_test.rb test/services/catalog/promotions/delete_draft_test.rb test/services/catalog/promotions/create_code_test.rb test/services/catalog/promotions/reveal_code_test.rb
```

Expected: fail because the command classes do not exist.

### Step 3: Implement shared command idempotency helpers locally

Keep the helper under `app/services/catalog/promotions/` unless a second
domain needs it. Each command must:

- Normalize its attributes with `to_h.deep_symbolize_keys`.
- Canonicalize nested hashes/arrays before hashing.
- Derive a SHA-256 request digest from the normalized request.
- Derive a command audit key from operation name, aggregate ID/event ID, and
  the normalized client idempotency-key digest.
- Acquire `Core::Database::AdvisoryLock` for that command scope.
- Look up the existing audit row and record ID before writing when possible.
- Call `Core::Audit::Record` inside the business transaction with only the
  request digest and record IDs in metadata.
- Return the original/current record on identical replay and a localized
  conflict on a different request digest.

Do not put plaintext `code` or `code_ciphertext` in `audited_changes`,
`metadata`, or exception messages.

### Step 4: Implement `Create` and `Update`

`Create` must lock the event, validate a superseded version when supplied, set
the exact next version, create the promotion, and insert scope rows after
checking all products belong to the event. `Update` must lock the promotion,
require `status == "draft"`, validate a candidate model before deleting scope
rows, then replace scope rows and audit the changed fields.

Both commands return `Core::Result` values and translate all failure messages
through `config/locales/catalog/promotion.en.yml`.

### Step 5: Implement `DeleteDraft`, `CreateCode`, and `RevealCode`

`DeleteDraft` locks and deletes only a draft. `CreateCode` locks the promotion,
requires draft or active status, normalizes the code before both digest and
encryption, validates code windows, and returns a small result object such as:

```ruby
CodeResult = Data.define(:record, :plaintext)
```

`RevealCode` authorizes through the controller before the service call, locks
the code, emits a reveal audit with code ID and actor only, and returns the
canonical decrypted code. A replay with the same idempotency key returns the
same code without a second audit.

### Step 6: Verify command tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/create_test.rb test/services/catalog/promotions/update_test.rb test/services/catalog/promotions/delete_draft_test.rb test/services/catalog/promotions/create_code_test.rb test/services/catalog/promotions/reveal_code_test.rb
bundle exec rubocop app/services/catalog/promotions test/services/catalog/promotions
```

Expected: all command tests pass, including replay and audit assertions, with
no N+1 errors or RuboCop offenses.

---

## Task 4: Implement Publish, Disable, and Promotion Quote

### Step 1: Write the immutable quote value and failing tests

Create `app/values/catalog/promotion_quote.rb` with a frozen `Data.define`
containing promotion/code IDs, version, eligible product IDs and subtotal,
discount, currencies, calculation inputs, promotion/code limits/windows/active
snapshot, FX evidence, and quote timestamp.

Create `test/services/catalog/promotions/lifecycle_test.rb` and
`test/services/catalog/promotions/quote_test.rb` covering:

- Draft publishes once and is idempotent on replay.
- Superseding publish disables the prior active version atomically.
- Invalid or expired windows cannot publish or quote.
- Active disable transitions once and is idempotent.
- Percentage discount uses half-up basis-point arithmetic.
- Fixed discount converts and caps at subtotal.
- Maximum discount caps percentage and fixed results.
- Minimum subtotal rejection is localized.
- Scoped product IDs are validated against the event and promotion scope.
- Unscoped promotions accept event products.
- Invalid, inactive, or out-of-window codes fail.
- Code-level limit/window/active fields appear in immutable evidence.
- Same-currency quotes need no FX rate.
- Different-currency quotes use DB rate or validated supplied evidence.
- Tampered/mismatched FX evidence fails.
- Quote evidence cannot be mutated after creation.
- Usage counts are not queried by Task 5.

Example percentage assertion:

```ruby
result = Catalog::Promotions::Quote.call(
  promotion: @promotion,
  code: "OPENING10",
  eligible_product_ids: [ @product.id ],
  eligible_subtotal_minor: 10_000,
  charge_currency: "ETB",
  at: Time.current
)

assert result.success?, result.error&.message
assert_equal 1_000, result.value.discount_minor
assert_equal 1, result.value.per_user_limit
assert_equal 250, result.value.code_redemption_limit
assert_raises(NoMethodError) { result.value.discount_minor = 1 }
```

### Step 2: Run the RED lifecycle/quote tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/lifecycle_test.rb test/services/catalog/promotions/quote_test.rb
```

Expected: fail because lifecycle, quote, and value-object implementations do
not exist.

### Step 3: Implement lifecycle commands

`PublishVersion` locks the draft and its superseded version, validates the
definition/window, disables a superseded active version, sets the draft active,
and records an audit. `Disable` locks the promotion and changes active to
disabled. Both commands return the existing target state on exact replay and
use locale-backed failures for invalid state transitions.

### Step 4: Implement promotion quote

`Catalog::Promotions::Quote` must:

- Normalize the code with `PromotionCode.normalize_code` and find the digest.
- Validate promotion is active and usable at `at`.
- Validate code belongs to promotion, is active, and is usable at `at`.
- Validate product IDs belong to the event and satisfy optional promotion scope.
- Validate `eligible_subtotal_minor` is a nonnegative integer.
- Convert minimum, fixed amount, and maximum cap through
  `Catalog::Pricing::CurrencyConverter`.
- Apply percentage basis points with half-up integer rounding.
- Cap discount at maximum discount and eligible subtotal.
- Return `Catalog::PromotionQuote` with both promotion-level and code-level
  evidence.
- Never count `orders_promotion_redemptions` or invent catalog counters.

### Step 5: Verify lifecycle and quote tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/lifecycle_test.rb test/services/catalog/promotions/quote_test.rb
bundle exec rubocop app/values/catalog/promotion_quote.rb app/services/catalog/promotions/publish_version.rb app/services/catalog/promotions/disable.rb app/services/catalog/promotions/quote.rb test/services/catalog/promotions/lifecycle_test.rb test/services/catalog/promotions/quote_test.rb
```

Expected: all lifecycle and quote tests pass with no N+1 errors.

---

## Task 5: Add Policies, Serializers, Controllers, and Routes

### Step 1: Write failing integration tests

Create `test/integration/catalog/promotions_test.rb` covering:

- Owner/admin/manager can list/show/create/update/delete draft promotions.
- Staff, scanner, attendee, and public users cannot manage promotions.
- Publish/disable require an idempotency header and are audited.
- Missing or empty `Idempotency-Key` returns 400 with the shared error code.
- Same-key replay does not duplicate the promotion/audit.
- Code creation returns plaintext once; normal list/show excludes plaintext,
  digest, and ciphertext.
- Reveal returns canonical plaintext only to an authorized manager/admin,
  requires idempotency, and does not put plaintext in audit data.
- Quote validates JSON product IDs and subtotal and returns stable evidence.
- Staff/scanner/public cannot access organizer management endpoints.

Use `as: :json`, `admin_headers`, `owner_headers`, and
`headers_for(:staff/:scanner)` from existing test helpers. Assert locale-backed
error codes/messages rather than hard-coded controller strings.

### Step 2: Run the RED integration tests

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/catalog/promotions_test.rb
```

Expected: fail because routes/controllers/policies/serializers do not exist.

### Step 3: Implement policy visibility

Create `Catalog::PromotionPolicy` and `Catalog::PromotionCodePolicy` with an
explicit `VISIBILITY` hash for every action. Use
`Events::AuthorizationResolver.can_manage_catalog?` against the promotion's
event. Scope list/show records through manageable event IDs. Restrict quote in
this organizer API to the same manager/admin catalog surface; Orders will call
the quote service directly for buyer checkout.

Safe fields include promotion definition/status/version/scope IDs and code
metadata. Exclude `code`, `code_ciphertext`, `code_digest`, and any raw request
fields from every serializer profile.

### Step 4: Implement serializers and controllers

Create serializers for promotion, code metadata, and immutable promotion quote.
Create `PromotionsController` with `index`, `show`, `create`, `update`,
`destroy`, `publish`, `disable`, and `quote`. Create
`PromotionCodesController` with `index`, `show`, `create`, and `reveal`.

Use `Core::Common` only for read/list behavior if it preserves policy scopes;
send all lifecycle/write actions through the command services. Permit nested
`product_ids` and `fx_quote` fields explicitly and call `.to_h.deep_symbolize_keys`
at service boundaries. Add `before_action :ensure_idempotency_key_present` to
create/update/destroy/publish/disable/code-create/reveal, not to read-only
quote requests.

### Step 5: Add routes and verify integration tests

Add under the existing `/catalog` scope:

```ruby
resources :promotions, only: %i[index show create update destroy] do
  post :publish, on: :member
  post :disable, on: :member
  post :quote, on: :member
end
resources :promotion_codes, only: %i[index show create] do
  post :reveal, on: :member
end
```

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/catalog/promotions_test.rb
bundle exec rubocop app/controllers/catalog/promotions_controller.rb app/controllers/catalog/promotion_codes_controller.rb app/policies/catalog/promotion_policy.rb app/policies/catalog/promotion_code_policy.rb app/serializers/catalog/promotion_serializer.rb app/serializers/catalog/promotion_code_serializer.rb app/serializers/catalog/promotion_quote_serializer.rb test/integration/catalog/promotions_test.rb
```

Expected: integration tests and linter pass with no sensitive field exposure.

---

## Task 6: Locales, Seed, Postman, and Documentation

### Step 1: Complete locale files before wiring messages

Complete the three locale files under `config/locales/catalog/` that were
created before the RED tests. Define every failure key used by
models/services/controllers, including invalid fields, state transitions,
scope, code windows, FX evidence, minimum subtotal, reveal, draft deletion,
and idempotency conflicts. Use `I18n.t` or `failure_i18n` for all messages; do
not add a literal user-facing error string.

### Step 2: Update parameter filtering

Add `:promotion_code` and `:code_ciphertext` to
`config/initializers/filter_parameter_logging.rb`. Add a regression assertion
that request logs and audit payloads do not contain plaintext promotion codes.

### Step 3: Update development seed

In `db/seeds/dev.rb`, after the existing fest products/prices are present:

- Find or create a draft promotion through `Promotions::Create`.
- Use the VIP product ID as a scope where it exists.
- Create or reuse an active version through `PublishVersion`.
- Create or reuse `OPENING10` through `CreateCode` with a local constant.
- Keep the operation idempotent and avoid direct `create!` bypasses.
- Print the local test code only in the explicit seed summary; never emit it
  through application request logging or audit metadata.
- Include the promotion/code count in the final seed summary.

### Step 4: Update Postman collection

Add request folders/examples for:

- Promotion index/show/create/update/delete draft
- Publish and disable
- Promotion quote with scoped product IDs and subtotal
- Promotion code create/list/show/reveal

Every mutating request includes an `Idempotency-Key` header. Example request
bodies and response fields must match the serializers, routes, and locale/error
contract. Do not expose digest/ciphertext/plaintext in safe read examples.

### Step 5: Align architecture documentation

Keep `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md` aligned with the
implementation: use `code_ciphertext`, required `per_user_limit` default 1,
and draft update/delete/version semantics. Keep the approved design spec
consistent with the final route and evidence names.

### Step 6: Verify documentation/data changes

Run:

```bash
bundle exec rubocop db/seeds/dev.rb
git diff --check
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:seed:dev
```

Expected: seed completes idempotently, creates the sample promotion/code, and
the Postman JSON remains valid.

---

## Task 7: Full Verification and Handoff

Run each command separately so failures remain attributable:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/promotion_test.rb test/models/catalog/promotion_code_test.rb test/models/catalog/promotion_product_test.rb test/services/catalog/promotions test/integration/catalog/promotions_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
bundle exec rubocop
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails zeitwerk:check
bundle exec brakeman
git diff --check
```

The existing unrelated full N+1 errors in
`Catalog::Products::Activate#zones_active_for?` must be reported separately
unless the user explicitly expands Task 5 to fix them.

Before handing off:

- Inspect `git status`, `git diff --stat`, and the complete diff.
- Confirm no commit was created.
- Confirm only intended files changed; do not revert unrelated user changes.
- Provide grouped staging/commit commands by database/models, services/tests,
  API/policies/serializers/routes, and locales/seed/Postman/docs.
