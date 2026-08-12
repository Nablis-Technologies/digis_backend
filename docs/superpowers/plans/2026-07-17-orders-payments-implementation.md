# Orders, Multi-Currency Checkout, and Payments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an event-scoped, multi-currency order aggregate with immutable pricing, bounded inventory holds, sequential provider retries, durable webhook processing, and exactly-once fulfillment.

**Architecture:** HTTP routes remain at the root pre-launch, while controllers live in domain namespaces under `app/controllers/orders/`. Each mutating endpoint authorizes with Pundit and invokes exactly one `Core::BaseService` command. Commands own transactions and deterministic lock order; `Commercial::ResolveCharges` provides the only platform-fee calculation evidence; provider adapters normalize external APIs; `Core::Outbox::Publish` isolates post-commit effects. Financial calculation uses integer minor units, `Core::Money`, and `BigDecimal`; orchestration never lives in callbacks.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs/check constraints/partial indexes/advisory locks, Pundit, ActiveModelSerializers, Solid Queue, Minitest fixtures.

**Approved sources:** `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`, `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`, and `docs/superpowers/specs/2026-08-08-commercial-agreements-platform-pricing-design.md`.

---

## Delivery gate and invariants

Start after event, catalog pricing/inventory/promotions, registration/purchase-limit, and Commercial foundations pass. Reuse Phase 0 `Core::Money`, `Core::BaseService::Result`, `Core::BusinessError`, `Core::CommandResponse`, `Core::Audit::Record`, and `Core::Outbox::Publish`. Reuse Phase 2 `catalog_exchange_rates` and `Catalog::ExchangeRate`; do not recreate them. Consume `Commercial::ResolveCharges`, immutable component evidence, payer selections, volume usage, entitlement, and subsidy-budget contracts; do not recreate platform-fee calculation in Orders. Remove inferior development-only order/payment structures rather than dual-writing.

## Commercial handoff sequence

This plan is intentionally interleaved with the Commercial plan. Execute its
tasks in the following boundary order:

1. Orders Tasks 1–2 may begin after the Commercial foundations and Task 7A
   budget invariant are complete.
2. After Orders Task 2 has created and verified `orders_orders`, pause this
   plan while Commercial Task 7B creates the real order-linked subsidy
   reservation contract, followed by Commercial Task 8's volume-usage and
   event-payer selection contracts.
3. Begin Orders Task 3 only after Commercial Tasks 7B and 8 are complete.
   Execute it together with Commercial Task 10's immutable Commercial-results
   integration; checkout is not complete until both plans' contracts and race
   tests pass.

Do not add a placeholder Orders table, a seed order, or a weakened foreign key
to make the Commercial reservation work. Orders Task 2 is the authoritative
owner of the order schema.

Migration versions follow the dependency graph rather than the plan's original
document date: Commercial foundations through Task 7A use versions through
`20260808090012`, Orders Tasks 1–2 use `20260811090001` through
`20260811090004`, Commercial Tasks 7B–8 use the next versions, and the later
payment tables follow those handoffs. This keeps a fresh database install from
attempting an Orders foreign key before its Catalog and Commercial parent table
exists.

- One order has one event and one buyer.
- Charge currency is selected before persistence and never changes.
- Price, FX, fee, adjustment, and refund-policy snapshots become immutable at `pending_payment`.
- Every platform/service/processing/subsidy/resale fee adjustment references the exact immutable Commercial component/version; configuration failure never becomes an implicit zero fee.
- Checkout expires ten minutes after creation; refresh/retry/provider switching never extends it.
- At most three sequential attempts and exactly one current attempt per order.
- At most one succeeded payment is accepted; every other succeeded charge is fully reversed.
- Provider calls do not run while database aggregate locks are held.
- Browser redirects never prove payment state; verified provider events do.
- Complex endpoints call exactly one `Core::BaseService` command.

## File map

### Database and models

- Create `db/migrate/20260811090001_create_orders.rb`
- Create `db/migrate/20260811090002_create_order_items.rb`
- Create `db/migrate/20260811090003_create_order_adjustments.rb`
- Create `db/migrate/20260811090004_create_promotion_redemptions.rb`
- Create `db/migrate/20260811090009_create_payments.rb`
- Create `db/migrate/20260811090010_create_payment_events.rb`
- Create models under `app/models/orders/`: `order.rb`, `order_item.rb`, `order_adjustment.rb`, `promotion_redemption.rb`, `payment.rb`, `payment_event.rb`

### Commands and values

- Create `app/services/orders/quote.rb`
- Create `app/services/orders/largest_remainder_allocator.rb`
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
- Modify `config/routes.rb` with root routes mapped to domain controllers; URL versioning remains deferred by the master roadmap

### Tests

