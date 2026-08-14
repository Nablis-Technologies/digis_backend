# Controlled Resale Marketplace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an organizer-controlled marketplace that resells one whole unused commercial package through normal checkout while atomically replacing credentials and safely holding seller proceeds.

**Architecture:** Marketplace commerce is separate from free transfer. Routes remain at the root pre-launch and controllers live under `app/controllers/marketplace/`. Each mutation authorizes and invokes exactly one `Core::BaseService` command. Reservation creates a quantity-one resale order without primary inventory and invalidates seller access before checkout is exposed; accepted payment changes ownership and creates a buyer generation exactly once; `Commercial::ResolveCharges` supplies the distinct resale-platform-fee evidence; seller economics use a separate append-only ledger.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs/check constraints/partial indexes/row locks, Pundit, ActiveModelSerializers, Solid Queue, Minitest fixtures, existing Ed25519 credentials/revocation and transactional outbox.

**Approved sources:** `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`, `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`, and `docs/superpowers/specs/2026-08-08-commercial-agreements-platform-pricing-design.md`.

---

## Hard sequencing gate

Despite the architecture's Phase 3.75 label, executable resale ships **after Phase 4 credential core**. Before routes/jobs activate, tests must prove tickets, slots, generations, credentials, claims, revocations, suspensions, attendee-index deltas, transactional outbox, all-or-nothing delegation, package transfer/acquisition history, uses, orders/payments/reversals, registration/purchase limits, refunds, and organizer finance. Migrations may land earlier behind disabled routes. Replace old paid-transfer/resale shortcuts; do not dual write.

### Commercial handoff

Commercial Task 11 is executed here, not as an isolated Commercial-only
change. Run it together with Marketplace Task 3 after Marketplace Tasks 1–2
and the package/credential, Orders, Refunds/Finance prerequisites are green.
Marketplace Task 3 must consume `Commercial::ResolveCharges` for the distinct
`resale_platform_fee`; it must not create a second resale fee engine. Once the
resale plan and Finance evidence are complete, return to Commercial Task 12
for the final reconciliation and Phase 3.5 gate.

Task 3 is now implemented locally together with Commercial Task 11. The next
implementation task is Task 4 below; listing activation owns the first caller
that snapshots this adapter's immutable result. The commit step remains
unchecked until the user reviews and commits the current worktree.

## Approved AJ invariants

- **AJ-A:** Organizer may allow or disallow resale per ticket type.
- **AJ-A1:** Only the complete, unused commercial package is resold. No slot resale, delegated-package resale, or partially used multi-day-pass resale. Package is group mode with no active delegated claims.
- **AJ-B:** Exactly one cap per ticket type: fixed maximum in event settlement currency **or** percentage of the current seller's immutable acquisition product value. Never compete, stack, prioritize, or use `LEAST`.
- **AJ-C1:** Organizer maximum completed-resale count defaults to one and is bounded by platform hard maximum. Listings/failed checkouts do not increment it.
- **AJ-D1:** A separately versioned Commercial `resale_platform_fee` is deducted from seller proceeds. It never automatically inherits the primary-sale commission; buyer processing adjustment remains separate.
- **AJ-E1:** Seller proceeds remain pending until event completion plus safety buffer. Event/date cancellation refunds each acquisition payer's own value and reverses matching pending proceeds/fee.
- **AJ-F1:** Payout requires a verified tokenized seller destination; never fall back to original payment method.
- **AJ-G1:** New buyer gets a committed purchase-limit allocation while seller historical allocation remains committed.
- **AJ-H1:** Checkout reservation revokes seller generation and suspends access. Success creates buyer group generation; failure/expiry creates newer seller group generation. No old QR/PNR is reactivated.

Every AJ item is a release-blocking named test.

## File map

### Database and models

