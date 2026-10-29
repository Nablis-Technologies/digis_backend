# Featured Event Placements Implementation Plan

> Local implementation is complete. Render deployment/checkout acceptance remains pending. Do not enable production sales until per-rail refund behavior is confirmed and production offer/capacity settings are explicitly approved.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers-ruby:subagent-driven-development` (recommended) or `superpowers-ruby:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an event owner/admin buy a scheduled Featured placement that is paid through Chapa, capacity-reserved, shown in public discovery, and cancelled/refunded/reconciled safely.

**Architecture:** Marketing owns server-priced daily-rate offers, scheduled placement entitlements, and per-surface inventory checks. Orders owns generic billing purchases, provider payment, and durable refund obligations; product domains consume shared billing outbox events idempotently. Finance records platform billing facts separately from organizer settlement. Public discovery and the `featured=true` filter share one eligibility query. Capacity is reserved under a transaction-scoped advisory lock.

**Tech Stack:** Ruby 3.4, Rails 8.1, PostgreSQL UUIDv7/check constraints/triggers, Pundit, ActiveModelSerializers, Chapa V2 through `Payments::Providers`, `Orders::BillingPurchase`, `Core::Outbox`, `Core::Database::AdvisoryLock`, Solid Queue, Minitest, Prosopite, Postman.

---

**Design spec:** [`docs/superpowers/specs/2026-10-13-featured-event-placements-design.md`](../specs/2026-10-13-featured-event-placements-design.md)

## Scope and execution guard

- Implement only the paid Featured-placement vertical slice. Do not add credit wallets, SMS/email campaign products, auctions, CPM/CPC, impression analytics, or paid changes to organic ranking.
- Use the current branch and workspace. Do not create a worktree, stage, commit, or deploy without the user's instruction.
- New tables each receive one migration. Edit the original `orders_billing_purchases` and `orders_refunds` migrations; do not add alter migrations for these existing tables.
- Rebuilding a database after editing original migrations is destructive. Confirm the exact local/preview target and data-retention expectations before any reset. Never reset Render during local implementation.
- Use the domain generator first for Marketing model skeletons, then hand-write constrained migrations and behavior. Do not generate generic CRUD actions for billing commands.
- `Core::Outbox::HandlerRegistry::HandlerChain` executes every registered handler for an event type in priority order. Messaging, Marketing, and Finance consumers must each return success/no-op for billing sources they do not own; failures for a matching source must still retry.
- For every idempotent command, use `IdempotencyAssertions` (`assert_idempotent` / `assert_audit_idempotent`) and an integration replay/missing-key test. Do not replace the shared helper with hand-rolled count comparisons.
- G-40's ETB amount-unit concern was verified in Chapa test mode (513 minor units displayed as a 5.13 ETB subtotal). For this new product, still compare the server-priced placement amount with the Chapa receipt and accepted payment evidence; production offer/capacity settings and per-rail refund behavior remain separate launch gates.
- Local schema verification used the newly created `digis_backend_featured_acceptance_test` database and replayed the migration history from source. Existing development, `digis_backend_test`, and Render databases were not reset.

## File map

### Orders billing/refund boundary

- Modify: `db/migrate/20260811085959_create_orders_billing_purchases.rb`
- Modify: `db/migrate/20260812090011_create_refunds.rb`
- Modify: `app/models/orders/billing_purchase.rb`
- Modify: `app/models/orders/payment.rb`
- Modify: `app/models/orders/refund.rb`
- Modify: `app/services/messaging/outbox_handlers/grant_top_up_credits.rb`
- Modify: `app/services/messaging/outbox_handlers/resolve_top_up_payment.rb`
- Modify: `app/models/messaging/credit_top_up.rb`
- Modify: `app/services/orders/submit_refund.rb`
- Modify: `app/services/orders/apply_refund_result.rb`
- Modify: `app/services/orders/create_item_refund.rb`, `app/services/orders/gift_purchases/claim.rb`, `app/services/marketplace/{activate_listing,fulfill_sale,reserve_listing}.rb`, and `app/services/ticketing/apply_date_refund.rb` to count manual-review obligations as outstanding
- Existing and unchanged: `config/initializers/messaging_outbox_handlers.rb` (retained as the Messaging-specific registration in the shared billing handler chain)