- Create fixtures under `test/fixtures/orders/`
- Create model tests under `test/models/orders/`
- Create service tests under `test/services/orders/` and `test/services/payments/providers/`
- Create controller tests under `test/controllers/orders/`
- Create job tests under `test/jobs/orders/`
- Create concurrency tests under `test/integration/orders/`

## Task 1: Add deterministic order-quote and allocation primitives before the Commercial reservation handoff

**Files:**
- Create: `app/services/orders/quote.rb`
- Create: `app/services/orders/largest_remainder_allocator.rb`
- Test: `test/services/orders/quote_test.rb`
- Test: `test/services/orders/largest_remainder_allocator_test.rb`

- [x] **Step 1: RED — write immutable Commercial-evidence and allocation tests**

```ruby
# frozen_string_literal: true

require "test_helper"

class Orders::QuoteTest < ActiveSupport::TestCase
  test "preserves exact immutable commercial results without recalculating them" do
    commercial_result = Commercial::Resolution::ChargeResult.new(
      currency: "ETB",
      quoted_at: Time.current,
      component_results: [],
      buyer_fee_total: 250,
      organizer_fee_total: 0,
      subsidy_total: 0
    )

    quote = Orders::Quote.new(commercial_results: [ commercial_result ], expires_at: 10.minutes.from_now)

    assert_same commercial_result, quote.commercial_results.first
    assert quote.commercial_results.frozen?
  end
end
```

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/quote_test.rb test/services/orders/largest_remainder_allocator_test.rb
```

Expected: FAIL because the Orders quote/allocation values do not exist. Commercial calculation already passes its own phase gate. Verified after granting the test process access to the local PostgreSQL socket: 4 tests, 1 failure, 3 errors, all caused by the missing constants.

- [x] **Step 3: GREEN — implement narrow immutable Orders results and deterministic allocation**

```ruby
# frozen_string_literal: true

module Orders
  Quote = Data.define(:commercial_results, :expires_at) do
    def initialize(commercial_results:, expires_at:)
      super(commercial_results: commercial_results.to_a.freeze, expires_at:)
      freeze
    end
  end
end
```

Implement largest-remainder allocation with rational shares, floor, then remaining units by descending remainder and ascending stable ID. `Orders::Quote` carries the immutable Commercial/expiry evidence without duplicating currency or fee calculation; Task 3's `Orders::BuildQuote` composes the `Core::Money`, product, and FX evidence around it.

For this task, `LargestRemainderAllocator.call(total_minor:, allocations:)`
accepts hashes with `id` and `allocation_basis_points`, requires a complete
10,000-basis-point share set, and returns frozen `Allocation` values sorted by
stable ID. Task 3's `Orders::BuildQuote` will compose product, FX, and
`Core::Money` evidence around this immutable Commercial/expiry envelope; Task 1
does not duplicate that checkout-specific assembly.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 1 command. Expected: PASS. Verified: 4 tests, 17 assertions,
0 failures, 0 errors with `N_PLUS_ONE=1`.

- [x] **Step 5: Refactor and verify**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders
```

Expected: PASS with no float calculations. Verified: 4 tests, 17 assertions,
0 failures, 0 errors with `N_PLUS_ONE=1`; RuboCop reported no offenses in the
4 changed Ruby files.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders test/services/orders
git commit -m "feat(orders): add deterministic pricing primitives"
```

## Task 2: Create immutable order schema for the Commercial reservation handoff

**Files:**
- Create: order/item/adjustment/promotion migrations and models from the file map
- Test: `test/models/orders/order_test.rb`
- Test: `test/models/orders/order_adjustment_test.rb`

- [x] **Step 1: RED — write model and direct PostgreSQL constraint tests**

Prove total reconciliation, nonnegative caches, item/event ownership, adjustment/order ownership, Commercial `subsidy`/`resale_platform_fee` types, allowlisted statuses/refund policies/calculation types/bases/funding sources, exact immutable component/version evidence, paired source fields, currency consistency, immutable snapshots, and STI-disabled `type` behavior.

- [x] **Step 2: Run tests and verify RED**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders
```

Expected: FAIL because the tables/models do not exist. Verified before implementation:
16 tests, 0 assertions, 0 failures, and 16 errors with `N_PLUS_ONE=1`.

- [x] **Step 3: GREEN — create exact schema and indexes**

```ruby
add_index :orders_orders, %i[buyer_user_id event_id], unique: true,
  where: "status IN ('draft', 'pending_payment')",
  name: "idx_one_active_checkout_per_buyer_event"
add_index :orders_orders, :replaces_order_id, unique: true,
  where: "replaces_order_id IS NOT NULL"
add_check_constraint :orders_orders,
  "total_minor = subtotal_minor - discount_minor - subsidy_minor + fee_minor + tax_minor + adjustment_minor",
  name: "orders_total_reconciles"
add_check_constraint :orders_order_items, "quantity > 0", name: "order_item_quantity_positive"
add_check_constraint :orders_order_adjustments,
  "(source_type IS NULL) = (source_id IS NULL)", name: "order_adjustment_source_pair"
```

