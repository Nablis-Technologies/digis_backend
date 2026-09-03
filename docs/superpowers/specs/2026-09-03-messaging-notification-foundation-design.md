# Messaging Notification Foundation Design

**Status:** Design approved during brainstorming on 2026-09-03

## Goal

Build a reusable, transactional notification foundation for the event platform.
It will give authenticated users a durable in-app notification inbox, category
and channel preferences, scheduled delivery, and provider-neutral email/SMS
contracts without introducing marketing campaigns or messaging-credit billing.

Campaign messaging and paid credits will be separate follow-up designs that
consume the delivery contracts defined here.

## Current repository context

The application already has the durable `Core::OutboxEvent` transport and
bounded Solid Queue jobs. Several domains publish notification-shaped events,
but their sender seams default to no-op lambdas. `Events::ScheduleChangedNotificationsJob`
is intentionally an extension point, and `ApplicationMailer` is only a base
mailer. There is no Messaging model, migration, controller, provider adapter,
preference store, or campaign/credit ledger in the current checkout.

The architecture review records the missing capabilities as G9 (campaign
tracking), G9b (pay-per-message pricing), and M4 (notifications). The current
frontend/backend contract plan explicitly excludes notifications. This design
closes only M4's transactional foundation; it does not silently pull G9 or G9b
forward.

## Scope

### Included

- A `Messaging` domain for recipient-owned transactional notifications.
- Durable notification records and one delivery record per channel.
- Category/channel preferences with mandatory transactional categories.
- In-app delivery as the first implemented adapter.
- Explicit provider-neutral email and SMS adapter contracts, with an
  observable unavailable state when no provider is configured.
- Immediate and scheduled delivery through the existing outbox and Solid Queue
  boundaries.
- Recipient-scoped, paginated notification and preference APIs.
- Initial integration with existing user-recipient domain events plus the
  baseline transactional event types listed below.
- Locale-backed notification type definitions and safe data contracts.
- Retention, privacy, idempotency, retry, and observability rules.
- Focused unit, service, integration, concurrency, privacy, and N+1 tests.

### Explicitly excluded

- Marketing campaign creation, audience targeting, templates, links,
  attribution, or campaign analytics.
- Marketing consent/suppression lists beyond the transactional preference
  boundary needed here.
- Messaging credit balances, top-ups, rates, reservations, refunds, or
  provider-cost accounting.
- Chapa or another payment provider integration for messaging credits.
- Real email/SMS provider credentials or production provider selection.
- Admin broadcast tools or organizer campaign UI.
- Delivery to an arbitrary email/phone contact that is not a `Core::User`.
  Existing invitation delivery keeps its encrypted-contact seam until a
  separate external-recipient design exists.

## Design decisions

### 1. Notification hub over the existing outbox

The outbox remains a transport and recovery mechanism. It is not reused as the
user-facing inbox because transport rows do not model read state, per-channel
delivery, preferences, retention, or recipient authorization. Domain commands
continue publishing ID-only payloads with `Core::Outbox::Publish`. A messaging
handler turns a committed event into a notification and delivery rows.

The outbox registry must support ordered handler composition. Existing domain
handlers run before the Messaging projection handler, and every existing
handler is audited for replay safety before composition is enabled. A failed
Messaging handler may replay a successful domain handler, so domain handlers and
injected senders must be idempotent under their existing durable keys.

Exact and namespace registrations share one `Core::Outbox::HandlerRegistry`
owner but use separate internal stores, so a key cannot collide across lookup
types and Dispatch has one typed API without a Hash fallback.

### 2. Separate transactional and marketing semantics

Each notification type declares a category (`transactional`, `security`,
`credential`, or `legal`) and a channel policy. Marketing is a separate future
category with separate consent and billing rules. A user may disable optional
transactional channels, but security, credential, and legally required notices
always retain an in-app delivery.

### 3. In-app first, adapters before providers

The first plan implements the in-app adapter and defines a stable adapter
interface for email and SMS. A missing email/SMS adapter creates an observable
`unavailable` delivery state while the in-app notification remains available;
it never silently drops a required notice. Provider credentials and provider
selection belong to a later provider-configuration plan.

### 4. Database uniqueness is the idempotency boundary

Notification creation and channel delivery creation are protected by unique
indexes, not an application-level "already seen" check. Delivery jobs carry a
deterministic provider request key and claim rows with the same short lock/
lease pattern used by the outbox dispatcher. External calls occur outside
business transactions; provider webhooks, when added, will be deduplicated by
provider event identity.

