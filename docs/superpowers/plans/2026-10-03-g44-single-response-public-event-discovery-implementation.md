# G-44 Single-Response Public Event Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Return event lifecycle and typed ticket availability in one bounded, paginated public event-list response.

**Architecture:** Page public events before computing availability; use one timestamp for event lifecycle, sales windows, prices, and offer states. A shared read-only product-status resolver will apply the same event-date and capacity-pool rules as checkout from preloaded snapshots without taking checkout locks. The obsolete batch endpoint is deleted, and the existing per-product `available` boolean is derived from the same status.

**Tech Stack:** Rails 8, ActiveRecord, Minitest, `Core::Pagination`, Postman collection JSON, RuboCop.

**Status:** Implemented locally; focused verification passes (104 tests / 859 assertions with N+1 detection); frontend integration and deployment remain pending.

---

## File map

- Modify `app/services/catalog/inventory/capacity.rb`: build shared indexed snapshots for product/date inventory and reuse capacity-pool and venue rules without locks.
- Modify `app/services/orders/event_date_eligibility.rb`: build a shared index of eligible date IDs so fixed/choose-one checks do not rescan all dates per candidate.
- Create `app/services/catalog/public/offer_availability.rb`: classify one product's sale/date/capacity state from preloaded data.
- Modify `app/services/catalog/public/product_availability.rb`: batch the offer resolver into a product-ID-to-status map.
- Modify `app/services/catalog/public/event_availability_summary.rb`: bound child fan-out before loading ticket associations, aggregate lifecycle/statuses, and compute minimum ticket price by event.
- Modify `app/controllers/events/public_events_controller.rb`: always page the list, preload the event-card graph, capture one `at`, compute the bounded projection, and return pagination metadata.
- Modify `app/serializers/events/public/event_list_serializer.rb`: expose `event_lifecycle`, `ticket_availability`, and `price_from_minor` from that precomputed map.
- Modify `app/controllers/catalog/public_products_controller.rb` and `app/serializers/catalog/public/event_product_serializer.rb`: preload the same data and derive the existing `available` boolean from the shared product status.
- Remove `GET /public/events/availability`, `app/controllers/catalog/public_event_availability_controller.rb`, `config/locales/catalog/public_availability.en.yml`, and its batch-specific tests.
- Modify `config/routes.rb` to remove the batch route.
- Create `test/services/catalog/inventory/capacity_test.rb`: prove snapshot planning and capacity violation match the existing planner without locks.
- Modify `test/services/catalog/public/product_availability_test.rb`: cover structured statuses, date selection, capacities, and sales windows.
- Modify `test/services/catalog/public/event_availability_summary_test.rb`: replace batch-boolean tests with lifecycle and event-state aggregation tests.
- Modify `test/integration/events/public_events_test.rb`, `test/integration/catalog/public_products_test.rb`, and `test/performance/public_event_catalog_test.rb`: verify one-call response, compatibility of product `available`, pagination, and bounded queries.
- Modify `postman/Digis API_collection.json` and `docs/operations/frontend-backend-gap-tracker-2026-09-08.md` to document the new list contract and local-only status.

## Task 1: Add failing product-state and event-lifecycle tests

**Files:**
- Modify: `test/services/catalog/public/product_availability_test.rb`
- Modify: `test/services/catalog/public/event_availability_summary_test.rb`

- [x] **Step 1: Define the product-state contract in tests**

Update service assertions to expect a status string keyed by product ID:

```ruby
states = Catalog::Public::ProductAvailability.for(
  products: [ product ], events_by_id: { @event.id => @event }, at: @at
)
assert_equal "available", states.fetch(product.id)
```

Add individual cases for `available`, `coming_soon`, `sold_out`, `sales_closed`, `no_eligible_dates`, and `unavailable`. Use public active ticket products, real sales windows, product-access dates, inventory rows, and venue counters. Include a minimum-order case where remaining capacity is less than `min_per_order` and therefore the offer is not available.

