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

When using one serialized worktree, Scanner Task 1 is the documented next
task and this plan follows as the independent Wave 5 Task 1. Do not begin
Commercial Task 11 or Controlled Resale from this plan.

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
- Create `db/migrate/20260717100002_create_product_date_allocations.rb`
- Create `db/migrate/20260717100003_create_refunds.rb`
- Create `db/migrate/20260717100004_create_refund_items.rb`
- Create `db/migrate/20260717100005_create_refund_adjustment_allocations.rb`
- Create `db/migrate/20260717100006_create_finance_ledger_entries.rb`
- Create `db/migrate/20260717100007_create_finance_payouts.rb`
- Create `db/migrate/20260717100008_create_finance_payout_allocations.rb`
- Create `db/migrate/20260717100009_create_finance_provider_reserve_policies.rb`
- Create corresponding models under `app/models/events/`, `app/models/catalog/`, `app/models/orders/`, and `app/models/finance/`

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
- Create `app/jobs/finance/provider_reserve_monitor_job.rb`
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

- [ ] **Step 1: RED — write direct database-constraint tests**

Test exact approved fields and states. Direct writes must fail for: nonpositive refund; currency different from payment; cancellation from another event; `pending_funds` without reason; inconsistent provider-fee fields; item refund without reconciling items; payment reversal with items or less than full unaccepted payment; refund item from another order; date without product grant/allocation; over-refunded package/date/item/adjustment; malformed cancellation counters. Add STI regression for `Orders::Refund.type`.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders/refund_test.rb test/models/orders/refund_item_test.rb test/models/orders/refund_adjustment_allocation_test.rb test/models/events/event_cancellation_test.rb test/models/catalog/product_date_allocation_test.rb
```

Expected: FAIL because schema/models are absent.

- [ ] **Step 3: GREEN — implement exact tables and constraints**

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

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 1 command. Expected: PASS.

- [ ] **Step 5: Refactor and inspect schema**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/orders test/models/events/event_cancellation_test.rb test/models/catalog/product_date_allocation_test.rb
```

Expected: migrations and tests PASS; deferred trigger is present.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/orders app/models/events app/models/catalog test/models test/fixtures
git commit -m "feat(refunds): add itemized refund obligations"
```

## Task 2: Implement deterministic item, date, and adjustment allocation

**Files:**
- Create: `app/services/orders/refund_amount.rb`
- Create: `app/services/orders/allocate_refund_adjustments.rb`
- Create: `app/services/orders/allocate_date_value.rb`
- Test: `test/services/orders/allocate_refund_adjustments_test.rb`
- Test: `test/services/orders/allocate_date_value_test.rb`

- [ ] **Step 1: RED — test signed and date-level reconciliation**

Test proportional allocation of order-level refundable adjustments, item-scoped adjustments, negative discount shares, positive fee/tax shares, nonrefundable exclusion, stable largest-remainder tie breaking, unequal multi-day weights, and proof that refunding every date returns exactly the original eligible value.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/allocate_refund_adjustments_test.rb test/services/orders/allocate_date_value_test.rb
```

Expected: FAIL because allocators are absent.

- [ ] **Step 3: GREEN — implement immutable refund values**

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

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 2 command. Expected: PASS.

- [ ] **Step 5: Refactor and run property-style fixture matrix**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/allocate_refund_adjustments_test.rb test/services/orders/allocate_date_value_test.rb --seed 21803
```

Expected: PASS across every currency/date/discount fixture.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders test/services/orders
git commit -m "feat(refunds): allocate refundable value exactly"
```

## Task 3: Create idempotent item refunds and payment reversals

**Files:**
- Create: `app/services/orders/create_item_refund.rb`
- Create: `app/services/orders/create_payment_reversal.rb`
- Test: `test/services/orders/create_item_refund_test.rb`
- Test: `test/services/orders/create_payment_reversal_test.rb`
- Test: `test/integration/orders/concurrent_refund_test.rb`

- [ ] **Step 1: RED — test reason allowlists, cumulative bounds, and races**

