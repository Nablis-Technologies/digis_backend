# Messaging Notification Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a recipient-owned transactional notification foundation with a durable in-app inbox, category/channel preferences, scheduled and retryable delivery, and provider-neutral email/SMS seams.

**Architecture:** Keep `Core::OutboxEvent` as the transactional transport and add a `Messaging` notification hub behind it. Persist one notification per authenticated user and one delivery row per channel, enforce replay/concurrency with database uniqueness, implement `in_app` first, and expose email/SMS only through explicit adapters. Campaigns, marketing consent, and messaging-credit billing remain separate follow-up plans.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL UUIDv7/check constraints/foreign keys/partial indexes, ActiveModelSerializers, Pundit, Solid Queue, Active Record retention conventions, Minitest, Prosopite, and the existing `Core::JsonResponse`/`Core::Pagination`/`Core::Outbox` contracts.

**Design spec:** `docs/superpowers/specs/2026-09-03-messaging-notification-foundation-design.md`

**Current checkpoint:** The original implementation and acceptance gates are
complete on this branch. Post-review reliability hardening is tracked in
`docs/superpowers/plans/2026-09-03-messaging-notification-foundation-hardening.md`
and must be accepted with it before this foundation is treated as final. User-
owned commit checkpoints remain pending; after both plans are committed and
merged, author/review the separate Messaging Credit/Billing plan before
planning Marketing Campaigns.

**Prerequisites:** Core outbox, authentication, retention policy tables, and existing event/order/ticket/refund/transfer producers are present. Merge the pending frontend/organizer contract follow-ups and Launch Hardening gate before enabling this plan on the master roadmap. Do not pull campaign or credit billing into this plan.

---

## File map

### Schema and retention

- Modify: `db/migrate/20260727090100_create_core_data_retention_policies.rb`
- Modify: `db/migrate/20260727090102_create_core_data_retention_holds.rb`
- Modify: `app/models/core/data_retention_policy.rb`
- Create: `db/migrate/20260903090001_create_messaging_notifications.rb`
- Create: `db/migrate/20260903090002_create_messaging_notification_deliveries.rb`
- Create: `db/migrate/20260903090003_create_messaging_notification_preferences.rb`
- Modify: `db/seeds/base.rb`

### Models and type contracts

- Create: `app/models/messaging/application_record.rb`
- Create: `app/models/messaging/notification.rb`
- Create: `app/models/messaging/notification_delivery.rb`
- Create: `app/models/messaging/notification_preference.rb`
- Modify: `app/models/core/user.rb`
- Create: `app/services/messaging/notification_type_definition.rb`
- Create: `app/services/messaging/notification_types.rb`
- Create: `app/services/messaging/notification_projection.rb`

### Commands and delivery

- Create: `app/services/messaging/publish_notification.rb`
- Create: `app/services/messaging/mark_notification_read.rb`
- Create: `app/services/messaging/update_preferences.rb`
- Create: `app/services/messaging/providers/adapter.rb`
- Create: `app/services/messaging/providers/delivery_result.rb`
- Create: `app/services/messaging/providers/registry.rb`
- Create: `app/services/messaging/providers/in_app.rb`
- Create: `app/services/messaging/deliver_notification.rb`
- Create: `app/jobs/messaging/deliver_notification_job.rb`
- Create: `app/jobs/messaging/fanout_notification_job.rb`
- Create: `config/initializers/messaging.rb`
- Modify: `config/queue.yml`

### Outbox composition and integrations

- Create: `lib/core/outbox/handler_registry.rb`
- Modify: `config/application.rb`
- Modify: `app/services/core/outbox/dispatch.rb`
- Modify: `config/initializers/catalog_outbox_handlers.rb`
- Modify: `config/initializers/commercial_outbox_handlers.rb`
- Modify: `config/initializers/events_outbox_handlers.rb`
- Modify: `config/initializers/orders_outbox_handlers.rb`
- Modify: `config/initializers/streaming_outbox_handlers.rb`
- Modify: `config/initializers/ticketing_outbox_handlers.rb`
- Create: `config/initializers/messaging_outbox_handlers.rb`
- Create: `app/services/messaging/outbox_handlers/publish_transactional_notification.rb`
- Modify: `app/services/ticketing/outbox_handlers/registration_issuance_ready.rb`
- Modify: `app/services/ticketing/waitlist/expire_offer.rb`
- Modify: `app/services/orders/process_payment_event.rb`
- Delete: `app/jobs/ticketing/registration_notification_job.rb`

### Jobs and API

- Create: `app/jobs/messaging/process_notifications_job.rb`
- Create: `app/jobs/messaging/purge_notification_payloads_job.rb`
- Modify: `config/recurring.yml`
- Create: `app/controllers/messaging/application_controller.rb`
- Create: `app/controllers/messaging/notifications_controller.rb`
- Create: `app/controllers/messaging/notification_preferences_controller.rb`
- Create: `app/policies/messaging/notification_policy.rb`
- Create: `app/policies/messaging/notification_preference_policy.rb`
- Create: `app/serializers/messaging/notification_serializer.rb`
- Create: `app/serializers/messaging/notification_delivery_serializer.rb`
- Create: `app/serializers/messaging/notification_preference_serializer.rb`
- Modify: `config/routes.rb`
- Create: `config/locales/messaging/notifications.en.yml`
- Create: `config/locales/messaging/preferences.en.yml`

### Tests and documentation

- Create: `test/models/messaging/notification_test.rb`
- Create: `test/models/messaging/notification_delivery_test.rb`
- Create: `test/models/messaging/notification_preference_test.rb`
- Create: `test/services/messaging/notification_types_test.rb`
- Create: `test/services/messaging/notification_projection_test.rb`
- Create: `test/services/messaging/publish_notification_test.rb`
- Create: `test/services/messaging/mark_notification_read_test.rb`
- Create: `test/services/messaging/update_preferences_test.rb`
- Create: `test/services/messaging/deliver_notification_test.rb`
- Create: `test/services/messaging/providers/registry_test.rb`
- Create: `test/jobs/messaging/deliver_notification_job_test.rb`
- Create: `test/jobs/messaging/fanout_notification_job_test.rb`
- Create: `test/jobs/messaging/process_notifications_job_test.rb`
- Create: `test/jobs/messaging/purge_notification_payloads_job_test.rb`
- Create: `test/support/messaging_test_helpers.rb`
- Create: `test/services/core/outbox/handler_registry_test.rb`
- Create: `test/services/core/outbox/dispatch_test.rb`
- Create: `test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb`
- Create: `test/integration/messaging/notifications_test.rb`
- Create: `test/integration/messaging/notification_preferences_test.rb`
- Create: `test/integration/messaging/outbox_delivery_test.rb`
- Create: `test/services/ticketing/waitlist/expire_offer_test.rb`
- Create: `test/services/ticketing/outbox_handlers/package_issued_test.rb`
- Create: `test/performance/messaging_notification_fanout_test.rb`
- Modify: `test/services/orders/process_payment_event_test.rb`
- Modify: `test/services/orders/fulfill_order_test.rb`
- Modify: `test/services/orders/apply_refund_result_test.rb`
- Modify: `test/services/ticketing/packages/issue_test.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md`

