# Orders, Multi-Currency Checkout, and Payments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an event-scoped, multi-currency order aggregate with immutable pricing, bounded inventory holds, sequential provider retries, durable webhook processing, and exactly-once fulfillment.

**Architecture:** HTTP routes remain under `/api/v1`, while controllers live in domain namespaces under `app/controllers/orders/`. Each mutating endpoint authorizes with Pundit and invokes exactly one `Core::BaseService` command. Commands own transactions and deterministic lock order; provider adapters normalize external APIs; `Core::Outbox::Publish` isolates post-commit effects. Financial calculation uses integer minor units, `Core::Money`, and `BigDecimal`; orchestration never lives in callbacks.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs/check constraints/partial indexes/advisory locks, Pundit, ActiveModelSerializers, Solid Queue, Minitest fixtures.

**Approved sources:** `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md` and `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`.

---

## Delivery gate and invariants

Start after event, catalog pricing/inventory/promotions, registration, and purchase-limit foundations pass. Reuse Phase 0 `Core::Money`, `Core::BaseService::Result`, `Core::BusinessError`, `Core::CommandResponse`, `Core::Audit::Record`, and `Core::Outbox::Publish`. Reuse Phase 2 `catalog_exchange_rates` and `Catalog::ExchangeRate`; do not recreate them. Remove inferior development-only order/payment structures rather than dual-writing.

- One order has one event and one buyer.
- Charge currency is selected before persistence and never changes.
- Price, FX, fee, adjustment, and refund-policy snapshots become immutable at `pending_payment`.
- Checkout expires ten minutes after creation; refresh/retry/provider switching never extends it.
- At most three sequential attempts and exactly one current attempt per order.
- At most one succeeded payment is accepted; every other succeeded charge is fully reversed.
- Provider calls do not run while database aggregate locks are held.
- Browser redirects never prove payment state; verified provider events do.
- Complex endpoints call exactly one `Core::BaseService` command.

## File map

### Database and models

- Create `db/migrate/20260717090002_create_orders.rb`
- Create `db/migrate/20260717090003_create_order_items.rb`
- Create `db/migrate/20260717090004_create_order_adjustments.rb`
- Create `db/migrate/20260717090005_create_promotion_redemptions.rb`
- Create `db/migrate/20260717090006_create_payments.rb`
- Create `db/migrate/20260717090007_create_payment_events.rb`
- Create models under `app/models/orders/`: `order.rb`, `order_item.rb`, `order_adjustment.rb`, `promotion_redemption.rb`, `payment.rb`, `payment_event.rb`

### Commands and values

- Create `app/services/orders/quote.rb`
- Create `app/services/orders/largest_remainder_allocator.rb`
- Create `app/services/orders/processing_fee_calculator.rb`
- Create `app/services/orders/build_quote.rb`
- Create `app/services/orders/create_checkout.rb`
- Create `app/services/orders/restart_checkout.rb`
- Create `app/services/orders/release_checkout.rb`
- Create `app/services/orders/start_payment_attempt.rb`
- Create `app/services/orders/record_payment_event.rb`
- Create `app/services/orders/process_payment_event.rb`
- Create `app/services/orders/accept_payment.rb`
- Create `app/services/orders/fulfill_order.rb`
- Create `app/services/orders/reverse_unaccepted_payment.rb`
- Create `app/services/orders/expire_checkout.rb`
- Create `app/services/orders/expire_settlement_grace.rb`
- Create `app/services/payments/providers/adapter.rb`, `registry.rb`, `result.rb`, and `chapa_adapter.rb`

### API and jobs

- Create `app/controllers/orders/order_quotes_controller.rb`
- Create `app/controllers/orders/orders_controller.rb`
- Create `app/controllers/orders/payment_attempts_controller.rb`
- Create `app/controllers/orders/payment_webhooks_controller.rb`
- Create `app/policies/orders/order_policy.rb`
- Create serializers under `app/serializers/orders/`
- Create jobs under `app/jobs/orders/`: `process_payment_event_job.rb`, `enter_settlement_grace_job.rb`, `expire_settlement_grace_job.rb`, `reconcile_payment_job.rb`
- Modify `config/routes.rb` with `/api/v1` scope mapped to domain controllers

### Tests

