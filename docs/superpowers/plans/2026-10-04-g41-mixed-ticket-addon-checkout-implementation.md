# G-41 Mixed Ticket and Add-on Checkout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permit one admission selection to purchase ticket lines and supported add-on lines together in one correctly reserved order.

**Architecture:** Derive each line's kind from the locked product; preserve ticket-specific registration/proof handling only for ticket lines. A shared inventory-line builder will turn ticket and add-on inputs into `Catalog::Inventory::Line` values for preflight and quote construction, while existing `BuildQuote` and `CreateCheckout` remain the price, order, and atomic-reservation authorities.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, Minitest, ActiveRecord, Postman collection JSON, RuboCop.

**Spec:** `docs/superpowers/specs/2026-10-04-g41-mixed-ticket-addon-checkout-design.md`

## Global Constraints

- No database migration or new order/payment model.
- Derive line kind from the locked `Catalog::EventProduct`; do not trust a client `line_type`.
- Ticket lines alone receive registration, form, audience-proof, and ticket-date-selection validation.
- Date-bound add-on lines carry explicit `event_date_ids`; physical venue-date demand is server-derived.
- One selection creates one order; all lines either reserve together or roll back together.
- Preserve ticket-only, manual-approval, waitlist, guest OTP, replay, and payment invariants.
- Keep the broader G-31 `requires_ticket` policy unresolved; this route still requires at least one ticket line.
- Do not stage, commit, deploy, reset, or seed; update only G-41 contract documentation and Postman coverage.

## Review Focus

1. **Ticket/registration misassociation when items are interleaved:** pair registrations to ticket products by product ID, never array position; test ticket/add-on/ticket input ordering.
2. **Date-scoped add-on misuse:** reject dates outside configured inventory/access dates and derive physical date demand from product accesses; test parking with valid, missing, and mismatched dates.
3. **Partial side effects on mixed failure:** fail a mixed basket after one ticket registration or line validation and assert no persisted partial order, registration, consumed proof, or reservation.
4. **Waitlist/manual-approval leakage into add-ons:** preserve standalone manual approval and per-ticket waitlist outcomes without creating add-on order items or holds.
5. **Checkout status stuck at `issuing`:** compare issued credentials against expected ticket/parking credential quantities only; prove merchandise/food quantity does not delay confirmation.

---

### Task 1: Normalize add-on date selections and build shared inventory lines

**Files:**
- Modify: `app/values/orders/admission_selection_envelope.rb`
- Create: `app/services/catalog/inventory/product_line.rb`
- Test: `test/services/catalog/inventory/product_line_test.rb`
- Modify: `test/values/orders/admission_selection_envelope_test.rb`

**Interfaces:**
- Consumes: existing `Orders::AdmissionSelectionEnvelope::Item`, `Catalog::Inventory::AdmissionLine`, `Catalog::Inventory::Line`, `Catalog::Inventory::Capacity`, product accesses, and product inventories.
- Produces: `Catalog::Inventory::ProductLine.call(product:, package_quantity:, selected_event_date_id: nil, event_date_ids: nil)` returning a `Catalog::Inventory::Line` for a valid product selection or `nil` for an invalid date selection. Ticket lines retain existing `AdmissionLine` behavior; non-ticket lines use explicit `event_date_ids` and server-derived physical-date IDs with `admissions_per_unit: 1`.

- [x] **Step 1: Write RED tests for add-on line construction.** Add tests named `builds an event-wide product line without dates`, `requires configured dates for per-date inventory`, `builds parking physical demand from selected parking access dates`, and `rejects dates that do not belong to the add-on`. Add envelope tests named `normalizes add-on event date ids` and `does not accept client venue date demand`.
- [x] **Step 2: Run the new service tests and verify they fail for the absent shared builder.**

Run: `N_PLUS_ONE=1 bin/rails test test/services/catalog/inventory/product_line_test.rb`

Expected: failures show `Catalog::Inventory::ProductLine` is not defined or does not yet build the expected lines.

