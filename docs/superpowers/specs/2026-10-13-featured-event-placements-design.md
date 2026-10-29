# Paid Featured Event Placements — Design Spec

- Status: Implemented locally; live preview acceptance pending
- Date: 2026-10-13
- Scope: Backend product and API design for organizer-purchased event discovery placement.

## 1. Product decision

An authorized organizer can buy a fixed-price, fixed-duration placement for one
eligible public event. The organizer may choose a future start time. Once Chapa
confirms payment, the placement becomes scheduled and is served during its
paid window in a clearly labeled Featured section on public event discovery.
The paid placement does not change organic event ordering and does not promise
a specific number of impressions, clicks, or ticket sales.

The first release supports public events with registration currently open,
including free RSVP events. It does not depend on whether an event has paid
products.

This is not the `featured` boolean mentioned in G-43 or imported in preview
event data. G-43 is a public event-detail projection gap. A paid placement is a
separately purchased, auditable entitlement with its own payment and expiry
lifecycle; neither the event nor the frontend can set it directly.

## 2. Goals

- Let an event owner or organization administrator purchase and schedule a
  Featured placement without creating a fake ticket order or ticket.
- Use the existing Chapa hosted checkout, webhook, verification, idempotency,
  and refund provider boundaries.
- Activate only from authoritative accepted-payment evidence; a browser return
  URL or client claim is never payment proof.
- Display only currently paid, scheduled/active, eligible placements, using a
  safe public event projection and a visible Featured label.
- Stop serving placements when the event is cancelled or otherwise no longer
  publicly eligible; return the unserved amount when a paid placement is
  stopped under the cancellation policy below.
- Keep provider payments, refunds, and placement state reconcilable and
  separate from organizer ticket-sale/payout accounting.

## 3. Out of scope for v1

- Impression-based, click-based, auction, bidding, or guaranteed-reach billing.
- Discount codes or ticket-price reductions. Existing Catalog promotions
  continue to mean checkout discounts only.
- SMS/email marketing campaigns, credit wallets, credit top-ups, and campaign
  analytics. Those are separate future products; this model must not pretend
  a featured placement is a generic credit campaign.
- Paid changes to organic ranking, event search relevance, or event availability.
- Organizer self-service creation/editing of placement packages or prices.
- Cross-event or organization-wide placement purchases.

## 4. Offer and scheduling rules

V1 uses server-managed, versioned daily-rate offers rather than fixed 24-hour,
72-hour, or 7-day packages. The placement runs from the organizer-selected
`starts_at` until the event's first scheduled start (“doors open”). Its exact
duration and price are calculated by the server. Offer configuration contains
the ETB daily rate, a 24-hour minimum duration, a 14-day maximum duration,
currency, active interval, surface, and terms version. Exact prices are
deployment data configured by the platform; no amount or duration is accepted
from the client. Changing an offer later does not mutate an existing purchase.

Price is proportional to the exact interval and rounded up to the smallest
currency unit: `ceil(daily_rate_minor * duration_seconds / 86_400)`. The
server snapshots the offer version, daily rate, duration, amount, currency,
placement surface, and policy version at quote/purchase time. Initial rollout
is ETB-only through Chapa. The public API may expose the active offer ID, daily
rate, interval, currency, and quoted amount, but these remain informational;
the create command reloads the offer and recomputes the authoritative amount.

Scheduling constraints:

- The event must be public, published, upcoming, and accepting at least one
  public registration offer when the purchase is created. Free RSVP qualifies.
- The selected start must be at least 60 minutes after purchase creation so
  hosted checkout has time to complete. It must also be no more than 14 days
  before the event's first scheduled start.
- `ends_at` is exactly the event's first scheduled start. The resulting
  placement duration must be between 24 hours and 14 days. This product
  promotes upcoming events, not ongoing or ended events.
- The same event cannot have two overlapping scheduled/active placements.
  Sequential placements are allowed.
- A configured per-surface capacity limits the number of scheduled/active
  placements that overlap any point in time. An unexpired `pending_payment`
  purchase reserves capacity until its billing-purchase expiry. Cancelled,
  failed, expired, and completed placements release capacity.
- A capacity quote may report the next viable `starts_at`. If no placement of
  at least 24 hours fits before event start, the period is sold out for that
  event.
- Checkout purchases expire after the existing billing-purchase checkout
  window. A late provider success is reversed using the existing payment
  reversal path and must never activate the placement.
- The placement's serving window is the immutable `[starts_at, ends_at)` range.
  A periodic job may update display state for organizers, but public serving
  must derive eligibility from payment acceptance and the current time, not
  depend on the job running on a schedule.