- Create fixtures under `test/fixtures/orders/`
- Create model tests under `test/models/orders/`
- Create service tests under `test/services/orders/` and `test/services/payments/providers/`
- Create controller tests under `test/controllers/orders/`
- Create job tests under `test/jobs/orders/`
- Create concurrency tests under `test/integration/orders/`

## Task 1: Add deterministic quote and fee primitives

**Files:**
- Create: `app/services/orders/quote.rb`
- Create: `app/services/orders/largest_remainder_allocator.rb`
- Create: `app/services/orders/processing_fee_calculator.rb`
- Test: `test/services/orders/processing_fee_calculator_test.rb`
- Test: `test/services/orders/largest_remainder_allocator_test.rb`

- [ ] **Step 1: RED — write fee rounding and allocation tests**

```ruby
# frozen_string_literal: true

require "test_helper"

class Orders::ProcessingFeeCalculatorTest < ActiveSupport::TestCase
  test "calculates fixed plus percentage with half-up rounding" do
    result = Orders::ProcessingFeeCalculator.call(
      basis_minor: 1_005, fixed_amount_minor: 20, rate_bps: 250,
      minimum_minor: nil, maximum_minor: nil
    )

    assert_equal 45, result.amount_minor
    assert_equal 1_005, result.basis_minor
  end

  test "clamps optional bounds" do
    result = Orders::ProcessingFeeCalculator.call(
      basis_minor: 100_000, fixed_amount_minor: 0, rate_bps: 100,
      minimum_minor: 10, maximum_minor: 50
    )
    assert_equal 50, result.amount_minor
  end
end
```

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/processing_fee_calculator_test.rb test/services/orders/largest_remainder_allocator_test.rb
```

Expected: FAIL because the calculation classes do not exist.

- [ ] **Step 3: GREEN — implement narrow immutable results and reuse `Core::Money`**

```ruby
# frozen_string_literal: true

module Orders
  class ProcessingFeeCalculator
    Result = Data.define(:amount_minor, :basis_minor, :fixed_amount_minor, :rate_bps, :minimum_minor, :maximum_minor)

    def self.call(...) = new(...).call

    def initialize(basis_minor:, fixed_amount_minor:, rate_bps:, minimum_minor:, maximum_minor:)
      @basis = Integer(basis_minor)
      @fixed = Integer(fixed_amount_minor)
      @bps = Integer(rate_bps)
      @minimum = minimum_minor&.then { Integer(_1) }
      @maximum = maximum_minor&.then { Integer(_1) }
    end

    def call
      percentage = (BigDecimal(@basis.to_s) * @bps / 10_000).round(0, :half_up).to_i
      amount = @fixed + percentage
      amount = [amount, @minimum].max if @minimum
      amount = [amount, @maximum].min if @maximum
      Result.new(amount_minor: amount, basis_minor: @basis, fixed_amount_minor: @fixed,
        rate_bps: @bps, minimum_minor: @minimum, maximum_minor: @maximum)
    end
  end
end
```

Implement largest-remainder allocation with rational shares, floor, then remaining units by descending remainder and ascending stable ID. `Orders::Quote` composes `Core::Money` values with product/FX/fee-source/expiry evidence and does not duplicate currency arithmetic.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 1 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders
```

Expected: PASS with no float calculations.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders test/services/orders
git commit -m "feat(orders): add deterministic pricing primitives"
```

## Task 2: Create immutable order schema

**Files:**
- Create: order/item/adjustment/promotion migrations and models from the file map
- Test: `test/models/orders/order_test.rb`
- Test: `test/models/orders/order_adjustment_test.rb`

- [ ] **Step 1: RED — write model and direct PostgreSQL constraint tests**

Prove total reconciliation, nonnegative caches, item/event ownership, adjustment/order ownership, allowlisted statuses/types/refund policies, paired source fields, currency consistency, immutable snapshots, and STI-disabled `type` behavior.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders
```

Expected: FAIL because the tables/models do not exist.

- [ ] **Step 3: GREEN — create exact schema and indexes**