- Modify the existing `db/migrate/20260727090021_create_ticketing_ticket_types.rb` resale-policy columns/checks; do not create a duplicate migration
- Create `db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb`
- Create `db/migrate/20260814090002_create_marketplace_resale_listings.rb`
- Create `db/migrate/20260814090003_create_marketplace_resale_sales.rb`
- Create `db/migrate/20260814090004_create_marketplace_seller_ledger_entries.rb`
- Create `db/migrate/20260814090005_create_marketplace_seller_payouts.rb`
- Create `db/migrate/20260814090006_create_marketplace_seller_payout_allocations.rb`
- Create models under `app/models/marketplace/`

### Commands/calculations

- Create `app/services/marketplace/calculate_price_cap.rb`
- Create `app/services/marketplace/configure_ticket_type_resale.rb`
- Create `app/services/marketplace/activate_listing.rb`
- Create `app/services/marketplace/cancel_listing.rb`
- Create `app/services/marketplace/reserve_listing.rb`
- Create `app/services/marketplace/expire_reservation.rb`
- Create `app/services/marketplace/fulfill_sale.rb`
- Create `app/services/marketplace/restore_seller_access.rb`
- Create `app/services/marketplace/cancel_acquisition_chain_value.rb`
- Create `app/services/marketplace/freeze_chargeback_proceeds.rb`
- Create `app/services/marketplace/verify_payout_account.rb`
- Create `app/services/marketplace/build_seller_payout.rb`
- Create `app/services/marketplace/dispatch_seller_payout.rb`
- Create `app/services/marketplace/apply_seller_payout_result.rb`
- Create `app/services/marketplace/payout_providers/adapter.rb` and `registry.rb`

### API/jobs/tests

- Create controllers under `app/controllers/marketplace/` and admin payout controls under `app/controllers/admin/marketplace/`; Commercial owns platform-fee administration
- Create policies/serializers under `app/policies/marketplace/`, `app/policies/admin/marketplace/`, and `app/serializers/marketplace/`
- Create jobs under `app/jobs/marketplace/`: expiry, restore credential, mature proceeds, build/dispatch/reconcile payout
- Modify `config/routes.rb` with root paths mapped to domain controllers; URL versioning remains deferred
- Create matching fixtures/model/service/controller/policy/serializer/job tests under domain paths
- Create races under `test/integration/marketplace/` and scanner privacy/freshness under `test/integration/ticketing/`

## Task 1: Add organizer policy and exact cap

**Files:**
- Modify: the existing resale-policy columns/checks in `db/migrate/20260727090021_create_ticketing_ticket_types.rb`
- Modify: `app/models/ticketing/ticket_type.rb`
- Create: `app/services/marketplace/calculate_price_cap.rb`
- Create: `app/services/marketplace/configure_ticket_type_resale.rb`
- Test: `test/models/ticketing/ticket_type_resale_test.rb`
- Test: `test/services/marketplace/calculate_price_cap_test.rb`
- Test: `test/services/marketplace/configure_ticket_type_resale_test.rb`

- [x] **Step 1: RED — encode AJ-A, AJ-B, AJ-C1**

Test disabled shape, enabled exactly-one cap shape, positive fixed/event settlement currency, positive percentage, direct-DB rejection of competing fields, default one, and the platform maximum. Immutable listing snapshots are covered when the listing schema is introduced in Task 2; Task 1 has no listing table to snapshot.

- [x] **Step 2: Run tests and verify RED**

```bash
N_PLUS_ONE=1 PARALLEL_WORKERS=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/ticket_type_resale_test.rb test/services/marketplace/calculate_price_cap_test.rb test/services/marketplace/configure_ticket_type_resale_test.rb
```

Observed RED before implementation: 16 tests, 11 assertions, 6 failures, and 10 errors.

- [x] **Step 3: GREEN — implement mutually exclusive calculator**