- [x] **Step 3: Extend the immutable envelope with normalized `event_date_ids`.** Preserve public payload allowlisting; keep ticket `selected_event_date_id`, answers, consents, registration, and audience proof fields unchanged. Normalize date IDs deterministically and ensure the new field participates in canonical request hashing through the existing item serialization.
- [x] **Step 4: Implement `Catalog::Inventory::ProductLine.call`.** Delegate ticket selection to `AdmissionLine`; for supported add-ons validate explicit dates against configured product inventory/access dates, derive `venue_event_date_ids` only from physical product accesses, and create a shared `Line` with one admission per add-on package.
- [x] **Step 5: Run the tests and verify GREEN.**

Run: `N_PLUS_ONE=1 bin/rails test test/services/catalog/inventory/product_line_test.rb test/values/orders/admission_selection_envelope_test.rb`

Expected: all new line/envelope tests pass; existing ticket `AdmissionLine` callers remain unchanged.

### Task 2: Make selection creation assemble registrations only for tickets

**Files:**
- Modify: `app/services/orders/admission_selections/create.rb`
- Modify: `app/services/orders/admission_selections/registration_assembler.rb`
- Modify: `app/services/orders/admission_selections/checkout_dispatcher.rb`
- Test: `test/services/orders/admission_selections/create_test.rb`

**Interfaces:**
- Consumes: `Catalog::Inventory::ProductLine.call` from Task 1 and normalized `event_date_ids` on each envelope item.
- Produces: one mixed order quote/reservation; registrations and response registration summaries exist only for ticket lines. `CheckoutDispatcher` pairs registrations by `event_product_id` and sends all lines plus server-derived date demand to `BuildQuote`.

- [x] **Step 1: Write RED service tests.** Add tests named `creates one order for ticket and merchandise with a ticket registration only`, `creates one order for ticket and date-scoped parking`, `pairs interleaved ticket lines to registrations by product`, `does not count noncredential add-ons as pending issuance`, `replays legacy ticket-only receipts after adding empty add-on dates`, `rejects add-on-only admission selections`, `rejects add-on date ids on a ticket line`, and `rejects a manual ticket mixed with an add-on atomically`. Add a rollback assertion for a mixed basket whose quote or reservation fails after ticket registration assembly.
- [x] **Step 2: Run the focused tests and verify the current `product_unavailable` rejection and positional registration assumption fail the new cases.**

Run: `N_PLUS_ONE=1 bin/rails test test/services/orders/admission_selections/create_test.rb`

Expected: new mixed-selection assertions fail before implementation; existing ticket-only assertions continue to pass.

- [x] **Step 3: Partition validated lines by the server-loaded product.** Require at least one ticket; allow only `parking`, `merchandise`, `food`, `donation`, and `digital_addon` as add-ons; reject `other`. Validate active same-event products, quantity/sales-window/date rules, and ticket-only data boundaries. Apply registration/audience/form/manual-approval rules to tickets only; keep manual-approval mixed selections rejected. Test that non-empty answers, consents, audience proof, or registration IDs on add-on lines fail closed while omitted/empty ticket-only values are accepted.
- [x] **Step 4: Preflight ticket and add-on capacity together.** Build each line with `ProductLine`, pass all lines to `CheckAvailability`, and preserve waitlist as a ticket-only outcome with no add-on order or reservation.
- [x] **Step 5: Assemble registrations for ticket items only and dispatch one quote for every selected item.** Match returned registrations by product ID, not by `zip` or array position. Pass only server-derived `event_date_ids` and `venue_event_date_ids` into quote requests; leave pricing, promotion, and actual reservation to existing orders services.
- [x] **Step 6: Correct the post-order issuance projection.** Count expected ticket and parking credential units only when determining whether a paid/fulfilled mixed order is still `issuing`; do not count merchandise, food, donation, or digital add-on quantities.
- [x] **Step 7: Run focused service tests and verify GREEN.**

Run: `N_PLUS_ONE=1 bin/rails test test/services/orders/admission_selections/create_test.rb test/services/catalog/inventory/product_line_test.rb`

Expected: mixed and existing ticket-only cases pass; failures roll back the full basket.

### Task 3: Extend guest OTP preflight and HTTP contract coverage

