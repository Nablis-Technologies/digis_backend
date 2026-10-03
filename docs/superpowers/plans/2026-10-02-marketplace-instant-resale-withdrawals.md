# Marketplace Immediate Resale Withdrawals Implementation Plan

**Status:** Implemented locally; focused verification passed. Render/provider payout verification remains pending.

> **For agentic workers:** This plan records the completed local implementation. Do not stage or commit.

**Goal:** Let a seller request payout of resale proceeds as soon as an accepted buyer payment has transferred the ticket, while keeping Chapa's asynchronous state and the signed seller ledger authoritative.

**Architecture:** Marketplace owns immediate resale-ledger eligibility instead of inheriting Finance event maturity. A seller-scoped request builds/reserves one currency payout across the seller's events, writes debit ledger entries back to the source events, records audit and outbox intent in the same transaction, and asynchronously dispatches through the existing Chapa V2 adapter. Chapa status remains pending/processing until reconciliation confirms completion.

**Tech Stack:** Rails 8.1, PostgreSQL, Pundit, ActiveJob/Solid Queue, Core transactional outbox, Minitest, Postman.

---

### Task 1: Reproduce the actual resale payout gap

**Files:**
- Modify: `test/services/marketplace/build_seller_payout_test.rb`
- Create: `test/integration/marketplace/seller_payouts_test.rb`
- Modify: `test/support/marketplace/seller_payout_test_helpers.rb` only if needed for verified Chapa account setup

- [x] Add a test that fulfills a real resale on an event that is not completed, then builds a seller-wide currency payout from the resulting `resale_proceeds` after its `available_at`.
- [x] Assert payout amount is seller proceeds after Marketplace fee and allocations include the signed sale facts.
- [x] Add coverage that positive `cancellation_reversal` facts participate in net availability while negative reversals/chargebacks offset it.
- [x] Replace the test that expects Marketplace payout to wait for event completion plus seven days; retain Finance organizer maturity coverage unchanged.
- [x] Run the focused tests and observe expected failures before changing production code.

### Task 2: Give Marketplace its own immediate ledger eligibility

**Files:**
- Modify: `app/services/marketplace/seller_payout_support.rb`
- Modify: `app/services/marketplace/build_seller_payout.rb`
- Modify: `app/services/marketplace/dispatch_seller_payout.rb`
- Modify: `app/services/marketplace/fulfill_sale.rb`
- Modify: `app/services/marketplace/seller_balance_report.rb`
- Modify: `app/controllers/marketplace/seller_reports_controller.rb`
- Modify: `config/locales/marketplace/resale.en.yml`

- [x] Remove `include Finance::PayoutSupport`; define Marketplace positive-fact eligibility for positive `resale_proceeds`, `cancellation_reversal`, and `adjustment`, gated by `available_at <= at` and not event completion.
- [x] Set new resale ledger rows' `available_at` to fulfillment time; retain existing immutable timestamps and all organizer payout maturity behavior.
- [x] Preserve seller/currency scope, verified account ownership, seller lock, signed negative offsets, reserve behavior, and payout dispatch/reconciliation safety while allowing source facts from multiple events.
- [x] Keep seller balance aggregate by currency and make its available amount exclude facts whose `available_at` is in the future.
- [x] Run Task 1 tests and ensure new real `resale_proceeds` tests pass.

### Task 3: Add the seller-initiated payout command and API

**Files:**
- Create: `app/services/marketplace/seller_payouts/command_support.rb`
- Create: `app/services/marketplace/seller_payouts/request.rb`
- Create: `app/controllers/marketplace/seller_payouts_controller.rb`
- Modify: `app/policies/marketplace/seller_payout_policy.rb`
- Modify: `app/services/core/payout_command_support.rb` only to support generic payout record replay extraction
- Modify: `app/services/marketplace/build_seller_payout.rb` to reject same-key changes to event/amount/account scope
- Modify: `config/initializers/marketplace_outbox_handlers.rb`
- Modify: `config/routes.rb`
- Modify: `config/locales/marketplace/resale.en.yml`
- Test: `test/services/marketplace/seller_payouts/request_test.rb`
- Test: `test/integration/marketplace/seller_payouts_test.rb`

- [x] Add `POST /marketplace/seller/payouts` with required `currency`, optional `amount_minor`, optional verified seller-owned `seller_payout_account_id`, and the standard `Idempotency-Key`.
- [x] Resolve an omitted account ID to the seller's verified Chapa default; reject absent, unverified, or foreign destinations before payout creation.
- [x] Build the payout/reservations, audit the seller request without credentials, and publish `marketplace.seller_payout.requested` in one transaction.
- [x] Register an exact outbox handler that queues `DispatchSellerPayoutJob` with only the payout ID.
- [x] Make same-key/same-payload replay return the same payout and changed-payload replay return `409 idempotency_conflict`.
- [x] Add seller-scoped payout index/show and policy scope; a platform role must not make the seller endpoints list other sellers' payouts.
- [x] Add idempotency, account ownership/default, insufficient balance, currency scope, replay conflict, audit/outbox, visibility, dispatch-unknown, and failure-release tests.
- [x] Run these tests red before production implementation, then green.