`Marketplace::CalculatePriceCap` returns a typed `Core::BaseService::Result`, accepts exactly one fixed or percentage shape, rejects free acquisitions for percentage caps, and uses half-up rounding for integer minor units. All service errors are localized; no user-facing messages are hard-coded. The original ticket-type migration now permits only disabled/no-cap, enabled/fixed-only, or enabled/percentage-only rows. `max_completed_resales` uses PostgreSQL `smallint`, making 32,767 the explicit platform hard maximum because the approved design specifies the type but no lower numeric cap. No fallback or `LEAST` behavior is used.

- [x] **Step 4: Run tests and verify GREEN**

The focused command passed: 17 tests, 64 assertions, 0 failures, and 0 errors after rebuilding the test database from the edited original migration.

- [x] **Step 5: Refactor and verify direct writes**

```bash
N_PLUS_ONE=1 PARALLEL_WORKERS=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/ticket_type_test.rb test/models/catalog/event_product_test.rb test/integration/catalog/event_products_test.rb test/models/ticketing/ticket_type_resale_test.rb test/services/marketplace
```

Passed: 43 tests, 147 assertions, 0 failures, and 0 errors. Direct SQL tests prove the database rejects disabled cap data and a completed-resale limit above the platform maximum. RuboCop passed on all six changed Ruby files.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/structure.sql app/models/ticketing/ticket_type.rb app/services/marketplace test/models/ticketing test/services/marketplace
git commit -m "feat(marketplace): configure controlled resale policy"
```

## Task 2: Create marketplace schema

**Files:**
- Create: marketplace migrations/models from file map
- Test: `test/models/marketplace/resale_listing_test.rb`
- Test: `test/models/marketplace/resale_sale_test.rb`
- Test: `test/models/marketplace/seller_ledger_entry_test.rb`
- Test: `test/models/marketplace/seller_payout_test.rb`

- [x] **Step 1: RED — write direct constraints and STI tests**

Reject two open listings/ticket, mixed cap fields, asking above cap, inconsistent reservation, duplicate sale or `(ticket,resale_number)`, seller=buyer, mismatched payment/order/registration, gross mismatch, zero ledger entry, overallocation, and unverified payout. Prove payout-account and ledger business `type` do not trigger STI. Commercial's phase gate already proves fee scope/version/currency invariants.

- [x] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/marketplace
```

Expected: FAIL.

Observed RED before the Marketplace models existed: 16 tests, 0 assertions,
16 `NameError` errors.

- [x] **Step 3: GREEN — install exact indexes/checks**

```ruby
add_index :marketplace_resale_listings, :ticket_id, unique: true,
  where: "status IN ('active', 'reserved')",
  name: "idx_one_open_resale_listing_per_ticket"
add_index :marketplace_resale_listings, :reserved_order_id, unique: true,
  where: "reserved_order_id IS NOT NULL"
add_index :marketplace_resale_sales, :resale_listing_id, unique: true
add_index :marketplace_resale_sales, %i[ticket_id resale_number], unique: true
add_index :marketplace_resale_sales, :accepted_payment_id, unique: true
add_index :marketplace_seller_ledger_entries, :idempotency_key, unique: true
add_index :marketplace_seller_payout_accounts, %i[provider account_token], unique: true
```

Add state coupling, positive amounts, cap exclusivity, gross=Commercial resale fee+proceeds, and allocation constraints. Ledger rows are append-only. STI disabled on business `type` models. Do not create a Marketplace fee configuration table.

- [x] **Step 4: Run tests and verify GREEN**

Run Task 2 command. Expected: PASS.

Passed after the final lifecycle and ledger-scope hardening: 20 tests, 41
assertions, 0 failures, and 0 errors with `N_PLUS_ONE=1`.

- [x] **Step 5: Refactor and inspect schema**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/marketplace
```

Expected: PASS.

The six migrations apply from a committed-baseline schema in dependency order.
Task 1 plus Marketplace regression coverage passed with 37 tests, 105
assertions, 0 failures, and 0 errors. Full RuboCop passed for 1,325 files.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/structure.sql app/models/marketplace test/models/marketplace test/fixtures/marketplace
git commit -m "feat(marketplace): add resale and seller-ledger schema"
```

