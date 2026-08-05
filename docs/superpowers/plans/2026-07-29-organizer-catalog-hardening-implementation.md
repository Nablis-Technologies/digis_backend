# Organizer Catalog Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the organizer product-creation and inventory-reservation implementation safe through the real HTTP boundary, correctly authorized, idempotent under retries/concurrency, and accurate for event-wide, per-date, unlimited, and multi-day venue capacity.

**Architecture:** Product lifecycle commands normalize and fingerprint their inputs at one service boundary, use event-scoped idempotency, and write atomic audits. Inventory commands serialize each reservation group with a PostgreSQL advisory lock, acquire product-inventory and event-date locks in one deterministic order, and use separate date-level reservation rows so venue accounting is independent of the selected product inventory mode.

**Tech Stack:** Rails 8.1, Ruby, PostgreSQL, Pundit, ActiveModel Serializers, Minitest.

**Implementation status (2026-07-29):** Tasks 1–5 are implemented. Task 6 static verification is complete; the final database-backed inventory GREEN/full-suite run is pending because the workspace exhausted execution credits after the RED run.

---

### Task 1: Lock the organizer HTTP and authorization contracts

**Files:**
- Create: `test/integration/catalog/event_products_test.rb`
- Modify: `app/controllers/catalog/event_products_controller.rb`
- Modify: `app/services/catalog/products/create_draft.rb`
- Modify: `app/services/catalog/products/update_inventory_configuration.rb`
- Modify: `app/services/events/authorization_resolver.rb`
- Modify: `app/policies/catalog/event_product_policy.rb`
- Modify: `app/policies/catalog/product_price_policy.rb`
- Modify: `app/policies/catalog/product_inventory_policy.rb`

- [ ] Add failing integration tests proving a permitted JSON `inventory_configuration` reaches both create and update commands as a plain symbolized hash.
- [ ] Add failing policy/integration tests proving primary-organization owner/admin/manager and active co-organizer owner/admin/manager can manage catalog data, while staff, scanners, attendees, and public-event readers cannot read raw inventory/price definitions or mutate products.
- [ ] Normalize permitted parameters with `to_h.deep_symbolize_keys` at command boundaries.
- [ ] Add one `Events::AuthorizationResolver.can_manage_catalog?` predicate and matching manageable-event scope; make all three catalog policies use it.
- [ ] Align create/update policy visibility with the controller’s `ticket_type` include and reload lifecycle responses with their eager-load graph.
- [ ] Run the new integration/policy tests and verify zero failures.

### Task 2: Make product lifecycle canonical, idempotent, auditable, and one-way

**Files:**
- Modify: `db/migrate/20260727090020_create_catalog_event_products.rb`
- Modify: `app/models/catalog/event_product.rb`
- Modify: `app/services/catalog/products/create_draft.rb`
- Modify: `app/services/catalog/products/activate.rb`
- Modify: `app/services/catalog/products/deactivate.rb`
- Delete: `app/services/catalog/products/create.rb`
- Modify: affected catalog tests and `db/seeds/dev.rb`

- [ ] Add failing service tests for same-request replay, cross-event key isolation, conflicting-payload rejection, and concurrent replay.
- [ ] Replace the raw key with a normalized SHA-256 digest and canonical request digest, scoped uniquely by event; serialize first creation with `Core::Database::AdvisoryLock`.
- [ ] Add failing lifecycle tests for complete per-date coverage, future sale-start price readiness, idempotent active/retired replays, forbidden draft retirement, and preserved retired history.
- [ ] Enforce `draft -> active -> retired` under row lock; remove destructive retired-product deletion and the legacy `Catalog::Products::Create` bypass.
- [ ] Record product creation, inventory configuration, activation, retirement, and allowed edits through `Core::Audit::Record` in the authoritative transaction.
- [ ] Migrate seeds/tests to `CreateDraft` plus `Activate`; run the targeted lifecycle suite.