- [x] **Step 2: Cover fixed and choose-one date behavior**

For fixed access, assert every required venue/parking date must be `scheduled` and start after the evaluation time. For choose-one access, assert one eligible future date with available capacity is sufficient. Cancelled, postponed, completed, and past dates are not eligible purchase dates.

- [x] **Step 3: Cover event lifecycle and aggregation**

Update the event summary test to call `Catalog::Public::EventAvailabilitySummary.call(events:, at:)` and assert it returns a map keyed by event ID with these fields:

```ruby
{ event_lifecycle: "upcoming", ticket_availability: "available", price_from_minor: 1_000 }
```

Cover `upcoming`, `ongoing`, `ended`, and `unscheduled`, plus event-level states `no_public_tickets`, `no_eligible_dates`, `available`, `unavailable`, `coming_soon`, `sold_out`, and `sales_closed`. Gated-only offers never affect public ticket status. Cover ticket/date fan-out overages returning `unavailable`. Cancelled/completed event records are absent from public discovery.

- [x] **Step 4: Run the service tests to establish the expected contract change**

Run:

```bash
bin/rails test test/services/catalog/public/product_availability_test.rb test/services/catalog/public/event_availability_summary_test.rb
```

Before implementation, the expected contract was the opposite of the baseline: product states must be strings and the summary must consume event-page rows. The final matrix below verifies the implemented contract.

## Task 2: Add a lock-free capacity snapshot path

**Files:**
- Modify: `app/services/catalog/inventory/capacity.rb`
- Modify: `app/services/orders/event_date_eligibility.rb`
- Create: `test/services/catalog/inventory/capacity_test.rb`

- [x] **Step 1: Add a snapshot planner parity test**

Create a line with one product, event-date IDs, package quantity, and admissions per unit. Load its inventory and event-date rows once, then assert the snapshot plan selects the same inventory IDs and yields the same `Capacity.violation` as `Capacity.plan!(line)`. Subscribe to SQL notifications and assert the snapshot evaluator performs no `FOR UPDATE` or advisory-lock query.

- [x] **Step 2: Implement snapshot planning by reusing the existing pool rules**

Add a reusable indexed snapshot interface:

```ruby
snapshot = Catalog::Inventory::Capacity::Snapshot.new(inventory_rows:, event_date_rows:)
def self.plan_from_snapshot!(line:, snapshot:)
  validate_line!(line, event_dates_by_id: snapshot.event_dates_by_id)
  product_id = line.product.id.to_s
  global = snapshot.inventories_by_product_and_date.fetch([ product_id, nil ], []).first
  dated = line.event_date_ids.filter_map do |id|
    snapshot.inventories_by_product_and_date.fetch([ product_id, id ], []).first
  end
  Plan.new(line:, inventory_ids: inventory_ids_for!(line, global, dated))
end
```

Refactor the existing `plan!` to continue querying normally and delegate the final pool selection to the same internal method. Preserve all existing lock acquisition in `CheckAvailability` and `Reserve`; the new GET projection must only read the preloaded snapshot.

- [x] **Step 3: Add preloaded-row support to event-date eligibility**

Extend `Orders::EventDateEligibility` with an indexed snapshot of eligible future date IDs. Discovery passes the snapshot to `error_for`; existing quote/checkout calls retain their DB-backed behavior and the same UUID/error contract.

- [x] **Step 4: Verify checkout and reservation behavior**

Run:

```bash
bin/rails test test/services/catalog/inventory/capacity_test.rb test/services/catalog/inventory/reserve_test.rb test/services/catalog/inventory/lifecycle_test.rb test/services/orders/admission_selections/create_test.rb
```

Expected: snapshot evaluation matches capacity semantics while existing reservation and admission-selection tests retain their locking and write behavior.

## Task 3: Implement structured per-product availability