### Marketing, platform billing, and capacity

- Create: `app/models/marketing/application_record.rb`
- Create: `app/controllers/marketing/application_controller.rb`
- Create: `app/models/marketing/placement_offer.rb`
- Create: `app/models/marketing/featured_placement.rb`
- Create: `db/migrate/20261013090001_create_marketing_placement_offers.rb`
- Create: `db/migrate/20261013090002_create_marketing_featured_placements.rb`
- Create: `app/services/marketing/featured_placements/quote.rb`
- Create: `app/services/marketing/featured_placements/event_eligibility.rb`
- Create: `app/services/marketing/featured_placements/capacity.rb`
- Create: `app/services/marketing/featured_placements/create.rb`
- Create: `app/services/marketing/featured_placements/cancel.rb`
- Create: `app/services/marketing/featured_placements/reconcile.rb`
- Create: `app/services/marketing/featured_placements/public_query.rb`
- Create: `app/services/marketing/outbox_handlers/billing_payment_accepted.rb`
- Create: `app/services/marketing/outbox_handlers/billing_payment_lifecycle.rb`
- Create: `app/services/marketing/outbox_handlers/event_cancelled.rb`
- Create: `app/controllers/marketing/featured_placements_controller.rb`
- Create: `app/controllers/public/events_controller.rb` as the public discovery composition boundary for index, show, and featured actions
- Delete: `app/controllers/marketing/public_featured_events_controller.rb`; route featured discovery through `Public::EventsController#featured`
- Delete: `app/controllers/events/public_events_controller.rb`; move the detail action into `Public::EventsController#show`
- Create: `app/policies/marketing/featured_placement_policy.rb`
- Create: `app/serializers/marketing/featured_placement_serializer.rb`
- Create: `app/serializers/marketing/featured_event_serializer.rb`
- Create: `config/initializers/marketing.rb`
- Create: `config/initializers/marketing_outbox_handlers.rb`
- Create: `app/jobs/marketing/reconcile_featured_placements_job.rb`
- Create/modify: `app/models/finance/platform_billing_entry.rb` with association-backed source validation during journal posting
- Create: `db/migrate/20261013090003_create_finance_platform_billing_entries.rb`
- Create: `app/services/finance/post_platform_billing_entry.rb`
- Create: `app/services/finance/reconcile_platform_billing_entries.rb`
- Create: `config/initializers/finance_billing_outbox_handlers.rb`
- Create: `app/jobs/finance/reconcile_platform_billing_entries_job.rb`

### Refund operations, API, and deployment artifacts

- Create: `app/services/orders/create_billing_purchase_refund.rb`
- Create: `app/services/orders/resolve_manual_billing_purchase_refund.rb`
- Create: `app/controllers/admin/orders/refund_resolutions_controller.rb`
- Create: `app/policies/admin/orders/refund_resolution_policy.rb`
- Modify: `config/routes.rb`
- Modify: `db/seeds/base.rb` for the explicit manual-refund permission.
- Modify: `config/recurring.yml`
- Modify: `config/locales/orders/payments.en.yml`
- Create: `config/locales/marketing/featured_placements.en.yml`
- Modify: `db/seeds/preview.rb` with a clearly test-priced ETB offer.
- Modify: `render.yaml` with the preview-only enable flag and an operator-configured per-surface capacity setting; missing/invalid capacity fails closed.
- Modify: `postman/Digis API_collection.json`
- Modify: `db/structure.sql` regenerated from the fresh migration-replay acceptance database.

### Tests

