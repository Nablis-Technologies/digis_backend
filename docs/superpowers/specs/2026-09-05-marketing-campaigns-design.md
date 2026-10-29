# Marketing Campaigns Design

**Status:** Draft for review

**Date:** 2026-09-05

**Prerequisites:** Messaging Notification Foundation and Messaging Credit/Billing
are acceptance-green. The repository owner must merge Credit/Billing before this
design enters implementation.

## Goal

Give organizers a simple, auditable way to send one-channel marketing campaigns
to relevant event audiences and organizer-managed contacts, while reusing the
existing Messaging delivery, outbox, provider, and credit contracts.

The feature must be useful for an organizer who runs several events, but it
must not create a second wallet, a second provider pipeline, or a second
transactional notification system.

## Product decisions

1. **One channel per campaign.** At creation, the organizer chooses SMS or
   Email. The channel cannot change after the campaign is created. A campaign
   therefore has one channel-specific template, eligibility policy, credit
   estimate, delivery stream, and report.
2. **Fixed credit units, configurable prices.** One SMS credit is one
   provider-billed physical SMS segment; one Email credit is one recipient
   delivery. A message containing GSM-7 text, Unicode/Amharic text, emoji, or
   enough characters to concatenate consumes the exact number of segments it
   requires. `CreditRateVersion` configures the money price of each credit,
   including volume tiers, organization overrides, currency, country scope,
   and future provider-cost changes; it never changes what a credit means. The
   segment counter uses 160/153 septets for GSM-7 and 70/67 UTF-16 code units
   for UCS-2/Unicode concatenation; GSM-7 extension characters count as two
   septets and non-BMP emoji count as two UTF-16 units.
3. **Two audience families.** Organizers can select first-party audiences and
   reusable organizer-managed contact lists in the same campaign.
4. **First-party audiences.** The v1 audience builder exposes registrants,
   ticket holders, past event-goers, and explicit organization subscribers.
   It does not expose arbitrary platform-wide targeting. Selecting a
   relationship audience does not silently imply marketing permission; the
   organizer must attest to the selected audience at launch.
5. **Organizer lists.** Lists support CSV upload and manual entry, are saved as
   named reusable lists, and can be updated with an explicit append or replace
   operation.
6. **Organizer attestation.** On each list import and campaign launch, the
   organizer attests that the selected list or first-party relationship
   audience may receive the selected marketing channel. The system records the
   actor, organization, list/campaign, source label, and timestamp. This is a
   product control, not a claim that the platform independently proved
   consent.
7. **Suppression always wins.** Global unsubscribe, channel suppression,
   invalid contact data, and organization-level blocks prevent delivery even
   when an organizer has attested to a list. Suppressed recipients do not
   consume credits.
8. **Audience union.** Multiple selected sources are combined as a union and
   deduplicated by normalized channel address. A person receives at most one
   delivery per campaign.
9. **Organizer-controlled sending.** An authorized organizer reviews the
   audience preview, message, and cost, attests to the selected audience, then
   explicitly sends or schedules the campaign. There is no per-campaign
   platform approval in v1. Authorization, attestation, credit, rate-limit,
   and audit checks remain mandatory.
10. **Send now or schedule.** Scheduled times are interpreted in the
    valid IANA timezone captured on the campaign. An event timezone may prefill
    the field; otherwise the organizer supplies it. A scheduled campaign can
    be canceled before dispatch begins.
11. **Versioned localized templates.** Templates have immutable versions and
    locale variants. Only allowlisted variables can be interpolated; unknown
    variables fail validation before launch. Delivery resolves the same
    allowlisted variables for each recipient, using a neutral fallback for
    missing values; provider calls never receive literal template tokens.
12. **Campaign-level tracking.** Links are tracked by campaign and channel via
    the existing `Links::ShortLink` capability. Reports expose aggregate clicks, not
    recipient-level link attribution.
13. **Reserve at launch.** The exact eligible audience count and selected rate
    version are quoted first. At launch, one aggregate hold reserves the full
    eligible quantity before dispatch. Suppressed recipients never receive an
    allocation; permanent provider failures refund their allocated quantity;
    successful sends consume it.