Cover all permitted reasons; reject voluntary change-of-mind; lock-protected cumulative quantity/amount; one row per package; date access not already used/refunded; full reversal only for succeeded unaccepted payment; reversal does not change order fulfillment/inventory/promotion/tickets/organizer sale entries; concurrent refund requests cannot exceed original value; repeated idempotency key returns same obligation.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/create_item_refund_test.rb test/services/orders/create_payment_reversal_test.rb test/integration/orders/concurrent_refund_test.rb
```

Expected: FAIL because commands are absent.

- [ ] **Step 3: GREEN — implement deterministic transaction lock order**

`Orders::CreateItemRefund < Core::BaseService` locks payment → order items by UUID → package tickets by UUID → event dates by UUID → prior refunds/items. It returns `success(existing_refund)` for an idempotent replay, then rechecks eligibility, builds item and adjustment-allocation rows, verifies exact reconciliation, and calls `Core::Outbox::Publish` for the submit-refund effect. Expected rejection returns `failure Core::BusinessError.new(message, code:, status:, errors:)`. `Orders::CreatePaymentReversal` locks payment and prior refunds, requires `succeeded` with null `accepted_at`, and creates exactly one full refund without item rows using a deterministic key `payment-reversal:<payment-id>`.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 3 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify race suite repeatedly**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/orders/concurrent_refund_test.rb --seed 77391
```

Expected: PASS with no cumulative over-refund.

- [ ] **Step 6: Commit**

```bash
git add app/services/orders test/services/orders test/integration/orders
git commit -m "feat(refunds): create bounded refund obligations"
```

## Task 4: Submit, retry, and reconcile provider refunds

**Files:**
- Create: submit/apply/reconcile commands and jobs from the file map
- Extend: payment provider adapter contract from the orders/payments plan
- Test: `test/services/orders/submit_refund_test.rb`
- Test: `test/services/orders/apply_refund_result_test.rb`
- Test: `test/jobs/orders/reconcile_refund_job_test.rb`

- [ ] **Step 1: RED — model every provider and liquidity outcome**

Test immediate processing/success/failure; timeout/unknown; provider refund fee reported later; insufficient funds; zero reserve; depleted reserve; missing balance API; top-up signal; duplicate provider request/callback; job crash before call and after response; exact buyer amount never reduced by provider fee.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders/submit_refund_test.rb test/services/orders/apply_refund_result_test.rb test/jobs/orders/reconcile_refund_job_test.rb
```

Expected: FAIL because submission pipeline is absent.

- [ ] **Step 3: GREEN — implement durable submission state machine**

`Orders::SubmitRefund` locks the refund and returns `success(refund)` for terminal or already-processing states. It checks adapter capabilities and reliable balance when available, but treats reserve target only as a discretionary-outflow floor: refunds may consume it. If the complete promised refund plus provider charge cannot be sent, set `pending_funds`, controlled reason, and `next_retry_at`, then return `success(refund)` because the obligation was recorded correctly. Unsupported operations and invalid transitions use `failure Core::BusinessError.new(message, code:, status:, errors:)`. Otherwise persist `processing` and provider idempotency intent, commit, call adapter, and apply normalized response under a new lock. Unknown timeouts remain processing for verification; never resubmit blindly.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 4 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify failure recovery**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/orders test/jobs/orders --seed 44209
```

Expected: PASS; injected crashes converge without double refund.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: RED — test suspend-before-refund and generation replacement**

Cover unused paid organizer cancellation; active suspension while refund created/processing/pending/failed; package-dead only on success; date refund revokes current generation before submission; successful date exclusion preserves other dates; failed refund restores date through a newer generation; group/delegated mode preserved; scan/refund race has one valid outcome; already-used paid package is rejected except audited legal/platform override.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/cancel_paid_package_test.rb test/services/ticketing/apply_date_refund_test.rb test/integration/ticketing/refund_entry_race_test.rb
```

Expected: FAIL until the credential core and commands exist.

- [ ] **Step 3: GREEN — implement versioned access changes**

Package cancellation locks ticket → active generation → slots/uses → active suspension → payment/refunds. It opens/reuses one idempotent suspension and creates the package refund. Refund success marks ticket refunded, calls `Core::Outbox::Publish` for package-dead/index-tombstone effects, and resolves suspension in one transaction. Date-refund processing revokes the generation and creates a replacement excluding that date; failure creates another generation restoring eligibility; no historical QR/PNR is reactivated.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 5 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify QR privacy/freshness**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing test/integration/ticketing
```

Expected: PASS; refund amounts, provider data, and finance state never enter QR/index payloads.

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
- Modify: `config/routes.rb`
- Test: `test/services/events/cancellation/prepare_batch_test.rb`
- Test: `test/jobs/events/process_cancellation_batch_job_test.rb`
- Modify: `test/controllers/events/event_cancellations_controller_test.rb`