## Task 3: Integrate Commercial resale fee resolution

**Files:**
- Create: `app/services/marketplace/resolve_resale_charge.rb`
- Test: `test/services/marketplace/commercial_resale_fee_test.rb`
- Test: `test/integration/marketplace/resale_fee_isolation_test.rb`

- [x] **Step 1: RED — encode AJ-D1**

Resolve the allowlisted `resale_platform_fee` sale context through Commercial event → organization → program → default precedence. Prove no automatic inheritance from primary-sale commission, bounded product/currency/provider/channel specificity, no stacking, immutable exact component/version evidence, seller fee never above gross, and separation from buyer processing adjustment.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/commercial_resale_fee_test.rb test/integration/marketplace/resale_fee_isolation_test.rb
```

Expected: FAIL. Observed before the adapter existed: 5 tests, 0 assertions,
5 `NameError` errors for `Marketplace::ResolveResaleCharge` after the shared
Commercial test helper was installed.

- [x] **Step 3: GREEN — consume one immutable Commercial result**

`Marketplace::ResolveResaleCharge` is a narrow context adapter that calls `Commercial::ResolveCharges` with resale context and trusted listing/order facts, requires exactly one valid `resale_platform_fee`, rejects a result above gross, and returns the unchanged immutable Commercial result for later snapshotting on the resale order/sale. Commercial's admin APIs own authoring, approval, simulation, and activation; Marketplace creates no competing calculator or admin surface.

The adapter forces the trusted resale gross into the allowlisted
`resale_acquisition_amount` basis, propagates Commercial failures unchanged,
and rejects missing/invalid commercial evidence with localized errors. It does
not modify listing or sale persistence; those consumers belong to later
Marketplace tasks.

- [x] **Step 4: Run tests and verify GREEN**

The focused suite passes with `N_PLUS_ONE=1`: 7 tests, 45 assertions, 0
failures, and 0 errors.

- [x] **Step 5: Refactor and verify authorization**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace test/integration/marketplace/resale_fee_isolation_test.rb
```

Marketplace and Commercial regression coverage passes with `N_PLUS_ONE=1`: 162
tests, 1,253 assertions, 0 failures, and 0 errors. Full RuboCop passes for
1,329 files, and `git diff --check` is clean.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace test/services/marketplace test/integration/marketplace
git commit -m "feat(marketplace): consume commercial resale fees"
```

## Task 4: Activate whole-package listings

**Files:**
- Create: `app/services/marketplace/activate_listing.rb`
- Create: `app/services/marketplace/cancel_listing.rb`
- Test: `test/services/marketplace/activate_listing_test.rb`
- Test: `test/integration/marketplace/concurrent_listing_test.rb`

- [ ] **Step 1: RED — encode AJ-A1 and snapshots**

Accept only seller-owned, paid nonzero, group-mode, entirely unused/unstreamed, unrefunded, unsuspended package before cutoff with no transfer/claim and count remaining. Reject free/complimentary, slot, delegated, partially used pass, over-cap, wrong currency, disabled policy. Snapshot acquisition basis, one cap, count/max, cutoff, fee. Concurrent activation gives one listing; disabling policy cancels unsold listings idempotently.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/activate_listing_test.rb test/integration/marketplace/concurrent_listing_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — lock complete eligibility**

Lock ticket → active generation → slots → admission/stream uses → suspension → refunds → transfer/claims. Recheck policy/cutoff, resolve fee, calculate one cap, create listing by idempotency key. Return `success(listing)`; expected rejection uses `failure Core::BusinessError.new(message, code:, status:, errors:)`.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 4 command. Expected: PASS.

- [ ] **Step 5: Refactor and repeat race test**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/marketplace/concurrent_listing_test.rb --seed 71593
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace test/services/marketplace test/integration/marketplace
git commit -m "feat(marketplace): list eligible whole packages"
```