### 5. Safe projections only

Notification types own an allowlist of data fields. The persisted data is a
small, render-safe projection, never a copy of the domain object or outbox
payload. Tokens, QR/PNR credentials, passwords, provider credentials, raw
contacts, financial secrets, and unrestricted JSON are rejected. User-facing
text resolves through locale entries; controllers and jobs contain no literal
messages.

## Domain model

All new tables use UUIDv7 primary keys, explicit foreign keys, status checks,
indexes for recipient/status/scheduling lookups, and one table per migration
file as required by the repository conventions.

All three Messaging models explicitly define safe
`ransackable_attributes`/`ransackable_associations`; notification and delivery
payload JSON is never searchable by default. These high-volume derived rows do
not include `Core::AuditableModel`; the originating domain outbox/audit event
is the business evidence.

### `messaging_notifications`

One durable notification shown to one authenticated user.

- `user_id` — required FK to `core_users`.
- `notification_type` — registered type key, not an arbitrary class name.
- `category` — registered category used by preference and mandatory-channel
  rules.
- `source_type`, `source_id` — optional polymorphic source for navigation and
  audit context; never a substitute for recipient authorization.
- `data` — required JSONB safe projection validated by the type definition.
- `projection_digest` — lowercase SHA-256 of the canonical projection. It is
  retained after payload erasure so a replay can still distinguish the
  original request from conflicting reuse without retaining the payload.
- `dedupe_key` — deterministic event/type/recipient key with a unique index
  scoped to the recipient.
- `available_at`, `read_at`, `created_at`, `updated_at` — scheduling and inbox
  state.
- `retention_policy_id`, `retain_until`, `erased_at`, and `erasure_reason` —
  retention metadata linked to the Core policy boundary. The policy category
  and its database check constraint must be updated together with the original
  Core retention migration under this repository's migration convention.

`retain_until` is nullable by design: an `erase_payload` policy must provide
positive retention days and produces a deadline, while a `retain` policy leaves
the deadline null. Model validation enforces that the stored deadline matches
the selected policy.

The notification row is the inbox record. Read state belongs here, not on a
delivery row, so reading an in-app notification does not imply that email or
SMS was delivered.

`source_type` is restricted to the first plan's allowlist (`Orders::Order`,
`Orders::Payment`, `Orders::Refund`, `Ticketing::Ticket`,
`Ticketing::TicketTransfer`, `Ticketing::Registration`,
`Ticketing::RegistrationConsentRequirement`, and `Events::Event`). New source
types require an explicit registry and database-check update.

### `messaging_notification_deliveries`

One attempted channel delivery for a notification.

- `notification_id` — required FK.
- `channel` — `in_app`, `email`, or `sms` in the first contract.
- `status` — `pending`, `processing`, `sent`, `delivered`, `failed`,
  `suppressed`, or `unavailable`.
- `provider` and `provider_message_id` — nullable provider metadata; never
  exposed by default to clients.
- `attempts`, `next_attempt_at`, `claimed_at`, and `enqueue_claimed_at` — bounded
  retry, delivery-claim, and scheduler-enqueue lease state.
- `scheduled_at`, `sent_at`, `delivered_at`, `failed_at` — state timestamps.
- `failure_code` and sanitized `failure_detail` — operational diagnosis with
  no secrets or raw provider response bodies.
- deterministic delivery idempotency digest.

Unique `(notification_id, channel)` prevents duplicate channel rows. A
provider-specific unique identity will be added when a real adapter supports
provider callbacks.

### `messaging_notification_preferences`

One user/category/channel choice.

- `user_id` — required FK.
- `category` — registered preference category.
- `channel` — registered channel.
- `enabled` — explicit user choice.
- timestamps and a unique `(user_id, category, channel)` index.

Missing rows resolve to the type's default. Mandatory categories ignore a
disabled optional channel and always create the mandatory in-app delivery.

### Type registry (code, not a table)

`Messaging::NotificationTypes` will define, for each type:

- category and mandatory status;
- default and allowed channels;
- recipient resolver;
- source-aware projection builder plus safe data schema/allowlist;
- locale keys for title/body;
- deduplication-key builder;
- navigation metadata safe for the authenticated client.

This keeps the database generic while preventing arbitrary notification types
or arbitrary JSON from entering it.

Dedupe keys include the authoritative source version or transition identity when
one exists. A second schedule version or credential-generation version must
create a new notification; a second waitlist offer for the same registration
must include the offer's immutable `offer_expires_at` (and event ID) so it does
not collapse onto the first offer; replaying the same identity must return the
existing row.