- [ ] **Step 1: RED — test authority, immediate shutdown, and resumability**

Test primary owner/admin or platform admin only; collaborator without authority denied; event becomes irreversibly cancelled immediately; sales/registration/admission/streaming stop; affected accepted payments snapshot once; free credentials revoked without financial rows; batch retries reuse refunds; `pending_funds` and failed providers produce `partially_failed`; completion requires every snapshot resolved; attendee serializer excludes internal notes/treasury state.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/cancellation/prepare_batch_test.rb test/jobs/events/process_cancellation_batch_job_test.rb test/controllers/events/event_cancellations_controller_test.rb
```

Expected: FAIL because coordinator is absent.

- [ ] **Step 3: GREEN — implement one-command API and resumable batches**

`POST /api/v1/events/:event_id/cancellation` continues to authorize and call only `Events::Cancellation::Initiate`; do not introduce a competing cancellation command. The `events.cancellation_initiated` outbox handler calls `Events::Cancellation::PrepareBatch`, which locks the existing cancellation, snapshots affected accepted payments once, and enqueues bounded work. Batch workers select unresolved payment work with `FOR UPDATE SKIP LOCKED`, call `Events::Cancellation::ProcessPayment`, and atomically update bounded progress counters. No controller or outbox handler loops over all payments, and a retry never creates a second cancellation snapshot.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 6 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify crash recovery**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events test/jobs/events test/controllers/events/event_cancellations_controller_test.rb --seed 62017
```

Expected: PASS after injected mid-batch crash and retry.

- [ ] **Step 6: Commit**

```bash
git add app/services/events/cancellation app/jobs/events app/controllers/events/event_cancellations_controller.rb app/policies app/serializers config/routes.rb test/services/events/cancellation test/jobs/events test/controllers/events
git commit -m "feat(events): coordinate automatic cancellation refunds"
```

## Task 7: Create append-only organizer ledger

**Files:**
- Create: finance ledger migration/model and posting commands
- Test: `test/models/finance/ledger_entry_test.rb`
- Test: `test/services/finance/post_accepted_sale_test.rb`
- Test: `test/services/finance/post_refund_test.rb`

- [ ] **Step 1: RED — test ownership, signs, currency, immutability, and idempotency**

Test event entry uses primary organization; references share event; amount nonzero and type/sign valid; reversal same currency/opposite amount; unique global idempotency; accepted payment posts sale/organizer adjustments exactly once; unaccepted payment posts none; refund/chargeback append negative entries; normal update/delete forbidden; STI regression for `Finance::LedgerEntry.type`.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/finance/ledger_entry_test.rb test/services/finance/post_accepted_sale_test.rb test/services/finance/post_refund_test.rb
```

Expected: FAIL because ledger is absent.

- [ ] **Step 3: GREEN — create immutable finance seam**

Create `finance_ledger_entries` exactly as section 10.1 specifies. Add globally unique idempotency, organization/currency/availability indexes, type/sign/reference constraints, and `self.inheritance_column = nil`. Posting commands lock their source payment/refund, calculate only from immutable order/adjustment snapshots, use deterministic source keys, and insert rows. Corrections call `Finance::ReverseLedgerEntry`; no command updates historical amount/type/currency.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 7 command. Expected: PASS.

- [ ] **Step 5: Refactor and reconcile sample orders**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/finance test/services/finance
```

Expected: PASS; same-currency sum matches fixture order/refund facts.

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

- [ ] **Step 1: RED — test maturity, negative inclusion, reserve gate, and races**

Cover event completion plus seven-day/default buffer; postponement delays without editing ledger; suspended/postponed/cancelled ineligible; all negatives through cutoff included before positives; same organization/currency; partial allocation; concurrent builders; success consumes and appends payout row; failure/cancellation releases; balance would breach target; target zero; no balance API requires audited treasury approval; provider timeout reconciles rather than blindly retries.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/finance/build_payout_test.rb test/services/finance/dispatch_payout_test.rb test/integration/finance/concurrent_payout_build_test.rb test/services/finance/payout_providers/adapter_contract_test.rb
```

Expected: FAIL because payout domain is absent.

- [ ] **Step 3: GREEN — implement allocation ledger and safe dispatch**

Create exact `finance_payouts`, `finance_payout_allocations`, and `finance_provider_reserve_policies` tables. Enforce unique payout idempotency/provider reference, unique allocation pair, same-currency/organization through command plus composite constraints, positive net payout, and nonnegative unique provider/currency target.

`Finance::BuildPayout` locks organization/currency scope, then eligible ledger rows by ID. It includes all available negatives through cutoff, allocates positives only after live event completion/buffer recheck, and creates reserved allocations. `Finance::DispatchPayout` rechecks every gate plus provider cash/reserve after locking payout and allocations, persists processing intent, commits, invokes provider, and reconciles. Success consumes allocations and appends one negative payout ledger entry; failure/cancellation releases them.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 8 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify repeated concurrency/failure suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/finance test/integration/finance test/jobs/finance --seed 81629
```