## Task 5: Reserve listing and invalidate seller access

**Files:**
- Create: `app/services/marketplace/reserve_listing.rb`
- Create: `app/jobs/marketplace/expire_reservation_job.rb`
- Test: `test/services/marketplace/reserve_listing_test.rb`
- Test: `test/integration/marketplace/concurrent_purchase_test.rb`
- Test: `test/integration/ticketing/resale_reservation_revocation_test.rb`

- [ ] **Step 1: RED — encode AJ-G1 and reservation half of AJ-H1**

Two buyers race; one reserves. Create buyer registration, quantity-one resale order/item, buyer purchase allocation, no primary inventory, separate buyer processing adjustment. Seller allocation remains committed. Seller generation revoked/index tombstoned/package suspended before serialization. Replay returns same order; precommit failure changes nothing.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/reserve_listing_test.rb test/integration/marketplace/concurrent_purchase_test.rb test/integration/ticketing/resale_reservation_revocation_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — reserve atomically**

Lock listing → ticket/generation/slots → buyer purchase-limit scope → registration/order scope. Recheck all eligibility. In one transaction create buyer registration/requirements/allocation, resale order/item/adjustments, reserve listing, revoke seller generation, suspend package, call `Core::Audit::Record`, and call `Core::Outbox::Publish` for `(tid,v)` revocation/index/payment effects. Expose checkout only after commit. Replay returns `success(existing_order)`.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 5 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify races**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/marketplace test/integration/ticketing/resale_reservation_revocation_test.rb --seed 34811
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace app/jobs/marketplace test/services/marketplace test/integration/marketplace test/integration/ticketing
git commit -m "feat(marketplace): reserve resale checkout safely"
```

## Task 6: Fulfill accepted resale exactly once

**Files:**
- Create: `app/services/marketplace/fulfill_sale.rb`
- Integrate: existing order fulfillment boundary
- Test: `test/services/marketplace/fulfill_sale_test.rb`
- Test: `test/integration/marketplace/concurrent_resale_success_test.rb`

- [ ] **Step 1: RED — test ownership/generation/count/ledger atomicity**

Accepted payment only; exact listing/order/payment; duplicate callbacks produce one sale; buyer allocation committed; ownership/acquisition changed; count once; assignments reset; buyer group generation possibly pending requirements; listing sold; gross and separate fee ledger rows; no primary inventory/organizer ledger; injected failure rolls back all.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/fulfill_sale_test.rb test/integration/marketplace/concurrent_resale_success_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — implement accepted-payment transaction**

Lock listing → order/payment → ticket/generation/slots → policy/count → buyer allocation → seller-ledger keys. Recheck snapshots. Create immutable sale, commit allocation, change owner/acquisition, increment version/count, create buyer group generation, clear suspension, mark sold, post gross/fee, call `Core::Audit::Record` and `Core::Outbox::Publish`. Uniqueness is retry boundary; return `success(existing_sale)` on replay. Expected rejection uses typed `Core::BusinessError` failure.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 6 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify failure injection**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/fulfill_sale_test.rb test/integration/marketplace/concurrent_resale_success_test.rb --seed 90731
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace app/services/orders test/services/marketplace test/integration/marketplace
git commit -m "feat(marketplace): fulfill resale exactly once"
```

## Task 7: Restore seller through a newer generation

**Files:**
- Create: `app/services/marketplace/expire_reservation.rb`
- Create: `app/services/marketplace/restore_seller_access.rb`
- Create: `app/jobs/marketplace/restore_seller_credential_job.rb`
- Test: `test/services/marketplace/expire_reservation_test.rb`
- Test: `test/integration/marketplace/resale_late_payment_test.rb`

- [ ] **Step 1: RED — complete AJ-H1 failure path**

