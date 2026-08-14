# Refunds, Cancellation, and Organizer Settlement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build itemized refunds, resumable event cancellation, explicit insufficient-liquidity handling, and an append-only same-currency organizer ledger with safe post-event payouts.

**Architecture:** Refund obligations are immutable database records created before provider submission; provider adapters and Solid Queue jobs converge them to canonical states. Organizer financial truth is an append-only ledger whose payout allocations are locked and reconciled, never a mutable balance counter. Complex API endpoints authorize and call exactly one `Core::BaseService` command; commands own transactions, outbox records, and deterministic locks without callback orchestration.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs/check constraints/partial indexes/deferred constraints, Pundit, ActiveModelSerializers, Solid Queue, Minitest fixtures.

**Approved sources:** `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md` and `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`.

---

## Delivery gate and policy boundary

Begin after the order/payment acceptance pipeline is complete. Ticket/date credential transitions named here begin only after the commercial-package credential core exists; before that gate, refund services may be implemented and tested behind a disabled API boundary. Do not retain legacy voluntary-refund, mutable-balance, or ticket-void shortcuts. Development data may be reset; no backward compatibility or dual writes are required.

### Execution route

For the integrated platform sequence, begin this plan after Orders Tasks 7–9
and Ticket Packages Tasks 2–6 are green. It is a Wave 5 parallel track with
Scanner Tasks 1–8; neither track is a prerequisite for the other. The Finance
evidence produced here is required before Controlled Resale completes and
before Commercial Task 12 runs. Do not start Commercial Task 11 from this plan;
that handoff belongs to the Controlled Resale plan's Marketplace Task 3.

Scanner Tasks 1–8 are now complete on the Rails side; the native client
SQLite acceptance gate remains external because no native scanner client is
present in this repository. Refunds/Finance Tasks 1–10 are implemented and
phase-gate verified in this worktree; user review/commit remains pending.
Task 10 remains independent of the native scanner-client gate. After this
plan is reviewed and committed, the next repository work is Controlled
Resale Tasks 1–2. Commercial Task 11 starts only with Controlled Resale
Task 3, and Commercial Task 12 remains last. Do not begin Commercial Task 11
or Controlled Resale Task 3 from this plan.

- There is no voluntary buyer change-of-mind refund at launch.
- Refunds arise only from cancellation, eligible schedule changes, unaccepted payments, legal remedies, or audited platform administration.
- Buyer entitlement comes from original immutable item/adjustment snapshots, never current rules.
- `pending_funds` is an unresolved payable obligation, never success.
- Refund fees never silently reduce the promised buyer amount.
- A soft provider/currency reserve target may be zero, unavailable, or depleted without changing entitlement.
- Paid package cancellation suspends access first and becomes permanently dead only after successful refund.
- Organizer finance rows are append-only; correction means an opposite linked row.
- Positive organizer funds mature only after event completion plus the platform safety buffer.

## Planned file map

### Database and models

- Create `db/migrate/20260717100001_create_event_cancellations.rb`
- Create `db/migrate/20260813090003_create_events_event_cancellation_payments.rb`
- Create `db/migrate/20260717100002_create_product_date_allocations.rb`
- Create `db/migrate/20260717100003_create_refunds.rb`
- Create `db/migrate/20260717100004_create_refund_items.rb`
- Create `db/migrate/20260717100005_create_refund_adjustment_allocations.rb`
- Create `db/migrate/20260717100006_create_finance_ledger_entries.rb`
- Create `db/migrate/20260717100007_create_finance_payouts.rb`
- Create `db/migrate/20260717100008_create_finance_payout_allocations.rb`
- Create `db/migrate/20260717100009_create_finance_provider_reserve_policies.rb`
- Create corresponding models under `app/models/events/`, `app/models/catalog/`, `app/models/orders/`, and `app/models/finance/`
- Create `app/models/events/event_cancellation_payment.rb`

### Commands, values, and provider boundaries

- Create `app/services/orders/refund_amount.rb`
- Create `app/services/orders/allocate_refund_adjustments.rb`
- Create `app/services/orders/allocate_date_value.rb`
- Create `app/services/orders/create_item_refund.rb`
- Create `app/services/orders/create_payment_reversal.rb`
- Create `app/services/orders/submit_refund.rb`
- Create `app/services/orders/apply_refund_result.rb`
- Create `app/services/orders/reconcile_refund.rb`
- Reuse `app/services/events/cancellation/initiate.rb` and `app/controllers/events/event_cancellations_controller.rb` from the event-foundation plan
- Create `app/services/events/cancellation/prepare_batch.rb`
- Create `app/services/events/cancellation/process_payment.rb`
- Create `app/services/events/cancellation/outbox_handlers/cancellation_initiated.rb`
- Create `app/services/ticketing/cancel_paid_package.rb`
- Create `app/services/ticketing/apply_date_refund.rb`
- Create `app/services/ticketing/restore_failed_date_refund.rb`
- Create `app/services/finance/post_accepted_sale.rb`
- Create `app/services/finance/post_refund.rb`
- Create `app/services/finance/post_chargeback.rb`
- Create `app/services/finance/reverse_ledger_entry.rb`
- Create `app/services/finance/complete_event.rb`
- Create `app/services/finance/build_payout.rb`
- Create `app/services/finance/dispatch_payout.rb`
- Create `app/services/finance/apply_payout_result.rb`
- Create `app/services/finance/update_provider_reserve_policy.rb`
- Create `app/services/finance/payout_providers/adapter.rb`
- Create `app/services/finance/payout_providers/registry.rb`