Persist the aggregate retry identity in `orders_orders`: store a unique
SHA-256 `idempotency_key_digest` together with the exact
`creation_request_digest`. Both are required lowercase 64-character hex
snapshots so `Orders::CreateCheckout` can distinguish an exact replay from a
same-key request with different checkout intent before it mutates inventory or
Commercial reservations.

Use composite `(id,order_id)` uniqueness and a composite FK for item-scoped adjustments. Add sign/type/refund/currency/fee-bound checks plus `calculation_type`, `basis_type`, `funded_by`, and allowlisted `resolution_evidence`; Commercial sources reference the exact immutable component/version contract, never a mutable schedule identity. Subsidies are explicit negative platform-funded offsets. `Orders::OrderAdjustment` sets `self.inheritance_column = nil`. Do not recreate catalog FX or Commercial tables.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 2 command. Expected: PASS. Verified: 16 tests, 108 assertions,
0 failures, and 0 errors with `N_PLUS_ONE=1`.

- [x] **Step 5: Refactor and verify schema**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders
```

Expected: PASS and named constraints appear in schema. Verified migrations on
development and test databases, loaded the tracked `db/structure.sql` into a
disposable PostgreSQL database, ran Zeitwerk, and ran full RuboCop with no
offenses.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260811090001_create_orders.rb \
  db/migrate/20260811090002_create_order_items.rb \
  db/migrate/20260811090003_create_order_adjustments.rb \
  db/migrate/20260811090004_create_promotion_redemptions.rb \
  db/structure.sql app/models/orders test/models/orders
git commit -m "feat(orders): add immutable order aggregate"
```

## Task 3: Build quote and atomic checkout creation after Commercial Tasks 7B and 8

**Files:**
- Create: `app/services/orders/build_quote.rb`
- Create: `app/services/orders/create_checkout.rb`
- Test: `test/services/orders/build_quote_test.rb`
- Test: `test/services/orders/create_checkout_test.rb`
- Test: `test/integration/orders/concurrent_checkout_test.rb`

- [ ] **Step 1: RED — test multi-currency snapshots and last-unit concurrency**

Cover fixed price override, Phase 2 automatic FX conversion, expired quote, unsupported currency, immutable order/item FX evidence, Commercial event/organization/program/default component inheritance, allowed payer selection, explicit zero versus failure, exact Commercial source snapshots, shared ten-minute inventory/promotion/subsidy holds, package versus admission capacity, promotion reservation, zero-total fulfillment, and two buyers racing for the last inventory or subsidy-budget unit.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/build_quote_test.rb test/services/orders/create_checkout_test.rb test/integration/orders/concurrent_checkout_test.rb
```

Expected: FAIL because commands do not exist.

- [ ] **Step 3: GREEN — implement one locked transaction**

`Orders::CreateCheckout < Core::BaseService` validates quote/provider-compatible currency, locks inventories then physical dates and Commercial subsidy budgets by the shared deterministic order, calls `Commercial::ResolveCharges`, creates order/items/exact commercial adjustments, reserves package stock, attendee capacity, promotion, and subsidy funding, reconciles buyer totals plus organizer settlement evidence, and calls `Core::Outbox::Publish` for durable effects. Return `success(order)`. Expected failures use:

```ruby
failure Core::BusinessError.new(
  "Inventory is no longer available",
  code: "inventory_unavailable",
  status: :conflict,
  errors: { quantity: ["exceeds current availability"] }
)
```

Use the same typed contract for stale quote, unsupported currency, promotion unavailable, active checkout, missing/ambiguous commercial configuration, forbidden payer selection, and exhausted subsidy funding. Do not rescue broken database invariants and never convert commercial resolution failure into zero fees.

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
- Create: `app/controllers/orders/application_controller.rb`
- Create: `app/controllers/orders/order_quotes_controller.rb`
- Create: `app/controllers/orders/orders_controller.rb`
- Create: `app/policies/orders/order_policy.rb`
- Create: buyer-safe serializers under `app/serializers/orders/`
- Create: `app/services/orders/quote_token.rb`
- Create: `app/services/orders/restart_checkout.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/orders/orders_controller_test.rb`
- Test: `test/controllers/orders/order_quotes_controller_test.rb`
- Test: `test/services/orders/restart_checkout_test.rb`
- Test: `test/integration/orders/concurrent_restart_test.rb`

- [x] **Step 1: RED — test Pundit, privacy, idempotency, and restart races**

Assert buyer/event authority; serializer hides inventory counters, provider internals, promo digests, organizer adjustments, and payment references; one active checkout; at most two replacements per buyer/event/hour; concurrent restarts yield one replacement; and failed revalidation leaves old checkout intact. Because Task 5 owns the payment table, the restart command uses a capability-gated payment check now and Task 5 must add the concrete active-payment test when `Orders::Payment` exists.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders test/services/orders/restart_checkout_test.rb
```