### Task 4: Retire the old maturity path and synchronize contracts

**Files:**
- Delete: `app/jobs/marketplace/mature_seller_proceeds_job.rb`
- Delete: `app/jobs/marketplace/build_seller_payout_job.rb`
- Delete: `test/jobs/marketplace/seller_payout_jobs_test.rb` (maturity jobs are retired)
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/superpowers/specs/2026-09-10-marketplace-seller-payout-direct-transfer-design.md` with a supersession notice

- [x] Remove the obsolete maturity fan-out/build path; keep dispatch and reconciliation jobs.
- [x] Add Postman seller payout create/list/show requests; keep the existing seller-wide balance projection aligned with withdrawal.
- [x] State in the prior design that the 2026-10-02 immediate-withdrawal decision supersedes only resale payout timing.
- [x] Run seller payout, fulfillment, reversal, account, policy/controller, and outbox tests with `N_PLUS_ONE=1` where appropriate; run RuboCop on changed Ruby files and `git diff --check`.
- [x] Review final diff; do not stage, commit, reset the database, change Render settings, or perform a provider payout in this implementation.

### Task 5: Multi-event payout accounting hardening and secondary cleanups

**Files:**
- Modify: `app/services/marketplace/apply_seller_payout_result.rb`
- Modify: `test/services/marketplace/build_seller_payout_test.rb`
- Modify: `app/controllers/marketplace/seller_payouts_controller.rb`
- Modify: `test/integration/marketplace/seller_payouts_test.rb`
- Modify: `app/services/marketplace/seller_payouts/request.rb`

- [x] Write regression tests in `test/services/marketplace/build_seller_payout_test.rb`:
  - Assert exact per-event payout debit amounts when events have fees (`-sale.seller_proceeds_minor` on event 1, `-1_000` on event 2).
  - Assert a negative adjustment in Event A and `+5_000` in Event B produce a `4_000` seller-wide payout without debiting Event A.
  - Exercise a real full resale chargeback across events: Event A ends at `-marketplace_fee`, Event B carries the remaining positive balance, and the seller-wide payout balances to zero.
  - Assert a partial payout nets Event 1's `+2_000/-500` facts and Event 2's `+4_000` fact: a `4_000` payout debits Event 1 by `-1_500` and Event 2 by `-2_500`.
- [x] Implement deterministic net-capacity debit attribution algorithm in `ApplySellerPayoutResult#create_payout_ledger_entries!`:
  - Compute net allocation per event (`event_net_allocations` using signed allocation amounts).
  - Select only events with positive net capacity (`net > 0`), sorted deterministically by `event_id`.
  - Distribute `payout.amount_minor` across positive-net events capped by their respective net capacity.
  - Create payout ledger entries only for events with positive debits.
- [x] Wire `allowed_order_columns` to `apply_ordering` in `Marketplace::SellerPayoutsController#index` and add integration test coverage.
- [x] Construct the seller-scoped command key directly with `Core::IdempotencyKey` after digesting and validating the client key.
- [x] Run full test suite with `N_PLUS_ONE=1` and `bundle exec rubocop` to ensure zero offenses.

## Verification record

- Full Marketplace suite: 188 tests, 1,273 assertions, 0 failures/errors with `N_PLUS_ONE=1`.
- Focused payout/allocation suite: 14 tests, 117 assertions, 0 failures/errors in `test/services/marketplace/build_seller_payout_test.rb`.
- Seller payout API and request command: 8 tests, 83 assertions, 0 failures/errors with `N_PLUS_ONE=1`.
- RuboCop: 20 changed Ruby files inspected, 0 offenses. `git diff --check` and Postman collection JSON parsing passed.
- Strict event-level attribution verified:
  - Exact fee-netted per-event debits (`-sale.seller_proceeds_minor` and `-1_000`) leave each event at net 0 balance.
  - Negative cross-event adjustment (`-1_000` on Event A, `+5_000` on Event B, payout `4_000`) debits Event B for `-4_000` and creates no payout debit for Event A.
  - A full resale chargeback is exercised through `FreezeChargebackProceeds`; the resulting negative event is not debited and the other event carries the payout debit while the seller-wide balance nets to zero.
  - Multi-event partial payout (`4_000` of `5_500`) debits Event 1 by `-1_500` and Event 2 by `-2_500`, leaving the expected event balances.
- `Core::IdempotencyKeyResolver` is unchanged; the existing shared resolver still requires the `Idempotency-Key` header, and the API test verifies a missing key returns 400.
- Render deployment and a Chapa payout have not been performed; live payout verification remains pending.