### Jobs and API

- Create `app/jobs/events/process_cancellation_batch_job.rb`
- Create `app/jobs/orders/submit_refund_job.rb`
- Create `app/jobs/orders/retry_pending_funds_refund_job.rb`
- Create `app/jobs/orders/reconcile_refund_job.rb`
- Create `app/jobs/finance/mature_event_funds_job.rb`
- Create `app/jobs/finance/build_payouts_job.rb`
- Create `app/jobs/finance/dispatch_payout_job.rb`
- Create `app/jobs/finance/reconcile_payout_job.rb`
- Create `app/jobs/finance/provider_reserve_monitor_job.rb` and
  `app/services/finance/monitor_provider_reserves.rb` in Task 10, where
  operational reserve observations and reconciliation transitions are verified
  together
- Create cancellation/refund/finance controllers, Pundit policies, and AMS serializers under their domain paths
- Modify `config/routes.rb`

### Tests

- Add fixtures for every new table
- Add model/constraint, service, controller, serializer, policy, job, adapter-contract, integration, concurrency, and failure-injection tests under matching `test/` paths

## Task 1: Create refund and cancellation schema with executable invariants

**Files:**
- Create: refund/cancellation migrations and models from the file map
- Test: `test/models/orders/refund_test.rb`
- Test: `test/models/orders/refund_item_test.rb`
- Test: `test/models/orders/refund_adjustment_allocation_test.rb`
- Test: `test/models/events/event_cancellation_test.rb`
- Test: `test/models/catalog/product_date_allocation_test.rb`

- [x] **Step 1: RED — write direct database-constraint tests**

Test exact approved fields and states. Direct writes must fail for: nonpositive refund; currency different from payment; cancellation from another event; `pending_funds` without reason; inconsistent provider-fee fields; item refund without reconciling items; payment reversal with items or less than full unaccepted payment; refund item from another order; date without product grant/allocation; over-refunded package/date/item/adjustment; malformed cancellation counters. Add STI regression for `Orders::Refund.type`.

- [x] **Step 2: Run tests and record the initial failure**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders/refund_test.rb test/models/orders/refund_item_test.rb test/models/orders/refund_adjustment_allocation_test.rb test/models/events/event_cancellation_test.rb test/models/catalog/product_date_allocation_test.rb
```

Expected: FAIL because schema/models are absent.

- [x] **Step 3: GREEN — implement exact tables and constraints**

Create `orders_refunds`, `orders_refund_items`, and `orders_refund_adjustment_allocations` exactly as sections 9.7–9.9 specify. Use UUID FKs and these minimum executable constraints/indexes:

```ruby
add_index :orders_refunds, :idempotency_key, unique: true
add_index :orders_refunds, %i[event_cancellation_id status],
  where: "event_cancellation_id IS NOT NULL"
add_index :orders_refunds, %i[status next_retry_at]
add_index :orders_refund_adjustment_allocations,
  %i[refund_item_id order_adjustment_id], unique: true,
  name: "idx_refund_adjustment_once_per_item"
add_check_constraint :orders_refunds, "amount_minor > 0", name: "refund_amount_positive"
add_check_constraint :orders_refunds,
  "status <> 'pending_funds' OR pending_reason IS NOT NULL",
  name: "pending_funds_has_reason"
```

Use composite keys/FKs where practical to enforce order/event ownership. Install a deferred constraint trigger that asserts every `full_or_partial` multi-date product has one unique allocation per granted date and totals exactly 10,000 basis points at commit. `Orders::Refund` declares `self.inheritance_column = nil`.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 1 command. Expected: PASS.

- [x] **Step 5: Refactor and inspect schema**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders test/models/events/event_cancellation_test.rb test/models/catalog/product_date_allocation_test.rb
```

Expected: migrations and tests PASS; deferred trigger is present.

- [ ] **Step 6: Commit (user-owned)**

Codex intentionally does not run this commit. Review the diff, stage the
approved files, and commit the Task 1 tranche before starting Task 2.

```bash
git add db/migrate db/schema.rb app/models/orders app/models/events app/models/catalog test/models test/fixtures
git commit -m "feat(refunds): add itemized refund obligations"
```

## Task 2: Implement deterministic item, date, and adjustment allocation

**Files:**
- Create: `app/services/orders/refund_amount.rb`
- Create: `app/services/orders/allocate_refund_adjustments.rb`
- Create: `app/services/orders/allocate_date_value.rb`
- Extend: `app/services/orders/largest_remainder_allocator.rb`
- Test: `test/services/orders/allocate_refund_adjustments_test.rb`
- Test: `test/services/orders/allocate_date_value_test.rb`
- Extend: `test/services/orders/largest_remainder_allocator_test.rb`

- [x] **Step 1: RED — test signed and date-level reconciliation**

