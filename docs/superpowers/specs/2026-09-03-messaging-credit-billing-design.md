# Messaging Credit and Billing Design

**Status:** Design direction approved during brainstorming on 2026-09-03;
formal specification saved for user review.

## Goal

Provide organizers with prepaid, channel-specific messaging credits for future
marketing campaigns while keeping payment evidence, provider delivery, and
organizer event-finance ledgers separate and auditable.

This design follows the notification foundation and must be implemented before
the Marketing Campaigns design. It does not add campaign targeting, templates,
or broadcast behavior.

## Repository context

The repository already provides:

- `Messaging::Notification`, `Messaging::NotificationDelivery`, notification
  preferences, provider adapters, bounded delivery jobs, and the outbox
  transport;
- immutable `Orders::Order`/payment-attempt/provider-event contracts for event
  commerce;
- `Finance::LedgerEntry` and payout ledgers for organizer event proceeds; and
- Chapa through `Payments::Providers::Registry` and the existing Orders
  payment boundary.

The notification foundation intentionally excludes campaign credits, campaign
consent, and provider billing. This design adds only the credit/rate/top-up
boundary required by campaigns. It must not repurpose `messaging_notifications`
as a wallet or mutate the Finance organizer ledger.

## Product decisions

1. Credits are organization-owned, not user-owned or event-owned. An
   organization can run several events and use one balance without manually
   transferring funds between event wallets.
2. SMS and email have separate balances. Credits are integer channel units and
   cannot be silently converted between channels.
3. Only explicitly authorized organization members can purchase or spend
   credits. Platform administrators can inspect and make audited adjustments.
4. Campaign recipients must satisfy the future campaign consent and
   relationship rules. Transactional notifications never consume campaign
   credits.
5. A reservation is released when a recipient is suppressed before a provider
   send. A successful provider send consumes the reservation. A permanent
   provider failure refunds it. A retryable failure keeps it reserved until it
   succeeds, is permanently failed, or expires under policy.
6. Top-ups are paid through the existing Orders/provider contract. A top-up is
   never credited merely because a checkout or Chapa initialization succeeded;
   only the durable accepted-payment boundary grants credits.
7. Rate versions are immutable. A campaign records the rate version used for
   its estimate and reservations; later price changes never rewrite history.
8. No plaintext provider credentials, payment tokens, recipient contact
   values, or complete provider payloads are stored in credit rows or jobs.

## Scope

### Included

- Organization/channel credit accounts and an append-only credit ledger.
- Immutable channel rate versions, effective dates, and optional volume tiers.
- Reservation, consumption, release, refund, expiry, and audited adjustment
  commands with database idempotency boundaries.
- Cost estimation that returns the selected rate version and required credit
  quantity before a campaign is launched.
- A billing purchase boundary that uses Orders and Chapa payment attempts.
- Accepted-payment outbox handling that grants credits exactly once.
- Safe credit balance/ledger APIs for authorized organizer and administrator
  views, with pagination and localized errors.
- Provider-cost observations that are operational evidence and do not alter
  the organizer credit balance after a charge is committed.
- Reconciliation jobs for unresolved top-ups and credit reservations.
- Seeds, Postman examples, privacy checks, concurrency tests, and N+1 gates.

### Explicitly excluded

- Campaign records, audience selection, marketing consent, templates,
  scheduling, tracking links, opens/clicks, or campaign APIs.
- Organizer payout balances, event-sale ledgers, refunds for ticket orders, or
  Chapa organizer subaccounts.
- Postpaid invoicing, subscriptions, credit limits, debt collection, or tax
  invoices.
- Automatic bank payouts or converting unused credits to cash.
- A universal wallet shared with ticket sales or Finance.
- Real SMS/email provider credentials. Provider adapters remain the delivery
  plan's explicit seam.

## Alternatives considered

### Organization credit accounts (selected)

Each organization owns one account per channel. Campaigns reserve against that
account, while the immutable ledger records every grant and outcome. This fits
the product boundary, supports multiple events, and keeps accounting clear.

### Event-scoped wallets (rejected)

Event wallets make campaign reporting look simple, but they fragment an
organizer's prepaid balance across events and require transfers or refunds when
an event is cancelled. They also make organization-wide campaigns awkward.

### Shared Finance wallet (rejected)

Putting messaging credits in the organizer proceeds ledger couples marketing
spend to ticket settlement, mixes two different liabilities, and makes payout
reconciliation ambiguous. Credit billing must remain a Messaging concern with
Orders as its payment boundary.

## Domain model

All new tables use UUIDv7 primary keys, explicit foreign keys, status checks,
appropriate indexes, and one table per migration. No mutable balance counter is
the source of truth; balances are derived from immutable entries while a stable
account row provides a deterministic lock.

### `messaging_credit_accounts`