- Create: `test/models/marketing/placement_offer_test.rb`
- Create: `test/models/marketing/featured_placement_test.rb`
- Create: `test/models/finance/platform_billing_entry_test.rb`
- Modify: `test/models/orders/refund_test.rb`
- Create: `test/models/orders/billing_purchase_test.rb`
- Create: `test/services/marketing/featured_placements/quote_test.rb`
- Create: `test/services/marketing/featured_placements/capacity_test.rb`
- Create: `test/services/marketing/featured_placements/create_test.rb`
- Create: `test/services/marketing/featured_placements/public_query_test.rb`
- Create: `test/services/marketing/featured_placements/cancel_test.rb`
- Create/modify: `test/services/marketing/featured_placements/reconcile_test.rb` with bounded recovery-read assertions
- Create: `test/services/marketing/outbox_handlers/billing_payment_accepted_test.rb`
- Create: `test/services/marketing/outbox_handlers/billing_payment_lifecycle_test.rb`
- Create: `test/services/marketing/outbox_handlers/event_cancelled_test.rb`
- Create: `test/services/orders/create_billing_purchase_refund_test.rb`
- Create: `test/services/orders/resolve_manual_billing_purchase_refund_test.rb`
- Create: `test/services/finance/post_platform_billing_entry_test.rb`
- Create/modify: `test/services/finance/reconcile_platform_billing_entries_test.rb` with bounded batch-read assertions
- Modify: `test/support/performance_query_helpers.rb` to expose captured SQL for deterministic query-budget tests
- Create: `test/services/core/outbox/billing_purchase_handler_chain_test.rb`
- Modify: `test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb`
- Modify: `test/services/messaging/outbox_handlers/resolve_top_up_payment_test.rb`
- Create: `test/integration/marketing/featured_placements_test.rb`
- Modify: `test/integration/events/public_events_test.rb`
- Modify: `test/integration/marketing/featured_placements_test.rb`
- Create: `test/integration/admin/orders/refund_resolutions_test.rb`

## Task 1: Generalize the billing-purchase source contract safely

**Files:** BillingPurchase/Refund original migrations and models, Messaging top-up model/handlers, Orders and Messaging billing tests.

- [x] **Step 1: Add failing source-routing tests.** Assert that Marketing billing payment events are no-ops for Messaging consumers, Messaging events are no-ops for Marketing/Finance consumers, and the matching consumer processes its own source exactly once. Matching source with missing/mismatched records must remain a typed retryable failure.
- [x] **Step 2: Run RED.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/resolve_top_up_payment_test.rb \
  test/services/core/outbox/dispatch_test.rb
```

Expected: the existing Messaging handlers reject non-Messaging billing sources, so a shared `orders.billing_payment.*` handler chain cannot yet serve a second purchase product.

- [x] **Step 3: Edit the original `orders_billing_purchases` migration.** Add `featured_placement` and `Marketing::FeaturedPlacement` to the kind/source allowlists while retaining UUID FKs, payment subject rules, source uniqueness, organization-scoped idempotency, price digest, and expiry constraints. Preserve the one-table-per-migration history.
- [x] **Step 4: Remove Orders-to-Messaging reverse associations.** Remove `BillingPurchase#credit_top_up` and `Payment#accepted_credit_top_up`; keep `Messaging::CreditTopUp#billing_purchase` as the product-owned association and remove stale `inverse_of` declarations. Update Messaging code/jobs/tests to resolve top-ups from their own billing-purchase ID.
- [x] **Step 5: Make Messaging outbox consumers no-op for other allowlisted products.** Return `success(nil)` before attempting a top-up lookup when `source_type` is not `Messaging::CreditTopUp`; retain hard failure for invalid matching-source IDs and payment evidence.
- [x] **Step 6: Run billing/top-up regression tests GREEN.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/orders/start_billing_payment_attempt_test.rb \
  test/services/orders/accept_billing_payment_test.rb \
  test/services/orders/process_payment_event_test.rb \
  test/services/messaging/create_credit_top_up_test.rb \
  test/services/messaging/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/resolve_top_up_payment_test.rb
```

Expected: current Messaging purchases still create the same provider request and credit grant; Marketing events pass through Messaging consumers without side effects or retries.

## Task 2: Add offer and placement persistence

**Files:** New Marketing model skeletons, original/new migrations, model/schema tests, `db/structure.sql` after approved rebuild.

- [x] **Step 1: Generate the Marketing model skeletons.**

```bash
bin/rails generate domain_module Marketing::PlacementOffer \
  code:string version:integer daily_rate_minor:integer currency:string \
  minimum_duration_seconds:integer maximum_duration_seconds:integer \
  surface:string terms_version:string active:boolean starts_at:datetime ends_at:datetime \
  --only=model --no-interactive --no-auditable