The placement lifecycle is `pending_payment`, `scheduled`, `active`,
`completed`, `cancelled`, or `failed`. Successful payment moves a future
placement to `scheduled` (or directly to `active` if its start has arrived).
Time determines whether a scheduled placement is currently served; expiry
reconciliation may persist `completed` for organizer reads. Cancellation is
terminal. Refund status belongs to the refund obligation and is reported
separately; `cancelled` never implies that a provider refund succeeded.
The billing-refund obligation state set adds `manual_review` alongside the
existing created/pending/processing/succeeded/failed states.

## 5. Public discovery behavior

Add a dedicated public read endpoint, `GET /public/featured_events`, returning
eligible placements for the configured surface capacity. Each card uses the
existing public event-list projection, including server-computed lifecycle,
availability, and starting price, plus a safe `placement_label: "featured"`.
No payment amount, provider reference, organizer-only state, or internal
placement identifiers are required in the public card.

Also support `GET /public/events?featured=true` so featured filtering composes
with the ordinary paginated event-list contract and any future list filters.
The filter applies before pagination and includes only events with a currently
serving placement. A top-level public discovery controller composes the Events
read model with one canonical `Marketing::FeaturedPlacements::PublicQuery`;
neither domain calls backward into the other. The dedicated route returns all
currently serving placements up to the configured cap, with a stable rotation
of card positions; the filtered route retains ordinary pagination and event-list
ordering among eligible placements. An omitted or false `featured` parameter
leaves the organic public list unchanged.

If the featured eligibility query returns a typed failure, the filtered list
returns `503 featured_events_unavailable`; it never silently drops the filter
or returns organic results for a `featured=true` request.

The result is globally discoverable in v1; location/category targeting is not
sold yet. A purchase-time capacity cap limits concurrent competition. Card
position can rotate deterministically within that bounded active set, but this
does not guarantee impressions, a specific share of visits, or ticket sales.
The UI must label the section and every card as Featured/Sponsored; organic
`/public/events` pagination and ordering remain unchanged. The Featured
response promises eligible placement during the paid interval, not measured
reach or conversion.

The read query must:

- Require an accepted payment and a scheduled/active placement whose interval
  contains the request time.
- Exclude cancelled, private, unpublished, ended, or non-registration-accepting
  events; include open free RSVP events.
- Avoid duplicate events if corrupt or legacy data contains multiple eligible
  placements.
- Reuse the existing public event and availability projection rules, with
  bounded eager loading and no N+1 queries.

## 6. Organizer API and authorization

Proposed routes:

- `GET /events/:event_id/featured_placements/offers` — list currently
  purchasable offers and the server-computed eligibility result.
- `POST /events/:event_id/featured_placements/quote` — quote
  `{ "offer_id": "...", "starts_at": "..." }`; return authoritative
  `ends_at`, duration, amount/currency, capacity availability, and
  `next_available_at` when full. This endpoint does not reserve capacity.
- `POST /events/:event_id/featured_placements` — create an idempotent purchase
  using `{ "offer_id": "...", "starts_at": "..." }` and the required
  `Idempotency-Key` header. Returns the placement state and Chapa checkout URL
  while payment is pending.
- `GET /events/:event_id/featured_placements` — list this event's placements
  and payment/refund status for authorized organizers.
- `GET /events/:event_id/featured_placements/:id` — show one placement scoped
  to its event and organization.
- `POST /events/:event_id/featured_placements/:id/cancel` — stop an
  unpaid/scheduled/active placement under the refund policy below. Requires
  `Idempotency-Key`.

The create command rechecks price, eligibility, exact duration, and capacity
inside its reservation transaction; the quote is never a reservation. If
capacity filled between quote and create, return `409 featured_capacity_full`
with the next viable start when one exists.

Organizer placement responses expose the immutable purchase snapshot needed
to explain the entitlement later: offer code/version, daily rate, charged
amount/currency, terms version, and serving interval. They omit redundant
internal foreign keys; payment/refund details stay in their explicit safe
nested projections.

Only active organization owners and admins may purchase or cancel placements
in v1. Event staff, managers, scanners, and ordinary organization members
cannot spend organization funds. All resources are scoped through the event's
owning organization. Every mutation uses the shared idempotency resolver and
records an audit/outbox fact without secrets or raw provider payloads.

## 7. Payment and activation lifecycle

The placement is the marketing entitlement; `Orders::BillingPurchase` is the
non-event purchase/payment envelope. Do not create an `Orders::Order`, order
item, registration, ticket, or organizer sale-ledger fact for a placement.