One stable lock and ownership record for an organization/channel pair.

- `organization_id` — required FK to `organizations_organizations`.
- `channel` — `sms` or `email`.
- timestamps.

Unique `(organization_id, channel)` is the account boundary. The row contains
no balance that can drift from the ledger.

### `messaging_credit_rate_versions`

An immutable price definition selected by estimates and reservations.

- `organization_id` — nullable FK; null means the global rate and a value
  means an organization-specific negotiated rate.
- `channel` — `sms` or `email`.
- `version` — positive integer within a channel.
- `currency` — ISO currency, initially `ETB`.
- `unit_price_minor` — organizer price per credit in integer minor units.
- `provider_cost_minor` — optional observed/estimated platform cost snapshot.
- `country_code` — optional destination country scope; `ET` is the initial
  default for phone-first campaigns.
- `volume_tiers` — validated JSON array of non-overlapping quantity ranges and
  integer prices.
- `effective_from`, `effective_until`, `status` (`draft`, `active`, `retired`).
- creator and timestamps.

The database and model reject overlapping active definitions for the same
channel/country scope and effective interval. A rate is never edited after it
has been used by a top-up or reservation; a new version supersedes it.

### Rate resolution and administration

`Messaging::ResolveCreditRate` selects exactly one rate for an organization,
channel, destination country, quantity, and charge currency at a point in time.
The deterministic precedence is:

1. an active organization-specific rate for the exact country and channel;
2. an active global rate for the exact country and channel;
3. an active organization-specific default-country rate for the channel; and
4. an active global default-country rate for the channel.

Within one scope, the resolver chooses the active version whose effective
interval contains the request and whose volume tier contains the quantity. A
missing or ambiguous match is a typed `rate_unavailable` failure; it never
silently falls back to a different currency or channel. The selected rate
version, tier, and resolver inputs are copied into the estimate, top-up, and
campaign reservation records.

Platform administrators manage rates through explicit draft → active → retired
commands. Activation rejects overlapping effective intervals and requires a
new version when any price, provider-cost, country, or tier changes. Organizer
members can read the rates that apply to their organization but cannot activate
or alter them. Every rate command is idempotent and audited without placing
provider credentials or recipient data in the audit payload.

### `messaging_credit_ledger_entries`

Append-only evidence for credit grants and outcomes.

- `credit_account_id` — required FK.
- `entry_type` — `top_up`, `reserve`, `consume`, `release`, `refund`,
  `expire`, or `adjustment`.
- `quantity` — positive integer credit units.
- `available_delta` — signed integer delta applied to available credits;
  reserve consumes availability, release/refund restore it, and consume is a
  zero-delta terminal evidence row.
- `rate_version_id` — required for campaign charges and optional for grants or
  adjustments.
- `reference_type`, `reference_id` — allowlisted source such as a billing
  purchase, campaign reservation, delivery, or admin adjustment.
- `idempotency_key_digest` — lowercase SHA-256, unique per account and
  operation identity.
- sanitized metadata and timestamps.

Rows are never updated or deleted. A database trigger rejects changes after
insert. Available balance is the sum of `available_delta`; consumed quantity
is derived from `consume` rows. Negative available balance is rejected while
holding the account row and the relevant active reservations in a deterministic
order.

### `messaging_credit_reservations`

The mutable per-campaign-recipient hold that connects a planned delivery to
credit evidence.

- `credit_account_id` and `organization_id` — required FKs.
- `source_type`, `source_id` — an allowlisted source identity for the future
  Campaigns plan (initially `Messaging::CampaignRecipient`); these are not a
  foreign key to a campaign table because Campaigns is a later plan.
- `channel`, `quantity`, and `rate_version_id` snapshots.
- `status` — `reserved`, `consumed`, `released`, `refunded`, or `expired`.
- `idempotency_key_digest`, `reserved_at`, `resolved_at`, and timestamps.
- sanitized `resolution_code`.

Unique `(source_type, source_id, channel)` when a source is present, together
with the account-scoped idempotency digest, prevents a retry from holding the
same recipient twice. State transitions append the corresponding ledger
evidence in one transaction. A reservation cannot change channel, quantity,
organization, or rate version after creation.

### `messaging_credit_top_ups`

The Messaging-owned billing intent that connects a purchased quantity to an
Orders payment boundary.

- `organization_id`, `credit_account_id`, `channel`, `quantity`, and
  `rate_version_id` snapshots.
- `currency`, `amount_minor`, and immutable quote/price digest.
- `status` — `created`, `pending_payment`, `paid`, `cancelled`, `failed`, or
  `reversed`.
- `orders_billing_purchase_id` and accepted payment identity once the Orders
  integration creates one; both are nullable until linked.
- `idempotency_key_digest`, provider-independent reference, and timestamps.