bin/rails generate domain_module Marketing::FeaturedPlacement \
  'event:belongs_to[Events::Event]' \
  'organization:belongs_to[Organizations::Organization]' \
  'placement_offer:belongs_to[Marketing::PlacementOffer]' status:string \
  starts_at:datetime ends_at:datetime --only=model --no-interactive --no-auditable
```

Add `Marketing::ApplicationController` if the generator only creates the model base.
The placement's BillingPurchase is resolved by the unique
`Orders::BillingPurchase(source_type: "Marketing::FeaturedPlacement", source_id: placement.id)`
identity. Do not add a reverse product association or a cyclic `billing_purchase_id`
foreign key to the placement.

- [x] **Step 2: Add RED model/schema tests.** Test offer version uniqueness, ETB integer rate, active window, exact 24-hour minimum/14-day maximum, placement interval, immutable pricing snapshot, event/organization scope, allowed statuses, and one purchase identity. Add PostgreSQL FK/check/index assertions and explicit `ransackable_attributes`/`ransackable_associations` allowlists.
- [x] **Step 3: Create one migration per table.** Use `db/migrate/20261013090001_create_marketing_placement_offers.rb` and `db/migrate/20261013090002_create_marketing_featured_placements.rb`. Include UUIDv7 IDs, explicit FKs/check constraints, offer version snapshot, rate/amount/currency snapshots, timing/status, idempotency/request digests, and refund linkage. Use the typed BillingPurchase source identity described above instead of a cyclic FK. Each file contains exactly one `create_table`.
- [x] **Step 4: Implement model behavior and snapshot immutability.** A placement's event must belong to its organization; offer surface/currency/rate/version must match the stored snapshot; `ends_at` equals the event's first scheduled start; the stored duration is within offer bounds; terminal placements cannot reactivate.
- [x] **Step 5: Run model tests GREEN.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/models/marketing/placement_offer_test.rb \
  test/models/marketing/featured_placement_test.rb
```

## Task 3: Implement exact quote and capacity reservation

**Files:** Quote/capacity services, offer/quote controller actions, per-surface configuration, service tests.

- [x] **Step 1: Write quote RED tests.** Cover `ceil(daily_rate_minor * duration_seconds / 86_400)`, exactly 24 hours, exactly 14 days, a 50-hour “until doors” example, less than 24 hours to doors, start earlier than 60 minutes from quote/purchase, ineligible event states, free RSVP, and no client-controlled end/amount.
- [x] **Step 2: Write capacity RED tests.** Cover available overlap count, cap reached, `next_available_at`, no viable window before doors, pending-payment reservation until `expires_at`, pending checkout expiry releasing capacity, and cancellation releasing only the unserved interval.
- [x] **Step 3: Implement `Marketing::FeaturedPlacements::Quote.call(event:, offer:, starts_at:, at:)`.** Return a typed quote with `starts_at`, event-derived `ends_at`, `duration_seconds`, price snapshots, `capacity_available`, and `next_available_at`. Use integer arithmetic; reject zero, negative, or out-of-range intervals. Sales fail closed unless `MARKETING_FEATURED_PLACEMENTS_ENABLED=true`.
- [x] **Step 4: Implement `Marketing::FeaturedPlacements::Capacity`.** Require a valid positive per-surface cap from `config/initializers/marketing.rb`; missing/invalid configuration makes offer quote and creation unavailable. Count interval-overlapping scheduled/active placements and unexpired pending-payment holds. Find the earliest later start with a full 24-hour minimum before event doors.
- [x] **Step 5: Serialize quote/create reservations across different event rows.** In a transaction, call `Core::Database::AdvisoryLock.acquire!("marketing", "featured_placements", surface)` before checking/inserting an interval. Lock the event row next, then placement/billing-purchase rows. Quote remains read-only; create rechecks all conditions.
- [x] **Step 6: Run quote/capacity tests GREEN.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/marketing/featured_placements/quote_test.rb \
  test/services/marketing/featured_placements/capacity_test.rb