## Delivery flow

1. A domain command writes its authoritative change and an ID-only outbox row
   in one transaction.
2. `Core::Outbox::Dispatch` invokes the registered messaging handler after the
   transaction commits.
3. The handler resolves the registered recipient and type, validates the safe
   projection, and creates/replays the notification and its channel rows under
   the unique database boundaries.
4. A bounded notification job claims a delivery, invokes the selected adapter
   outside the lock, and records the result.
5. In-app delivery marks its delivery complete once the notification is
   durably visible. Email/SMS adapters are called only when registered and
   permitted by the type and preference policy.
6. Retryable provider errors set `next_attempt_at` and retry within a bounded
   attempt budget. Permanent errors become `failed`; missing configuration is
   `unavailable`. Neither state removes the in-app record.
7. Scheduled rows are selected by `available_at` through a bounded recurring
   sweep. A poisoned row is isolated and aggregated so it cannot starve later
   notifications.

One-to-many events never loop all recipients inside `Core::Outbox::Dispatch`.
The handler enqueues a `Messaging::FanoutNotificationJob` with the outbox event
ID; the job processes at most 100 recipients per page using a stable user-ID
cursor, calls the idempotent publish command for each recipient, aggregates
individual failures, and re-enqueues the next cursor. A crash safely repeats a
page because notification uniqueness deduplicates already-published rows. This
keeps the outbox claim well below `CLAIM_TIMEOUT`.

The minute scheduler claims a short `enqueue_claimed_at` lease before placing
a delivery job on Solid Queue. This lease is separate from the provider-
delivery claim, expires for recovery, and prevents repeated sweeps from
creating duplicate queued jobs while a worker is delayed.

No provider call happens inside the originating order, ticket, event, or
finance transaction. Outbox publication and notification creation are safe to
replay; provider delivery uses an adapter-supplied idempotency key wherever the
provider supports one.

## Initial event integrations

The first plan uses this explicit producer-to-notification map. Every row must
have a real producer before its handler is registered; the two marked producer
additions are part of this plan.

| Producer event | Notification type | Recipient | Delivery shape |
|---|---|---|---|
| `orders.payment.fulfilled` | `payment_succeeded` | order buyer | one recipient |
| `orders.payment.failed` *(new producer in Orders processing)* | `payment_failed` | payment order buyer | one recipient |
| `orders.refund.succeeded` | `refund_succeeded` | payment order buyer | one recipient |
| `orders.refund.failed` | `refund_failed` | payment order buyer | one recipient |
| `ticketing.package_issued` | `ticket_issued` | ticket owner | one recipient |
| `ticketing.credential_generation_replaced` | `credential_replaced` | ticket owner | one recipient |
| `ticketing.ticket_transfer.accepted` | `transfer_received` | transfer recipient | one recipient |
| `ticketing.registration.waitlist_offer_created` | `waitlist_offer_created` | registration user | one recipient |
| `ticketing.registration.waitlist_offer_expired` *(new producer in Waitlist)* | `waitlist_offer_expired` | registration user | one recipient |
| `ticketing.registration.rejected` | `registration_rejected` | registration user | one recipient |
| `ticketing.registration_consent.reminder_due` | `consent_reminder` | registration user | one recipient |
| `events.schedule_changed` | `schedule_changed` | active owners/admins of the event's primary or active collaborator organizations, active ticket holders for affected dates, and current registrations whose selected or fixed product date is affected | bounded fan-out |

Invitation creation with an unclaimed encrypted contact is intentionally not a
user notification. Its existing sender receives the invitation ID and decrypts
the one-time token only at its delivery boundary. Marketing recipients and
organizer broadcasts are deferred to the campaign plan. The old
`RegistrationNotificationJob` path for waitlist/rejection/issuance events is
removed once the Messaging handler is wired, so each user-recipient event has
one durable notification path rather than a no-op sender plus a notification
handler.

`consent_reminder_sender` and `credential_delivery_sender` remain separate
extension seams. They are currently no-op by default and are not duplicates of
the in-app inbox: credential delivery handles one-time credential transport,
while consent delivery may target an encrypted contact. A future provider
initializer must compose or replace those seams explicitly before enabling an
email/SMS adapter for the same event.

## API contract

All endpoints require authentication and are scoped to `current_user`; no admin
read-all surface is included in this foundation.

- `GET /notifications` — paginated own inbox; supports unread, category, and
  type filters plus the repository's normal ordering/pagination parameters.