14. **No transactional mixing.** Campaign records and deliveries are separate
    from recipient-owned transactional `Messaging::Notification` rows. They
    reuse the provider adapter, delivery result, outbox, retry, and bounded
    worker seams. Marketing delivery must never appear as a transactional inbox
    item by accident.
15. **Aggregate launch hold.** A campaign reserves one aggregate credit hold at
    launch rather than acquiring the organization account lock once per
    recipient. Delivery batches allocate and settle slices of that hold with
    idempotent allocation evidence. The hold is released for unclaimed work on
    abort/cancel and is never allowed to become a mutable balance counter.
16. **Unsubscribe ingress.** SMS opt-out is received through a verified
    provider inbound webhook (including `STOP`); email opt-out is received
    through a tokenized public unsubscribe endpoint and standard
    `List-Unsubscribe` headers. Both paths update the same suppression boundary
    idempotently.
17. **Pause then abort.** Pause prevents new delivery batches from claiming
    recipients. An explicit abort is available after sending begins; it stops
    future claims, releases the unallocated aggregate hold, and moves the
    campaign to terminal `canceled` with reason `aborted`.
18. **Bounded list imports.** Contact-list imports run in
    `ImportCampaignContactListJob` with a 5 MB file limit, 10,000 rows per
    import, and 50 saved lists per organization. The job emits an import report
    and carries only list/import IDs. First-party audience materialization is
    capped at 10,000 candidates per snapshot; larger audiences fail explicitly
    rather than exhausting worker memory.
19. **Missing-variable fallback.** A missing `first_name` renders a configured
    neutral fallback such as `there`; missing contextual values such as links or
    venue names render as empty text. The resolved message is shown in the
    pre-launch preview.
20. **Historical audience basis.** Organizers choose whether a past-event
    segment means issued/registered people or checked-in attendees. The choice
    is captured in the audience snapshot and attestation.
21. **Configurable volume policy.** Admin policy controls per-organization and
    per-channel daily/monthly campaign limits. The organizer sees remaining
    quota before launch and a typed limit error when a request exceeds it. Quota
    measures launched send attempts using quoted units, including canceled and
    failed campaigns, to prevent cancel/relaunch abuse.
22. **Template ownership.** Admins may publish safe localized baseline
    templates; organizers may create and version custom templates within the
    same variable and content-safety rules.
23. **Quote pinning.** Estimate persists the exact rate-version ID, credit
    quantity, digest, and a 15-minute expiry on the campaign. Launch must
    present the same quote identity; a mismatch or expired quote fails closed
    and never silently re-resolves a new price. The digest is
    `Core::KeyedDigest.digest(namespace: "messaging-campaign-quote", value:
    "<campaign_id>:<rate_version_id>:<quantity>:<quoted_at.to_i>")`.
24. **Scheduled launch handoff.** Launch publishes
    `messaging.campaign.launched` with campaign/hold IDs and dispatch time. Its
    exact handler starts immediate fan-out or leaves scheduled work for the
    bounded scheduler; replay is idempotent.
25. **Audience preparation.** First-party snapshots and per-recipient message
    quantities are prepared asynchronously in bounded insert batches. Estimate
    and launch return progress until the snapshot is ready instead of doing an
    unbounded read/render/insert in an HTTP request.
26. **Import reports and abuse limits.** Every import exposes an authorized
    rejected-row report with spreadsheet-formula sanitization. Public
    unsubscribe and inbound webhook routes have explicit cache-backed request
    limits, and unsubscribe tokens use a 30-day `MessageVerifier` purpose.

## Scope

### Included

- Organization-owned campaigns with a fixed `sms` or `email` channel.
- Reusable named contact lists with CSV and manual entry.
- First-party event/subscriber audience selectors.
- Union/deduplication and immutable launch-time audience snapshots.
- Organizer attestation records and suppression/unsubscribe enforcement.
- Versioned localized templates with safe variable validation.
- Draft, send-now, scheduled, cancel, pause, abort, sending, completed, and
  failed campaign lifecycle behavior.
- Credit estimation, launch-time reservation, delivery settlement, and
  reconciliation through Messaging Credit/Billing.
- Bounded, retryable delivery through the existing provider registry and
  outbox infrastructure.