The top-up row is not itself a payment acceptance. Credit grant occurs only
after the Orders accepted-payment event is durably processed and deduplicated.
Late success after cancellation creates a reversal obligation rather than a
second grant.

## Top-up flow

1. An authorized organization member requests an SMS or email quantity with an
   `Idempotency-Key`.
2. `Messaging::EstimateCreditTopUp` selects one active rate version, validates
   volume tiers, and returns quantity, unit price, total, currency, and rate
   identity. It never grants credits.
3. `Messaging::CreateCreditTopUp` persists the immutable purchase intent and
   invokes the Orders billing-purchase seam. It does not call Chapa directly.
4. Orders creates the durable payment attempt and invokes the registered Chapa
   adapter under its existing idempotency/provider-event rules.
5. `Orders::AcceptBillingPayment` publishes
   `orders.billing_payment.accepted` in the same transaction as the billing
   payment transition. A failed billing payment publishes
   `orders.billing_payment.failed`; a late reversal publishes
   `orders.billing_payment.reversed`.
6. A Messaging outbox handler claims `orders.billing_payment.accepted` and calls
   `Messaging::GrantTopUpCredits`. The command locks the top-up and account,
   verifies the accepted payment identity and amount, appends one `top_up`
   entry, and marks the top-up `paid`.
7. Replaying the outbox event returns the existing grant; a different payment,
   organization, amount, or rate snapshot returns a typed conflict.
8. A payment reversal appends a `refund`/`reversed` evidence row and never
   silently removes the original grant.

The Orders billing-purchase seam must not create an event ticket, placeholder
event, or fake fulfillment record merely to satisfy the existing event-sales
shape. The implementation plan must extend the payment boundary explicitly for
non-event platform purchases while preserving event-order invariants.

### Orders billing-payment invariants

`orders_payments` supports two explicit subjects: an event `order_id` or an
`orders_billing_purchases` `billing_purchase_id`. Both columns are nullable,
but a database check requires exactly one to be present. Each subject has its
own attempt, accepted-payment, and current-attempt unique indexes:

- `idx_payments_on_order_and_attempt` and
  `idx_payments_on_billing_purchase_and_attempt`;
- one accepted payment per order or billing purchase; and
- one current `created`/`processing` attempt per order or billing purchase.

The existing payment snapshot trigger must branch on the subject. For an event
order it compares amount/currency with `orders_orders` and keeps the existing
Commercial-signature consistency check. For a billing purchase it compares
amount/currency with `orders_billing_purchases` and compares the stored
`billing_purchase_price_digest` snapshot with the purchase digest. It must not
query `orders_orders` when `order_id` is null.

Event-order payments retain `commercial_signature`; billing payments use the
separate billing-purchase price digest. The model and database checks require
the digest appropriate to the selected subject, preventing an event fee
signature from being reused as a credit-price proof.

## Campaign reservation and delivery flow

The later Campaigns plan owns campaign and recipient rows. It calls this plan's
commands as follows:

1. Resolve a consented audience snapshot and rate version.
2. Estimate the required channel quantity and show it to the organizer.
3. Lock the organization/channel account, derive available credits, and create
   bounded reservations. If any page cannot be funded, no recipient on that
   page is released to sending.
4. For a preference/consent suppression before provider invocation, transition
   the reservation to `released` and append release evidence. No provider call
   occurs and no credit is charged.
5. For a successful provider delivery, a standalone credit-settlement command
   transitions to `consumed` and appends a zero-delta consume evidence row.
6. For a permanent provider failure, the same standalone command transitions
   to `refunded` and restores the reserved quantity through a refund ledger
   entry.
7. For a retryable failure, leave the reservation `reserved`; delivery retry
   owns the next attempt and cannot create a second reservation.
8. A cancelled or expired campaign releases every unresolved reservation in
   bounded, cursor-based jobs.

Campaign jobs carry IDs, rate/reservation identities, and cursors only. They do
not carry contact values, provider credentials, or message bodies.

## Consistency and safety invariants

- Organization and channel are immutable on accounts, rates, reservations, and
  ledger entries.
- Every mutating command requires `Idempotency-Key`; missing or malformed keys
  return the shared `400` contract.
- Database unique constraints, not an app-level pre-check, are the replay
  boundary. `RecordNotUnique` is translated into replay or conflict after
  canonical request-digest comparison.
- Account, reservation, and top-up locks use one documented order to prevent
  deadlocks. Provider calls never occur while those locks are held.
- A credit balance can never become negative. Insufficient funds fail before
  any reservation row is committed.
- The ledger is append-only. Corrections append adjustment/refund evidence;
  they never edit historical rows.
- Suppression before provider invocation is free to the organizer. A provider
  call that actually happened is charged or refunded according to its canonical
  delivery result, not according to a local guess.