Failure/expiry releases buyer allocation and creates newer seller group generation before listing active; old seller credential stays revoked; disabled/cutoff/count reached expires listing; late success fully reverses without ownership; concurrent expiry/success yields complete sale or restoration, never both.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/expire_reservation_test.rb test/integration/marketplace/resale_late_payment_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — generation replacement only**

Use fulfillment lock order. Create brand-new seller group generation/credential/PNR, clear suspension only afterward, release buyer allocation, and active-or-expire listing based on current policy. Never reactivate an old row.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 7 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify offline limitation**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/marketplace test/integration/ticketing --seed 46121
```

Expected: PASS; stale scanner limitation is explicit, synchronized scanner rejects seller credential, high-risk near-gate flow can require online validation.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace app/jobs/marketplace test/services/marketplace test/integration/marketplace test/integration/ticketing
git commit -m "feat(marketplace): recover resale checkout credentials"
```

## Task 8: Build verified seller payouts

**Files:**
- Create: payout-account/build/dispatch/apply commands, provider adapter, jobs
- Test: `test/services/marketplace/verify_payout_account_test.rb`
- Test: `test/services/marketplace/build_seller_payout_test.rb`
- Test: `test/services/marketplace/dispatch_seller_payout_test.rb`
- Test: `test/integration/marketplace/concurrent_seller_payout_test.rb`

- [ ] **Step 1: RED — encode AJ-E1/AJ-F1**

Raw credentials absent, token/encrypted display only, verified required, proceeds mature after completed+buffer, blocked for postponed/suspended/cancelled/refund/chargeback, negatives before positives, same currency, concurrent builders, ambiguous reconciliation, failure release, success once.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/verify_payout_account_test.rb test/services/marketplace/build_seller_payout_test.rb test/services/marketplace/dispatch_seller_payout_test.rb test/integration/marketplace/concurrent_seller_payout_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — implement tokenized same-currency payout**

Adapter tokenizes/verifies/submits/verifies and returns canonical result. Builder locks seller/account then matured rows by ID, includes negatives, creates reserved allocations. Dispatch persists intent, commits, calls provider, reconciles. Never pay original purchase method.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 8 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify crashes/races**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace test/integration/marketplace test/jobs/marketplace --seed 52967
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace app/jobs/marketplace test/services/marketplace test/integration/marketplace test/jobs/marketplace
git commit -m "feat(marketplace): settle verified seller payouts"
```

## Task 9: Refund acquisition chain and handle chargebacks

**Files:**
- Create: chain cancellation/chargeback commands
- Test: `test/services/marketplace/cancel_acquisition_chain_value_test.rb`
- Test: `test/services/marketplace/freeze_chargeback_proceeds_test.rb`
- Test: `test/integration/marketplace/multi_acquisition_cancellation_test.rb`

- [ ] **Step 1: RED — prove payer-specific refunds and proportional reversals**

Primary → resale1 → resale2 cancellation refunds each payment's payer/value, reverses matching seller gross/fee, does not award reseller profit; current-acquisition chargeback suspends package; older chargeback does not steal current credential.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/marketplace/cancel_acquisition_chain_value_test.rb test/services/marketplace/freeze_chargeback_proceeds_test.rb test/integration/marketplace/multi_acquisition_cancellation_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — traverse immutable acquisitions**

Lock ticket → sales sequence → payments/refunds → seller ledger. Use each item's date allocation/adjustments; create normal idempotent refund per acquisition/date; append proportional ledger reversals. Never edit ownership history.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 9 command. Expected: PASS.

- [ ] **Step 5: Refactor and verify currencies**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/marketplace/multi_acquisition_cancellation_test.rb --seed 68143
```

Expected: PASS; payer refunds original currency, seller reversal stays settlement currency.

- [ ] **Step 6: Commit**

```bash
git add app/services/marketplace test/services/marketplace test/integration/marketplace
git commit -m "feat(marketplace): reverse cancelled resale acquisitions"
```