- Campaign-level tracked links and aggregate delivery/click analytics.
- Aggregate launch holds with per-delivery allocation and settlement evidence.
- Verified SMS/email unsubscribe ingress and suppression APIs.
- Asynchronous bounded contact-list imports and configurable send quotas.
- Asynchronous bounded audience snapshot preparation and authorized import
  rejection reports.
- Organizer APIs, admin inspection/operational APIs, serializers, policies,
  Postman examples, seeds, and focused/full acceptance tests.

### Explicitly excluded

- A shared wallet or balance counter outside Messaging Credit/Billing.
- Direct Chapa calls from Campaigns or campaign-specific provider credentials.
- Multi-channel campaigns; an organizer creates one SMS and one Email campaign
  when both channels are desired.
- Recipient-level click/open attribution, behavioral profiling, or selling
  audience data.
- Arbitrary platform-wide targeting without an organization relationship or
  explicit subscription.
- Provider-specific template authoring or provider-specific delivery logic in
  Campaigns.
- Automated platform approval of every campaign.
- Credit conversion to cash, postpaid invoicing, subscriptions, or debt.

## Existing contracts to consume

Campaigns depends on these existing boundaries and must not duplicate them:

- `Messaging::ResolveCreditRate` / credit estimate services select an immutable
  channel rate and return the rate version used for the quote.
- `Messaging::CreditAccounts::Reserve`, `Consume`, `Release`, `Refund`, and
  `Expire` own the append-only credit ledger and idempotency boundary. The
  campaign plan adds an aggregate campaign-hold command/source identity to this
  boundary; it does not call the per-recipient `Reserve` command 10,000 times
  from an HTTP request.
- `Messaging::Providers::Registry`, adapter, and `DeliveryResult` own provider
  selection and sanitized delivery outcomes. Campaigns never call Chapa,
  email, or SMS providers directly.
- `Core::Outbox` carries only identifiers and safe event metadata. Campaign
  payloads and contact values do not go into outbox rows or job arguments.
- `Core::Outbox` uses the exact `messaging.campaign.launched` event contract:
  topic `messaging`, payload `{ campaign_id, credit_hold_id, dispatch_at,
  launch_version }`, and idempotency key
  `messaging-campaign-launched-<campaign_id>-v<launch_version>`.
- Existing bounded fan-out and notification retry patterns provide the worker
  shape. Campaign fan-out must remain outside a long-held outbox claim.
- `Links::ShortLink` owns tracked-link creation and redirect analytics. Campaign
  links use `custom_url` plus `utm_campaign`, `utm_source`, and `utm_medium`; a
  campaign target type is not added to the shared allowlist.
- Organization authorization, `Core::IdempotencyKeyResolver`, serializer
  profiles, `VISIBILITY`, pagination, and `Core::JsonResponse` remain the API
  conventions.

## User experience

### Create and launch flow

1. **Choose channel:** `SMS Campaign` or `Email Campaign`. The choice is
   required and immutable.
2. **Name campaign:** enter an internal name and select the organization/event
   context. The campaign timezone is prefilled from the event when available;
   otherwise the organizer selects a valid IANA timezone before scheduling.
3. **Choose audience:** select one or more event/subscriber segments and/or
   reusable contact lists. The UI displays the union count and explains how
   duplicates are removed.
4. **Manage lists:** upload a CSV or add contacts manually. CSV processing is
   asynchronous; a dry-run/import report shows accepted, duplicate, invalid,
   suppressed, and missing-channel rows before the organizer confirms append or
   replace. The organizer can download the rejected-row report.
5. **Compose:** select a template version, locale variants, and allowlisted
   variables. SMS GSM-7/UCS-2 segment estimates and email subject/body
   previews are shown before launch. Missing variables use the configured
   neutral fallback. The quote quantity is the sum of required SMS segments or
   the number of eligible email recipients, not merely the number of audience
   rows.
6. **Preview and quote:** show eligible count, suppressed/invalid count,
   selected rate version, channel credits required, and current available
   credits. If the audience snapshot is still preparing, show progress and do
   not present a launchable quote. The quote is a snapshot, not a promise that
   later audience edits will be included.