```

## Task 4: Create purchase intents and connect Chapa billing

**Files:** Marketing creation command/controller/policy/serializer, Orders billing purchase, outbox handlers, integration/service tests.

- [x] **Step 1: Write failing command/controller cases.** Owner/admin can create; manager/staff/foreign organization cannot spend; missing `Idempotency-Key` returns 400; exact replay returns the same purchase/payment; changed event/offer/start under the same key conflicts; full inventory returns `409 featured_capacity_full` and next time; provider initialization does not activate. Use `assert_idempotent` for duplicate side effects and an integration replay plus missing-header test.
- [x] **Step 2: Implement `Marketing::FeaturedPlacements::Create.call(event:, purchaser:, offer_id:, starts_at:, idempotency_key:, at:)`.** Fingerprint canonical event, offer version, purchaser, and scheduled time. Under the surface advisory lock, re-run the quote and persist `pending_payment` placement plus `Orders::BillingPurchase` atomically. Client amount/duration/source are ignored; exact replays of already accepted payment evidence recover the scheduled/active placement rather than starting a closed checkout.
- [x] **Step 3: Start payment through `Orders::StartBillingPaymentAttempt`.** Use Chapa, the current supported method contract, and a deterministic payment idempotency key. Return payment summary/checkout URL with pending status; do no provider I/O while holding the placement/capacity transaction.
- [x] **Step 4: Add Marketing payment outbox handlers.** Register accepted and failed/reversed lifecycle handlers in `config/initializers/marketing_outbox_handlers.rb`. Accepted handling checks typed source, payment acceptance, purchase ID, amount, currency, and price digest before scheduling/activating. Failure/reversal closes the placement without serving. Every handler is idempotent and no-ops for other allowlisted billing sources.
- [x] **Step 5: Test chain composition with Messaging handlers.** Verify one billing event runs all handlers in priority order; nonmatching consumers no-op; a handler replay does not duplicate activation or credit grant.
- [x] **Step 6: Run purchase/payment tests GREEN.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/marketing/featured_placements/create_test.rb \
  test/services/marketing/outbox_handlers/billing_payment_accepted_test.rb \
  test/services/marketing/outbox_handlers/billing_payment_lifecycle_test.rb \
  test/integration/marketing/featured_placements_test.rb \
  test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb
```

## Task 5: Add platform billing journal facts

**Files:** `Finance::PlatformBillingEntry`, one new migration, posting/reconciliation services, finance outbox handlers, model/service tests.

- [x] **Step 1: Write RED journal tests.** One accepted featured billing purchase posts one immutable charge row. Duplicate outbox delivery is a no-op. A successful refund posts one linked negative row; pending/manual-review/failed refund does not. Non-featured billing sources and event ticket payments do not post a featured-platform row.
- [x] **Step 2: Generate the Finance model skeleton and create its table migration.** Use `Finance::PlatformBillingEntry` with `type` as a business discriminator (`--business-type`); create only `db/migrate/20261013090003_create_finance_platform_billing_entries.rb`. Include billing purchase/payment/refund FKs, entry type, signed minor amount, currency, provider-fee evidence fields, immutable source identity, timestamps, idempotency key, and database constraints. Do not alter organizer `finance_ledger_entries`.

```bash
bin/rails generate domain_module Finance::PlatformBillingEntry \
  type:string amount_minor:integer currency:string idempotency_key:string \
  --only=model --no-interactive --no-auditable --business-type
```

Add the optional `billing_purchase`, `payment`, and `refund` associations and their constraints explicitly; not every journal entry has a refund or a provider-fee fact.
- [x] **Step 3: Implement `Finance::PostPlatformBillingEntry.call(payment:, billing_purchase:, type:)`.** Validate payment against the canonical Orders billing purchase and validate its allowlisted source type; do not query the product-owned source table from Finance. Use a payment/refund-derived unique idempotency key. Create the accepted-charge fact after payment acceptance, append provider-fee evidence only when the provider supplies it, and create a refund fact only after provider success or audited manual confirmation.
- [x] **Step 4: Add Finance handlers for `orders.billing_payment.accepted` and `orders.refund.succeeded`.** They no-op for non-featured purchase/refund subjects. Add a bounded reconciliation job for accepted Marketing billing payments or succeeded refunds missing their platform journal row; register the recurring job.
- [x] **Step 5: Run journal tests GREEN.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/models/finance/platform_billing_entry_test.rb \
  test/services/finance/post_platform_billing_entry_test.rb \
  test/services/finance/reconcile_platform_billing_entries_test.rb
