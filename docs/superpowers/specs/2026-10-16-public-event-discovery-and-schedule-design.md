# Public Event Discovery and Schedule API Design

## Goal

Give the consumer client a truthful, bounded public event API for recurring schedules, offer date coverage, discovery filters, and event history without computing or returning unbounded child collections.

## Current problems

- Public event list/detail serializers do not identify recurrence or group materialized dates into a series.
- Public product records do not identify the event dates a ticket offer covers. `Catalog::ProductDateAllocation` is a refund-value split and is not the public source of ticket validity.
- Public list/detail responses preload and serialize full `event_dates` associations.
- `/public/events` paginates but uses fixed ordering and does not apply search, city, category, date, price, or followable-entity filters.
- Entity profile pages cannot retrieve a paginated event history for an organization, venue, or artist.

## Proposed API

### Event discovery

Keep one public collection endpoint: `GET /public/events`. Accept validated parameters:

- `q` (trimmed 2–120 characters, matching public event title/description), `category` (slug), `city` (trimmed case-insensitive city name), `date_from`, and `date_to` (ISO-8601 instants);
- `organization_id`, `venue_id`, and `artist_id` for profile event lists;
- `sort` (`newest`, `soonest`, `price_asc`, `price_desc`);
- `currency`, `min_price_minor`, and `max_price_minor`;
- existing `page` and `per_page` pagination.

Filters are applied to a public-visible event relation before counting and pagination. Followable filters match the primary/collaborating organization, event-date venue, or public event participant. Event date predicates use `EXISTS`-style conditions so joins do not duplicate events. Sorting always has a stable event-ID tie-breaker. Existing `featured=true` behavior intersects with these filters and keeps its fail-closed availability contract.

All supplied filters combine with AND. A date range matches an event date whose interval overlaps `[date_from, date_to)`; either bound may be omitted. City matching uses venue city on a matching event date. Price bounds or price sorting require an explicit ISO currency; the API does not perform FX conversion. Supplying `currency` selects events with an active public ticket price in that currency, and the response identifies the currency used for its `price_from_minor` value. Price and availability calculations share one request timestamp and consider active public ticket offers only. Invalid parameter values return HTTP 422 with `invalid_public_event_filter`.

### Bounded schedules and series identity

- Event cards return one `next_event_date` summary (the first scheduled/postponed date whose end is after the request timestamp), not the entire date association.
- Event detail returns `event_dates_preview`, capped to seven dates with `ends_at > at` and status `scheduled`, `postponed`, or `cancelled`, ordered by `starts_at,id`, plus the public dates URL.
- `GET /public/events/:slug/dates` returns chronologically ordered, paginated dates. `from` defaults to the current instant; the inclusive lower/exclusive upper `[from,to)` interval may explicitly request history. Pagination defaults to 25 and has a hard maximum of 100.
- Public dates include safe schedule fields and a `series_id` only for valid recurrence-generated occurrences. Event detail includes boolean `is_recurring`. Neither private recurrence rule text nor internal `source_key` is serialized.
- Ticket products expose sorted `covered_event_date_ids` derived from product access rules. Non-ticket products return `covered_event_date_ids: null`. Refund allocation basis points are not part of the public coverage contract.

### Availability and safety

The existing availability summary remains advisory and is computed for the returned event page only. Search filters never expose private, draft, cancelled, gated-only, or organizer-only data. Invalid filters return a typed 422; unsupported sorts are not silently ignored. Public date lists are bounded independently from recurrence materialization.

## Alternatives considered

1. Add unrelated endpoint/controller pairs for each filter and profile type. Rejected because it duplicates query, authorization, pagination, and availability behavior.
2. Extend the public list query and provide one dedicated paginated event-date subresource. Recommended: one event search contract plus a distinct schedule collection where pagination is intrinsic.
3. Keep all nested event dates and rely on the client to truncate. Rejected because it preserves unbounded database preloads and response payloads.

## Verification

Add integration tests for every filter, currency-required price behavior, deterministic sorting, entity scoping, featured-filter composition, preview truncation, historical date ranges, recurrence identity, covered-date semantics, and page bounds. Run focused tests with `N_PLUS_ONE=1`, performance tests with large schedules and many offers, targeted RuboCop, route checks, and Postman collection validation.