The current billing-purchase implementation is explicitly scoped to messaging
credit top-ups and has product-specific associations from `Orders::BillingPurchase`
and `Orders::Payment` back into `Messaging`. Generalize its typed source
contract for `Marketing::FeaturedPlacement` and remove those reverse
product-specific associations: each product domain owns its association to
`Orders::BillingPurchase` and its typed outbox handler. Orders owns provider
payment; accepted/reversed billing-payment outbox events carry a typed source
reference; a Marketing handler applies the placement transition idempotently.
This is a focused boundary correction required to add another billing product,
not a generic advertising framework.

Lifecycle:

1. Validate actor, event eligibility, offer version, schedule bounds, and
   overlap under a lock. Persist the pending placement and billing purchase
   atomically with a frozen request/price digest.
2. Start a Chapa billing payment attempt through
   `Orders::StartBillingPaymentAttempt`; return its checkout URL. Do not mark
   the placement active on payment initialization or redirect.
3. `Orders::AcceptBillingPayment` accepts provider evidence and publishes the
   durable accepted-payment outbox event. A Marketing handler verifies the
   payment, billing purchase, source ID, amount, currency, and digest before
   moving the placement to `scheduled` or `active`.
4. Payment failure leaves the placement non-serving and retryable only under
   the existing billing-purchase attempt rules. Expired/late/duplicate
   successes use payment reversal and never create a second entitlement.
5. Reconciliation can recover a missed outbox dispatch by comparing accepted
   payment state to placement state; repeat processing is a no-op.

The existing `Orders::BillingPurchase` and `Orders::Payment` status remain the
financial source of truth. The placement never infers payment success from its
own status alone.

## 8. Cancellation and refunds

If the organizer cancels the placement or the event is cancelled, stop serving
it immediately. Calculate a refund from the unserved portion of the immutable
placement interval:

`refund_minor = floor(paid_amount_minor * unserved_seconds / total_seconds)`

A placement cancelled before it starts receives the full amount; a placement
that has fully run receives no refund. The same rule applies to organizer
cancellation and event cancellation. Do not refund more than the original
purchase or the remaining refundable balance across all prior refunds. If the
calculated refund is zero minor units, create no provider refund.

Create the durable, idempotent refund obligation in the same transaction that
stops serving, then submit it after commit through the existing provider
submit, verify, retry, and reconciliation boundary. The existing refund domain
supports ticket-item refunds and full payment reversals, but billing purchases
do not yet have a first-class partial-refund subject. Extend that domain with a
typed partial `billing_purchase_refund` bound to `Orders::BillingPurchase`;
do not fabricate an `OrderItem` or use the event-cancellation reversal path.

Chapa's published V2 contract describes full and partial refunds generically,
but does not establish that every account/payment rail behaves identically.
Treat configured capability as a preflight, not proof that every individual
refund will succeed. For a definitive unsupported-method/account response,
leave the placement stopped and move the durable refund obligation to
`manual_review`, preserving the requested amount, provider error code, and
payment/refund references. Do not mark it succeeded or retry provider
submission blindly. Provide an audited operator resolution that records the
actor, reason, and non-sensitive evidence reference; mark the obligation
succeeded only after the external refund is confirmed. Transient/unknown
outcomes remain processing and are resolved through verification before any
manual action.

The current `Finance::LedgerEntry` is an organizer settlement ledger that
requires organization/event sale facts. Do not post placement revenue or
refunds into organizer balances. Add a separate immutable
`Finance::PlatformBillingEntry` journal for accepted placement charges,
provider-fee evidence when available, and succeeded refunds, keyed
idempotently to payment/refund IDs. A successful provider payment without its
journal/outbox fact is reconcilable and must not be double-posted.

## 9. Data and module boundaries

Add a `Marketing` domain with:

- `Marketing::PlacementOffer`: versioned server-managed offer data (daily rate,
  minimum/maximum interval, currency, active interval, surface, and terms
  version).
- `Marketing::FeaturedPlacement`: event/organization owner, offer and immutable
  purchase snapshot, schedule, lifecycle state, billing purchase/payment
  linkage, idempotency/request digests, and cancellation/refund linkage.
- A focused serving query that returns public event-card inputs only.
- A fail-closed per-surface `max_concurrent_placements` setting. Capacity
  creation is serialized per surface using the shared advisory-lock mechanism
  so purchases for different events cannot oversell the same time window.
- `Finance::PlatformBillingEntry`: immutable platform-side accepted-charge,
  provider-fee, and succeeded-refund facts for billing purchases.

