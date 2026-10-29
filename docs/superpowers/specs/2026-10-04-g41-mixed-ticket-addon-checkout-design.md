# G-41 Mixed Ticket and Add-on Checkout Design

Date: 2026-10-04  
Status: Proposed for review  
Related design: [Composable Admission Selection and Hybrid Checkout](2026-09-28-composable-admission-selection-design.md)  
Gap: G-41 in `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

## Goal

Allow an attendee to buy one or more ticket products together with supported
non-ticket add-ons in one admission-selection request, producing one quote,
one order, one payment (when the total is positive), and one atomic inventory
reservation. Registration and admission-proof rules continue to apply only to
ticket lines.

## Evidence and current boundary

The frontend gap report says `useCheckoutFlow.buildSelectionInput` submits the
selected ticket followed by selected extras in one `items` array. The reported
extras include parking, merchandise, and food. The frontend source repository
is not part of this backend workspace, so the request report is the available
frontend evidence; it has not been independently inspected here.

The backend currently rejects a non-ticket item in both
`Orders::AdmissionSelections::Create` and `RequestOtp`. The registration
assembler then assumes every item has a `TicketType`, and the checkout
dispatcher zips every selection line to a registration. In contrast,
`Orders::BuildQuote` and `Orders::CreateCheckout` already support generic
product lines and reserve all order-item inventory in the checkout transaction.
The fulfillment boundary already issues tickets and parking credentials from
the paid order outbox. The current admission response's expected-ticket count
also sums every order item, so adding merchandise or food without correcting
that projection could leave the response at `issuing` indefinitely.

## Approaches considered

1. **One admission selection, one mixed order (recommended).** The backend
   derives each line's kind from the locked product, creates registrations only
   for ticket lines, preflights the whole basket, and submits all lines through
   the existing quote and atomic checkout path. This matches the frontend's
   reported basket and avoids split charges or partial purchases.
2. **Separate add-on order after ticket checkout.** This keeps admission
   selection ticket-only but requires a second quote/order/payment flow and
   breaks the reported one-basket experience.
3. **Client-composed ticket and add-on orders.** This lets the client sequence
   independent purchases, but can leave a paid ticket without its requested
   extras (or vice versa) and duplicates checkout orchestration in the client.

Approach 1 is selected for this design.

## Public request contract

Keep the existing event-scoped admission-selection route and `items` array.
The server loads and locks each `Catalog::EventProduct` and derives its kind;
the client must not submit a trusted `line_type` discriminator.

Ticket lines retain the existing contract:

- `event_product_id`, `quantity`
- optional `registration_id` and `selected_event_date_id`
- `answers`, `consents`, and `audience_proof` for ticket-specific form and
  audience rules

Add-on lines use:

- `event_product_id`, `quantity`
- optional `event_date_ids` when the product has date-scoped inventory or
  date-scoped access (including parking)

The server validates `event_date_ids` against the product's configured access
and inventory dates, and derives physical venue-date demand itself. The client
cannot submit `venue_event_date_ids`, prices, or inventory quantities. Add-on
lines do not create registrations. Empty ticket-only fields may be omitted or
empty on an add-on line; non-empty ticket-only proofs, answers, consents, or a
registration ID on an add-on are rejected as invalid input rather than being
silently applied.

An admission selection must contain at least one ticket line. This preserves
the endpoint's admission purpose and means any add-on submitted through this
flow is in the same order as a ticket. The broader meaning of the public
`requires_ticket` hint remains the separate G-31 product decision; this design
does not define its semantics for other quote/order routes.

## Product validation and line behavior

All lines must be active products belonging to the selected event and satisfy
their server-side quantity limits, sales window, price/currency, and inventory
configuration. Unsupported product type `other` remains unavailable for this
checkout.

- **Ticket:** Keep existing ticket-type presence, date-selection, audience
  authorization, form validation, persisted-registration, and waitlist rules.
- **Parking:** Validate its configured parking access/date requirements and
  use the existing parking credential fulfillment path after payment.
- **Merchandise, food, donation, and digital add-on:** Use the existing generic
  add-on product validation and order-item lifecycle. This change does not add
  custom-amount donation pricing, pickup, delivery, redemption, or other
  organizer-side fulfillment workflows. Donation lines use their configured
  catalog price because the current quote contract has no custom-amount field.

Manual-approval ticket applications remain standalone and cannot be combined
with other lines. A capacity-exhausted waitlist result remains ticket-scoped;
it must create no add-on order item or inventory hold. All other selection
errors roll back the entire basket.

## Flow and transaction invariants

1. Normalize and lock all selected products; classify lines from server-owned
   product records.
2. Validate ticket-specific rules only on ticket lines and add-on sales/date
   rules only on add-on lines.
3. Preflight capacity for all lines together using deterministic product/date
   locking. Do not create probe reservations or consume proofs during preflight.
4. Assemble/reuse registrations only for ticket lines, keyed by product ID.
5. Build one quote containing every line and its server-derived date demand.
6. Create one order and reserve all product and venue capacity through the
   existing `CreateCheckout` transaction. A failure on any line leaves no
   committed partial registration/order/hold.
7. On positive total, wait for payment before fulfilling any line. On zero
   total, use the existing zero-total fulfillment path without provider
   dispatch.
8. Preserve request idempotency and guest OTP recovery. OTP preflight validates
   ticket lines and prices every line, but creates no order, registration, or
   inventory hold. Adding the optional `event_date_ids` field must not change
   the canonical digest for existing ticket-only requests when the field is
   empty; nonempty add-on dates remain bound to the replay digest.
9. Batch-load products and active price rows for multi-line quotes so guest OTP
   preflight does not add product/price queries per basket line. Preserve
   current active-window and fixed-override precedence.
10. Guest OTP preflight validates add-on inventory configuration, including
    per-date pools, without creating holds. Capacity exhaustion remains a
    selection/checkout decision; OTP preflight must not consume inventory.

## Response behavior

`registrations` contains only ticket registrations. Add-on lines never receive
placeholder registration records. The returned order and `next_action` continue
to describe the single mixed order. The issuance-pending projection must compare
issued ticket/parking credentials against expected credential units only—not
against merchandise, food, donation, or digital add-on quantities—so a paid
mixed order cannot remain `issuing` after all credentials are issued.

## Scope boundaries

- No database migration or new order/payment model.
- No changes to payment-provider contracts, price calculation, promotion rules,
  or the existing order reservation transaction.
- No change to the global G-31 `requires_ticket` policy; only require at least
  one ticket in an admission selection.
- No support for `other` products, cross-event baskets, manual-approval mixed
  baskets, or waitlist add-ons.
- No frontend repository edits. The backend contract and Postman example must
  document the add-on `event_date_ids` field for date-scoped add-ons.
- Do not deploy, reset, or seed the database as part of implementation.

## Acceptance tests

- Paid ticket + merchandise/food add-on yields one order with both lines, one
  payment amount, one inventory reservation per eligible line, and a ticket
  registration only for the ticket.
- Ticket + parking on explicit configured dates yields one order; after payment,
  the ticket and parking credentials are issued through their existing paths.
- Missing, duplicate, cross-event, unscheduled, or unauthorized add-on date IDs
  fail closed and leave no partial order, registration, or reservation.
- Mixed free/paid ticket lines and promotions retain existing totals; free
  ticket plus paid add-on is not confirmed before payment.
- Access-code/invitation/form validation applies to ticket lines only; malformed
  or mismatched ticket proof still rejects the whole basket.
- A failed ticket or add-on validation or capacity reservation rolls back every
  line. Waitlist fallback applies only to eligible ticket lines and creates no
  add-on order/hold.
- Manual approval mixed with any other line remains rejected.
- Guest OTP request quotes the full basket without creating side effects.
- Same-key replay returns the same mixed order without duplicate lines,
  registrations, reservations, or audits; changed payload conflicts.
- Existing ticket-only replay receipts remain valid across this additive
  request-envelope change; empty `event_date_ids` do not alter their canonical
  request digest.
- A multi-product quote passes with `N_PLUS_ONE=1` while preserving the same
  product price selection.
- A date-bound add-on without a configured per-date inventory pool cannot
  trigger guest OTP, and the preflight creates no reservation.
- After payment, `next_action` becomes `confirmed` once all ticket/parking
  credentials exist, regardless of non-credential add-on quantities.
- Existing ticket-only, multiple-ticket, guest/authenticated, idempotency,
  waitlist, access-code, invitation, zero-total, and checkout-release tests
  remain green.