Test proportional allocation of order-level refundable adjustments, item-scoped adjustments, negative discount shares, positive fee/tax shares, nonrefundable exclusion, stable largest-remainder tie breaking, unequal multi-day weights, and proof that refunding every date returns exactly the original eligible value.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/allocate_refund_adjustments_test.rb test/services/orders/allocate_date_value_test.rb
```

Expected: FAIL because allocators are absent.

- [x] **Step 3: GREEN — implement immutable refund values**

```ruby
# frozen_string_literal: true

module Orders
  RefundAmount = Data.define(:subtotal_minor, :adjustment_minor, :amount_minor, :currency) do
    def initialize(subtotal_minor:, adjustment_minor:, amount_minor:, currency:)
      fail ArgumentError, "refund does not reconcile" unless amount_minor == subtotal_minor + adjustment_minor
      fail ArgumentError, "amount must be positive" unless amount_minor.positive?
      super
    end
  end
end
```

The allocators use rational arithmetic and the same stable largest-remainder implementation as checkout. Allocation order is order adjustments → eligible items → date basis points. They never query current fee/promotion/tax policy.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 2 command. Expected: PASS.

- [x] **Step 5: Refactor and run property-style fixture matrix**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/allocate_refund_adjustments_test.rb test/services/orders/allocate_date_value_test.rb --seed 21803
```

Expected: PASS across every currency/date/discount fixture.

- [ ] **Step 6: Commit (user-owned)**

Codex intentionally does not run this commit. Review and stage only the Task 2
files after confirming the existing shared allocator change is approved.

```bash
git add app/services/orders test/services/orders
git commit -m "feat(refunds): allocate refundable value exactly"
```

## Task 3: Create idempotent item refunds and payment reversals

**Files:**
- Create: `app/services/orders/create_item_refund.rb`
- Create: `app/services/orders/create_payment_reversal.rb`
- Modify: `app/services/orders/accept_payment.rb`
- Delete: `app/services/orders/reverse_unaccepted_payment.rb`
- Modify: `config/locales/orders/payments.en.yml`
- Test: `test/services/orders/create_item_refund_test.rb`
- Test: `test/services/orders/create_payment_reversal_test.rb`
- Test: `test/integration/orders/concurrent_refund_test.rb`

- [x] **Step 1: RED — test reason allowlists, cumulative bounds, and races**

Cover all permitted reasons; reject voluntary change-of-mind; lock-protected cumulative quantity/amount; one row per package; date access not already used/refunded; full reversal only for succeeded unaccepted payment; reversal does not change order fulfillment/inventory/promotion/tickets/organizer sale entries; concurrent refund requests cannot exceed original value; repeated idempotency key returns same obligation.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" N_PLUS_ONE=1 bundle exec rails test test/services/orders/create_item_refund_test.rb test/services/orders/create_payment_reversal_test.rb test/integration/orders/concurrent_refund_test.rb
```

Expected: FAIL because commands are absent.

- [x] **Step 3: GREEN — implement deterministic transaction lock order**

`Orders::CreateItemRefund < Core::BaseService` locks payment → order items by UUID → package tickets by UUID → event dates by UUID → prior refunds/items. It returns `success(existing_refund)` for an idempotent replay, then rechecks eligibility, builds item and adjustment-allocation rows, verifies exact reconciliation, and calls `Core::Outbox::Publish` for the submit-refund effect. Expected rejection returns `failure Core::BusinessError.new(message, code:, status:, errors:)`. `Orders::CreatePaymentReversal` locks payment and prior refunds, requires `succeeded` with null `accepted_at`, and creates exactly one full refund without item rows using a deterministic key `payment-reversal:<payment-id>`.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 3 command with `N_PLUS_ONE=1`. It passes with 20 tests and 126
assertions, including the used-date rejection, exact adjustment reconciliation,
payment-reversal isolation, and idempotent replay cases. The Orders service
regression suite also passes with 75 tests and 473 assertions.

- [x] **Step 5: Refactor and verify race suite repeatedly**

```bash
PATH="$HOME/.asdf/shims:$PATH" N_PLUS_ONE=1 bundle exec rails test test/integration/orders/concurrent_refund_test.rb --seed 77391
```

Expected: PASS with no cumulative over-refund. The race test passed twice with
seed `77391`; the changed service files pass RuboCop with no offenses.

- [ ] **Step 6: Commit (user-owned)**

Codex intentionally does not run this commit. Review and stage only the Task
3 files, including the replacement of the superseded reversal command, before
starting Task 4.

```bash
git add app/services/orders test/services/orders test/integration/orders
git commit -m "feat(refunds): create bounded refund obligations"
```

## Task 4: Submit, retry, and reconcile provider refunds

**Files:**
- Create: `app/services/orders/submit_refund.rb`,
  `app/services/orders/apply_refund_result.rb`, and
  `app/services/orders/reconcile_refund.rb`
- Create: `app/jobs/orders/submit_refund_job.rb`,
  `app/jobs/orders/reconcile_refund_job.rb`, and
  `app/jobs/orders/retry_pending_funds_refund_job.rb`
- Extend: payment provider adapter contract with normalized refund capabilities
- Modify: `config/initializers/orders_outbox_handlers.rb` and
  `config/locales/orders/payments.en.yml`
- Delete: `app/jobs/orders/reconcile_payment_job.rb` and its superseded test
- Test: `test/services/orders/submit_refund_test.rb`
- Test: `test/services/orders/apply_refund_result_test.rb`
- Test: `test/jobs/orders/reconcile_refund_job_test.rb`
- Extend: `test/services/payments/providers/adapter_contract_test.rb`

- [x] **Step 1: RED — model every provider and liquidity outcome**

Test immediate processing/success/failure; timeout/unknown; provider refund fee reported later; insufficient funds; zero reserve; depleted reserve; missing balance API; top-up signal; duplicate provider request/callback; job crash before call and after response; exact buyer amount never reduced by provider fee.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" N_PLUS_ONE=1 bundle exec rails test test/services/orders/submit_refund_test.rb test/services/orders/apply_refund_result_test.rb test/jobs/orders/reconcile_refund_job_test.rb
```