- A payment accepted once grants once. A late reversal creates a compensating
  entry and never deletes the original grant.
- Provider cost metadata is operational evidence only; it cannot rewrite the
  organizer-facing rate or a committed credit quantity.

## API surface

The implementation plan will add authenticated, organization-scoped endpoints
using the existing `success/data/pagination` envelope:

- `GET /organizations/:organization_id/messaging/credits` — separate SMS and
  email available/reserved/consumed summaries.
- `GET /organizations/:organization_id/messaging/credit_ledger` — paginated,
  filterable, safe ledger evidence without provider secrets.
- `GET /organizations/:organization_id/messaging/credit_rates` — list the
  active and historical rate versions applicable to the organization; the
  caller may read but never activate or alter them.
- `POST /organizations/:organization_id/messaging/credit_estimates` — quote a
  channel quantity and return the selected rate version.
- `POST /organizations/:organization_id/messaging/credit_top_ups` — create a
  top-up intent and return the Orders payment boundary/reference.
- `GET /organizations/:organization_id/messaging/credit_top_ups/:id` — show
  top-up status and accepted-payment evidence safe for the caller.

Administrative rate management and audited adjustments use separate admin
routes and policies:

- `GET /admin/messaging/credit_rates` — list rate versions with filters and
  effective status.
- `POST /admin/messaging/credit_rates` — create a draft version.
- `POST /admin/messaging/credit_rates/:id/activate` — activate one version
  after overlap and tier validation.
- `POST /admin/messaging/credit_rates/:id/retire` — retire a version that is
  no longer selectable while preserving historical snapshots.
- `POST /admin/organizations/:organization_id/messaging/credit_adjustments` —
  append a signed, reasoned manual adjustment with an idempotency key.

No endpoint exposes raw ledger metadata, provider credentials, payment tokens,
or another organization's balance.

`CreditEstimatesController` authorizes `Messaging::CreditTopUpPolicy#estimate?`
after loading the organization scope, so estimates use the same membership
boundary as top-up creation without inventing a rate-management permission.

All writes use the shared `Core::IdempotencyKeyResolver`; serializers expose
channel, quantity, currency, rate version, status, timestamps, and safe error
codes only. Postman requests and examples are part of implementation.

## Errors and reconciliation

Typed errors include invalid channel, invalid quantity, rate unavailable,
insufficient credits, top-up conflict, payment not accepted, reservation
already resolved, credit account unavailable, and provider/billing dependency
unavailable. Messages are locale-backed.

Reconciliation jobs inspect:

- paid top-ups without a grant;
- grants whose accepted payment was reversed;
- reservations stuck past their retry/expiry policy;
- ledger totals that do not match reservation and delivery terminal evidence;
  and
- provider-cost observations missing from a completed delivery.

Reconciliation may append a documented compensating entry or alert an operator;
it never edits a historical ledger row or invents provider liquidity.

## Privacy, retention, and operations

Credit rows contain identifiers and numeric quantities, not message bodies or
recipient contact details. Retention follows the Core policy for billing and
operational evidence. High-volume credit and reservation rows are not
`Core::AuditableModel`; command audit/outbox evidence records the actor and
identity without duplicating sensitive payloads.

Metrics include reserved/consumed/released/refunded quantities by channel,
top-up acceptance latency, unresolved reservation age, and provider-cost
variance. Logs contain IDs, statuses, and typed codes only.

## Acceptance requirements for the implementation plan

The implementation plan must prove, with `N_PLUS_ONE=1` where applicable:

- migrations, foreign keys, checks, append-only trigger, indexes, and unique
  idempotency boundaries;
- active-rate selection, volume-tier calculation, effective-date behavior, and
  immutable snapshots;
- concurrent reservations never overspend an account;
- duplicate top-up requests and duplicate accepted-payment outbox events grant
  exactly once;
- payment failure, cancellation, late success, and reversal paths never grant
  or consume incorrectly;
- suppression releases credit without a provider call;
- successful, retryable, permanent-failure, and expired delivery outcomes map
  to the correct reservation/ledger evidence;
- organization authorization and serializer visibility prevent cross-tenant
  balance or ledger leakage;
- pagination/order/filter contracts and localized errors;
- Postman, seeds, route checks, Zeitwerk, RuboCop, Brakeman, and full-suite
  verification; and
- no campaign targeting, consent list, organizer payout, or Finance ledger
  behavior enters this plan.

## Campaign handoff

After this plan is implemented and accepted, the separate Marketing Campaigns
design will own campaigns, consented audience snapshots, templates, scheduling,
tracked links, delivery analytics, and organizer/admin campaign APIs. It must
consume these credit commands and the existing notification delivery seam. It
must not create a second balance, sender, provider call path, or ledger.
