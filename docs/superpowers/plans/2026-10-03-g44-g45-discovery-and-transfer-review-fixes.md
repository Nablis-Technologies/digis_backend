# G-44/G-45 Discovery and Transfer Review Fixes

> Execute inline with test-first checkpoints. Preserve unrelated worktree changes. Do not stage, commit, or deploy.

**Goal:** Make discovery prices and offer states match public ticket access, physical versus online inventory rules, and the same result regardless of page neighbors; bind transfer route IDs and optional tokens inside the locked acceptance command.

**Architecture:** Events owns date eligibility; Catalog owns offer access and inventory demand; Orders adapts shared date results to checkout errors. Public discovery keeps one list response, but evaluates public offers in fixed-size batches without a business-result cap. Transfer acceptance takes all credentials through one locked command.

**Tech Stack:** Rails 8, PostgreSQL, Minitest, N+1 detection, RuboCop.

**Rulings:** A public event card's starting price is the minimum current public-audience ticket price; gated-only events have no public starting price. Availability precedence remains `available`, `unavailable`, `coming_soon`, `sold_out`, `sales_closed`, after excluding offers without eligible dates. Stream access requires an eligible event date and product inventory but consumes no venue capacity. List-event results cannot depend on which other events share the page.

## Task 1: Filter discovery prices to public offers

**Files:** `app/services/catalog/public/event_availability_summary.rb`, `test/services/catalog/public/event_availability_summary_test.rb`, `test/integration/events/public_events_test.rb`.

- [x] Add a failing test for a public 50,000-minor ticket plus a gated 5,000-minor ticket; the event card must report 50,000. A gated-only event must return a null public starting price.
- [x] Join `ticketing_ticket_types` with audience `public` in the minimum-price projection.
- [x] Verify the service and HTTP tests with N+1 detection.

## Task 2: Short-circuit capacity while preserving state precedence

**Files:** `app/services/catalog/public/offer_availability.rb`, `test/services/catalog/public/product_availability_test.rb`.

- [x] Extend the multi-date choose-one test to count real capacity-planning calls with `TracePoint`; expect the first available date to stop further plans. Add a mixed misconfigured/sold-out candidate test that expects `unavailable`.
- [x] Evaluate date eligibility first, then sale window and price once, then visit capacity candidates. Return immediately on `available`; when none are available, retain precedence `unavailable` over `sold_out`.
- [x] Run product availability tests with N+1 detection.

## Task 3: Bind transfer acceptance to the route ID under lock

**Files:** `app/controllers/ticketing/transfers_controller.rb`, `app/services/ticketing/transfers/accept.rb`, `test/services/ticketing/transfers/accept_test.rb`, `test/integration/ticketing/transfers_test.rb`.

- [x] Add failing service and HTTP tests for a valid token paired with a different route ID; acceptance must fail and leave the transfer and ticket unchanged.
- [x] Have the controller pass route ID, optional token, and actor once. Match ID and token digest together under the service transaction/row lock; preserve token-only direct calls, ID-only verified-recipient calls, recipient checks, replay, audit, and outbox behavior.
- [x] Run transfer acceptance service and integration tests with N+1 detection.

## Task 4: Share event-date rules and derive physical demand from access type

**Files:** create `app/services/events/event_date_eligibility.rb` and `app/services/catalog/inventory/admission_line.rb`; modify `app/services/orders/event_date_eligibility.rb`, `app/models/ticketing/ticket_type.rb`, `app/services/catalog/inventory/capacity.rb`, `app/services/catalog/inventory/check_availability.rb`, `app/services/catalog/inventory/reserve.rb`, `app/services/catalog/public/offer_availability.rb`, `app/services/orders/admission_selections/create.rb`, `app/services/orders/admission_selections/request_otp.rb`, `app/services/orders/build_quote.rb`, `app/services/ticketing/registrations/support.rb`, and `app/services/ticketing/waitlist/submit.rb`.

- [x] Add failing tests for a stream-only ticket with full venue capacity remaining available, a fixed stream access on a past date being ineligible despite another future event date, and a hybrid ticket charging venue capacity only for its physical access dates. Cover the composed admission/registration reservation path. Also prove waitlist rejects a started choose-one date.
- [x] Move the pure scheduled/future snapshot and selected-ID check to `Events::EventDateEligibility`; keep the Orders wrapper responsible for the existing checkout error object and message, and use the shared rule in waitlist validation.
- [x] Add one `Catalog::Inventory::AdmissionLine` constructor that derives all granted dates for inventory/eligibility and only venue/parking dates for physical demand. Reuse it in public availability, selection preflight, OTP quote inputs, BuildQuote, registration reservations, and waitlist capacity checks. Ignore or validate client-supplied physical-date demand; the server derives it.
- [x] Centralize the post-lock/preflight check in `Catalog::Inventory::Capacity.evaluate`, which revalidates the line against the snapshot/locked date rows before assessing capacity. Lock access dates for ownership validation while creating venue reservations only for physical accesses.
- [x] Run the affected event-date, inventory, registration, waitlist, admission-selection, quote, and checkout tests with `N_PLUS_ONE=1`.

## Task 5: Remove page-dependent fan-out caps and evaluate large catalogs in batches

**Files:** `app/services/catalog/public/event_availability_summary.rb`, `app/services/catalog/public/product_availability.rb`, `test/services/catalog/public/event_availability_summary_test.rb`, `test/performance/public_event_catalog_test.rb`, G-44 spec and tracker.

- [x] Add regressions proving an event with 51 public offers is classified, its result is unchanged after 1,000 neighboring offers, and availability resolves with more than 100 event dates.
- [x] Remove per-event, per-page, and event-date result caps. Stream active public ticket rows with `find_in_batches(batch_size: 100)`, build indexed snapshots per batch, and fold per-event state flags without accumulating all product records. Keep malformed ticket types as `unavailable`; gated offers remain excluded from public availability.
- [x] Keep grouped public-price SQL and one shared timestamp. The 1,050-offer fixture now asserts page-order invariance, total products visited, maximum batch size, and query bound; an opt-in measurement records elapsed time and Ruby allocations.
- [x] Update the approved G-44 spec and tracker to remove limit-induced `unavailable` states and document measured batch behavior.

## Task 6: Reconcile the contract and verify

**Files:** `config/routes.rb` only if required, `postman/Digis API_collection.json`, `tasks/lessons.md`, this plan.

- [x] Reuse `Core::Pagination#apply_pagination` for the public list and verify existing page/order tests still pass.
- [x] Update Postman and the tracker to describe public-only price, physical versus stream availability, and transfer ID/token binding. Add the lesson that query-count checks alone do not prove row-volume or payload performance.
- [x] Run the final combined focused suite with `N_PLUS_ONE=1`, targeted RuboCop, Postman JSON parsing, and `git diff --check`. Review the final diff; leave changes unstaged and uncommitted.