```

## Task 6: Implement public Featured serving and pagination filter

**Files:** `Marketing::FeaturedPlacements::PublicQuery`, public Marketing controller/serializer, a top-level `Public::EventsController` composition endpoint, routes, tests. Keep domain dependencies one-way: the public API composition layer may call both Events and Marketing, while Events remains unaware of Marketing.

- [x] **Step 1: Write public discovery RED tests.** Cover paid active placement within `[starts_at, ends_at)`, exact start/end boundaries, unpaid/pending exclusion, capacity-capped carousel, stable card-position rotation, one event once, public/published/upcoming/open registration, free RSVP inclusion, and safe projection.
- [x] **Step 2: Implement one eligibility query.** Reuse event public visibility and `Catalog::Public::EventAvailabilitySummary`; fetch a bounded set with eager loading. All joins constrain accepted payment, placement interval, surface config, and event eligibility.
- [x] **Step 3: Add `GET /public/featured_events`.** Return current eligible placements up to the configured cap using safe event-list fields and a Featured label. Never serialize purchase/payment/refund details.
- [x] **Step 4: Compose the featured filter in the single public event-list action.** `Public::EventsController#index` applies the shared Marketing eligibility IDs before `total_count` and pagination when `featured=true`; it preserves ordinary `published_at`/ID ordering and leaves omitted/false organic results unchanged. A typed eligibility failure returns 503 rather than silently falling back to organic results. The same action remains the insertion point for future list filters, without introducing a Marketing dependency into Events.
- [x] **Step 5: Run public regression tests with N+1 detection.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/integration/events/public_events_test.rb \
  test/integration/marketing/featured_placements_test.rb
```

## Task 7: Implement cancellation, partial refund, and manual review

**Files:** Original refund migration/model, Orders refund commands/jobs, Marketing cancel/event-cancel handlers, admin controller/policy/permission, locales/tests.

- [x] **Step 1: Write refund RED tests.** Cover full refund before start; prorated integer refund mid-window; zero-minor refund creates no provider request; cumulative partial refunds cannot exceed purchase amount; competing refund commands serialize; event/organizer cancel immediately removes serving; no refund success is inferred from request submission.
- [x] **Step 2: Edit `db/migrate/20260812090011_create_refunds.rb`.** Add nullable billing-purchase FK; add `billing_purchase_refund` type and `manual_review` status; update the cumulative-outstanding-refunds trigger so created/pending/processing/manual-review/succeeded obligations consume remaining refundable amount. Preserve original ticket item and payment reversal constraints.
- [x] **Step 3: Implement `Orders::CreateBillingPurchaseRefund.call(...)`.** Lock payment, billing purchase, and existing refunds in the global lock order; enforce currency and remaining-balance bounds; create durable obligation plus `orders.refund.created` outbox fact in one transaction. Provider I/O stays in the existing submit job.
- [x] **Step 4: Update provider result mapping and manual review.** Capability false and definitive provider refusal become `manual_review`, with a stable failure reason and provider references; unknown/timeouts stay processing and are verified before resubmission. `SubmitRefund` must never auto-submit a `manual_review` refund.
- [x] **Step 5: Implement `Marketing::FeaturedPlacements::Cancel` and event-cancellation handler.** Lock surface then placement, stop serving and persist refund amount/obligation atomically, publish after commit, and make repeats idempotent. Event cancellation makes the public event disappear immediately even if its refund handler retries. Reconciliation also cancels/refunds a placement when its event becomes private or stops accepting public registrations.
- [x] **Step 6: Implement audited manual resolution.** Add `POST /admin/orders/refunds/:id/resolve_manual` with the explicit `orders.billing_refund.resolve_manual` permission assigned only to the super-admin role, an idempotency key, reason, and non-sensitive evidence reference. Implement `Orders::ResolveManualBillingPurchaseRefund.call(refund:, actor:, reason:, evidence_reference:, idempotency_key:)`. Only an authorized operator attesting a completed external refund may transition `manual_review` to succeeded; that transition emits the standard refund-succeeded outbox event for Finance.
- [x] **Step 7: Run refund/admin tests GREEN.**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/models/orders/refund_test.rb \
  test/services/orders/create_item_refund_test.rb \
  test/services/orders/submit_refund_test.rb \
  test/services/orders/apply_refund_result_test.rb \
  test/services/orders/create_billing_purchase_refund_test.rb \
  test/services/orders/resolve_manual_billing_purchase_refund_test.rb \
  test/services/marketing/featured_placements/cancel_test.rb \
  test/integration/admin/orders/refund_resolutions_test.rb
```