7. **Attest and launch:** the organizer confirms list permission, reviews the
   final message/audience/cost and relationship-audience permission, supplies
   an `Idempotency-Key`, and chooses `Send now` or `Schedule`.
8. **Monitor:** show lifecycle state, delivery totals, failures, released or
   refunded credits, aggregate tracked-link clicks, and the reason a campaign
   stopped or was canceled.

### Saved-list behavior

- A list has a name, organization owner, channel-compatible entries, and
  timestamps. The list itself is not a campaign snapshot.
- CSV columns accepted by v1 are `phone_number`, `email`, and optional
  `first_name`/`last_name`; the selected campaign channel determines which
  address is required. Extra columns are reported as ignored, not silently
  stored.
- Phone numbers are normalized to the platform's canonical international form
  before digesting/deduplicating. Email addresses are normalized before
  digesting. Raw contact values are encrypted at rest and never placed in
  jobs, logs, audit metadata, or outbox payloads.
- Each import is capped at 5 MB and 10,000 rows. An organization may own at
  most 50 saved lists. Parsing, normalization, digesting, encryption, and
  insertion run in `ImportCampaignContactListJob`, not in the upload request.
- Completed imports expose an authorized rejected-row CSV report. Report cells
  beginning with `=`, `+`, `-`, or `@` are prefixed with a single quote before
  export so spreadsheet applications cannot execute formulas.
- Manual entry uses the same row validation and import report as CSV. A list
  import must finish successfully before it can be selected for a campaign.
- Append and replace are separate idempotent operations. Replace requires an
  explicit confirmation and retains an audit record of the prior list version.
- Updating a list never changes a campaign whose audience snapshot already
  exists.

## Domain model

The implementation plan will use one table per migration, UUIDv7 identifiers,
explicit foreign keys, string status checks, Ransack allowlists, and database
unique constraints for idempotency. Names below define responsibilities; the
plan will pin exact columns and indexes.

### `messaging_campaigns`

Organization-owned lifecycle and channel boundary.

- organization, created-by user, optional event context, fixed channel, name, timezone,
  and positive `launch_version` (default `1`);
- status (`draft`, `scheduled`, `sending`, `paused`, `canceled`, `completed`,
  `failed`);
- template version, audience snapshot, schedule/send timestamps;
- encrypted subject/body plus an object of allowlisted runtime variable values;
- quoted eligible quantity, rate version, and launch/finish timestamps.

The campaign cannot change channel, template version, audience snapshot, or
quoted rate after launch. State transitions are explicit commands and are
idempotent.

### `messaging_campaign_templates` and versions

Organization-owned reusable template definitions with immutable versions and
locale variants. A version stores sanitized subject/body/content and the
allowlisted variable names. Provider-specific payloads are generated only at
delivery time by the adapter boundary.

### `messaging_campaign_contact_lists` and entries

Reusable organization-owned lists and encrypted contact entries. Each entry
stores a normalized-address digest, encrypted channel address, optional display
name, source/import metadata, and current list version. A unique digest per
list/channel prevents duplicate entries without exposing contact values.

### `messaging_campaign_audience_snapshots` and recipients

The snapshot freezes source membership and eligibility at launch. Snapshot
preparation is asynchronous and uses 500-row `insert_all` batches. Each
recipient stores only the minimum delivery identity: campaign, normalized
channel digest, encrypted channel address, source classification, eligibility
status/reason, and timestamps. A unique `(campaign_id, channel_address_digest)`
constraint is the deduplication boundary. A snapshot has `preparing`, `ready`,
or `failed` status and progress counters so preview/launch can return `202`
until all source rows and per-recipient quantities are ready.

For historical event audiences, the snapshot records whether the selection was
based on issued/registered people or checked-in attendees. The organizer
attestation is bound to that basis.

### `messaging_campaign_attestations`

Append-only evidence that an authorized organizer attested to a list or
campaign's permission to contact. It records actor, organization, target,
channel, attestation version, and timestamp; it never stores a raw contact
export or provider payload.

### `messaging_campaign_deliveries`

