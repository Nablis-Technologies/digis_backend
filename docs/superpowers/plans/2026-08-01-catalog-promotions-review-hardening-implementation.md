# Catalog Promotions Review Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. No commit steps are included because the user requested no automatic commits.

**Goal:** Fix the five actionable review findings in catalog promotions while preserving the approved API and quote behavior.

**Architecture:** Keep authorization at the existing Pundit policy-scope boundary, validate list input in the promotion command services, batch active-zone eligibility checks inside product activation, and propagate `CurrencyConverter` results through promotion quote calculations. Leave the verified-safe delete replay and Data serializer behavior unchanged.

**Tech Stack:** Ruby 3.4, Rails 8.1, ActiveRecord, Pundit, ActiveModelSerializers, Minitest, Prosopite, RuboCop.

---

### Task 1: Scope Promotion and Code Lookups

**Files:**
- Modify: `app/controllers/catalog/promotions_controller.rb:8,51,111`
- Modify: `app/controllers/catalog/promotion_codes_controller.rb:7,22,56`
- Test: `test/integration/catalog/promotions_test.rb`

- [ ] **Step 1: Add failing integration assertions for inaccessible records**

Add tests that use the attendee token against known organizer-owned promotion
and code IDs and assert the scoped lookup does not return the record. Keep the
existing owner tests unchanged. The requests should be:

```ruby
test "attendee cannot show an organizer promotion" do
  get "/catalog/promotions/#{@promotion.id}", headers: user_headers, as: :json

  assert_response :not_found
end

test "attendee cannot show an organizer promotion code" do
  get "/catalog/promotion_codes/#{@code.id}", headers: user_headers, as: :json

  assert_response :not_found
end
```

- [ ] **Step 2: Run the new tests to verify the current unscoped behavior**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/catalog/promotions_test.rb -i '/attendee cannot show/'
```

Expected: the tests fail because the current controllers load the record and
then return authorization failure instead of scoped not-found behavior.

- [ ] **Step 3: Use policy scopes for all promotion and code resource loads**

Change the controller lookups to these boundaries:

```ruby
def find_promotion
  @promotion = policy_scope(Catalog::Promotion).find(params[:id])
end

def destroy
  promotion = policy_scope(Catalog::Promotion).find_by(id: params[:id])
  authorize promotion if promotion

  result = Catalog::Promotions::DeleteDraft.call(
    promotion:,
    actor: current_user,
    idempotency_key:,
    promotion_id: params[:id]
  )
  render_command_result(result)
end
```

In `PromotionCodesController`, use `policy_scope(Catalog::Promotion).find`
for `create` and `policy_scope(Catalog::PromotionCode).find` for `find_code`.
Do not change the ID-only delete replay path in `DeleteDraft`.

- [ ] **Step 4: Run the focused integration tests**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/catalog/promotions_test.rb
```

Expected: all promotion HTTP tests pass, including the new not-found cases.

---

### Task 2: Enforce Array-Valued Product IDs

**Files:**
- Modify: `app/services/catalog/promotions/command_support.rb`
- Modify: `app/services/catalog/promotions/create.rb`
- Modify: `app/services/catalog/promotions/update.rb`
- Modify: `config/locales/catalog/promotion.en.yml`
- Test: `test/services/catalog/promotions/create_test.rb`
- Test: `test/services/catalog/promotions/update_test.rb`
- Test: `test/integration/catalog/promotions_test.rb`

- [ ] **Step 1: Add failing service tests for scalar product IDs**

Add one create test and one update test that pass a single UUID string instead
of an array. Assert failure, the localized `invalid_product_ids` message, and
no mutation. The create call should use a unique name and the existing
event/product setup:

```ruby
before_count = Catalog::Promotion.where(name: "Scalar product IDs").count
result = Create.call(
  event: @event,
  actor: @actor,
  attributes: { name: "Scalar product IDs", type: "fixed", fixed_amount_minor: 100, currency: "ETB", per_user_limit: 1 },
  product_ids: @product.id,
  idempotency_key: "promotion-create-scalar-product-id"
)

assert result.failure?
assert_equal I18n.t("catalog.promotion.errors.invalid_product_ids"), result.error.message
assert_equal before_count, Catalog::Promotion.where(name: "Scalar product IDs").count
```

For update, pass `product_ids: @product.id` and assert the existing promotion
scope/name remains unchanged.

- [ ] **Step 2: Run the scalar-input tests to verify they fail**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/create_test.rb test/services/catalog/promotions/update_test.rb -i /scalar/
```

Expected: the tests fail because `Array("id")` currently accepts a scalar as a
one-element list.

- [ ] **Step 3: Add localized validation at the command boundary**

Add this locale entry:

```yaml
invalid_product_ids: "product_ids must be an array"
```

Add a private helper to `CommandSupport`:

```ruby
def normalize_product_ids(value)
  return if value.nil?
  return value.compact.map(&:to_s).uniq.sort if value.is_a?(Array)

  raise Core::Error, I18n.t("catalog.promotion.errors.invalid_product_ids")
end
```

Keep raw `product_ids` in `Create` and `Update` until `call` so the helper's
`Core::Error` is handled by each service's existing rescue path. Normalize to
`[]` for Create when nil and preserve nil for Update when omitted:

```ruby
# Create#call
@product_ids = normalize_product_ids(@product_ids) || []

# Update#call
@product_ids = normalize_product_ids(@product_ids)
```

The existing update behavior remains: nil preserves scope and an empty array
replaces it with no scope.

- [ ] **Step 4: Add the HTTP scalar-input regression**

Post a promotion with `product_ids: "not-an-array"`, the owner token, and an
Idempotency-Key. Assert `422` and the localized invalid-product-IDs message.

- [ ] **Step 5: Run promotion command and HTTP tests**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions test/integration/catalog/promotions_test.rb
```

Expected: all tests pass with scalar values rejected and array semantics
preserved.

---

### Task 3: Batch Activation Zone Queries

**Files:**
- Modify: `app/services/catalog/products/activate.rb:71-81,104-108`
- Test: `test/services/catalog/products/lifecycle_test.rb`

- [ ] **Step 1: Confirm the existing N+1 regression**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/products/lifecycle_test.rb
```

Expected: the five existing `zones_active_for?` N+1 errors reproduce.

- [ ] **Step 2: Add a focused multi-access activation regression**

Add a lifecycle test with two venue accesses for the same event and active
zone mappings. Use different access types on one date so allocation validation
does not add an unrelated requirement:

```ruby
test "activation batches active zone lookup for multiple accesses" do
  draft = create_draft(event: @event, name: "Multi Access Pass").value
  Catalog::ProductPrice.create!(
    event_product: draft,
    type: "base",
    currency: "ETB",
    amount_minor: 1_000,
    active_from: 1.hour.ago
  )
  date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                   ends_at: 1.day.from_now + 4.hours)
  venue_zone = Events::AccessZone.create!(event: @event, event_date: date,
                                          code: "VENUE", name: "Venue Gate",
                                          type: "venue", sort_order: 0)
  parking_zone = Events::AccessZone.create!(event: @event, event_date: date,
                                            code: "PARKING", name: "Parking",
                                            type: "parking", sort_order: 1)
  venue_access = draft.product_accesses.create!(event_date: date, type: "venue")
  parking_access = draft.product_accesses.create!(event_date: date, type: "parking")
  venue_access.product_access_zones.create!(access_zone: venue_zone)
  parking_access.product_access_zones.create!(access_zone: parking_zone)

  result = Activate.call(product: draft, actor: @actor)

  assert result.success?, result.error&.message
  assert_equal "active", draft.reload.status
