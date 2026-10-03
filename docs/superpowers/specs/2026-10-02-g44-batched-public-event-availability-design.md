# G-44 Single-Response Public Event Discovery Design

**Date:** 2026-10-03

**Status:** Revised design approved; implemented and verified locally; frontend integration and deployment pending

**Revision:** Replaces the initial two-request batch-availability design. The
previous batch route was local and undeployed, so it can be removed without a
live-client migration.

## Goal

Make one bounded public event-list response sufficient to render discovery
cards, including lifecycle and a useful public-ticket availability state. The
frontend should not fetch the event list and then join a second availability
response by ID.

## Current gap and evidence

`GET /public/events` currently returns every published public event, with
`price_from_minor`, but no lifecycle or availability state and no pagination.
The G-44 batch route adds a second request and a client-side event-ID join. Its
`has_available_tickets` boolean also collapses “sold out,” “sales not open,”
“sales closed,” and “no public ticket offers” into the same false value.

More importantly, `Catalog::Public::ProductAvailability` currently checks the
product sales window and whether any inventory row has capacity. It does not
check that the product's required event dates are future `scheduled` dates, nor
does it apply the complete global/per-date inventory and venue-capacity rules
used by `Catalog::Inventory::Capacity`. A still-published event whose dates
have passed can therefore be reported available if its product sales window
and inventory remain open.

The authoritative checkout path uses `Orders::EventDateEligibility` and
`Catalog::Inventory::Capacity`; discovery must align with those rules as a
read-only snapshot, without taking checkout locks or reserving inventory.

## Design

Replace the separate batch route with the public event list:

```http
GET /public/events?page=1&per_page=25
```

The response preserves the existing `success`, `data` array, and event-card
fields, retains `price_from_minor`, and always includes the repository's
standard `pagination` metadata. Page size defaults to 25 and is capped at 100;
rows have deterministic ordering by `published_at DESC, id DESC`. Availability
work is performed only for the returned page.

Each event adds two separate projections so event timing is not conflated with
ticket sellability:

```json
{
  "event_lifecycle": "upcoming",
  "ticket_availability": "available"
}
```

`event_lifecycle` is one of:

- `upcoming`: at least one `scheduled` event date starts in the future and no
  scheduled date is currently in progress.
- `ongoing`: at least one `scheduled` date satisfies `starts_at <= at < ends_at`.
- `ended`: event dates exist, none are upcoming or in progress, and at least
  one non-cancelled date is completed or has ended.
- `unscheduled`: no date is upcoming, in progress, or ended; this includes an
  event with no dates or only postponed/cancelled dates.

`ticket_availability` is one of:

- `available`: at least one active public-audience ticket offer is on sale,
  has an eligible future date, and can satisfy its minimum order quantity
  across all required inventory pools and venue capacity.
- `coming_soon`: no offer is currently available, but an active public offer
  with an eligible future date has a future `sales_start_at`.
- `unavailable`: the server cannot safely classify an otherwise relevant
  public offer because required price/inventory/venue configuration is invalid,
  or the bounded availability-projection budget is exceeded. This does not mean
  sold out and is not a checkout rejection.
- `sold_out`: eligible public offers are currently on sale, but every such
  offer is exhausted in at least one required capacity pool, with no eligible
  offer classified as `unavailable`.
- `sales_closed`: active public ticket offers exist for eligible future dates,
  but all their sales windows have ended and none have a future start.
- `no_public_tickets`: the event has no active ticket product whose audience
  is `public`; gated-only offers do not count.
- `no_eligible_dates`: public ticket offers exist, but none can be purchased
  for an eligible future scheduled date.

At event level, use `no_public_tickets` when there are no active public ticket
products and `no_eligible_dates` only when none of the public products has an
eligible future date. Otherwise ignore products in `no_eligible_dates` and
aggregate the remaining states with this precedence: `available`,
`unavailable`, `coming_soon`, `sold_out`, then `sales_closed`. The status is an
event-level discovery hint, not a guarantee for a particular buyer, quantity,
promotion, or selected date. Quote and checkout remain authoritative. Do not
return exact counts, inventory rows, held/sold quantities, or user-specific
purchase-limit data.

The shared read-only availability resolver should classify individual ticket
offers and let the event-list projection aggregate them. The current
per-product `available` boolean remains derived from that same classification
so the event card and product list cannot disagree about the underlying
offer-level state. The resolver uses one `at` timestamp and evaluates the same
fixed-vs-choose-one date rules and capacity-pool semantics as checkout from
shared pre-indexed snapshots. Active public ticket products are streamed in
fixed-size batches of 100; SQL aggregates public starting prices and counts,
and each batch folds its offer states into the same event summary. There is no
per-event, per-page product, or event-date cap that changes a business result.
Gated-only offers are excluded from public availability; an active ticket
missing its type still fails closed as `unavailable`. The same event therefore
has the same discovery state regardless of its page neighbors or offer volume.
The event card's existing schedule fields remain unchanged. The resolver must
not call the lock-taking
`Catalog::Inventory::CheckAvailability` path from a GET request.

Only `Events::Event.publicly_visible` rows remain in discovery. That scope
excludes event records whose lifecycle status is `cancelled` or `completed`, so
`cancelled` is intentionally not a state in this response. Cancelled event
visibility is a separate product-policy decision. Cancelled event dates do
not count as eligible sale dates.

The current `GET /public/events/availability` route, controller, service,
locale entries, batch-specific tests, and Postman request are removed. The
public event list stays a single source for card data; the existing
`GET /public/events/:event_slug/products` remains the detail-page offer list.

## Alternatives considered

1. **Paginated event list with lifecycle and ticket status (selected).** One
   request, no client-side ID join, and availability computation is bounded to
   the requested page. This makes the discovery card's contract explicit.
2. Optional `include_availability` on the same list. This keeps non-card
   consumers lean, but creates two list response shapes and requires every
   discovery client to remember the flag. Reconsider only if a real lean-list
   caller exists.
3. Retain the batch endpoint. It remains useful for refreshing already-cached
   event IDs, but is inferior for initial discovery because it needs a second
   request and client-side joining.

## Out of scope

- Showing cancelled/completed event records in public discovery.
- Exact inventory quantities, buyer-specific purchase limits, promotion
  eligibility, access-code/invitation proofs, or reservation guarantees.
- Changing checkout, reservation, waitlist, or transfer behavior.
- Frontend implementation; that repository is not available in this workspace.

## Acceptance criteria

1. A single paginated `GET /public/events` response contains the existing card
   fields plus `event_lifecycle` and `ticket_availability`; no second
   availability request or client-side ID join is required.
2. Pagination defaults to 25, caps at 100, always returns metadata, and uses a
   stable ordering. Availability computation is scoped to the current page;
   public ticket associations are streamed in batches of 100, without a
   product/date cap that changes the reported state.
3. Lifecycle classifications correctly handle future, in-progress, past,
   postponed, cancelled-date, and missing-date cases; cancelled/completed event
   records remain omitted.
4. Ticket state honors active public ticket offers, sales windows,
   `fixed`/`choose_one` event-date eligibility, minimum purchase quantity,
   event-wide/per-date inventory modes, and venue capacity without writes or
   checkout locks; invalid/missing capacity setup fails closed as `unavailable`.
5. `available` remains an advisory, page-level statement. No exact inventory
   counters or buyer-specific constraints cross the public response.
6. Per-product availability is derived from the same shared offer status.
7. Tests cover every state, mixed event/date/product cases, pagination,
   privacy, stable ordering, and bounded query behavior with N+1 detection.
8. Postman documents the event-list response and pagination/status fields; the
   retired batch request is removed.