Expected: FAIL because submission pipeline is absent.

- [x] **Step 3: GREEN — implement durable submission state machine**

`Orders::SubmitRefund` locks the refund and returns `success(refund)` for terminal or already-processing states. It checks adapter capabilities and reliable balance when available, but treats reserve target only as a discretionary-outflow floor: refunds may consume it. If the complete promised refund plus provider charge cannot be sent, set `pending_funds`, controlled reason, and `next_retry_at`, then return `success(refund)` because the obligation was recorded correctly. Unsupported operations and invalid transitions use `failure Core::BusinessError.new(message, code:, status:, errors:)`. Otherwise persist `processing` and provider idempotency intent, commit, call adapter, and apply normalized response under a new lock. Unknown timeouts remain processing for verification; never resubmit blindly.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 4 command with `N_PLUS_ONE=1`. It passes with 20 tests and 143
assertions, covering provider success/failure/unknown/timeout, late provider
fees, balance/reserve behavior, unsupported refunds, duplicate callbacks, and
worker crash recovery. The provider contract extension passes with 5 tests and
27 assertions.

- [x] **Step 5: Refactor and verify failure recovery**

```bash
PATH="$HOME/.asdf/shims:$PATH" N_PLUS_ONE=1 bundle exec rails test test/services/orders test/jobs/orders --seed 44209
```

Expected: PASS; injected crashes converge without double refund. Verified with
96 tests and 617 assertions, zero failures/errors. Changed Task 4 Ruby files
also pass RuboCop with no offenses.

- [ ] **Step 6: Commit (user-owned)**

Codex intentionally does not run this commit. Review and stage only the Task 4
files, including deletion of the superseded payment-only reconciliation job,
before starting Task 5.

```bash
git add app/services/orders app/jobs/orders app/services/payments/providers test/services/orders test/jobs/orders
git commit -m "feat(refunds): reconcile provider refunds safely"
```

## Task 5: Implement package/date credential effects

**Files:**
- Create: ticketing commands from the file map
- Test: `test/services/ticketing/cancel_paid_package_test.rb`
- Test: `test/services/ticketing/apply_date_refund_test.rb`
- Test: `test/integration/ticketing/refund_entry_race_test.rb`

- [x] **Step 1: RED — test suspend-before-refund and generation replacement**

Cover unused paid organizer cancellation; active suspension while refund created/processing/pending/failed; package-dead only on success; date refund revokes current generation before submission; successful date exclusion preserves other dates; failed refund restores date through a newer generation; group/delegated mode preserved; scan/refund race has one valid outcome; already-used paid package is rejected except audited legal/platform override.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/cancel_paid_package_test.rb test/services/ticketing/apply_date_refund_test.rb test/integration/ticketing/refund_entry_race_test.rb
```

Expected: FAIL until the credential core and commands exist.

- [x] **Step 3: GREEN — implement versioned access changes**

Package cancellation locks ticket → active generation → slots/uses → active suspension → payment/refunds. It opens/reuses one idempotent suspension and creates the package refund. Refund success marks ticket refunded, calls `Core::Outbox::Publish` for package-dead/index-tombstone effects, and resolves suspension in one transaction. Date-refund processing revokes the generation and creates a replacement excluding that date; failure creates another generation restoring eligibility; no historical QR/PNR is reactivated.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 5 command. Expected: PASS.

- [x] **Step 5: Refactor and verify QR privacy/freshness**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing test/integration/ticketing
```

Expected: PASS; refund amounts, provider data, and finance state never enter QR/index payloads.