## Task 10: Expose authorized marketplace APIs without scanner leakage

**Files:**
- Create: controllers/policies/serializers under domain paths
- Modify: `config/routes.rb`
- Test: `test/controllers/marketplace/resale_listings_controller_test.rb`
- Test: `test/controllers/marketplace/resale_purchases_controller_test.rb`
- Test: `test/controllers/marketplace/seller_payout_accounts_controller_test.rb`
- Test: `test/integration/ticketing/marketplace_scanner_privacy_test.rb`

- [ ] **Step 1: RED — test routes, Pundit, one-command boundary, and privacy**

Include root `tickets/:id/resale`, `resale_listings/:id/purchase`, cancellation, seller history/balance/accounts, organizer policy, and admin payout. Commercial's existing admin surface owns resale-platform-fee configuration. Seller sees own economics; buyer sees asking/fees/refund terms; scanner receives no cap/price/acquisition/fee/proceeds/payout/ledger data.

- [ ] **Step 2: Run tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/marketplace test/controllers/admin/marketplace test/integration/ticketing/marketplace_scanner_privacy_test.rb
```

Expected: FAIL.

- [ ] **Step 3: GREEN — implement domain controller namespace**

```ruby
# frozen_string_literal: true

module Marketplace
  class ResalePurchasesController < Core::ApplicationController
    def create
      listing = ResaleListing.find(params.require(:resale_listing_id))
      authorize listing, :purchase?
      result = ReserveListing.call(
        actor: current_user,
        listing:,
        idempotency_key: request.headers.fetch("Idempotency-Key")
      )
      render_service_result(result, success_status: :created,
        serializer_options: { serializer: Orders::OrderSerializer })
    end
  end
end
```

Map root routes to `Marketplace::*Controller` and payout routes to `Admin::Marketplace::*Controller`; URL versioning remains deferred. Every mutation is authorize → one service → foundation renderer.

- [ ] **Step 4: Run tests and verify GREEN**

Run Task 10 command. Expected: PASS.

- [ ] **Step 5: Refactor and audit surfaces**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/marketplace test/controllers/admin/marketplace test/policies/marketplace test/serializers/marketplace test/integration/ticketing/marketplace_scanner_privacy_test.rb
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/marketplace app/controllers/admin/marketplace app/policies/marketplace app/policies/admin/marketplace app/serializers/marketplace config/routes.rb test/controllers/marketplace test/controllers/admin/marketplace test/integration/ticketing
git commit -m "feat(api): expose controlled resale marketplace"
```

## Task 11: Final AJ/failure-recovery gate

**Files:**
- Modify only introduced files when correcting findings

- [ ] **Step 1: RED audit — map AJ-A through AJ-H1 to tests**

Also map two-buyer race, one sale, late reversal, no primary inventory/organizer ledger, scanner privacy/staleness, authorization, and crash rollback. Missing direct evidence is RED.

- [ ] **Step 2: Run full suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: PASS.

- [ ] **Step 3: GREEN — remove obsolete paths**

Delete paid-transfer shortcuts and credential toggles; keep immutable listing/sale/acquisition/ledger plus generation replacement.

- [ ] **Step 4: Run full suite and verify GREEN**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: zero failures/errors.

- [ ] **Step 5: Refactor and stress concurrency**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/marketplace test/integration/ticketing --seed 83617
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate:status
```

Expected: PASS and migrations up.

- [ ] **Step 6: Commit**

```bash
git add app db config test
git commit -m "test(marketplace): prove controlled resale invariants"
```

## Completion evidence

Complete only when credential-core gate and full suite pass, every AJ invariant maps to direct evidence, two buyers cannot reserve/buy the same package, callbacks/retries are idempotent, failed checkout restores only newer seller credential, success creates one sale/new owner generation, both historical seller/new buyer purchase-limit facts remain, proceeds cannot mature early, acquisition-chain cancellation refunds correctly, and no marketplace finance data enters scanner payloads.