```ruby
add_index :orders_orders, %i[buyer_user_id event_id], unique: true,
  where: "status IN ('draft', 'pending_payment')",
  name: "idx_one_active_checkout_per_buyer_event"
add_index :orders_orders, :replaces_order_id, unique: true,
  where: "replaces_order_id IS NOT NULL"
add_check_constraint :orders_orders,
  "total_minor = subtotal_minor - discount_minor + fee_minor + tax_minor + adjustment_minor",
  name: "orders_total_reconciles"
add_check_constraint :orders_order_items, "quantity > 0", name: "order_item_quantity_positive"
add_check_constraint :orders_order_adjustments,
  "(source_type IS NULL) = (source_id IS NULL)", name: "order_adjustment_source_pair"
```

Use composite `(id,order_id)` uniqueness and a composite FK for item-scoped adjustments. Add sign/type/refund/currency/fee-bound checks. `Orders::OrderAdjustment` sets `self.inheritance_column = nil`. Do not recreate catalog FX tables.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 2 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify schema**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders
```

Expected: PASS and named constraints appear in schema.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/orders test/models/orders test/fixtures/orders
git commit -m "feat(orders): add immutable order aggregate"
```

## Task 3: Build quote and atomic checkout creation

**Files:**
- Create: `app/services/orders/build_quote.rb`
- Create: `app/services/orders/create_checkout.rb`
- Test: `test/services/orders/build_quote_test.rb`
- Test: `test/services/orders/create_checkout_test.rb`
- Test: `test/integration/orders/concurrent_checkout_test.rb`

- [ ] **Step 1: RED — test multi-currency snapshots and last-unit concurrency**

Cover fixed override, Phase 2 automatic FX conversion, expired quote, unsupported currency, immutable order/item FX evidence, shared ten-minute holds, package versus admission capacity, promotion reservation, zero-total fulfillment, and two buyers racing for the last unit.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/build_quote_test.rb test/services/orders/create_checkout_test.rb test/integration/orders/concurrent_checkout_test.rb
```

Expected: FAIL because commands do not exist.

- [ ] **Step 3: GREEN — implement one locked transaction**

`Orders::CreateCheckout < Core::BaseService` validates quote/provider-compatible currency, locks inventories then physical dates by sorted UUID, creates order/items/adjustments, reserves package stock and attendee capacity, reserves promotion, reconciles totals, and calls `Core::Outbox::Publish` for durable effects. Return `success(order)`. Expected failures use:

```ruby
failure Core::BusinessError.new(
  "Inventory is no longer available",
  code: "inventory_unavailable",
  status: :conflict,
  errors: { quantity: ["exceeds current availability"] }
)
```

Use the same typed contract for stale quote, unsupported currency, promotion unavailable, and active checkout. Do not rescue broken database invariants.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 3 command. Expected: PASS.

- [ ] **Step 5: Refactor and repeat race tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders test/integration/orders --seed 19427
```

Expected: PASS with no oversell.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders test/services/orders test/integration/orders
git commit -m "feat(orders): create multi-currency checkout atomically"
```

## Task 4: Add checkout APIs and bounded restart

**Files:**
- Create: controllers/policy/serializers listed in the file map
- Create: `app/services/orders/restart_checkout.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/orders/orders_controller_test.rb`
- Test: `test/controllers/orders/order_quotes_controller_test.rb`
- Test: `test/services/orders/restart_checkout_test.rb`

- [ ] **Step 1: RED — test Pundit, privacy, idempotency, and restart races**

Assert buyer/event authority; serializer hides inventory counters, provider internals, promo digests, organizer adjustments, and payment references; one active checkout; at most two replacements per buyer/event/hour; active payment blocks restart; concurrent restarts yield one replacement; failed revalidation leaves old checkout intact.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders test/services/orders/restart_checkout_test.rb
```

Expected: FAIL because API/restart command is absent.

- [ ] **Step 3: GREEN — implement domain controller namespace and advisory lock**

```ruby
# frozen_string_literal: true

module Orders
  class OrdersController < Core::ApplicationController
    def create
      event = Events::Event.find(params.require(:event_id))
      authorize Order.new(event:), :create?
      result = CreateCheckout.call(
        actor: current_user,
        event:,
        quote_id: order_params.fetch(:quote_id),
        item_requests: order_params.fetch(:items),
        promotion_code: order_params[:promotion_code],
        idempotency_key: request.headers.fetch("Idempotency-Key")
      )
      render_service_result(result, success_status: :created,
        serializer_options: { serializer: OrderSerializer })
    end

    private

    def order_params
      params.require(:order).permit(:quote_id, :promotion_code,
        items: %i[event_product_id quantity registration_id])
    end
  end
end
```