---

## Task 1: Create notification, delivery, preference, and retention schema

**Files:** the schema/retention files above and the three model contract tests.

- [x] **Step 1: Write failing schema tests**

Assert the exact UUID/JSONB columns, Core retention category, foreign keys, status checks, source-type allowlist, unique `(user_id, dedupe_key)` and `(notification_id, channel)` indexes, partial inbox/claimable indexes, and invalid category/channel/status rejection:

```ruby
test "notification schema has recipient and retention boundaries" do
  columns = Messaging::Notification.columns_hash
  assert_equal :uuid, columns.fetch("user_id").type
  assert_equal :jsonb, columns.fetch("data").type
  assert_equal :uuid, columns.fetch("retention_policy_id").type
  assert_includes Core::DataRetentionPolicy::CATEGORIES, "messaging_notification"
end
```

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test test/models/messaging
```

Expected: failure because the Messaging tables/models and retention category do not exist.

- [x] **Step 3: Extend the Core retention allowlist**

Add `messaging_notification` to `Core::DataRetentionPolicy::CATEGORIES` and to both original Core migration check constraints. Do not create a second migration for an existing Core table; this repository rebuilds its non-production database from canonical migrations.

- [x] **Step 4: Create `messaging_notifications`**

Use UUIDv7 IDs and fields `user_id`, `notification_type`, `category`, optional `source_type/source_id`, object-shaped `data`, `dedupe_key`, required `retention_policy_id`, nullable `retain_until`, `available_at` (current timestamp default), `read_at`, `erased_at`, `erasure_reason`, and timestamps. `retain_until` is intentionally nullable: an `erase_payload` policy must have positive `retention_days` and produces a deadline; a `retain` policy leaves it null. Add checks for the four transactional categories, JSON object data, the explicit source-type allowlist (`Orders::Order`, `Orders::Payment`, `Orders::Refund`, `Ticketing::Ticket`, `Ticketing::TicketTransfer`, `Ticketing::Registration`, `Ticketing::RegistrationConsentRequirement`, and `Events::Event`), and paired erasure fields. Add foreign keys to `core_users` and `core_data_retention_policies`, a unique `(user_id, dedupe_key)` index, a partial unread/inbox index where `erased_at IS NULL`, source indexes, and the retention lookup index.

- [x] **Step 5: Create `messaging_notification_deliveries`**

Use fields `notification_id`, `channel`, `status`, nullable provider fields, `attempts`, 64-character `idempotency_key_digest`, claim/retry timestamps, sent/delivered/failed timestamps, and sanitized failure fields. Constrain channels to `in_app/email/sms`, statuses to `pending/processing/sent/delivered/failed/suppressed/unavailable`, attempts to non-negative, and the digest to lowercase SHA-256. Add unique `(notification_id, channel)`, a partial claimable queue index where `status IN ('pending','processing')`, provider indexes, and a cascading FK to notifications.

- [x] **Step 6: Create `messaging_notification_preferences`**

Use `user_id`, `category`, `channel`, `enabled` (default true), and timestamps. Constrain categories/channels to the same registered allowlist, add unique `(user_id, category, channel)`, and add the user FK.

- [x] **Step 7: Seed the active notification retention policy**

In `db/seeds/base.rb`, add an idempotent active `messaging_notification` policy with `action: "erase_payload"`, `retention_days: 365`, `effective_at: 1.day.ago`, and `created_by: admin_user`, following the existing version/retirement pattern.

- [x] **Step 8: Run migrations and GREEN schema tests**

```bash
bin/rails db:migrate
N_PLUS_ONE=1 bundle exec rails test test/models/messaging
```

Expected: all schema tests pass and `db/structure.sql` contains every table, check, index, and FK. Verified locally with 6 tests, 19 assertions, zero failures/errors under `N_PLUS_ONE=1`.

- [ ] **Step 9: User-owned commit checkpoint**

```bash
git add db/migrate/20260727090100_create_core_data_retention_policies.rb \
  db/migrate/20260727090102_create_core_data_retention_holds.rb \
  app/models/core/data_retention_policy.rb db/seeds/base.rb \
  db/migrate/20260903090001_create_messaging_notifications.rb \
  db/migrate/20260903090002_create_messaging_notification_deliveries.rb \
  db/migrate/20260903090003_create_messaging_notification_preferences.rb
git commit -m "feat(messaging): add notification delivery schema"
```

---

## Task 2: Add Messaging models and safe type/projection contracts

**Files:** Messaging models, `Core::User`, type-definition/registry/projection files, and their tests.

- [x] **Step 1: Write failing model and registry tests**

Cover associations, status scopes, retention erasure state, mandatory in-app behavior, locale-key presence, deterministic dedupe keys, and secret rejection:

```ruby
test "credential notifications always include in-app" do
  definition = Messaging::NotificationTypes.fetch("ticket_issued")
  assert_equal "credential", definition.category
  assert definition.mandatory?
  assert_includes definition.channels, "in_app"
end

test "projection rejects credentials and raw contacts" do
  assert_raises(Messaging::NotificationProjection::UnsafeData) do
    Messaging::NotificationProjection.call("ticket_issued", { token: "secret" })
  end
end

test "all Messaging models expose only safe Ransack fields" do
  assert_includes Messaging::Notification.ransackable_attributes, "notification_type"
  assert_includes Messaging::Notification.ransackable_attributes, "category"
  assert_includes Messaging::Notification.ransackable_attributes, "read_at"
  assert_includes Messaging::Notification.ransackable_attributes, "available_at"
  refute_includes Messaging::Notification.ransackable_attributes, "data"
  assert_equal %w[notification], Messaging::NotificationDelivery.ransackable_associations
  assert_equal %w[user], Messaging::NotificationPreference.ransackable_associations
end
```

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb
```

Expected: failure because the models and registry are missing.

- [x] **Step 3: Implement the models**