Expected: FAIL because API/restart command is absent. Verified before implementation with the focused RED suite: 12 tests, 16 assertions, and 12 failures/errors.

- [x] **Step 3: GREEN — implement buyer-bound quote API and advisory-locked restart**

```ruby
# frozen_string_literal: true

module Orders
  class OrdersController < Orders::ApplicationController
    def create
      event = Events::Event.find(params.require(:event_id))
      authorize Order.new(event:, buyer_user: current_user), :create?
      quote = QuoteToken.decode(
        token: order_params.fetch(:quote_token), event:, buyer: current_user
      )
      return render_service_result(quote) if quote.failure?

      result = CreateCheckout.call(
        buyer: current_user,
        event:,
        quote: quote.value,
        idempotency_key: request.headers.fetch("Idempotency-Key")
      )
      render_service_result(result, success_status: :created,
        serializer_options: { serializer: OrderSerializer })
    end

    private

    def order_params = params.require(:order).permit(:quote_token)
  end
end
```

The quote endpoint builds the server-owned quote once and returns an encrypted, buyer/event-bound `quote_token`; there is no quote table or shared cache in this pre-launch design, so the token carries the exact immutable Commercial/FX evidence into checkout. Quote and order serializers expose buyer-safe totals and snapshots only. Routes remain at the root and map to `Orders::` controllers; URL versioning is deferred by the master roadmap. Restart takes `pg_advisory_xact_lock(buyer_user_id,event_id)`, locks old order/inventory/commercial reservations in the shared order, checks the rolling count, and atomically releases/replaces. Pass every command result to foundation `render_service_result`; the quote controller uses the serializer directly because `Orders::Quote` is an immutable value rather than an Active Record model.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 4 command with `N_PLUS_ONE=1`. Verified in the complete focused Orders suite: 30 tests, 207 assertions, 0 failures, and 0 errors; this includes the concurrent restart race with 10 assertions.

- [x] **Step 5: Refactor and verify surfaces**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders test/services/orders test/integration/orders
```

Expected: PASS with no internal leakage. The remaining active-payment behavior is intentionally completed with the payment association and test in Task 5.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/controllers/orders app/policies/orders app/serializers/orders \
  app/services/orders/create_checkout.rb app/services/orders/quote_token.rb \
  app/services/orders/restart_checkout.rb config/routes.rb \
  config/locales/orders/checkout.en.yml postman/'Digis API_collection.json' \
  docs/superpowers/plans/2026-07-17-orders-payments-implementation.md \
  test/controllers/orders test/services/orders/restart_checkout_test.rb \
  test/integration/orders/concurrent_restart_test.rb
git commit -m "feat(api): expose authorized checkout commands"
```

## Task 5: Create payment attempts and provider contract

**Files:**
- Create: payment/payment-event migrations/models and provider files from the map
- Test: `test/models/orders/payment_test.rb`
- Test: `test/services/payments/providers/adapter_contract_test.rb`

- [x] **Step 1: RED — test database and adapter invariants**

Test attempt 1..3, unique attempt/provider keys/reference, one current attempt, one accepted payment, amount/currency equality, immutable Commercial signature equality, same-signature cross-provider retry, `commercial_requote_required` when the newly resolved Commercial evidence changes any buyer/organizer fee, subsidy, payer, currency, or refund policy, fee triple, grace 3..15 minutes, event dedupe, and canonical success/failure/cancelled/unknown/timeout responses.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders/payment_test.rb test/services/payments/providers/adapter_contract_test.rb
```

Expected: FAIL because payment schema/contract is absent.
Verified before implementation: 13 tests, 10 assertions, 1 failure, and 11
errors with the missing payment/provider constants and the intentionally
provider-sensitive signature expectation.

- [x] **Step 3: GREEN — add partial indexes and canonical adapter result**

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

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 5 command with `N_PLUS_ONE=1`. Verified: 13 tests, 67
assertions, 0 failures, 0 errors, and 0 skips.

- [x] **Step 5: Refactor and verify adapters**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders/payment_test.rb test/services/payments/providers
```

Expected: PASS. The focused provider/model suite and the broader Orders
checkout suite were also run with `N_PLUS_ONE=1`; the latter required
refreshing the stale checked-in structure trigger before it passed.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/structure.sql app/models/orders app/services/payments test/models/orders test/services/payments test/fixtures/orders
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