end
```

The same test must pass with `N_PLUS_ONE=1` so Prosopite detects any
per-access query.

- [ ] **Step 3: Replace per-access zone queries with one batch lookup**

Materialize the already-included accesses, collect relevant `venue` and
`parking` types, and query active zones once:

```ruby
accesses = @product.product_accesses.includes(:product_access_zones, :event_date).to_a
active_zones = Events::AccessZone.active
  .where(event_id: @product.event_id, type: relevant_access_types(accesses))
  .pluck(:type, :event_date_id)

def relevant_access_types(accesses)
  accesses.filter_map { |access| access.type if access.venue? || access.parking? }.uniq
end
```

Use an in-memory predicate with the existing semantics:

```ruby
def zones_active_for?(access, active_zones)
  return active_zones.any? { |type, _date_id| type == access.type } if access.event_date_id.blank?

  active_zones.include?([ access.type, nil ]) ||
    active_zones.include?([ access.type, access.event_date_id ])
end
```

Skip the active-zone query when there are no relevant accesses. Keep the
existing empty-mapping error and product-access preload unchanged.

- [ ] **Step 4: Run the lifecycle N+1 tests**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/products/lifecycle_test.rb
```

Expected: all lifecycle tests pass with zero N+1 errors.

---

### Task 4: Propagate Promotion FX Conversion Failures

**Files:**
- Modify: `app/services/catalog/promotions/quote.rb:31-101`
- Test: `test/services/catalog/promotions/quote_test.rb`

- [ ] **Step 1: Add a failing later-conversion failure test**

Call the private conversion helper with a valid conversion result containing a
missing exchange-rate ID. This isolates the later conversion failure without
mocking the converter:

```ruby
conversion = Core::BaseService::Result.success(
  Catalog::Pricing::CurrencyConverter::Conversion.new(
    amount_minor: 0,
    from_currency: "ETB",
    to_currency: "USD",
    exchange_rate_id: "missing-rate",
    exchange_rate_value: 0.018
  )
)
quote = Quote.new(**quote_arguments.merge(charge_currency: "USD"))
result = quote.send(:convert_money, 1_000, conversion)

assert_instance_of Core::BaseService::Result, result
assert result.failure?
assert_equal I18n.t("catalog.promotion_quote.errors.invalid_fx_quote"), result.error.message
```

- [ ] **Step 2: Run the new test to verify the current swallowed failure**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/quote_test.rb -i /later-conversion/
```

Expected: the test fails because `convert_money` currently returns nil on the
failed conversion.

- [ ] **Step 3: Return Core results from monetary conversions**

Change `convert_money` to return `success(nil)` for absent optional values,
`success(amount_minor)` for same-currency values, and the converter result for
cross-currency values. In `call` and `calculate_discount`, return
`failure(result.error)` immediately whenever a conversion result fails. Use
the result value for minimum thresholds, fixed discounts, and maximum caps.

- [ ] **Step 4: Run quote and pricing tests**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/quote_test.rb test/services/catalog/pricing/quote_test.rb
```

Expected: all quote tests pass and existing product pricing behavior remains
unchanged.

---

### Task 5: Final Verification and Handoff

**Files:**
- Verify all files changed by Tasks 1-4.

- [ ] **Step 1: Run focused tests and lint**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/catalog/promotions_test.rb test/services/catalog/promotions test/services/catalog/products/lifecycle_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop app/controllers/catalog app/services/catalog/promotions app/services/catalog/products/activate.rb app/serializers/catalog/promotion_quote_serializer.rb test/integration/catalog/promotions_test.rb test/services/catalog/promotions test/services/catalog/products/lifecycle_test.rb
```

- [ ] **Step 2: Run repository verification**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails zeitwerk:check
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman
bundle exec rubocop
git diff --check
```

Report any unrelated pre-existing failures separately. Do not modify or stage
the existing untracked handoff documents, and do not create a commit.

- [ ] **Step 3: Inspect final worktree**

Run:

```bash
git status --short
```

Confirm only the scoped controllers, services, tests, locale, and design/plan
files changed. Provide grouped staging commands without executing them.