Verification evidence (2026-08-13): focused Task 5 tests pass with
`N_PLUS_ONE=1` (11 tests, 97 assertions); the suite covers package suspension
through failure, successful package finalization, used-package override audit,
group/delegated date exclusion, failed-date restoration through a newer
generation, idempotent replacement, and the scan/refund race. RuboCop passes
for all changed Task 5 Ruby files. The test database was recreated from the
current schema and the structure dump was synchronized with the immutable
generation exclusion column and organizer-cancellation suspension reason.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing test/services/ticketing test/integration/ticketing
git commit -m "feat(ticketing): apply refund credential transitions"
```

## Task 6: Build resumable event cancellation coordinator

**Files:**
- Reuse: `app/services/events/cancellation/initiate.rb`, `app/controllers/events/event_cancellations_controller.rb`, and the event cancellation model/policy/serializer from the event-foundation plan
- Create: `app/services/events/cancellation/prepare_batch.rb`
- Create: `app/services/events/cancellation/process_payment.rb`
- Create: `app/services/events/cancellation/outbox_handlers/cancellation_initiated.rb`
- Create: `app/jobs/events/process_cancellation_batch_job.rb`
- Modify: ticket-package issuance and registration outbox handlers so delayed
  fulfillment cannot issue credentials after cancellation; pass the shared
  attendee-index lock through bounded fulfillment batches.
- Modify: `config/routes.rb`
- Test: `test/services/events/cancellation/prepare_batch_test.rb`
- Test: `test/services/events/cancellation/revoke_free_ticket_test.rb`
- Test: `test/jobs/events/process_cancellation_batch_job_test.rb`
- Modify: `test/integration/events/event_cancellations_test.rb`

- [x] **Step 1: RED — test authority, immediate shutdown, and resumability**

Test primary owner/admin or platform admin only; collaborator without authority denied; event becomes irreversibly cancelled immediately; sales/registration/admission/streaming stop; affected accepted payments snapshot once; free credentials revoked without financial rows; batch retries reuse refunds; `pending_funds` and failed providers produce `partially_failed`; completion requires every snapshot resolved; attendee serializer excludes internal notes/treasury state.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/cancellation/prepare_batch_test.rb test/jobs/events/process_cancellation_batch_job_test.rb test/integration/events/event_cancellations_test.rb
```

Expected: FAIL because coordinator is absent.

- [x] **Step 3: GREEN — implement one-command API and resumable batches**

`POST /events/:event_id/event_cancellations` continues to authorize and call only `Events::Cancellation::Initiate`; do not introduce a competing cancellation command. The `events.cancellation_initiated` outbox handler calls `Events::Cancellation::PrepareBatch`, which locks the existing cancellation, snapshots affected accepted payments once into `events_event_cancellation_payments`, shuts down dates/registrations/streams, revokes free credentials, and enqueues bounded work. Batch workers select unresolved payment work with `FOR UPDATE SKIP LOCKED`, call `Events::Cancellation::ProcessPayment`, and atomically update bounded progress counters. No controller or outbox handler loops over all payments, and a retry never creates a second cancellation snapshot.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 6 command with `N_PLUS_ONE=1`. The expanded cancellation boundary
command passes with 119 tests and 708 assertions, zero failures/errors.
Coverage includes authorization, immediate
shutdown, payment snapshot uniqueness, free-ticket revocation, pending funds,
provider failure, ambiguous-provider reconciliation without resubmission,
registration/admission/checkout rejection, delayed fulfillment suppression,
registration decision/waitlist suppression, and serializer privacy.

- [x] **Step 5: Refactor and verify crash recovery**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events/event_cancellation_payment_test.rb test/services/events/cancellation/prepare_batch_test.rb test/services/events/cancellation/revoke_free_ticket_test.rb test/jobs/events/process_cancellation_batch_job_test.rb test/integration/events/event_cancellations_test.rb test/services/orders/build_quote_test.rb test/services/orders/create_checkout_test.rb test/services/orders/start_payment_attempt_test.rb test/services/orders/process_payment_event_test.rb test/services/ticketing/registrations/submit_test.rb test/services/ticketing/admissions/consume_test.rb test/services/ticketing/packages/issue_test.rb test/services/ticketing/complimentary_issuance/issue_test.rb test/services/ticketing/registration_decisions/approve_test.rb test/services/ticketing/waitlist/offer_next_test.rb --seed 62017
```

Expected: PASS after an injected post-provider worker crash and retry. The worker claims one
snapshot with `FOR UPDATE SKIP LOCKED`, stores a durable processing lease, and
reschedules pending/processing work by `next_retry_at`; retries reuse the same
refund idempotency key. The explicit crash-recovery test leaves the refund and
snapshot processing, then reconciles them without a second provider request.
The targeted Task 6 Ruby files pass RuboCop with no offenses. The PostgreSQL
structure dump contains the cancellation-payment snapshot table, integrity
trigger, indexes, and date-change foreign key. The existing cancellation
endpoint and Postman request remain route-compatible, so no Postman change was
needed for this task; no seed data is required for orchestration rows.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260813090003_create_events_event_cancellation_payments.rb app/models/events/event_cancellation_payment.rb app/services/events/cancellation app/jobs/events/process_cancellation_batch_job.rb test/services/events/cancellation test/jobs/events/process_cancellation_batch_job_test.rb test/models/events/event_cancellation_payment_test.rb test/integration/events/event_cancellations_test.rb
git add -p db/structure.sql app/models/events/event_cancellation.rb app/services/orders/accept_payment.rb app/services/orders/build_quote.rb app/services/orders/create_checkout.rb app/services/orders/start_payment_attempt.rb app/services/ticketing/registrations/submit.rb app/services/ticketing/admissions/consume.rb app/services/ticketing/packages/issue.rb app/services/ticketing/credential_generations/create_initial_group.rb app/services/ticketing/credentials/activate.rb app/services/ticketing/attendee_index app/services/ticketing/registrations/confirm_free.rb app/services/ticketing/complimentary_issuance/issue.rb app/services/ticketing/registration_decisions app/services/ticketing/waitlist app/services/ticketing/outbox_handlers/order_fulfilled.rb app/services/ticketing/outbox_handlers/registration_issuance_ready.rb config/locales/orders/payments.en.yml config/locales/orders/checkout.en.yml config/locales/ticketing/registration_workflows.en.yml config/locales/ticketing/package_issuance.en.yml
git commit -m "feat(events): coordinate automatic cancellation refunds"
```

