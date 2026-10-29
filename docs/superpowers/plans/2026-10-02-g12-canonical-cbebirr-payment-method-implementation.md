# G-12 Canonical CBE Birr Payment Method Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept and persist Chapa's canonical `cbebirr` method for event and billing payment attempts while rejecting the `cbe` alias.

**Architecture:** Make the order payment-rail allowlist explicit and independent from `Commercial::FeeComponent::PAYMENT_METHODS`. Keep the existing provider-capability gate and Hosted Checkout wire payload unchanged; do not add a migration or claim that Hosted Checkout forces a particular rail.

**Tech Stack:** Rails 8, ActiveRecord, Minitest, Postman collection JSON, RuboCop.

---

**Execution status:** Implemented and verified locally on 2026-10-03; not deployed; changes remain uncommitted.

## File map

- Modify `app/models/orders/payment.rb`: own the payment-rail allowlist while retaining the commercial fee component's distinct filter values.
- Modify `test/models/orders/payment_test.rb`: prove canonical acceptance and alias rejection at model validation.
- Modify `test/services/orders/start_payment_attempt_test.rb` and `test/services/orders/start_billing_payment_attempt_test.rb`: prove shared validation, provider capability enforcement, and persisted canonical value in both flows.
- Modify `postman/Digis API_collection.json`: show `cbebirr` in the event and billing payment-attempt examples.
- Modify `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`: record backend completion while keeping frontend mapping explicitly pending/unverified.

## Task 1: Add failing model and command tests

**Files:**
- Modify: `test/models/orders/payment_test.rb`
- Modify: `test/services/orders/start_payment_attempt_test.rb`
- Modify: `test/services/orders/start_billing_payment_attempt_test.rb`

- [x] **Step 1: Add payment-model allowlist tests**

In `test/models/orders/payment_test.rb`, add a test next to the payment validation tests:

```ruby
test "accepts canonical CBE Birr and rejects non-canonical aliases" do
  canonical = Orders::Payment.new(payment_attributes(payment_method: "cbebirr"))
  alias_method = Orders::Payment.new(payment_attributes(payment_method: "cbe"))

  assert_predicate canonical, :valid?, canonical.errors.full_messages
  assert_not alias_method.valid?
  assert_includes alias_method.errors.attribute_names, :payment_method
end
```

- [x] **Step 2: Add event-attempt behavior tests**

In `test/services/orders/start_payment_attempt_test.rb`, add `cbebirr` to the fake Chapa capability list in `setup`, then add tests asserting `cbebirr` creates one persisted attempt and `cbe` fails as `invalid_payment_method` without a provider call or payment row. Keep the fake Stripe capabilities unchanged so the provider-capability boundary remains testable.

Expected canonical assertions:

```ruby
assert_predicate result, :success?, result.error&.message
assert_equal "cbebirr", result.value.payment_method
assert_equal "cbebirr", @chapa.create_calls.sole.fetch(:payment_method)
```

- [x] **Step 3: Make the billing fake capability-configurable**

In `test/services/orders/start_billing_payment_attempt_test.rb`, let `FakeAdapter#capabilities` return both existing `telebirr` and `cbebirr`, add a `payment_method:` argument defaulting to `"telebirr"` to the private `start` helper, and add a `cbebirr` case asserting the persisted payment method. Add a `cbe` case asserting `invalid_payment_method` and no provider call.

- [x] **Step 4: Run the tests and confirm the intended red state**

Run:

```bash
bin/rails test test/models/orders/payment_test.rb test/services/orders/start_payment_attempt_test.rb test/services/orders/start_billing_payment_attempt_test.rb
```

Expected: the new `cbebirr` model/attempt cases fail because the current payment allowlist rejects `cbebirr`; existing tests remain green.

## Task 2: Separate the payment rail allowlist from commercial fee filters

**Files:**
- Modify: `app/models/orders/payment.rb`

- [x] **Step 1: Define the canonical payment-rail list**

Replace the alias with a separately owned, immutable list:

```ruby
PAYMENT_METHODS = (Commercial::FeeComponent::PAYMENT_METHODS + %w[cbebirr]).freeze
```

Do not add `cbe`, mutate `Commercial::FeeComponent::PAYMENT_METHODS`, change the commercial database constraint, or add a migration.

- [x] **Step 2: Re-run the focused tests**

Run the same command from Task 1. Expected: all three files pass; `cbebirr` succeeds only when the selected provider advertises it, and `cbe` remains an input error.

## Task 3: Synchronize client examples and gap status

**Files:**
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

- [x] **Step 1: Update event and billing examples**

Change the payment-method value in the existing event payment-attempt request and billing top-up request to `cbebirr`. Keep the surrounding request structure and Hosted Checkout semantics unchanged.

- [x] **Step 2: Preserve the frontend dependency in the tracker**

Update G-12's wording to state that the backend now accepts canonical `cbebirr`, rejects `cbe`, and still relies on the frontend mapping its selection to `cbebirr`. Do not mark the cross-repository integration verified; frontend source/call site is not available in this workspace.

- [x] **Step 3: Validate the collection JSON**

Run:

```bash
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "Postman JSON OK"'
```

Expected output: `Postman JSON OK`.

## Task 4: Run focused verification

**Files:** No additional files.

- [x] **Step 1: Run the focused regression suite**

Run:

```bash
bin/rails test test/models/orders/payment_test.rb test/services/orders/start_payment_attempt_test.rb test/services/orders/start_billing_payment_attempt_test.rb
```

Expected: all tests pass, covering model validation, both payment-attempt flows, provider capability rejection, and canonical persistence.

- [x] **Step 2: Lint changed Ruby files**

Run:

```bash
bundle exec rubocop app/models/orders/payment.rb test/models/orders/payment_test.rb test/services/orders/start_payment_attempt_test.rb test/services/orders/start_billing_payment_attempt_test.rb
```

Expected: no offenses in changed Ruby files.

- [x] **Step 3: Review the diff**

Run:

```bash
git diff --check -- app/models/orders/payment.rb test/models/orders/payment_test.rb test/services/orders/start_payment_attempt_test.rb test/services/orders/start_billing_payment_attempt_test.rb 'postman/Digis API_collection.json' docs/operations/frontend-backend-gap-tracker-2026-09-08.md
git diff -- app/models/orders/payment.rb test/models/orders/payment_test.rb test/services/orders/start_payment_attempt_test.rb test/services/orders/start_billing_payment_attempt_test.rb 'postman/Digis API_collection.json' docs/operations/frontend-backend-gap-tracker-2026-09-08.md
```

Expected: no whitespace errors; the diff contains no alias, schema, Direct Charge, or undocumented Hosted Checkout changes.