One delivery row per eligible campaign recipient. It references the recipient
and the existing provider result contract, with statuses such as `pending`,
`processing`, `delivered`, `retryable`, `failed`, and `suppressed`. Provider
message identifiers are operationally protected and omitted from public
serializers. Delivery rows are not transactional inbox notifications.

### `messaging_campaign_credit_allocations`

Per-delivery allocation evidence against the campaign's aggregate
`Messaging::CreditReservation`. An allocation records the delivery, quantity
(SMS segments or one email recipient), and terminal settlement (`consumed`,
`released`, or `refunded`) with an operation-scoped idempotency key. It does not
create a second balance; the existing Messaging credit ledger remains the
source of truth. The implementation extends the reservation source allowlist
with `Messaging::Campaign` for the aggregate hold while retaining
`Messaging::CampaignRecipient` for any future per-recipient reservation use.

### `messaging_campaign_links` and aggregate events

Campaign/channel-scoped tracked links reference `Links::ShortLink` records
created with an authorized `custom_url` and UTM fields. Click events are
aggregated by campaign, link, and time bucket. No per-recipient token or
identity is exposed to organizers.

### Consent and suppression

Campaigns need a marketing-specific consent/suppression boundary, separate
from transactional notification preferences and legal registration consents.
An event relationship is an audience source, not implicit permission; the
organizer attestation covers the selected relationship audience at launch.
Explicit subscriptions may make a user eligible but can never override a
suppression or unsubscribe. The boundary must support organization/channel
opt-out, global suppression, source and timestamp evidence where available,
and an unsubscribe operation that is idempotent and immediately effective for
future sends. SMS provider inbound webhooks must be signature-verified and
normalize `STOP` (and provider-defined equivalents) into the same suppression
command. Email uses tokenized public unsubscribe links and
`List-Unsubscribe`/`List-Unsubscribe-Post` headers. A short opt-out link is not
required in every SMS because it consumes message segments; provider replies
are the primary SMS path.

The backing `messaging_campaign_suppressions` table stores a channel-address
digest, optional organization scope (`nil` means global), suppression source,
reason, and timestamps. A unique organization/channel/address boundary makes
repeated STOP, unsubscribe-link, and admin operations idempotent. Raw channel
addresses are not stored in the suppression row.

Inbound provider verification is a separate `Messaging::Providers::InboundAdapter`
contract with `verify_inbound(raw_body:, headers:)`,
`parse_inbound(raw_body:, headers:)`, and provider-defined `stop_words`, selected
through an inbound-provider registry. The delivery adapter contract remains
responsible only for outbound delivery.

## Processing and reliability

### Quote and launch

The quote calculates the fixed channel's unit quantity first: one credit per
provider-billed SMS segment or one credit per eligible email recipient. It then
resolves one immutable rate version for that quantity and persists
`quoted_rate_version_id`, `quoted_quantity`, `quoted_unit_price_minor`,
`quote_digest`, `quoted_at`, and `quote_expires_at` on the campaign. Launch runs
inside a command transaction
that:

1. rechecks authorization, attestation, campaign state, audience snapshot,
   suppression, and available credits;
2. requires the client-supplied quote digest/rate ID to match the persisted
   quote and rejects an expired quote with `campaign_quote_stale`;
3. creates one idempotent aggregate campaign credit reservation through
   Messaging and records its quoted quantity;
4. records the launch audit and outbox event; and
5. commits before any provider call occurs.

Within the quote TTL, a rate version retired by an administrator remains valid
because the quote identity is immutable. After expiry, the organizer must
re-estimate; Launch never falls through to a newly active rate.

The same `Idempotency-Key` replay returns the existing launch result and does
not create another hold or dispatch. A different request identity with the
same key returns `409 idempotency_conflict`.

### Bounded fan-out

The launch command publishes `messaging.campaign.launched` with only
`campaign_id`, `credit_hold_id`, `dispatch_at`, and `launch_version`. The exact
handler is `Messaging::OutboxHandlers::CampaignLaunched`; it enqueues an
immediate `FanoutCampaignJob` only when `dispatch_at <= Time.current`, while
the scheduled-campaign worker handles future dispatch. The handler is safe to
replay because campaign fan-out claims rows idempotently.