- `GET /notifications/:id` — own notification detail.
- `POST /notifications/:id/read` — idempotent mark-read command.
- `GET /notification_preferences` — own category/channel preferences with
  defaults resolved from the type registry.
- `PATCH /notification_preferences` — idempotent update of allowed choices.

Mutating preference updates follow the repository's `Idempotency-Key` resolver
and localized error contract. Mark-read is a naturally idempotent state set and
does not require a durable request receipt; its repeated request remains a
no-op. Serializers expose notification identity, type,
category, safe data, read state, timestamps, and sanitized channel summaries;
they do not expose provider credentials, raw provider payloads, or internal
outbox details. Responses use the existing `Core::JsonResponse`, pagination,
serializer-profile, and policy-visibility conventions. Postman requests and
examples are part of the implementation gate.

## Authorization, privacy, and retention

- `Messaging::NotificationPolicy` scopes reads and writes to the recipient's
  own rows. A source aggregate does not grant access to another user's
  notification.
- Preference updates can only affect the current user and cannot suppress
  security, credential, or legal notices.
- Type-specific projection builders reject forbidden keys before persistence.
- Logs and metrics use notification/delivery IDs, type, channel, and status;
  they do not log message bodies, contacts, credentials, or provider secrets.
- Notification payload retention is registered through the Core retention
  policy boundary. Payload erasure preserves the structural delivery/audit
  row and marks the projection unavailable rather than deleting evidence.
- `Messaging::RetentionScopeResolver` resolves polymorphic sources to event,
  registration, and user hold scopes in bounded type-grouped queries; purge
  performs the final hold check after acquiring the shared advisory locks.
- Existing commercial term notices remain the authoritative in-app evidence for
  commercial-term delivery; the notification inbox must not replace or mutate
  those rows.

## Testing and acceptance gates

The implementation plan must provide:

- model and migration checks for foreign keys, statuses, indexes, uniqueness,
  and safe JSON validation;
- notification-type registry tests for recipient resolution, mandatory
  channels, locale keys, allowlists, and deterministic deduplication;
- service tests for new/replayed notifications, concurrent creation, preference
  enforcement, scheduled selection, retry/backoff, unavailable providers, and
  no-send-before-commit. Replay assertions use the shared `assert_idempotent`
  or `assert_audit_idempotent` helper rather than hand-rolled count checks;
- adapter contract tests for in-app plus fake email/SMS adapters, including
  provider idempotency and sanitized failures;
- integration tests for every endpoint, authentication/ownership, pagination,
  filters, Idempotency-Key requirements, replay behavior, and response privacy;
- outbox integration tests proving existing domain events produce exactly one
  notification and one delivery per channel;
- strict-loading and `N_PLUS_ONE=1` coverage for list/detail/preference paths;
- locale, route, serializer, Postman, migration, and seed convergence checks;
- bounded-job tests proving one failed notification does not starve the batch;
- retention tests proving payload erasure does not erase structural evidence.

## Follow-up handoffs

The campaign plan may consume:

- the notification type registry and safe rendering contract;
- provider-neutral delivery adapters and status mapping;
- recipient preference and suppression interfaces;
- outbox/job retry and observability conventions.

It must add its own organization/event campaign, audience snapshot, recipient
delivery, consent, tracking-link, and analytics records. It must not overload
`messaging_notifications` with campaign billing state.

The credits/billing plan may consume:

- delivery status and provider cost hooks;
- channel/provider capabilities;
- organization authorization and audit conventions.

It must add a separate organization-scoped immutable messaging-credit ledger,
rate versions, reservation/settlement/refund commands, and Chapa/Orders top-up
integration. It must never mutate the organizer payout ledger or infer a
message charge from a notification row alone.

## Rejected alternatives

- **Direct provider calls from domain commands:** rejected because provider
  outages would couple external side effects to business transactions and make
  retries/non-duplication unreliable.
- **Using outbox rows as inbox rows:** rejected because transport evidence lacks
  recipient read state, per-channel status, preferences, and safe client
  projections.
- **Adding campaign credits now:** rejected because campaign consent, provider
  cost, failed-delivery refunds, and organizer billing are independent
  liabilities and require a separate ledger design.
- **Storing provider credentials or plaintext contact secrets in notification
  rows/jobs:** rejected by the existing privacy and outbox payload boundaries.

There are no unresolved design decisions for the notification foundation. The
next gate is implementation-plan writing after this specification is reviewed.