Expected: PASS with no duplicate allocation/cash-out.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/finance app/services/finance app/jobs/finance test/models/finance test/services/finance test/integration/finance test/jobs/finance test/fixtures/finance
git commit -m "feat(finance): allocate safe post-event payouts"
```

## Task 9: Add authorized finance and refund API surfaces

**Files:**
- Create: `app/controllers/orders/refunds_controller.rb`, `app/controllers/finance/payouts_controller.rb`, and the corresponding domain policies/serializers
- Modify: `config/routes.rb`
- Test: `test/controllers/orders/refunds_controller_test.rb`
- Test: `test/controllers/finance/payouts_controller_test.rb`
- Test: `test/serializers/orders/refund_serializer_test.rb`

- [ ] **Step 1: RED — test authorization and sensitive-state filtering**

Buyer sees amount, currency, safe reason/status, and dates only. Buyer never sees provider balance, reserve target, organizer balance, provider fees, internal errors, or recovery notes. Organizer sees own same-currency ledger/payout reports but not provider treasury. Only platform finance admin changes reserve policy or approves no-balance-API dispatch. Each mutating endpoint must be proven to call exactly one command.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders/refunds_controller_test.rb test/controllers/finance/payouts_controller_test.rb test/serializers/orders/refund_serializer_test.rb
```

Expected: FAIL because APIs are absent.

- [ ] **Step 3: GREEN — implement thin Pundit/AMS boundaries**

Use endpoints for authorized event cancellation, ticket organizer cancellation, eligible schedule remedy, refund status, organizer balances/payouts, and platform reserve/payout controls. Every mutation follows `authorize → one Core::BaseService command → Core::CommandResponse#render_service_result`. Expected command rejection is always `failure Core::BusinessError.new(message, code:, status:, errors:)`; never introduce a second result or rendering API.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 9 command. Expected: PASS.

- [ ] **Step 5: Refactor and audit public/owner/admin surfaces**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/orders test/controllers/finance test/policies test/serializers
```

Expected: PASS with no cross-surface finance leakage.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/orders app/controllers/finance app/policies app/serializers config/routes.rb test/controllers/orders test/controllers/finance test/policies test/serializers
git commit -m "feat(api): expose safe refund and settlement views"
```

## Task 10: Final phase gate

**Files:**
- Modify only files from Tasks 1–9 when correcting findings

- [ ] **Step 1: RED audit — bind every policy to authoritative evidence**

Map named tests to: no voluntary refund; immutable policy snapshots; package/date/adjustment bounds; payment reversal isolation; `pending_funds`; zero/depleted/unsupported reserve behavior; resumable cancellation; credential revocation/restore; append-only ledger; completion/buffer; negative-first allocation; same-currency payout; reserve dispatch gate; authorization/privacy; concurrency and crash recovery.

- [ ] **Step 2: Run the complete suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: PASS. Any missing evidence or failure is RED.

- [ ] **Step 3: GREEN — correct uncovered requirements without dual writes**

Delete superseded development-only refund/balance/void paths. Retain only the approved immutable obligation, ledger, and payout flows.

- [ ] **Step 4: Run complete suite and verify GREEN**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: zero failures/errors.

- [ ] **Step 5: Refactor and inspect phase invariants**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate:status
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/orders test/integration/finance test/integration/ticketing --seed 99173
```

Expected: migrations up and all race suites PASS.

- [ ] **Step 6: Commit**

```bash
git add app db config test
git commit -m "test(finance): prove refund and settlement invariants"
```

## Completion evidence

This phase is complete only when tests prove exact item/date/adjustment refund reconciliation, bounded concurrent refunds, durable provider recovery, honest `pending_funds`, resumable event cancellation, version-safe ticket access changes, append-only organizer accounting, post-event payout maturity, negative-first same-currency allocation, soft reserve semantics, authorized private APIs, and idempotent failure recovery end to end.