Create `Messaging::ApplicationRecord < Core::ApplicationRecord`, `Notification`, `NotificationDelivery`, and `NotificationPreference`. Add class comments explaining recipient isolation, payload erasure, and per-channel delivery. These high-volume derived rows are not `Core::AuditableModel`; source outbox/audit events remain the business evidence. Validate registered values, object-shaped data, digest format, status timestamps, uniqueness, and the `retain_until`/policy-action contract. Add `visible`, `unread`, `due`, `queued`, and `claimable` scopes. Define explicit `ransackable_attributes` and `ransackable_associations` on all three models so `Core::Filterable` cannot expose undeclared columns; allow only safe fields and associations (`user`, `deliveries`, `retention_policy`, and `notification`).

Add these associations to `Core::User`:

```ruby
has_many :notifications, class_name: "Messaging::Notification",
         dependent: :restrict_with_exception, inverse_of: :user
has_many :notification_preferences, class_name: "Messaging::NotificationPreference",
         dependent: :destroy, inverse_of: :user
```

- [x] **Step 4: Implement the type registry**

Expose `fetch(key)` and immutable definitions with this interface:

```ruby
definition.category
definition.mandatory?
definition.channels
definition.data_keys
definition.locale_scope
definition.recipient_for(source:)
definition.dedupe_key_for(source:, recipient:)
```

Register `payment_succeeded`, `payment_failed`, `ticket_issued`, `credential_replaced`, `refund_succeeded`, `refund_failed`, `transfer_received`, `waitlist_offer_created`, `waitlist_offer_expired`, `registration_rejected`, `consent_reminder`, and `schedule_changed`. Do not register marketing types.

Every dedupe builder must include the authoritative source version when one
exists: `event.schedule_version` for schedule changes, credential generation
version for `credential_replaced`, the terminal event/payment-event identity
for payment and refund notifications, and the waitlist offer's immutable
`offer_expires_at` plus event ID. Tests must prove that schedule version 2,
credential version 2, and a second waitlist offer create new notifications
instead of collapsing onto version 1, while replaying the same identity remains
a no-op.

- [x] **Step 5: Implement the safe projection**

Deep-symbolize only registered fields, reject unknown/forbidden keys (`token`, `qr`, `pnr`, `password`, `secret`, `credential`, `provider`, and raw contact fields), and return a canonical JSON-safe hash. Do not serialize complete domain records.

- [x] **Step 6: Run GREEN and Zeitwerk**

```bash
N_PLUS_ONE=1 bundle exec rails test test/models/messaging test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb
bin/rails zeitwerk:check
```

Expected: zero failures/errors and a successful Zeitwerk check. Verified locally with 12 tests, 34 assertions, zero failures/errors under `N_PLUS_ONE=1`; Zeitwerk check remains part of the final gate.

- [ ] **Step 7: User-owned commit checkpoint**

```bash
git add app/models/messaging app/models/core/user.rb \
  app/services/messaging/notification_type_definition.rb \
  app/services/messaging/notification_types.rb \
  app/services/messaging/notification_projection.rb \
  test/models/messaging test/services/messaging/notification_types_test.rb \
  test/services/messaging/notification_projection_test.rb
git commit -m "feat(messaging): define notification types and safe projections"
```

---

## Task 3: Implement notification creation, preferences, and read state

**Files:** `app/services/messaging/publish_notification.rb`, `mark_notification_read.rb`, `update_preferences.rb`, localized service errors, and their tests.

- [x] **Step 1: Write RED service tests**

Prove first creation, exact replay, conflicting replay, mandatory in-app delivery, optional-channel suppression, retention-policy assignment, concurrent uniqueness, mark-read idempotency, and preference authorization. Use the shared `assert_idempotent` helper for every replayable command; do not hand-roll a count comparison.

Include both retention-policy cases: a policy with `retention_days: 365` sets a
future `retain_until`, while a policy with `action: "retain"` and no days leaves
`retain_until` null and remains valid.

```ruby
subject = -> do
  Messaging::PublishNotification.call(
    type: "ticket_issued", recipient: @user, source: @ticket,
    data: { event_title: "Concert", ticket_label: "General" },
    dedupe_key: "ticket-issued-#{@ticket.id}:v1"
  )
end
assert_idempotent(subject, counter: -> { Messaging::Notification.where(user: @user).count })
```

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/messaging/publish_notification_test.rb \
  test/services/messaging/mark_notification_read_test.rb \
  test/services/messaging/update_preferences_test.rb
```

Expected: failure because the commands do not exist.

- [x] **Step 3: Implement `PublishNotification`**

Use the type registry and projection service, select the active `messaging_notification` retention policy, and set `retain_until` to `Time.current + policy.retention_days.days` when the policy defines retention days. Create the notification inside a transaction with `create_or_find_by!` on `(user_id, dedupe_key)`. On replay, compare type/category/source/data and return the existing row only when the canonical request matches; otherwise return localized `idempotency_conflict`. Create exactly one delivery per registered channel with a SHA-256 idempotency digest. A mandatory type always creates `in_app`; a disabled optional preference creates a `suppressed` row; an unconfigured provider remains eligible for the delivery job to mark `unavailable`.

Document the transaction/idempotency boundary in the class comment. Never call an adapter from this command.

- [x] **Step 4: Implement `MarkNotificationRead`**

Lock the recipient-owned row, set `read_at` once, and return the same record on every replay. A missing or differently owned ID returns the existing localized not-found error. This is the documented exception to the request-receipt rule: setting `read_at` is naturally idempotent and has no external side effect, so the command does not require or persist an `Idempotency-Key`.

- [x] **Step 5: Implement `UpdatePreferences`**

Accept a list of `{ category, channel, enabled }` choices, normalize and validate them against the registry, reject changes to mandatory in-app behavior, and upsert under the unique `(user_id, category, channel)` constraint inside one transaction. The request digest binds the complete sorted choice list to the idempotency key so a changed retry returns `idempotency_conflict`.

- [x] **Step 6: Run GREEN service and concurrency tests**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/messaging/publish_notification_test.rb \
  test/services/messaging/mark_notification_read_test.rb \
  test/services/messaging/update_preferences_test.rb
```

Expected: all service tests pass, including two concurrent `PublishNotification` calls producing one notification and one delivery per channel. Verified locally with 10 tests, 42 assertions, zero failures/errors under `N_PLUS_ONE=1`.

- [ ] **Step 7: User-owned commit checkpoint**

