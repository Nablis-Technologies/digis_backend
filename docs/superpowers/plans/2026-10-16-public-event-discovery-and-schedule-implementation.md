# Public Event Discovery and Schedule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make public event discovery searchable/filterable and give the frontend bounded event-date, recurrence, and offer-coverage data without breaking the existing availability authority.

**Architecture:** Add one validated `Events::Public::Search` query object to compose SQL filters and stable ordering before pagination. Add a separate `Events::Public::DatesQuery` for bounded date previews and paginated event-date history. Keep availability in `Catalog::Public::EventAvailabilitySummary`, computing it only for the filtered event page and requested price currency. Derive public ticket date coverage from `Catalog::ProductAccess`, not refund allocations.

**Tech Stack:** Rails 8.1, ActiveRecord/PostgreSQL, ActiveModel Serializers, Minitest integration/service tests, Postman Collection v2.1.

---

## File map

- Create `app/services/events/public/search.rb` and cover the query contract through public-event integration tests.
- Create `app/services/events/public/dates_query.rb` and cover preview/history behavior through public-event integration tests.
- Modify `app/controllers/public/events_controller.rb`, `config/routes.rb`, public event serializers, and `Catalog::Public::EventAvailabilitySummary`.
- Modify `app/serializers/catalog/public/event_product_serializer.rb` for covered-date projection; its existing controller preload already loads product-access rows.
- Modify `test/integration/events/public_events_test.rb`, `test/integration/catalog/public_products_test.rb`, and availability tests.
- Modify `postman/Digis API_collection.json` and the existing gap tracker statuses after local verification.

## Task 1: Add the public search query contract

**Files:** Create `app/services/events/public/search.rb`; modify `app/controllers/public/events_controller.rb` and `test/integration/events/public_events_test.rb`.

- [x] **Step 1: Write failing integration tests.** Cover text/category/city/date filters; primary and active-collaborator organizations; venue and artist filters; AND composition and matching-date behavior; invalid input/sorts; and public visibility.
- [x] **Step 2: Run the focused tests to verify red.** The initial focused run failed on the missing query/filter/date contracts before implementation.
- [x] **Step 3: Implement `Events::Public::Search`.** It accepts a public-visible relation and validated scalar query values, escapes text matching, applies bound subqueries, combines filters with AND, and keeps events unique.
- [x] **Step 4: Add the sort allowlist.** Supports `newest`, `soonest`, `price_asc`, and `price_desc`, with a stable event-ID tie-breaker and 422 for unsupported values.
- [x] **Step 5: Integrate filters before count and pagination.** `featured=true` intersects the filtered public relation; count/pagination happen before page-only availability projection.
- [x] **Step 6: Re-run the focused tests** with `N_PLUS_ONE=1`.

## Task 2: Make price filters and sorting currency-safe

**Files:** Modify `app/services/events/public/search.rb`, `app/services/catalog/public/event_availability_summary.rb`, `app/serializers/events/public/event_list_serializer.rb`, and their tests.

- [x] **Step 1: Add failing tests** for missing currency, selected-currency isolation, inclusive price bounds, inverted/oversized bounds, and deterministic equal-price order.
- [x] **Step 2: Run the relevant tests to verify red** in the public-event integration suite and availability tests.
- [x] **Step 3: Implement the currency contract.** Price operations require an explicit three-letter ISO-formatted currency, reject inverted/oversized bounds, query active public ticket prices at one request timestamp, and never convert currencies. Response price and currency identify the selected currency; without one, event-currency behavior remains.
- [x] **Step 4: Run the same focused tests** with `N_PLUS_ONE=1`; availability remains advisory.

## Task 3: Bound public dates and expose series identity

**Files:** Create `app/services/events/public/dates_query.rb`; modify `app/controllers/public/events_controller.rb`, `config/routes.rb`, the public event serializers, `app/services/catalog/public/event_availability_summary.rb`, and `test/integration/events/public_events_test.rb`.

- [x] **Step 1: Write failing tests** for card/detail bounds, recurrence identity/privacy, upcoming defaults, historical ranges, and page-size caps.
- [x] **Step 2: Run tests and confirm the current serializers return all dates and lack series identity.**
- [x] **Step 3: Implement `Events::Public::DatesQuery`.** The dates endpoint uses public-visible events, defaults `from` to the captured current time, honors `[from,to)`, orders `starts_at,id`, and relies on standard pagination capped at 100. Cards use one scheduled/postponed next date; detail returns a seven-row preview and URL.
- [x] **Step 4: Add series-safe projections.** Exposes `is_recurring` and `series_id` from valid recurrence-generated rows only; internal source keys/rules stay private.
- [x] **Step 5: Remove full date-association loading from event list/detail.** Lifecycle is aggregated; list availability snapshots only access-rule date rows; previews use a bounded SQL window query.
- [x] **Step 6: Run date-query, detail, list, and availability tests** with `N_PLUS_ONE=1`.

## Task 4: Publish offer date coverage from product access rules

**Files:** Modify `app/controllers/catalog/public_products_controller.rb`, `app/serializers/catalog/public/event_product_serializer.rb`, and `test/integration/catalog/public_products_test.rb`.

- [x] **Step 1: Write failing tests** for sorted ticket coverage, null non-ticket coverage, and privacy of refund/allocation fields.
- [x] **Step 2: Run `N_PLUS_ONE=1 bin/rails test test/integration/catalog/public_products_test.rb`** and confirm the coverage assertion fails.
- [x] **Step 3: Preload `product_accesses.event_date`** and expose coverage only for ticket offers from product-access rules.
- [x] **Step 4: Re-run public product tests** with `N_PLUS_ONE=1`.

## Task 5: Sync docs and verify the public API slice

**Files:** Modify `postman/Digis API_collection.json`, `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`, and `test/performance/public_event_catalog_test.rb`.

- [x] Add Postman requests/examples for public filters, explicit-currency price sorting, bounded event-date listing, series identity, and ticket covered-date IDs.
- [x] Mark G-52 through G-56 locally implemented only after focused tests pass; no deployment/frontend claim is made.
- [x] Assert the detail preview is bounded and filtered pages are N+1-free; the existing availability suite also covers large schedule/page-neighbor inputs.
- [x] Run the focused public/product/availability tests with `N_PLUS_ONE=1`; targeted RuboCop, `bin/rails zeitwerk:check`, Postman JSON parsing, and `git diff --check` pass.