## Task 7: Create append-only organizer ledger

**Files:**
- Create: finance ledger migration/model and posting commands
- Test: `test/models/finance/ledger_entry_test.rb`
- Test: `test/services/finance/post_accepted_sale_test.rb`
- Test: `test/services/finance/post_refund_test.rb`

- [x] **Step 1: RED — test ownership, signs, currency, immutability, and idempotency**

Test event entry uses primary organization; references share event; amount nonzero and type/sign valid; reversal same currency/opposite amount; unique global idempotency; accepted payment posts sale/organizer adjustments exactly once; unaccepted payment posts none; refund/chargeback append negative entries; normal update/delete forbidden; STI regression for `Finance::LedgerEntry.type`.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/finance/ledger_entry_test.rb test/services/finance/post_accepted_sale_test.rb test/services/finance/post_refund_test.rb
```

The initial run was blocked before assertions by the local PostgreSQL socket and
the stale disposable test schema, so a true absent-ledger RED assertion could
not be captured. The tests were then rerun against a clean test database
rebuilt from the current migrations after synchronizing the existing
branch-level `orders_orders.commercial_signature` and
`orders_payments.succeeded_at` schema drift.

- [x] **Step 3: GREEN — create immutable finance seam**

Create `finance_ledger_entries` exactly as section 10.1 specifies. Add globally unique idempotency, organization/currency/availability indexes, type/sign/reference constraints, and `self.inheritance_column = nil`. Posting commands lock their source payment/refund, calculate only from immutable order/adjustment snapshots, use deterministic source keys, and insert rows. Corrections call `Finance::ReverseLedgerEntry`; no command updates historical amount/type/currency.

- [x] **Step 4: Run tests and verify GREEN**

The focused Task 7 command passes with 14 tests and 76 assertions, zero
failures, and zero errors under `N_PLUS_ONE=1`. The broader
`test/models/finance test/services/finance` command passes with the same
result. Changed Task 7 Ruby files and migration pass RuboCop with no offenses.

- [x] **Step 5: Refactor and reconcile sample orders**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/finance test/services/finance
```

The focused finance suite covers same-currency sale, organizer adjustment,
refund, chargeback, and reversal sums against immutable order facts. No finance
seed data is required because ledger rows are runtime facts, and Task 7 adds no
API route or serializer surface.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/finance app/services/finance test/models/finance test/services/finance test/fixtures/finance
git commit -m "feat(finance): post immutable organizer ledger entries"
```

## Task 8: Build payout allocation and provider reserve policy

**Files:**
- Create: payout/reserve migrations/models, commands, adapters, jobs
- Test: `test/services/finance/build_payout_test.rb`
- Test: `test/services/finance/dispatch_payout_test.rb`
- Test: `test/integration/finance/concurrent_payout_build_test.rb`
- Test: `test/services/finance/payout_providers/adapter_contract_test.rb`

- [x] **Step 1: RED — test maturity, negative inclusion, reserve gate, and races**

Cover event completion plus seven-day/default buffer; postponement delays without editing ledger; suspended/postponed/cancelled ineligible; all negatives through cutoff included before positives; same organization/currency; partial allocation; concurrent builders; success consumes and appends payout row; failure/cancellation releases; balance would breach target; target zero; no balance API requires audited treasury approval; provider timeout reconciles rather than blindly retries.

- [x] **Step 2: Run tests and verify RED**

The initial sandbox run was blocked by PostgreSQL socket permissions. The
escalated RED run reached the expected absent payout-domain constants after
test-only setup was corrected.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/finance/build_payout_test.rb test/services/finance/dispatch_payout_test.rb test/integration/finance/concurrent_payout_build_test.rb test/services/finance/payout_providers/adapter_contract_test.rb
```

Expected: FAIL because payout domain is absent.

- [x] **Step 3: GREEN — implement allocation ledger and safe dispatch**

Create exact `finance_payouts`, `finance_payout_allocations`, and `finance_provider_reserve_policies` tables. Enforce unique payout idempotency/provider reference, unique allocation pair, same-currency/organization through command plus composite constraints, positive net payout, and nonnegative unique provider/currency target.

`Finance::BuildPayout` locks organization/currency scope, then eligible ledger rows by ID. It includes all available negatives through cutoff, allocates positives only after live event completion/buffer recheck, and creates reserved allocations. `Finance::DispatchPayout` rechecks every gate plus provider cash/reserve after locking payout and allocations, persists processing intent, commits, invokes provider, and reconciles. Success consumes allocations and appends one negative payout ledger entry; failure/cancellation releases them.

`Finance::CompleteEvent` is the authoritative locked completion command. It
requires every materialized date to be completed or cancelled, records audit
and outbox evidence, and schedules `Finance::MatureEventFundsJob`, which fans
out deterministic currency-scoped build commands. Reserve-policy changes use
`Finance::UpdateProviderReservePolicy` with finance permission, audit, and
idempotency. Task 10 adds the scheduled provider-reserve monitor. It observes
live balances through the registered adapter and writes deduplicated,
privacy-safe audit observations for reserve breaches, recovery, unavailable
balance APIs, and invalid responses; it never changes refund or payout facts.