**Files:**
- Modify: `app/services/orders/admission_selections/request_otp.rb`
- Modify: `app/services/orders/build_quote.rb`
- Modify: `app/services/catalog/pricing/quote.rb`
- Modify: `test/services/orders/admission_selections/request_otp_test.rb`
- Modify: `test/services/orders/build_quote_test.rb`
- Modify: `test/services/catalog/pricing/quote_test.rb`
- Modify: `test/integration/orders/admission_selections_test.rb`
- Modify: `postman/Digis API_collection.json`

**Interfaces:**
- Consumes: Task 1 normalized item dates and product-line builder; Task 2 line classification rules.
- Produces: OTP preflight validates ticket proof/forms only for ticket lines, prices every line in the same quote, and creates no registrations, orders, holds, or consumed proofs.

- [x] **Step 1: Write RED quote, OTP, and integration tests.** Add `quotes multiple product lines with batched product and price reads` to BuildQuote tests; assert two literal resolved prices and run with Prosopite active. Add `prices a guest ticket-and-add-on OTP selection without checkout side effects`, invalid ticket-proof cases, and `rejects OTP when a date-bound add-on has no per-date inventory` to RequestOtp tests. Add integration tests named `guest can request OTP for a mixed ticket-and-add-on selection without side effects`, `creates a mixed ticket-and-add-on order with ticket-only registrations`, `mixed invitation and add-on selection uses one payable order`, `rejects nonempty ticket-only proof on an add-on without partial writes`, and `paid mixed ticket-and-parking order fulfills credentials exactly once`. Assert explicit parking dates, one order/payment lifecycle, one reservation per configured line, and response registrations only for tickets.
- [x] **Step 2: Run the tests and verify RED.** OTP cases should fail because validation currently requires every product to be a ticket; the BuildQuote basket test should report repeated product/price reads under Prosopite.

Run: `N_PLUS_ONE=1 bin/rails test test/services/orders/admission_selections/request_otp_test.rb test/services/orders/build_quote_test.rb test/services/catalog/pricing/quote_test.rb test/integration/orders/admission_selections_test.rb`

Expected: OTP cases fail at non-ticket validation and the batched-quote test reports repeated product/price reads; existing ticket-only cases pass.

- [x] **Step 3: Batch-load products and active price rows for multi-line quotes.** Normalize item inputs once, fetch product rows and prices in batched associations, and pass fresh server-loaded products to line normalization. Make `Catalog::Pricing::Quote` use preloaded price rows in ID order while preserving active windows, fixed override precedence, and first active base-price behavior.
- [x] **Step 4: Implement ticket-only OTP validation and complete-basket quote construction.** Use the same supported product/date and ticket-requirement rules as selection creation; validate all lines before requesting the phone challenge. Use `Catalog::Inventory::Capacity.plan_from_snapshot!` for add-on lines to verify configured inventory/date pools without holds or blocking on capacity exhaustion. Keep invalid ticket access/invitation proof rejection whole-basket and ensure empty ticket-only fields on add-ons never enter Ticketing validation.
- [x] **Step 5: Update the Postman admission-selection example.** Add one mixed ticket + add-on request and a date-bound add-on example with explicit `event_date_ids`; do not include `line_type`, `venue_event_date_ids`, client prices, or inventory counts.
- [x] **Step 6: Run service and HTTP tests; parse the Postman collection.**

Run:

```bash
N_PLUS_ONE=1 bin/rails test test/services/orders/admission_selections/request_otp_test.rb test/services/orders/build_quote_test.rb test/services/catalog/pricing/quote_test.rb test/integration/orders/admission_selections_test.rb
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "Postman JSON valid"'
```

Expected: OTP, batched quote, and selection HTTP tests pass with strict N+1 detection; Postman JSON parses.

### Task 4: Regression verification and tracker status