**Files:**
- Modify: `app/services/catalog/public/product_availability.rb`
- Create: `app/services/catalog/public/offer_availability.rb`
- Modify: `app/controllers/catalog/public_products_controller.rb`
- Modify: `app/serializers/catalog/public/event_product_serializer.rb`
- Modify: `test/services/catalog/public/product_availability_test.rb`
- Modify: `test/integration/catalog/public_products_test.rb`

- [x] **Step 1: Classify sale-window and date states**

Implement `ProductAvailability.for(products:, events_by_id:, at:)` to return `{ product_id => status_string }` by building one indexed date/capacity snapshot per event and calling `OfferAvailability` for each preloaded product. Use `Catalog::Products::SalesWindow` and `Orders::EventDateEligibility`; derive venue/parking dates from preloaded `product_accesses`; fixed tickets require every assigned date and choose-one tickets may use any eligible assigned date. Product-level statuses can classify gated offers, but event-level aggregation counts only active ticket products whose `ticket_type.audience == "public"`.

- [x] **Step 2: Evaluate minimum quantity, inventory mode, and venue capacity**

For each candidate line, set `package_quantity: product.min_per_order` and `admissions_per_unit: product.ticket_type.admissions_per_unit`. Build its capacity plan from preloaded inventory/date rows and apply `Catalog::Inventory::Capacity.violation` with no demand and no locks. Return `unavailable` if required pool configuration cannot be resolved; return `sold_out` only when a valid currently-on-sale line exceeds at least one required capacity pool and no eligible line remains available.

- [x] **Step 3: Preserve the existing product response while sharing the state**

Preload product accesses in `Catalog::PublicProductsController#index`, pass one indexed date/capacity snapshot per event to `ProductAvailability`, and make `EventProductSerializer#available` derive from `availability.fetch(object.id) == "available"`. Do not expose counts, new private fields, or buyer-specific limits.

- [x] **Step 4: Run product endpoint regressions with N+1 detection**

Run:

```bash
N_PLUS_ONE=1 bin/rails test test/services/catalog/public/product_availability_test.rb test/integration/catalog/public_products_test.rb
```

Expected: all new status cases pass, the existing public product `available` boolean remains consistent, and query-loaded associations do not trigger N+1 or strict-loading errors.

## Task 4: Paginate `/public/events` and embed the two status fields

**Files:**
- Modify: `app/controllers/events/public_events_controller.rb`
- Modify: `app/serializers/events/public/event_list_serializer.rb`
- Modify: `app/services/catalog/public/event_availability_summary.rb`
- Modify: `test/services/catalog/public/event_availability_summary_test.rb`
- Modify: `test/integration/events/public_events_test.rb`
- Modify: `test/performance/public_event_catalog_test.rb`

- [x] **Step 1: Add failing single-response and pagination tests**

Assert `GET /public/events` returns at most 25 items by default with pagination metadata, page/per-page requests return stable pages, per-page is capped at 100, and each event item contains `event_lifecycle` and `ticket_availability` without `has_available_tickets`. Cover empty page, page boundaries, deterministic timestamp evaluation, private/cancelled event omission, high product/date fan-out failing closed, and a past-only published event reporting `event_lifecycle: "ended"`.

- [x] **Step 2: Page before preloading and calculating availability**

Include `Core::Pagination` in `Events::PublicEventsController`; order by `published_at: :desc, id: :desc`; calculate `total_count`; apply `limit(per_page).offset(paginate_offset)` even when `page` is omitted; then materialize only that page. Capture one `at = Time.current` and eager-load the event-card graph. The summary first counts active public ticket products, then loads only public-offer rows within the caps (50 per event, 1,000 per page, 100 dates per ticket-bearing event); over-budget or malformed events fail closed as `unavailable`. Gated-only offers do not consume this public calculation budget.

- [x] **Step 3: Aggregate one deterministic status map for the page**