Routes use `scope "/api/v1", module: :orders`. Restart takes `pg_advisory_xact_lock(buyer_user_id,event_id)`, locks old order/inventory, checks rolling count, and atomically releases/replaces. Pass every `Core::BaseService::Result` to foundation `render_service_result`; do not create a second renderer.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 4 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify surfaces**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders test/policies/orders test/serializers/orders
```

Expected: PASS with no internal leakage.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/orders app/policies/orders app/serializers/orders app/services/orders/restart_checkout.rb config/routes.rb test/controllers/orders test/services/orders test/policies/orders test/serializers/orders
git commit -m "feat(api): expose authorized checkout commands"
```

## Task 5: Create payment attempts and provider contract

**Files:**
- Create: payment/payment-event migrations/models and provider files from the map
- Test: `test/models/orders/payment_test.rb`
- Test: `test/services/payments/providers/adapter_contract_test.rb`

- [ ] **Step 1: RED — test database and adapter invariants**

Test attempt 1..3, unique attempt/provider keys/reference, one current attempt, one accepted payment, amount/currency equality, fee triple, grace 3..15 minutes, event dedupe, and canonical success/failure/cancelled/unknown/timeout responses.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders/payment_test.rb test/services/payments/providers/adapter_contract_test.rb
```

Expected: FAIL because payment schema/contract is absent.

- [ ] **Step 3: GREEN — add partial indexes and canonical adapter result**

```ruby
add_index :orders_payments, %i[order_id attempt_number], unique: true
add_index :orders_payments, %i[provider idempotency_key], unique: true
add_index :orders_payments, %i[provider provider_reference], unique: true,
  where: "provider_reference IS NOT NULL"
add_index :orders_payments, :order_id, unique: true,
  where: "accepted_at IS NOT NULL", name: "idx_one_accepted_payment_per_order"
add_index :orders_payments, :order_id, unique: true,
  where: "superseded_at IS NULL AND status IN ('created', 'processing')",
  name: "idx_one_current_payment_attempt"
add_index :orders_payment_events, %i[provider provider_event_id], unique: true
```

Provider `Result = Data.define(:status, :provider_reference, :failure_code, :provider_fee_minor, :provider_fee_currency, :raw_status)`. Adapter defines create/cancel/verify/refund/verify_refund/available_balance/capabilities/grace. Every enabled adapter passes the contract.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 5 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify adapters**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders/payment_test.rb test/services/payments/providers
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/orders app/services/payments test/models/orders test/services/payments test/fixtures/orders
git commit -m "feat(payments): add canonical payment attempts"
```

## Task 6: Start and switch sequential attempts

**Files:**
- Create: `app/services/orders/start_payment_attempt.rb`
- Create: `app/controllers/orders/payment_attempts_controller.rb`
- Test: `test/services/orders/start_payment_attempt_test.rb`
- Test: `test/controllers/orders/payment_attempts_controller_test.rb`

- [ ] **Step 1: RED — test limits, capability, races, and idempotency**

Cover ownership, deadline, provider/method/currency, immutable buyer processing fee, superseding, provider cancel intent, max three, accepted block, concurrent starts, replay, and ambiguous provider timeout.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/start_payment_attempt_test.rb test/controllers/orders/payment_attempts_controller_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — serialize attempts under order lock**

Lock order then attempts by number. Replay returns `success(existing_payment)`. Expected rejections use `failure Core::BusinessError.new(message, code:, status:, errors:)`. Persist a local attempt before provider creation; timeout stays processing for verification and never automatically creates another attempt. Controller invokes only this command.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 6 command. Expected: PASS.

- [ ] **Step 5: Refactor and repeat concurrency test**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/start_payment_attempt_test.rb --seed 38711
```

Expected: PASS; one current attempt.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders/start_payment_attempt.rb app/controllers/orders/payment_attempts_controller.rb config/routes.rb test/services/orders test/controllers/orders
git commit -m "feat(payments): support bounded provider retries"
```

## Task 7: Build durable webhook inbox and exactly-once acceptance