**Files:**
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`
- Verify: the Task 1–3 implementation files and their focused tests.

- [x] **Step 1: Run affected checkout, fulfillment, inventory, and admission suites with N+1 detection.** Include existing ticket-only, free/paid mixed-ticket, access-code, invitation, guest OTP, waitlist, idempotency replay, payment fulfillment, and parking credential coverage.
- [x] **Step 2: Run the full repository test suite with N+1 detection.** Report any unrelated existing failures by exact test name; do not claim a full-suite pass if the command is not green.
- [x] **Step 3: Run full-project `bundle exec rubocop`, changed-file RuboCop, `bin/rails zeitwerk:check`, Postman JSON parsing, and `git diff --check`.** Fix all introduced offenses/errors.
- [x] **Step 4: Update only G-41's tracker entry** to “implemented and verified locally; Render/frontend verification pending,” with exact focused test counts. Preserve that the frontend source was not independently inspected. Do not claim deployed or frontend-integrated.
- [x] **Step 5: Report changed files, test commands/results, residual G-31/product-policy boundary, and the existing uncommitted worktree state.** Do not stage, commit, deploy, or force seed.

### Task 5: Resolve verified code-review consistency and duplication findings

**Files:**
- Create: `app/services/orders/admission_selections/validate_line.rb`
- Modify: `app/services/orders/admission_selections/create.rb`
- Modify: `app/services/orders/admission_selections/request_otp.rb`
- Modify: `app/services/catalog/inventory/product_line.rb`
- Modify: `app/models/catalog/product_price.rb`
- Modify: `app/services/catalog/pricing/quote.rb`
- Modify: `app/services/orders/build_quote.rb`
- Test: `test/services/orders/admission_selections/validate_line_test.rb`
- Modify: `test/services/catalog/inventory/product_line_test.rb`
- Modify: `test/models/catalog/product_price_test.rb`

**Rulings:**
- Share only line rules that must agree across Create and RequestOtp: ticket-type presence, required ticket submission shape, ticket-only fields on add-ons, supported add-on type, and parking access configuration. Keep request-only quantity/date/audience/form and transaction behavior local.
- Missing ticket type is invalid product configuration, so both paths return `product_unavailable` with HTTP 422.
- Keep `Catalog::AddOns::ValidateProduct`: a purchase line must be supported by downstream fulfillment. Parking remains separately validated because it follows credential issuance.
- Keep BuildQuote's canonical product reload; do not trust arbitrary caller-supplied ActiveRecord objects just to skip a query. Defer optimization until a trusted preloaded-input contract is designed and the cost is measured.

- [x] **Step 1: Write RED tests** for a common missing-ticket-type error/status, ticket-only payload rejection on add-ons, missing parking-access classification, and inclusive-start/exclusive-end active price selection with deterministic order.
- [x] **Step 2: Run the focused tests and confirm the expected current divergence / missing helper fails.**
- [x] **Step 3: Extract `AdmissionSelections::ValidateLine`** returning the validated line kind or a typed business error; make Create and RequestOtp consume the same result while keeping their distinct checks local.
- [x] **Step 4: Make `ProductLine` own date/capacity shape only**; remove its redundant missing-parking-access nil branch after shared validation reports `product_unavailable`.
- [x] **Step 5: Add `Catalog::ProductPrice.active_at_in_memory(prices, at:)`** and use it from both pricing selection and quote base-amount snapshotting.
- [x] **Step 6: Run the focused regression suites, changed-file RuboCop, Zeitwerk, and full test suite with `N_PLUS_ONE=1`; update the G-41 tracker only if verification status or counts change.**

## Acceptance Gate

- One ticket plus one or more supported add-ons produces one order and one quote; no client-provided type, price, or venue-capacity demand is trusted.
- Ticket-only admission checks and registrations are applied only to ticket products; add-ons have no synthetic registrations.
- Event-date selections are explicit for date-bound add-ons and validated before quote/order creation.
- Inventory capacity is checked for the whole basket and reserved atomically; any failure leaves no partial basket.
- Parking credentials continue through existing order fulfillment; noncredential add-ons do not keep checkout status at `issuing`.
- Existing ticket-only, manual-approval, waitlist, access-code, invitation, guest OTP, replay, zero-total, and payment behaviors remain green.
- Existing ticket-only audit receipts replay across the additive envelope change; nonempty add-on date IDs remain part of the digest.
- No migration, database reset, seed change, deploy, commit, or unrelated cleanup is included.