```bash
git add app/services/messaging/publish_notification.rb \
  app/services/messaging/mark_notification_read.rb \
  app/services/messaging/update_preferences.rb \
  config/locales/messaging/notifications.en.yml \
  config/locales/messaging/preferences.en.yml \
  test/services/messaging/publish_notification_test.rb \
  test/services/messaging/mark_notification_read_test.rb \
  test/services/messaging/update_preferences_test.rb
git commit -m "feat(messaging): persist idempotent notifications and preferences"
```

---

## Task 4: Add provider contracts and in-app delivery

**Files:** provider registry, adapter/result classes, in-app adapter, delivery command/job, initializer, and tests.

- [x] **Step 1: Write RED adapter and job tests**

Cover registry lookup, in-app success, missing email/SMS provider as `unavailable`, retryable/permanent adapter results, stale claims, sanitized failure details, and provider request idempotency:

```ruby
test "missing provider is observable without removing the in-app notification" do
  notification = publish_notification("payment_succeeded")
  delivery = notification.deliveries.find_by!(channel: "email")
  result = Messaging::DeliverNotification.call(delivery: delivery)
  assert_predicate result, :success?
  assert_equal "unavailable", delivery.reload.status
  assert_equal "delivered", notification.deliveries.find_by!(channel: "in_app").status
end
```

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/messaging/deliver_notification_test.rb \
  test/services/messaging/providers/registry_test.rb \
  test/jobs/messaging/deliver_notification_job_test.rb
```

Expected: failure because provider contracts and delivery code are missing.

- [x] **Step 3: Implement the provider-neutral adapter contract**

Define:

```ruby
module Messaging
  module Providers
    class Adapter
      def deliver(notification:, delivery:, content:, idempotency_key:)
        raise NotImplementedError, I18n.t("messaging.errors.adapter_not_implemented")
      end
    end
  end
end
```

`DeliveryResult` exposes `status`, `provider`, `provider_message_id`, `retryable`, `failure_code`, and sanitized `failure_detail`. `Registry.fetch(channel:)` returns the registered adapter or `nil`; `in_app` is registered by default, email/SMS are explicit empty slots until a provider plan installs them. Add comments explaining that this is a delivery seam, not campaign billing.

- [x] **Step 4: Implement `InApp` and `DeliverNotification`**

The in-app adapter marks a delivery `delivered` without a network request. `DeliverNotification` locks a delivery, rejects terminal rows, claims it with `claimed_at`, renders locale-backed content from the notification type, releases the lock before invoking an external adapter, and conditionally updates the row only if the claim is still owned. Map adapter results as follows: retryable → `pending` plus `next_attempt_at`; permanent → `failed`; missing adapter → `unavailable`; success → `sent`/`delivered` with timestamps. Store only sanitized failure detail.

- [x] **Step 5: Implement `DeliverNotificationJob`**

Enqueue only `delivery_id`, use `queue_as :notifications`, retry transport exceptions with a bounded polynomial policy, and leave terminal delivery state intact after retries are exhausted. The job must never receive message body secrets or provider credentials in its arguments.

- [x] **Step 6: Register the in-app adapter**

`config/initializers/messaging.rb` creates the registry and registers `in_app`. It must not overwrite adapters registered by a later provider-specific initializer; use the existing registry-registration convention.

- [x] **Step 7: Run GREEN adapter/job tests and RuboCop**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/messaging/deliver_notification_test.rb \
  test/services/messaging/providers/registry_test.rb \
  test/jobs/messaging/deliver_notification_job_test.rb
bundle exec rubocop app/services/messaging app/jobs/messaging config/initializers/messaging.rb
```

Expected: all tests pass and every touched Ruby file is RuboCop-clean. Verified locally with 8 tests, 26 assertions, zero failures/errors under `N_PLUS_ONE=1`; RuboCop reports no offenses across 26 touched files with `RUBOCOP_CACHE_ROOT` redirected to a writable cache.

- [ ] **Step 8: User-owned commit checkpoint**

```bash
git add app/services/messaging/providers app/services/messaging/deliver_notification.rb \
  app/jobs/messaging/deliver_notification_job.rb config/initializers/messaging.rb \
  test/services/messaging/deliver_notification_test.rb \
  test/services/messaging/providers/registry_test.rb \
  test/jobs/messaging/deliver_notification_job_test.rb
git commit -m "feat(messaging): add provider-neutral notification delivery"
```

---

## Task 5: Make the outbox registry composable without losing existing handlers

**Files:** `lib/core/outbox/handler_registry.rb`, `config/application.rb`, `app/services/core/outbox/dispatch.rb`, every existing outbox initializer, and registry/dispatch tests.

- [x] **Step 1: Write RED fan-out tests**

Prove exact handlers run in priority order, every registered handler is invoked once, a later-handler failure causes the event to retry, namespace fallback still excludes security topics, bracket reads/writes remain safe while initializers are migrated, and existing single-handler behavior remains valid:

```ruby
registry = Core::Outbox::HandlerRegistry.new
calls = []
registry.register("orders.payment.fulfilled", priority: 100) { calls << :domain }
registry.register("orders.payment.fulfilled", priority: 200) { calls << :messaging }
registry.fetch("orders.payment.fulfilled").call(event)
assert_equal %i[domain messaging], calls
assert_same registry.fetch("orders.payment.fulfilled"), registry["orders.payment.fulfilled"]
```

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/core/outbox/handler_registry_test.rb \
  test/services/core/outbox/dispatch_test.rb
```

Expected: failure because the registry is currently a plain Hash.

- [x] **Step 3: Implement `HandlerRegistry` and `HandlerChain`**

Create a small `lib/core/outbox/handler_registry.rb` object with `register(event_type, priority: 100, &block)`, `register_namespace(namespace, priority: 100, &block)`, `fetch(event_type)`, `fetch_namespace(namespace)`, `[](event_type)`, and `[]=(event_type, handler)`. Bracket assignment replaces that key with one explicitly registered handler; normal application code uses `register` so composition cannot be silently clobbered. `fetch` returns a chain sorted by priority then registration order; an empty registry returns `nil`. The chain calls each handler once and returns the last result. Add comments stating that handlers must be idempotent because a failed later handler replays earlier handlers.

- [x] **Step 4: Wire the registry into application configuration and dispatch**

Require `lib/core/outbox/handler_registry.rb` before the application configuration is evaluated, initialize `config.x.outbox_handlers` and `config.x.outbox_namespace_handlers` with `Core::Outbox::HandlerRegistry`, then update `Core::Outbox::Dispatch#handler_for` to call `fetch`/`fetch_namespace`. Preserve exact-handler precedence over namespace handlers and the existing security-topic exclusion.