Change `Catalog::Public::EventAvailabilitySummary.call(events:, at:)` to return one hash per event ID with `event_lifecycle`, `ticket_availability`, and `price_from_minor`; aggregate product states with the approved precedence and fail closed when the child-fan-out budget is exceeded. Compute minimum ticket prices as a grouped query so the serializer does not load every event product. Add/read these fields from `EventListSerializer`; price and status calculations share the same `at` snapshot.

- [x] **Step 4: Run list, status, pagination, and performance tests**

Run:

```bash
N_PLUS_ONE=1 bin/rails test test/integration/events/public_events_test.rb test/services/catalog/public/event_availability_summary_test.rb test/performance/public_event_catalog_test.rb
```

Expected: one request produces the full event-card contract; query count remains bounded as public events and ticket products grow; event-list pagination metadata and ordering are stable.

## Task 5: Remove the batch endpoint and update API documentation

**Files:**
- Modify: `config/routes.rb`
- Delete: `app/controllers/catalog/public_event_availability_controller.rb`
- Delete: `config/locales/catalog/public_availability.en.yml`
- Delete: `test/integration/catalog/public_event_availability_test.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

- [x] **Step 1: Remove the obsolete route and batch-specific artifacts**

Remove the static `GET /public/events/availability` route and delete its controller, locale file, and batch-only integration test. Replace the batch service implementation in `Catalog::Public::EventAvailabilitySummary`; do not leave a redirect or unused compatibility code.

- [x] **Step 2: Document the single event-list contract**

Remove `Batch Public Event Availability` from Postman. Update `List Public Events` to show `page`, `per_page`, the pagination object, `event_lifecycle`, and each `ticket_availability` enum value. The example must retain `data` as an array and omit `has_available_tickets` and inventory counts.

- [x] **Step 3: Update G-44 status accurately**

Record backend implementation and local verification only. Leave frontend rendering and live deployment pending; state that the frontend consumes one paginated list and uses the status fields directly.

- [x] **Step 4: Validate the collection and YAML**

Run:

```bash
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "Postman JSON OK"'
```

Expected output: `Postman JSON OK`. No new locale file is required by the single-response contract.

## Task 6: Run focused verification and lint

**Files:** No additional files.

- [x] **Step 1: Run the full focused G-44 matrix**

Run:

```bash
N_PLUS_ONE=1 bin/rails test test/services/catalog/inventory/capacity_test.rb test/services/catalog/inventory/reserve_test.rb test/services/catalog/inventory/lifecycle_test.rb test/services/orders/admission_selections/create_test.rb test/services/catalog/public/product_availability_test.rb test/services/catalog/public/event_availability_summary_test.rb test/integration/catalog/public_products_test.rb test/integration/events/public_events_test.rb test/performance/public_event_catalog_test.rb
```

Expected: all tests pass with no N+1/strict-loading errors; existing checkout remains authoritative and no GET request takes inventory locks or mutates counts.

- [x] **Step 2: Lint changed Ruby files**

Run:

```bash
bundle exec rubocop --cache false app/services/catalog/inventory/capacity.rb app/services/orders/event_date_eligibility.rb app/services/catalog/public/product_availability.rb app/services/catalog/public/event_availability_summary.rb app/controllers/events/public_events_controller.rb app/controllers/catalog/public_products_controller.rb app/serializers/events/public/event_list_serializer.rb app/serializers/catalog/public/event_product_serializer.rb test/services/catalog/inventory/capacity_test.rb test/services/catalog/public/product_availability_test.rb test/services/catalog/public/event_availability_summary_test.rb test/integration/events/public_events_test.rb test/integration/catalog/public_products_test.rb test/performance/public_event_catalog_test.rb
```

Expected: no offenses in changed Ruby files.

- [x] **Step 3: Review final boundaries**

Run:

```bash
git diff --check
```

Expected: no whitespace errors, no schema migration, no batch route, no cancelled event records exposed, no exact inventory counts, and no change to checkout/reservation writes.