`FanoutCampaignJob` receives campaign and cursor IDs
only. The job processes bounded pages (100 recipients), claims rows with
`SKIP LOCKED`, allocates the recipient's segment/recipient quantity against the
aggregate hold, and re-enqueues the next cursor. It never loops through an
unbounded audience while holding an outbox claim or transaction.

Each delivery invokes the shared provider adapter and records a sanitized
`DeliveryResult`. Retryable failures remain reserved; suppressed recipients
release; permanent failures refund; successful sends consume. Every transition
has an operation-scoped database idempotency key and is safe to retry.

### Pause, cancel, and recovery

- Pause stops new pages from being claimed; already-processing deliveries may
  finish and settle normally.
- Abort is allowed while `paused` or `sending`. It prevents future cursor
  claims, releases the aggregate hold's unallocated quantity with
  `campaign_aborted`, and moves the campaign to terminal `canceled` while
  holding the campaign lock. In-flight provider attempts are retried with the
  original delivery idempotency key so the provider can return a definitive
  result; never-attempted canceled deliveries are failed/refunded without
  provider I/O. The reconciler finalizes the hold only after every allocation is
  terminal.
- Pause, Cancel, Abort, and Resume each record a request-bound lifecycle audit
  with the actor and any supplied reason; replaying the same key does not add a
  second audit or enqueue duplicate work.
- Cancel is allowed while `draft` or `scheduled` and before any delivery is
  dispatched. It releases the complete aggregate hold (when present), records
  `campaign_canceled`, and moves the campaign to terminal `canceled`.
- Reconciliation finds stuck campaign deliveries, reservations, and launches
  by IDs/statuses and replays the matching existing command. It also requeues a
  `sending` campaign whose deliveries are all terminal, so a worker crash
  between settlement and completion cannot strand the campaign. Terminal
  campaign recovery uses `RecoverCampaignDeliveryJob` and never synthesizes a
  provider success or failure.
- Retryable provider results use bounded exponential backoff and become a
  permanent failed/refunded delivery after five attempts; provider exceptions
  follow the same cap.
- A campaign with a permanently invalid template, no eligible recipients, or
  insufficient credits fails before provider dispatch with a typed error.

## API surface

All mutating endpoints require `Idempotency-Key`; read endpoints use existing
pagination/filter/order contracts. Exact route names and serializer fields are
fixed in the implementation plan and Postman collection.

### Organizer endpoints

- `GET /organizations/:organization_id/campaigns`
- `POST /organizations/:organization_id/campaigns`
- `GET /organizations/:organization_id/campaigns/:id`
- `PATCH /organizations/:organization_id/campaigns/:id`
- `POST /organizations/:organization_id/campaigns/:id/estimate`
- `POST /organizations/:organization_id/campaigns/:id/attest`
- `POST /organizations/:organization_id/campaigns/:id/launch`
- `POST /organizations/:organization_id/campaigns/:id/pause`
- `POST /organizations/:organization_id/campaigns/:id/resume`
- `POST /organizations/:organization_id/campaigns/:id/cancel`
- `POST /organizations/:organization_id/campaigns/:id/abort`
- `GET/POST /organizations/:organization_id/campaign_contact_lists`
- `GET/PATCH/DELETE /organizations/:organization_id/campaign_contact_lists/:id`
- `POST /organizations/:organization_id/campaign_contact_lists/:id/import`
- `GET /organizations/:organization_id/campaign_contact_lists/:id/imports/:import_id`
- `GET /organizations/:organization_id/campaign_contact_lists/:id/imports/:import_id/report`
- `POST /organizations/:organization_id/campaign_contact_lists/:id/entries`
- `DELETE /organizations/:organization_id/campaign_contact_lists/:id/entries/:entry_id`
- `POST /organizations/:organization_id/campaign_contact_lists/:id/append`
- `POST /organizations/:organization_id/campaign_contact_lists/:id/replace`
- `GET/POST /organizations/:organization_id/campaign_templates`
- `GET /organizations/:organization_id/campaigns/:id/analytics`

Provider-neutral inbound and public unsubscribe routes are outside organizer
authorization and must verify their provider signature or token:

- `POST /messaging/webhooks/:provider/inbound`
- `GET/POST /messaging/unsubscribe/:token`