- [x] **Step 5: Convert existing initializers to registration calls**

Replace direct hash assignments with `register(key, priority: 100) { |outbox_event| ... }`. Future Messaging handlers use priority `200`. Do not change existing domain handler bodies except for registration syntax and the duplicate registration-notification enqueue removed in Task 6.

- [x] **Step 6: Audit every handler that can be replayed by a downstream failure**

Add replay tests before accepting the chain: `RegistrationIssuanceReady` must issue no second ticket, `OrderFulfilled` must issue no duplicate package/generation, `PackageIssued` must pass its deterministic key to an idempotent sender, and the refund handlers must produce no duplicate credential transition or audit row. The tests must call the same handler chain twice and assert durable counts/state, not merely assert that a comment or method exists.

- [x] **Step 7: Run GREEN outbox regression tests**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/core/outbox/handler_registry_test.rb \
  test/services/core/outbox/dispatch_test.rb \
  test/jobs/core/dispatch_outbox_event_job_test.rb \
  test/services/core/outbox/publish_test.rb \
  test/services/orders/fulfill_order_test.rb \
  test/services/orders/apply_refund_result_test.rb \
  test/services/ticketing/packages/issue_test.rb \
  test/services/ticketing/outbox_handlers/package_issued_test.rb
```

Expected: all existing outbox tests and the new composition tests pass with unchanged missing-handler/security semantics.

- [ ] **Step 8: User-owned commit checkpoint**

```bash
git add lib/core/outbox/handler_registry.rb config/application.rb \
  app/services/core/outbox/dispatch.rb config/initializers/*outbox_handlers.rb \
  test/services/core/outbox/handler_registry_test.rb \
  test/services/core/outbox/dispatch_test.rb \
  test/services/orders/fulfill_order_test.rb \
  test/services/orders/apply_refund_result_test.rb \
  test/services/ticketing/packages/issue_test.rb \
  test/services/ticketing/outbox_handlers/package_issued_test.rb
git commit -m "refactor(outbox): support ordered handler composition"
```

---

## Task 6: Wire existing transactional events into Messaging

**Files:** `config/initializers/messaging_outbox_handlers.rb`, `app/services/messaging/outbox_handlers/publish_transactional_notification.rb`, `app/jobs/messaging/fanout_notification_job.rb`, `app/services/ticketing/outbox_handlers/registration_issuance_ready.rb`, `app/services/ticketing/waitlist/expire_offer.rb`, `app/services/orders/process_payment_event.rb`, and event integration tests.

- [x] **Step 1: Write RED outbox integration tests**

Use this explicit producer-to-type table in the test helper and initializer:

| Producer event | Notification type | Recipient |
|---|---|---|
| `orders.payment.fulfilled` | `payment_succeeded` | order buyer |
| `orders.payment.failed` *(new producer)* | `payment_failed` | payment order buyer |
| `orders.refund.succeeded` / `orders.refund.failed` | `refund_succeeded` / `refund_failed` | payment order buyer |
| `ticketing.package_issued` | `ticket_issued` | ticket owner |
| `ticketing.credential_generation_replaced` | `credential_replaced` | ticket owner |
| `ticketing.ticket_transfer.accepted` | `transfer_received` | transfer recipient |
| `ticketing.registration.waitlist_offer_created` | `waitlist_offer_created` | registration user |
| `ticketing.registration.waitlist_offer_expired` *(new producer)* | `waitlist_offer_expired` | registration user |
| `ticketing.registration.rejected` | `registration_rejected` | registration user |
| `ticketing.registration_consent.reminder_due` | `consent_reminder` | registration user |
| `events.schedule_changed` | `schedule_changed` | owners/admins of the primary or active collaborator organizations, affected ticket holders, affected registrations |

The two marked producer additions must be implemented and tested before their
handlers are registered.

For each producer, dispatch a fixture event and assert one notification and one in-app delivery for the correct user. Replay the same outbox event and assert no duplicate notification/delivery. Assert an invitation with no `invited_user` continues through `DeliverInvitationJob` and is not forced into the user inbox.

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb \
  test/integration/messaging/outbox_delivery_test.rb \
  test/jobs/ticketing/deliver_invitation_job_test.rb \
  test/services/ticketing/waitlist/expire_offer_test.rb
```

Expected: failure because Messaging handlers are not registered.

- [x] **Step 3: Implement the handler using the type registry**

`Messaging::OutboxHandlers::PublishTransactionalNotification.call(event:)` maps only the producer events in the table above to registered notification types and ID-only payload resolvers. It may load the authoritative aggregate with explicit `.includes(...)`, but it passes only the safe projection to `PublishNotification`. Unknown event types return a typed `unsupported_event` result; missing recipients return `recipient_unavailable`. Add comments explaining why raw outbox payloads never cross the notification boundary.

For `events.schedule_changed`, the handler must enqueue `Messaging::FanoutNotificationJob` with only the outbox event ID and return immediately. The job's authoritative audience is the union of active owners/admins of the event's primary or active collaborator organizations, active ticket holders whose products grant one of the affected `event_date_ids`, and current registrations whose selected date is affected or whose fixed-date product grants an affected date. Deduplicate user IDs in the query, order by user ID, process at most 100 recipients per page, invoke `PublishNotification` per recipient, aggregate individual typed failures, and re-enqueue with the next cursor. It must not loop all recipients while `Core::Outbox::Dispatch` holds its claim.

Register these exact terminal/user-recipient events at priority `200`:

```ruby
%w[
  orders.payment.fulfilled
  orders.refund.succeeded
  orders.refund.failed
  orders.payment.failed
  ticketing.package_issued
  ticketing.credential_generation_replaced
  ticketing.ticket_transfer.accepted
  ticketing.registration.waitlist_offer_created
  ticketing.registration.waitlist_offer_expired
  ticketing.registration.rejected
  ticketing.registration_consent.reminder_due
  events.schedule_changed
].each do |event_type|
  Rails.application.config.x.outbox_handlers.register(event_type, priority: 200) do |outbox_event|
    result = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event: outbox_event)
    raise result.error if result.failure?
    result
  end
end
```

Use the repository's actual producer names when a producer uses a more specific terminal event; do not create a payment notification from `orders.payment_event.received` before payment status is authoritative.

- [x] **Step 4: Add the missing terminal producers**

In `Orders::ProcessPaymentEvent`, when a payment transitions to `failed`, publish one ID-only `orders.payment.failed` outbox event inside the same transaction with an idempotency key derived from the payment-event ID. In `Ticketing::Waitlist::ExpireOffer`, publish one ID-only `ticketing.registration.waitlist_offer_expired` event after the existing status transition using its existing idempotency identity. Add service tests proving each event is emitted once on a replay.

- [x] **Step 5: Remove both legacy duplicate notification paths**

Delete `Ticketing::RegistrationNotificationJob.perform_later(...)` from `Ticketing::OutboxHandlers::RegistrationIssuanceReady` and remove the `waitlist_offer_created/rejected` registration block plus `registration_notification_sender` default from `config/initializers/ticketing_outbox_handlers.rb`. Delete `app/jobs/ticketing/registration_notification_job.rb`; update `test/services/ticketing/packages/issue_test.rb` to assert the Messaging notification instead. Keep invitation delivery (`DeliverInvitationJob`) unchanged because it targets encrypted contacts that may not be users.

Keep `consent_reminder_sender` and `credential_delivery_sender` as separate
no-op-by-default seams. Consent delivery may target an encrypted contact, and
credential delivery transports one-time credential material; neither is the
in-app notification inbox. A future email/SMS provider initializer must compose
or replace those seams explicitly so the same channel is never delivered twice.

- [x] **Step 6: Run GREEN integration tests**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb \
  test/integration/messaging/outbox_delivery_test.rb \
  test/jobs/ticketing/deliver_invitation_job_test.rb \
  test/services/ticketing/waitlist/expire_offer_test.rb \
  test/services/orders/process_payment_event_test.rb \
  test/services/orders/fulfill_order_test.rb \
  test/services/orders/apply_refund_result_test.rb \
  test/services/ticketing/packages/issue_test.rb
```

Expected: mapped events create exactly one notification, existing ticket/refund/registration side effects remain green, and invitation external-contact behavior remains unchanged.

- [ ] **Step 7: User-owned commit checkpoint**

```bash
git rm app/jobs/ticketing/registration_notification_job.rb
git add config/initializers/messaging_outbox_handlers.rb \
  app/services/messaging/outbox_handlers/publish_transactional_notification.rb \
  app/jobs/messaging/fanout_notification_job.rb \
  app/services/ticketing/outbox_handlers/registration_issuance_ready.rb \
  app/services/ticketing/waitlist/expire_offer.rb \
  app/services/orders/process_payment_event.rb \
  config/initializers/ticketing_outbox_handlers.rb \
  test/services/messaging/outbox_handlers \
  test/integration/messaging/outbox_delivery_test.rb \
  test/jobs/ticketing/deliver_invitation_job_test.rb \
  test/services/ticketing/waitlist/expire_offer_test.rb \
  test/services/orders/process_payment_event_test.rb \
  test/services/orders/fulfill_order_test.rb \
  test/services/orders/apply_refund_result_test.rb \
  test/services/ticketing/packages/issue_test.rb
git commit -m "feat(messaging): project transactional outbox events"
```

---

## Task 7: Add bounded scheduling and retention jobs

**Files:** `app/jobs/messaging/process_notifications_job.rb`, `app/jobs/messaging/fanout_notification_job.rb`, `app/jobs/messaging/purge_notification_payloads_job.rb`, `config/recurring.yml`, `config/queue.yml`, and job tests.

- [x] **Step 1: Write RED job tests**

Cover due delivery selection, `SKIP LOCKED` batching, retry timestamps, per-row failure isolation, and payload erasure while preserving the structural notification/delivery row:

```ruby
test "one failed delivery does not starve later rows" do
  failing = queued_delivery(failure: true)
  succeeding = queued_delivery
  Messaging::ProcessNotificationsJob.perform_now
  assert_equal "failed", failing.reload.status
  assert_equal "delivered", succeeding.reload.status
end
```

Add a fan-out audience test that creates an active organization admin, an
active ticket holder on an affected date, a current registration selecting that
date, a current fixed-date registration whose product grants that date, and an
unrelated user. Dispatch a schedule-change event carrying the affected date ID
and assert the first page contains exactly the four relevant user IDs, with no
duplicate IDs and no unrelated recipient.

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/jobs/messaging/process_notifications_job_test.rb \
  test/jobs/messaging/fanout_notification_job_test.rb \
  test/jobs/messaging/purge_notification_payloads_job_test.rb \
  test/performance/messaging_notification_fanout_test.rb
```

Expected: failure because the jobs and recurring entries are missing.

- [x] **Step 3: Implement `ProcessNotificationsJob`**

Select at most 100 rows where status is `pending`, `next_attempt_at` is null or due, and the notification `available_at`/delivery `scheduled_at` is due. Lock with `FOR UPDATE SKIP LOCKED`, enqueue `DeliverNotificationJob` by ID, and isolate/aggregate unexpected per-row errors. Use a queue-specific recurring entry with an `every minute` schedule.

- [x] **Step 4: Implement the bounded fan-out job**

`Messaging::FanoutNotificationJob` accepts `outbox_event_id` and an optional last-user-ID cursor, queries the union of active owners/admins of the primary or active collaborator organizations, active ticket owners for affected dates, and current registrations whose selected or fixed product date is affected in deterministic ID order, then processes at most 100 recipients per page. It calls the idempotent publish command per recipient, logs an aggregate of typed failures, and enqueues the next cursor. A repeated page is safe because `(user_id, dedupe_key)` uniqueness absorbs duplicates. The job is the only place that performs one-to-many schedule-change fan-out; the outbox handler only enqueues it.

- [x] **Step 5: Implement `PurgeNotificationPayloadsJob`**

Select erased-eligible notifications through the `messaging_notification` retention policy, lock bounded batches, set `data` to `{}`, set `erased_at`/`erasure_reason`, and preserve type/category/source/delivery/audit identity. Respect active Core retention holds. Never delete a notification row solely because its payload expired.

- [x] **Step 6: Add recurring and worker configuration**

Add `process_messaging_notifications` on `every minute` and `purge_messaging_notification_payloads` on `every hour at minute 10`, staggered from the existing Core retention purge at minute 5. Keep `queue_as :notifications`; `config/queue.yml` currently uses a wildcard worker, so retain that coverage and add a comment/assertion that the notifications queue is intentionally included rather than adding a competing duplicate worker.

- [x] **Step 7: Run GREEN jobs and recurring syntax checks**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/jobs/messaging/process_notifications_job_test.rb \
  test/jobs/messaging/fanout_notification_job_test.rb \
  test/jobs/messaging/purge_notification_payloads_job_test.rb \
  test/performance/messaging_notification_fanout_test.rb
bin/rails runner 'YAML.load_file("config/recurring.yml")'
```

Expected: all tests pass, the scheduler file parses, and a failed row does not block later rows.

- [ ] **Step 8: User-owned commit checkpoint**

```bash
git add app/jobs/messaging/process_notifications_job.rb \
  app/jobs/messaging/fanout_notification_job.rb \
  app/jobs/messaging/purge_notification_payloads_job.rb config/recurring.yml \
  config/queue.yml \
  test/jobs/messaging test/performance/messaging_notification_fanout_test.rb
git commit -m "feat(messaging): add bounded notification scheduling and retention"
```

---

## Task 8: Add recipient-scoped notification and preference APIs

**Files:** Messaging application/controller/policy/serializer files, `config/routes.rb`, locale files, and integration tests.

- [x] **Step 1: Write RED integration tests**

Cover authenticated list/detail, ownership isolation, pagination/filtering/ordering, repeated mark-read, preference read/update, missing `Idempotency-Key` on preference updates, mandatory-category rejection, serializer privacy, and localized errors:

```ruby
test "mark read is a safe repeated state set" do
  post "/notifications/#{@notification.id}/read", headers: user_headers
  assert_response :success
  first_read_at = @notification.reload.read_at
  post "/notifications/#{@notification.id}/read", headers: user_headers
  assert_response :success
  assert_equal first_read_at, @notification.reload.read_at
end

test "missing idempotency key returns 400 for preference update" do
  patch "/notification_preferences", params: { preferences: [] }.to_json,
        headers: user_headers.merge("Content-Type" => "application/json")
  assert_response :bad_request
  assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
end

test "another user cannot read the notification" do
  get "/notifications/#{@notification.id}", headers: other_user_headers
  assert_response :not_found
end
```

- [x] **Step 2: Run RED**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/integration/messaging/notifications_test.rb \
  test/integration/messaging/notification_preferences_test.rb
```

Expected: failure because routes/controllers/policies/serializers are missing.

- [x] **Step 3: Implement controllers and policies**

`Messaging::ApplicationController < Core::ApplicationController` includes `Core::Pagination` and `Core::Filterable`. `NotificationsController#index` sets `@clazz`, authorizes the current-user scope, applies `available_at`, unread/category/type filters through `filter_records`, explicit `.includes(:deliveries)`, `eager_load_config`, `allowed_order_columns`, ordering, and pagination, then renders through `Core::JsonResponse`. Define `model_params`, `eager_load_config`, `allowed_order_columns`, and `serializer_profile` explicitly for each action so fields and delivery association visibility stay policy-gated and Ransack cannot expose undeclared data. `show` uses the policy scope. `read` is a naturally idempotent state set and calls exactly one `MarkNotificationRead` command without requiring a request receipt. `NotificationPreferencesController#show/update` defines its own `model_params` for the preference list, calls exactly one query/command, and the update uses the shared `Idempotency-Key` resolver and canonical request digest.

Define explicit `VISIBILITY` in both policies. `NotificationPolicy::Scope` returns only `where(user_id: user.id)`; there is no admin read-all bypass. Add comments for recipient isolation and mandatory-channel behavior.

- [x] **Step 4: Implement serializers with the profile contract**

`NotificationSerializer` exposes `id`, `notification_type`, `category`, safe `data`, `read_at`, `available_at`, `created_at`, and sanitized delivery summaries. `NotificationDeliverySerializer` exposes only `channel`, `status`, `sent_at`, `delivered_at`, `failed_at`, and safe failure code; omit provider credentials, provider message IDs, raw failure detail, idempotency digests, and outbox IDs. `NotificationPreferenceSerializer` exposes category/channel/enabled. Include `Core::AttributeVisibilitySerializer`, explicit fields, and no broad association includes.

- [x] **Step 5: Add routes and locale entries**

Add:

```ruby
resources :notifications, only: %i[index show], controller: "messaging/notifications" do
  post :read, on: :member
end
resource :notification_preferences, only: %i[show update],
  controller: "messaging/notification_preferences"
```

Add all success/error strings and type title/body keys to `config/locales/messaging/*.en.yml`; controllers/services must use `I18n.t`, never literals.

- [x] **Step 6: Run GREEN API tests and route/locale checks**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/integration/messaging/notifications_test.rb \
  test/integration/messaging/notification_preferences_test.rb
bin/rails routes | rg 'notifications|notification_preferences'
bundle exec rubocop app/controllers/messaging app/policies/messaging \
  app/serializers/messaging app/services/messaging config/routes.rb
```

Expected: all API tests pass, route methods match the design, and touched files are RuboCop-clean.

- [ ] **Step 7: User-owned commit checkpoint**

```bash
git add app/controllers/messaging app/policies/messaging app/serializers/messaging \
  config/routes.rb config/locales/messaging \
  test/integration/messaging/notifications_test.rb \
  test/integration/messaging/notification_preferences_test.rb
git commit -m "feat(messaging): expose notification inbox and preferences"
```

---

## Task 9: Synchronize Postman, seeds, documentation, and roadmap sequencing

**Files:** `postman/Digis API_collection.json`, `db/seeds/base.rb`/`db/seeds/preview.rb` when fixtures are needed, and `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md`.

- [x] **Step 1: Add deterministic preview notification fixtures**

Seed valid source records through existing services, then publish one representative notification per supported category for the seeded attendee and organizer. Do not insert terminal delivery states by hand; dispatch the in-app adapter or use a test helper that exercises the real command. Keep seed reruns idempotent and never add campaigns, credits, or provider secrets.

- [x] **Step 2: Add Postman requests and examples**

Add a `Notifications` folder with the five routes from the design. Include `Authorization`, `Idempotency-Key` on preference updates, unread/category/type query examples, a successful inbox response, a mark-read response, a preference update response, and the `400 missing_idempotency_key` example for preference updates. Validate the collection with:

```bash
bin/rails runner 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "postman JSON valid"'
```

- [x] **Step 3: Update the master roadmap sequence**

Add a post-Launch-Hardening Messaging sequence without marking future work complete:

1. Messaging Notification Foundation (this plan) after the current contract follow-ups and Launch Hardening gate.
2. Messaging Credit/Billing plan after this foundation; it owns rates, the organization credit ledger, Chapa/Orders top-ups, reservations, settlement, failed-delivery refunds, and provider costs.
3. Marketing Campaigns plan after credit/billing; it owns campaigns, audience snapshots, consent/suppression, scheduling, links, delivery analytics, and organizer/admin APIs.

State explicitly that the credit ledger is separate from finance payout ledgers and campaigns cannot bypass notification delivery or consent contracts.

- [x] **Step 4: Run seed and documentation checks**

```bash
N_PLUS_ONE=1 bundle exec rails test test/seeds_test.rb
bin/rails runner 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "postman JSON valid"'
git diff --check
```

Expected: preview seeds converge on repeated runs, Postman parses, and no diff errors exist.

- [ ] **Step 5: User-owned commit checkpoint**

```bash
git add postman/'Digis API_collection.json' db/seeds/base.rb db/seeds/preview.rb \
  docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md \
  docs/superpowers/specs/2026-09-03-messaging-notification-foundation-design.md \
  docs/superpowers/plans/2026-09-03-messaging-notification-foundation-implementation.md
git commit -m "docs(messaging): document notification contracts and follow-ups"
```

---

## Task 10: Final acceptance gate

**Files:** update this plan's checkboxes and verification evidence only after the commands pass.

- [x] **Step 1: Run the focused Messaging suite with N+1 detection**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/models/messaging \
  test/services/messaging \
  test/jobs/messaging \
  test/integration/messaging \
  test/performance/messaging_notification_fanout_test.rb \
  test/services/core/outbox/handler_registry_test.rb \
  test/services/core/outbox/dispatch_test.rb
```

Expected: zero failures and zero errors; record the exact test/assertion counts in this plan.

- [x] **Step 2: Run affected-domain regressions**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/orders test/services/ticketing test/services/events \
  test/jobs/core test/jobs/ticketing test/integration/orders \
  test/integration/ticketing test/integration/events
```

Expected: existing payment, refund, ticket issuance, transfer, registration, schedule, and outbox behavior remains green.

- [x] **Step 3: Run repository quality gates**

```bash
bundle exec rubocop
bin/brakeman
bin/rails zeitwerk:check
bin/rails routes >/tmp/digis-routes.txt
git diff --check
```

Expected: RuboCop and Brakeman clean, Zeitwerk successful, notification routes present, and no diff errors.

- [x] **Step 4: Run the full suite with N+1 detection**

```bash
N_PLUS_ONE=1 bundle exec rails test
```

Expected: zero failures, zero errors, and no regression in the repository's current full-suite baseline. If unrelated baseline failures exist, record their exact names and keep this plan incomplete until Messaging-related failures are isolated and fixed.

- [x] **Step 5: Review the final diff**

Confirm that:

- no campaign, credit, provider credential, or payout-ledger behavior entered the branch;
- every new public service/job/controller has a responsibility comment;
- idempotency, privacy, retention, locking, and provider-boundary comments explain rationale;
- every API change has locale, serializer, route, Postman, seed, and test updates;
- `db/structure.sql` reflects the migrations;
- no user-facing messages are hard-coded;
- the plan and master roadmap identify campaign/credit follow-ups without claiming them complete.

- [ ] **Step 6: User-owned final commit checkpoint**

```bash
git rm --ignore-unmatch app/jobs/ticketing/registration_notification_job.rb
git add app/models/core/user.rb app/models/core/data_retention_policy.rb \
  app/models/messaging app/services/core/outbox/dispatch.rb \
  app/services/messaging app/services/orders/process_payment_event.rb \
  app/services/ticketing/outbox_handlers/registration_issuance_ready.rb \
  app/services/ticketing/waitlist/expire_offer.rb \
  app/jobs/messaging \
  app/controllers/messaging \
  app/policies/messaging app/serializers/messaging \
  config/application.rb config/initializers/*outbox_handlers.rb config/queue.yml \
  config/initializers/messaging.rb config/initializers/messaging_outbox_handlers.rb \
  config/recurring.yml config/routes.rb config/locales/messaging \
  db/migrate/20260727090100_create_core_data_retention_policies.rb \
  db/migrate/20260727090102_create_core_data_retention_holds.rb \
  db/migrate/20260903090001_create_messaging_notifications.rb \
  db/migrate/20260903090002_create_messaging_notification_deliveries.rb \
  db/migrate/20260903090003_create_messaging_notification_preferences.rb \
  db/seeds/base.rb lib/core/outbox/handler_registry.rb \
  postman/'Digis API_collection.json' test/models/messaging \
  test/services/messaging test/services/core/outbox \
  test/jobs/messaging test/jobs/ticketing/deliver_invitation_job_test.rb \
  test/services/ticketing/waitlist/expire_offer_test.rb \
  test/performance/messaging_notification_fanout_test.rb \
  test/integration/messaging \
  docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md \
  docs/superpowers/specs/2026-09-03-messaging-notification-foundation-design.md \
  docs/superpowers/plans/2026-09-03-messaging-notification-foundation-implementation.md
git commit -m "feat(messaging): ship transactional notification foundation"
```

Do not run this command automatically; the repository owner reviews and commits it.

## Verification checkpoint (2026-09-03)

- Focused Messaging/outbox suite with `N_PLUS_ONE=1`: 56 tests, 186
  assertions, zero failures/errors.
- Affected Orders/Ticketing/Events jobs and integration suite with
  `N_PLUS_ONE=1`: 801 tests, 3,950 assertions, zero failures/errors.
- Full Rails suite with `N_PLUS_ONE=1`: 2,942 tests, 12,271 assertions, zero
  failures/errors, four skips.
- `bundle exec rubocop`: 1,645 files inspected, no offenses.
- `bin/brakeman`: Brakeman 8.0.6, zero security warnings (five ignored by the
  existing configuration).
- Zeitwerk, recurring YAML, Postman JSON, and `git diff --check` all pass.
- The user-owned commit checkpoints above remain intentionally unchecked; no
  files were staged or committed by the agent.

## Mandatory post-completion handoff

After this plan's final acceptance gate and user-owned commit, do not start
campaign work directly. First author and review the separate Messaging
Credit/Billing design and implementation plan, including the organization
credit ledger and Chapa/Orders top-up boundary. After Credit/Billing is
implemented and accepted, author and review the separate Marketing Campaigns
design and implementation plan. The master roadmap contains this sequence so
the next task remains visible across branches and sessions.

The post-review hardening plan is a prerequisite to this handoff; it does not
expand the notification foundation into campaigns or credit billing. The
separate Credit/Billing plan is now accepted and owns the organization credit
ledger, rate precedence, top-up payment boundary, and reservation settlement;
Marketing Campaigns must consume those contracts rather than add a second
balance or delivery path.