New tables are `marketing_placement_offers`, `marketing_featured_placements`,
and `finance_platform_billing_entries`; each gets its own migration file, with
one `create_table` per migration. Changes to existing
`orders_billing_purchases` and `orders_refunds` edit the original migrations
that created those tables; do not add follow-on alter migrations. This follows
the repository's zero-debt development rule. Database constraints/indexes
enforce valid lifecycle/schedule values, foreign keys, offer snapshot
integrity, idempotency uniqueness, and the bounded public-serving query. A
purchase/cancellation transaction uses the per-surface capacity lock and
locks the event before checking intervals, so concurrent purchases for
different events cannot oversell. Mutations lock the surface/event/placement/
purchase in the documented global lock order.

The offer package remains distinct from `Catalog::Promotion`, whose purpose is
discounting ticket checkout. No generic advertising/credit abstraction is
introduced in v1.

## 10. Failure and safety rules

- Missing idempotency key: 400; same key/same request: replay; same key with
  changed offer, event, or schedule: conflict.
- Chapa initialization timeout/unknown: retain pending payment state and use
  verification/reconciliation; never create an active placement optimistically.
- Invalid or inactive offer, unpublished/private event, closed registration,
  event/organization mismatch, overlapping placement, or invalid schedule:
  reject before provider dispatch.
- Missing/invalid capacity configuration: fail closed and do not sell a
  placement. Full inventory is a typed conflict with a safe next-available
  time when calculable.
- Provider refund unknown/timeout: retain processing state, retry verification,
  and do not reopen placement serving.
- Definitive partial-refund rejection: retain the durable obligation as
  `manual_review`; never mark it refunded or lose the outstanding amount.
- Serializer/policy allowlists explicitly exclude billing internals, provider
  payloads, audit metadata, and other organizations' placement state.
- Automated tests cover concurrent purchases, payment/refund replay, late
  provider success, event cancellation during payment/activation, scheduled
  start, expiration, free RSVP eligibility, sold-out/unpublished filtering,
  and N+1 bounded public serving.

## 11. Rollout gates and open configuration

- Preview/test offers may use explicit seeded ETB amounts. Production offers
  stay disabled until approved ETB package prices and terms are configured.
- G-40's ETB amount-unit concern was subsequently verified in Chapa test mode:
  a request for 513 minor units displayed a 5.13 ETB subtotal on the receipt.
  Treat that as evidence for the tested ETB flow, not a claim about every
  currency or provider contract. The Featured-placement test-mode purchase
  must still reconcile its server-priced amount against checkout, receipt, and
  accepted payment evidence.
- Verify Chapa partial-refund behavior in test mode for a billing purchase
  for each payment method/account configuration intended for production before
  enabling cancellation refunds. If a rail/account refuses the partial refund,
  the manual-review path must be exercised before launch.
- Configure the per-surface concurrency cap, response bound, rotation window,
  daily rate, and minimum/maximum schedule horizon as server-side settings.
  Choose the initial cap to fit the actual Featured UI and preview traffic; do
  not assume six/eight guarantees visibility or sales. Clients cannot
  override these settings.

## 12. Acceptance criteria

1. An authorized owner/admin can list current offers and buy one placement for
   an eligible public paid or free-RSVP event with a future schedule.
2. No ticket order, ticket, registration, or organizer-sale entry is created.
3. Only a verified/accepted Chapa payment makes the placement eligible to
   serve; duplicate callbacks and jobs never duplicate the placement or journal.
4. `GET /public/featured_events` returns a capped, safe, labeled, rotating
   section; `GET /public/events?featured=true` filters the paginated event list
   through the same eligibility query; the ordinary list remains organically
   ordered.
5. Capacity holds prevent overbooking under concurrent purchases across
   different events; expired pending checkouts release capacity.
6. Cancellation hides the placement immediately and creates at most one
   correctly calculated partial/full refund. Refund status is reconciled and
   visible without implying success early; definitive unsupported partial
   refunds remain durable in `manual_review` until auditable resolution.
7. Platform charge/refund journal totals reconcile to accepted provider
   payments, provider fee evidence, and succeeded refunds; organizer payout
   balances remain unchanged.
8. Local and preview tests prove purchase, activation, public display,
   idempotency, cancellation/refund, platform-journal reconciliation, billing
   top-up regression safety, and race safety.

## 13. Implementation plan

The approved implementation plan is
[`docs/superpowers/plans/2026-10-13-featured-event-placements-implementation.md`](../plans/2026-10-13-featured-event-placements-implementation.md).
Credit-based marketing campaigns remain out of scope unless the user
explicitly expands v1.