**Files:**
- Create: webhook/record/process/accept/fulfill/reversal files from map
- Test: `test/controllers/orders/payment_webhooks_controller_test.rb`
- Test: `test/services/orders/process_payment_event_test.rb`
- Test: `test/integration/orders/concurrent_payment_success_test.rb`

- [ ] **Step 1: RED — test signatures, dedupe, two successes, and crash recovery**

Cover invalid signature, fast durable receipt, duplicate/out-of-order/unknown events, two attempts succeeding concurrently, superseded and late success, one fulfillment/ledger/ticket/outbox set, crash after inbox insert, and crash after fulfillment commit.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders/payment_webhooks_controller_test.rb test/services/orders/process_payment_event_test.rb test/integration/orders/concurrent_payment_success_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — implement durable inbox and winner transaction**

Webhook controller verifies signature and calls only `Orders::RecordPaymentEvent`; it inserts-or-returns `(provider,provider_event_id)` and publishes processing via `Core::Outbox::Publish`. Worker locks inbox then payment → order → reservations → promotion. Winner sets accepted state, commits inventory/promotion, fulfills, posts organizer source rows, and publishes effects in one transaction. Losing/superseded/late success creates one full `payment_reversal` and performs no fulfillment.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 7 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify failure injection**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders test/integration/orders test/jobs/orders
```

Expected: PASS without duplicate effects.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/orders app/services/orders app/jobs/orders config/routes.rb test/controllers/orders test/services/orders test/integration/orders test/jobs/orders
git commit -m "feat(payments): process webhooks exactly once"
```

## Task 8: Enforce checkout expiry and settlement grace

**Files:**
- Create: expiry commands/jobs from file map
- Test: `test/services/orders/expire_checkout_test.rb`
- Test: `test/services/orders/expire_settlement_grace_test.rb`
- Test: `test/integration/orders/payment_grace_race_test.rb`

- [ ] **Step 1: RED — test deadline/grace/late-payment behavior**

Cover immediate release without current attempt, only current nonterminal attempt moving holds/promo to processing, 3..15 minute clamp, final verification, inside-grace fulfillment, unresolved release, concurrent webhook/worker, and late reversal without inventory reacquisition.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/expire_checkout_test.rb test/services/orders/expire_settlement_grace_test.rb test/integration/orders/payment_grace_race_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — reuse the acceptance lock order**

Lock order → current attempt → reservations by ID → promotion. Verify provider outside locks, then reacquire and apply canonical eligibility. Never extend a snapshot, recreate a hold, or trust a timeout as terminal.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 8 command. Expected: PASS.

- [ ] **Step 5: Refactor and run phase suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders test/services/orders test/services/payments test/controllers/orders test/jobs/orders test/integration/orders
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders app/jobs/orders test/services/orders test/jobs/orders test/integration/orders
git commit -m "feat(payments): enforce settlement grace"
```

## Task 9: Final phase gate

**Files:**
- Modify only files introduced above when correcting findings

- [ ] **Step 1: RED audit — map every invariant to a named test**

Map event ownership, `Core::Money`/FX immutability, adjustment reconciliation, ten-minute hold, bounded restart, three attempts, one current/accepted payment, durable inbox, reversals, grace, authorization/privacy, and failure recovery. Missing evidence is RED.

- [ ] **Step 2: Run full suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: PASS; fix every failure.

- [ ] **Step 3: GREEN — remove obsolete development paths**

Delete superseded order/payment implementations instead of dual writes or compatibility branches.

- [ ] **Step 4: Run full suite and verify GREEN**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: zero failures/errors.

- [ ] **Step 5: Refactor and inspect database evidence**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate:status
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/orders --seed 50321
```

Expected: migrations up and race tests PASS.

- [ ] **Step 6: Commit**

```bash
git add app db config test
git commit -m "test(orders): prove checkout and payment invariants"
```

## Completion evidence

Complete only when the full suite proves immutable multi-currency checkout, exact adjustments, concurrency-safe inventory/promotions, one active checkout, bounded restarts/attempts, durable verified webhooks, one accepted payment, reversal of all unaccepted success, bounded grace, exactly-once fulfillment/outbox/ledger behavior, Pundit/AMS privacy, and injected-failure recovery.