### Task 3: Represent date-level venue holds independently

**Files:**
- Create: `db/migrate/*_create_catalog_venue_capacity_reservations.rb`
- Create: `app/models/catalog/venue_capacity_reservation.rb`
- Create: `test/models/catalog/venue_capacity_reservation_test.rb`
- Modify: `app/models/catalog/inventory_reservation.rb`
- Modify: `app/models/events/event_date.rb`
- Modify: inventory fixtures as needed

- [ ] Add failing model/database tests for one row per reservation group/event date, positive people quantity, valid states, expiry metadata, and group request fingerprints.
- [ ] Add a single-table migration for `catalog_venue_capacity_reservations` with UUIDv7 IDs, event-date FK, group/date unique index, status/quantity checks, timestamps, and lookup indexes.
- [ ] Store the normalized reservation request fingerprint on both product-pool and date-level reservation records so a replay can be verified even for unlimited products.
- [ ] Add explicit associations/scopes and run the model tests.

### Task 4: Unify reservation locking and idempotency

**Files:**
- Create: `app/services/catalog/inventory/reservation_group_lock.rb`
- Create: `app/services/catalog/inventory/reservation_request.rb`
- Modify: `app/services/catalog/inventory/reserve.rb`
- Modify: `test/services/catalog/inventory/reserve_test.rb`

- [ ] Add failing tests for event-wide and unlimited venue holds, combined-mode missing-date rejection, same-group replay, mismatched replay rejection, cross-product group rejection, exact multi-pool counters, and concurrent reserve.
- [ ] Canonicalize product, dates, package quantity, admissions, owner, and expiry into one request digest.
- [ ] Acquire a group advisory lock, then product-inventory rows ordered by ID, then event-date rows ordered by ID.
- [ ] Require every requested per-date pool when the mode includes per-date inventory; keep event-wide inventory independent.
- [ ] Create product-pool reservations and one venue-capacity reservation per requested physical date; increment each locked counter exactly once, including unlimited/event-wide products.
- [ ] Run reserve tests and confirm exact counters and replay behavior.

### Task 5: Make commit, release, and expiry whole-group atomic

**Files:**
- Modify: `app/services/catalog/inventory/commit.rb`
- Modify: `app/services/catalog/inventory/release.rb`
- Modify: `app/services/catalog/inventory/expire.rb`
- Modify: `test/services/catalog/inventory/lifecycle_test.rb`
- Modify: `test/services/catalog/inventory/expire_test.rb`

- [ ] Add failing tests for groups containing `processing`, mixed terminal states, already-complete replay, multi-pool/date counters, expiry racing commit, and groups larger than the expiry batch size.
- [ ] Use the same group advisory lock and deterministic inventory-then-date lock order in all commands.
- [ ] Define legal group states: all active (`held`/`processing`) may transition; all target-terminal is idempotent success; every mixed/opposing/expired terminal composition fails without mutation.
- [ ] Recompute decrements only from locked active rows; replace `GREATEST` masking with checked exact arithmetic.
- [ ] Expire complete groups, including `processing`, and return the actual transitioned count.
- [ ] Run lifecycle and expiry tests.

### Task 6: Remove test debt and synchronize external contracts

**Files:**
- Delete: `test/services/catalog/pricing/debug_quote_test.rb`
- Delete: `test/services/catalog/pricing/debug_quote_test2.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: catalog locales and serializers as required

- [ ] Move any useful debug assertion into the canonical quote test and delete both debug files.
- [ ] Update Postman examples for the organizer product envelope, required idempotency header, lifecycle actions, and inventory configuration response.
- [ ] Run `git diff --check`, catalog tests, full `bin/rails test`, `bin/rails zeitwerk:check`, `bundle exec brakeman`, and `bundle exec rubocop`.
- [ ] Reconcile every prior P0/P1/P2 finding against the final diff and record any environment blocker without overstating validation.