## Task 8: Add offers, capacity configuration, and API documentation

**Files:** Preview seed, initializer/config, Render env declaration, locales, Postman, schema dump.

- [x] **Step 1: Seed preview-only offer data idempotently.** Use an explicitly labeled test daily rate; production daily rate remains disabled until approved. The preview Render service explicitly enables test-mode placement sales. Capacity is managed through the audited admin policy API; no capacity policy is silently seeded.
- [x] **Step 2: Add locale strings for offer unavailable, event ineligible, capacity full, checkout pending, refund processing, manual review, and manual resolution.** All controllers return typed `Core::BusinessError` through standard JSON helpers.
- [x] **Step 3: Update Postman.** Add offers, quote, create, list/show/cancel, manual resolution, `GET /public/featured_events`, and `GET /public/events?featured=true`; include required Idempotency-Key examples and no live secrets.
- [x] **Step 4: Validate seed idempotency, route names, locales, and Postman JSON.**

```bash
bin/rails routes | rg 'featured_placements|featured_events|refunds'
bin/rails zeitwerk:check
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "valid JSON"'
git diff --check
```

## Task 9: Isolated schema replay and acceptance

**Files:** `db/structure.sql`, full affected test set, preview test-mode verification.

- [x] **Step 1: Use a new disposable acceptance database.** Verified the unique local database name was absent before creating it; the existing development/test databases and Render were not dropped or reset.
- [x] **Step 2: Replay the migrations and synchronize the schema dump.** Replayed the migration history from source into `digis_backend_featured_acceptance_test`, including the edited billing/refund migrations, then regenerated `db/structure.sql` from that schema.
- [x] **Step 3: Run the focused vertical slice with `N_PLUS_ONE=1`.** The earlier affected feature slice passed 186 tests / 1,236 assertions. The final combined follow-up suite passed 37 tests / 252 assertions, with 0 failures, 0 errors, and 0 skips, against the isolated acceptance database; it covers public discovery/failure handling, Finance and Marketing reconciliation, billing-journal integrity, batch-query budgets, and shared performance-query consumers.
- [x] **Step 4: Run RuboCop.** The feature scan inspected 72 Ruby files with zero offenses, and the final follow-up scan inspected 13 touched Ruby files with zero offenses. A full repository scan (`--cache false`) found 260 unrelated existing offenses concentrated in `scratch/`; no scratch files were changed. The default command's user-level cache was not writable in the sandbox.
- [x] **Step 5: Run the full suite with `N_PLUS_ONE=1`.** Before the review refinements, the full regression run passed 4,167 tests / 19,802 assertions, with 0 failures, 0 errors, and 5 skips. The route, Finance, and reconciliation-query refinements were verified in the affected slices above; the full suite has not been rerun after those refinements.
- [ ] **Step 6: Complete preview acceptance after user deployment.** In Chapa test mode, compare the server-priced placement amount with the hosted checkout/receipt and accepted payment evidence, then verify webhook acceptance, scheduled activation, featured list/filter, capacity sold-out behavior, cancellation refund, unsupported-rail manual review, and operator resolution. Do not claim production readiness until per-account/method partial refunds are tested and production price/cap settings are approved.

## Review checkpoints

- After Task 1, confirm current Messaging top-ups still pass and shared Orders records no longer point back into product domains.
- After Task 4, verify handler-chain replays with both Messaging and Marketing event sources.
- After Task 7, verify cancellation immediately stops placement serving while refund state remains pending/manual-review until confirmed.
- Before live enablement, the user must approve the initial cap, ETB daily rate, Chapa method coverage, and any preview database reset.