- [x] **Step 4: Run tests and verify GREEN**

The focused Task 8 command passes with 16 tests, 127 assertions, zero
failures, and zero errors under `N_PLUS_ONE=1`. Completion, maturity-job, and
reserve-policy tests add 7 tests and 45 assertions.

- [x] **Step 5: Refactor and verify repeated concurrency/failure suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/finance test/integration/finance test/jobs/finance --seed 81629
```

The broader finance model/service/integration suite passes with 30 tests and
203 assertions, zero failures/errors under `N_PLUS_ONE=1`; targeted Task 8
Ruby files pass RuboCop with no offenses. The PostgreSQL structure dump
contains the event completion field, payout tables, foreign keys, checks,
allocation triggers, and ledger immutability trigger.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/finance app/services/finance app/jobs/finance test/models/finance test/services/finance test/integration/finance test/jobs/finance test/fixtures/finance
git commit -m "feat(finance): allocate safe post-event payouts"
```

## Task 9: Add authorized finance and refund API surfaces

**Files:**
- Create: `app/controllers/orders/refunds_controller.rb`, `app/controllers/finance/payouts_controller.rb`, `app/controllers/ticketing/cancellations_controller.rb`, and the corresponding domain policies/serializers
- Create: `app/services/finance/balance_report.rb`, `app/services/finance/approve_payout_without_balance_api.rb`, and the refund API test support helper
- Modify: `app/policies/ticketing/ticket_policy.rb`, `app/services/finance/dispatch_payout.rb`, `config/routes.rb`, `config/locales/finance.en.yml`, `db/seeds.rb`, and `postman/Digis API_collection.json`
- Test: `test/controllers/orders/refunds_controller_test.rb`, `test/controllers/finance/payouts_controller_test.rb`, `test/controllers/ticketing/cancellations_controller_test.rb`, `test/serializers/orders/refund_serializer_test.rb`, and `test/services/finance/approve_payout_without_balance_api_test.rb`

- [x] **Step 1: RED — test authorization and sensitive-state filtering**

Buyer sees amount, currency, safe reason/status, and dates only. Buyer never sees provider balance, reserve target, organizer balance, provider fees, internal errors, or recovery notes. Organizer sees own same-currency ledger/payout reports but not provider treasury. Only platform finance admin changes reserve policy or approves no-balance-API dispatch. Each mutating endpoint must be proven to call exactly one command.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders/refunds_controller_test.rb test/controllers/finance/payouts_controller_test.rb test/serializers/orders/refund_serializer_test.rb
```

Expected: FAIL because APIs are absent.

The initial run was blocked before test discovery by the sandbox PostgreSQL
socket restriction; after the database-backed test environment was available,
the same test targets were used to drive the implementation to GREEN.

- [x] **Step 3: GREEN — implement thin Pundit/AMS boundaries**

Use endpoints for authorized event cancellation, ticket organizer cancellation, eligible schedule remedy, refund status, organizer balances/payouts, and platform reserve/payout controls. Every mutation follows `authorize → one Core::BaseService command → Core::CommandResponse#render_service_result`. Expected command rejection is always `failure Core::BusinessError.new(message, code:, status:, errors:)`; never introduce a second result or rendering API.

- [x] **Step 4: Run tests and verify GREEN**

Run the Task 9 command. Expected: PASS.

- [x] **Step 5: Refactor and audit public/owner/admin surfaces**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders test/controllers/finance test/policies test/serializers
```

Expected: PASS with no cross-surface finance leakage.

Task 9 evidence: the focused `N_PLUS_ONE=1` suite passes with 24 tests and
148 assertions. The broader controller/policy/serializer/service suite passes
with 91 tests and 500 assertions, and the related finance/orders/events
integration suite passes with 10 tests and 32 assertions. Targeted RuboCop
passes for 22 files; routes resolve for every new endpoint; the Postman
collection parses with `jq`; and the API policy profiles keep provider,
treasury, fee, internal-error, recovery, and idempotency fields out of
buyer/organizer responses. Existing event cancellation and schedule-remedy
boundaries are reused rather than duplicated.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/orders app/controllers/finance app/policies app/serializers config/routes.rb test/controllers/orders test/controllers/finance test/policies test/serializers
git commit -m "feat(api): expose safe refund and settlement views"
```

## Task 10: Final phase gate

**Files:**
- Create: `app/services/finance/monitor_provider_reserves.rb`,
  `app/jobs/finance/provider_reserve_monitor_job.rb`, and their focused tests
- Modify: `config/recurring.yml` and files from Tasks 1–9 only when correcting
  evidence-backed findings

- [x] **Step 1: RED audit — bind every policy to authoritative evidence**

The Task 10 audit bound the required policies to authoritative tests:

| Policy | Authoritative evidence |
| --- | --- |
| No voluntary refunds and payment-reversal isolation | `test/services/orders/create_payment_reversal_test.rb`, `test/services/finance/post_refund_test.rb` |
| Immutable item, date, and adjustment snapshots with exact bounds | `test/services/orders/create_item_refund_test.rb`, `test/services/orders/allocate_date_value_test.rb`, `test/services/orders/allocate_refund_adjustments_test.rb`, `test/models/orders/refund_adjustment_allocation_test.rb` |
| Exact reconciliation and bounded concurrent refunds | `test/services/orders/allocate_date_value_test.rb`, `test/integration/orders/concurrent_refund_test.rb` |
| Honest `pending_funds`, zero/depleted/unsupported reserve behavior, and provider recovery | `test/services/orders/submit_refund_test.rb`, `test/jobs/orders/reconcile_refund_job_test.rb`, `test/jobs/events/process_cancellation_batch_job_test.rb` |
| Resumable cancellation and crash-safe recovery | `test/services/events/cancellation/prepare_batch_test.rb`, `test/jobs/events/process_cancellation_batch_job_test.rb`, `test/integration/events/event_cancellations_test.rb` |
| Version-safe credential revocation, restore, and refund races | `test/services/ticketing/cancel_paid_package_test.rb`, `test/services/ticketing/apply_date_refund_test.rb`, `test/integration/ticketing/refund_entry_race_test.rb`, `test/services/ticketing/credential_generations/replace_test.rb` |
| Append-only ledger and opposite-entry corrections | `test/models/finance/ledger_entry_test.rb`, `test/services/finance/post_accepted_sale_test.rb`, `test/services/finance/post_refund_test.rb` |
| Completion, maturity buffer, and payout readiness | `test/services/finance/complete_event_test.rb`, `test/jobs/finance/mature_event_funds_job_test.rb`, `test/services/finance/build_payout_test.rb` |
| Negative-first, same-currency payout allocation | `test/services/finance/build_payout_test.rb`, `test/integration/finance/concurrent_payout_build_test.rb` |
| Reserve dispatch gate | `test/services/finance/dispatch_payout_test.rb`, `test/services/finance/update_provider_reserve_policy_test.rb` |
| Authorization and privacy boundaries | `test/controllers/orders/refunds_controller_test.rb`, `test/controllers/finance/payouts_controller_test.rb`, `test/controllers/ticketing/cancellations_controller_test.rb`, `test/serializers/orders/refund_serializer_test.rb` |
| Concurrency and failure recovery end to end | `test/integration/orders`, `test/integration/finance`, `test/integration/ticketing`, and the cancellation/refund job suites |

- [x] **Step 2: Run the complete suite**

```bash
N_PLUS_ONE=1 PARALLEL_WORKERS=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

The first `N_PLUS_ONE=1` run exposed teardown contamination in the two
non-transactional payment-race tests, hard-coded refund command messages, and
two unrelated query-loading gaps in recurrence deletion and credential-index
projection. Those findings were treated as the RED audit result.

- [x] **Step 3: GREEN — correct uncovered requirements without dual writes**

The race-test teardown now removes only the isolated ledger facts created by
those tests, temporarily disabling and restoring the immutability trigger
inside teardown; production ledger behavior remains append-only. Refund
validation messages now resolve through `config/locales/orders/payments.en.yml`.
Recurrence destruction preloads refund items, and credential replacement
propagates the already-held event/index lock context to its activation seam,
removing the observed N+1 queries without changing the business contract.
The provider-reserve monitor records deduplicated, privacy-safe state
transitions under the existing audit boundary and leaves financial facts
unchanged; its focused job/service suite covers breach, recovery, unavailable
and invalid provider responses, and overlapping workers.
The audit found no additional active mutable-balance, voluntary-refund, or
paid-ticket-void path to delete: the superseded unaccepted-payment service was
already removed, `Finance::BalanceReport` is a derived read-only report, and
free-ticket revocation is the approved no-refund path.

- [x] **Step 4: Run complete suite and verify GREEN**

```bash
N_PLUS_ONE=1 PARALLEL_WORKERS=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

The final `N_PLUS_ONE=1` run passes with 2,470 tests, 9,842 assertions, zero
failures, zero errors, and zero skips.

- [x] **Step 5: Refactor and inspect phase invariants**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate:status
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/orders test/integration/finance test/integration/ticketing --seed 99173
```

`RAILS_ENV=test bundle exec rails db:migrate:status` reports every migration
up. The required `N_PLUS_ONE=1` Orders/Finance/Ticketing integration command
passes with 86 tests, 441 assertions, zero failures, zero errors, and zero
skips. The focused Task 10 regression command passes with 27 tests and 123
assertions, and the reserve-monitor job/service command passes with 5 tests
and 19 assertions; the targeted Ruby files pass syntax checks and RuboCop.

- [ ] **Step 6: Commit**

```bash
git add app db config test
git commit -m "test(finance): prove refund and settlement invariants"
```

## Completion evidence

This phase is complete when tests prove exact item/date/adjustment refund
reconciliation, bounded concurrent refunds, durable provider recovery, honest
`pending_funds`, resumable event cancellation, version-safe ticket access
changes, append-only organizer accounting, post-event payout maturity,
negative-first same-currency allocation, soft reserve semantics, authorized
private APIs, and idempotent failure recovery end to end. The complete suite,
migration status, and required cross-module race suite now provide that
evidence. Step 6 remains unchecked because the user owns review and commit.