The public unsubscribe token is verified with
`Rails.application.message_verifier("messaging-campaign-unsubscribe-v1")`,
purpose `campaign_unsubscribe`, and a 30-day expiry. The inbound and public
routes use cache-backed abuse limits of 120 inbound requests per provider/IP
per minute and 30 unsubscribe requests per IP per minute; limit responses are
typed `429` errors.

The unsubscribe `GET` is read-only: it verifies the token and returns a safe
preview (`valid` and `channel`) without recording suppression. The unsubscribe
`POST` performs the idempotent suppression mutation and returns the resulting
status. This prevents email security scanners from unsubscribing recipients
while prefetching links.

Controllers use policy-gated serializer profiles, explicit eager-load and
ordering allowlists, safe nested display fields, and `Core::JsonResponse`.
Public responses never expose encrypted addresses, address digests, provider
IDs, credit ledger internals, attestation evidence details, or outbox IDs.

### Administrative endpoints

Administrators can inspect campaigns, delivery aggregates, suppression trends,
attestations, and reconciliation failures through read-only or explicitly
audited operational actions. Admin access does not bypass suppression, credit
ledger invariants, or provider result handling.

## Authorization and privacy invariants

- Organization owners and authorized organization admins may manage that
  organization's campaigns and lists. Platform administrators may inspect and
  perform explicitly audited operational actions.
- A user cannot read another organization's contacts, campaign snapshots,
  message content, or analytics.
- List attestation is bound to organization, actor, channel, and list/campaign
  version. Reusing a key for a different target or attestation body conflicts.
- Suppression is checked when previewing, launching, and dispatching. A late
  unsubscribe wins over a queued delivery.
- Contact values are encrypted at rest with a digest for equality checks;
  serializers, jobs, outbox rows, logs, and audit metadata use IDs/digests only.
- Retention policy erases campaign message bodies and materialized recipient
  contact values on the configured schedule while preserving the minimum
  aggregate financial and delivery evidence needed for reconciliation. Reusable
  active contact-list entries are durable organizer assets; only entries marked
  `removed` or entries belonging to an `archived` list are eligible for contact
  value erasure.
- CSV imports enforce row and file-size limits, reject formula-injection fields
  in reports, and never execute uploaded content.
- Provider inbound webhooks are signature-verified before changing suppression;
  replayed webhook IDs are idempotent.
- Campaign launch checks the configured organization/channel daily and monthly
  quota before creating the aggregate credit hold.

## Testing and acceptance gates

The implementation plan must include:

- model/database tests for status transitions, encrypted-contact/digest
  invariants, unique list/campaign boundaries, and retention behavior;
- service tests for union/deduplication, append/replace imports, attestation,
  first-party relationship attestation, suppression precedence,
  fixed-channel validation, GSM-7/UCS-2 segment boundaries, Unicode and
  concatenated-message pricing, quote/rate snapshots, aggregate-hold
  allocation, and quota enforcement,
  launch idempotency, pause/cancel, and credit settlement;
- integration tests for organizer/admin authorization, missing idempotency keys,
  replay/conflict responses, pagination/filter/order, serializer visibility,
  CSV rejection reports, provider inbound signatures, email unsubscribe tokens,
  and unsubscribe behavior;
- job tests for 100-recipient cursor fan-out, asynchronous bounded imports,
  retries, pause/abort, provider outcomes, aggregate-hold settlement, and
  reconciliation;
- concurrency tests proving one snapshot/launch and one aggregate hold/allocation
  outcome under duplicate requests;
- `N_PLUS_ONE=1` coverage for audience preview, list APIs, campaign detail, and
  100-recipient fan-out;
- seed and Postman examples using synthetic contacts only, never real provider
  credentials or real personal data;
- RuboCop, Brakeman, Zeitwerk, route/schema, full-suite, and diff checks.

## Rollout and future extensions

The first implementation should ship the organizer-attestation model exactly
as specified, with strong audit, suppression, rate-limit, and abuse controls.
Future work can add provider-verified consent, threshold-based platform review,
recipient-level conversion attribution, richer audience predicates, and
multi-channel orchestration as separate reviewed changes. None of those may
introduce a parallel credit balance or provider path.
