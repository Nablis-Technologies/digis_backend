# Messaging Notification Foundation Hardening Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the real post-review reliability and scale gaps in the already-implemented Messaging Notification Foundation without changing the campaign or credit/billing scope.

**Architecture:** Preserve the existing recipient-owned notification model, outbox composition, digest-only payload policy, and provider-neutral adapters. Add only durable lease/digest metadata and short per-row maintenance transactions needed to make replay, scheduling, and purge behavior explicit under races.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL UUIDv7/check constraints/indexes, Solid Queue, ActiveModelSerializers, Minitest, Prosopite, RuboCop, and Brakeman.

**Parent plan:** `docs/superpowers/plans/2026-09-03-messaging-notification-foundation-implementation.md`

---

## Scope decisions

- Fix: failed-result propagation in `Core::Outbox::HandlerRegistry`.
- Fix: delivery claim ownership loss and misleading duplicate `sent_at` branch.
- Fix: compute one notification projection per event.
- Fix: preserve a non-sensitive projection digest so erased rows still detect conflicting key reuse.
- Fix: make purge locks short-lived and batch retention scopes/hold checks while preserving per-row advisory-lock rechecks.
- Fix: add a scheduler enqueue lease so the minute sweep does not repeatedly enqueue the same pending row.
- Fix: compose provider registries without discarding registrations from another initializer.
- Fix: keep exact/namespace handler storage separate and remove the typed-dispatch Hash fallback.
- Fix: make each notification definition own its source-aware projection.
- Fix: keep the outbox privacy boundary on persisted `Core::OutboxEvent` rows in tests and production.
- Add regression/performance tests for each behavior.
- Do not change the fan-out algorithm; its per-source `PAGE_SIZE + 1` bounded merge is correct for a global cursor. Add a large-audience cursor regression test.
- Do not change the already eager-loaded cancellation replay path; the reported `ticket_suspensions` warning does not apply to its private caller.

## Task 1: Harden ordered outbox chains

**Files:** `lib/core/outbox/handler_registry.rb`, `config/locales/core/errors.en.yml`, `test/services/core/outbox/handler_registry_test.rb`.

- [x] **Step 1: Add a failing test for a returned failure result**

Register a handler that returns `Core::BaseService::Result.failure(Core::Error.new(...))`, followed by a marker handler. Assert that the chain raises the returned error and the marker is not called.

- [x] **Step 2: Implement failure propagation**

After each handler call, inspect a result that responds to `failure?`. Raise its `error` when present; otherwise raise a localized `Core::Error` so a failed result can never be treated as a published event.

- [x] **Step 3: Run the registry and dispatch tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/core/outbox/handler_registry_test.rb test/services/core/outbox/dispatch_test.rb
```

Expected: all tests pass and an outbox chain cannot silently acknowledge a failed result.

## Task 2: Make delivery finalization claim-aware

**Files:** `app/services/messaging/deliver_notification.rb`, `config/locales/messaging/notifications.en.yml`, `test/services/messaging/deliver_notification_test.rb`.

- [x] **Step 1: Add failing tests**

Cover a finalization update that affects zero rows and assert the service returns a failure with `delivery_claim_lost`, and assert a successful delivery sets `sent_at` once without a redundant ternary branch.

- [x] **Step 2: Implement the ownership boundary**

Define a localized `ClaimLost` error. Make `update_claimed` check the `update_all` count and raise when the row is no longer owned. Clear any scheduler enqueue lease when a delivery worker successfully claims a row. Collapse `sent_at` to one timestamp assignment.

- [x] **Step 3: Run delivery tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/messaging/deliver_notification_test.rb test/jobs/messaging/deliver_notification_job_test.rb
```

## Task 3: Preserve erased-row idempotency with a projection digest

**Files:** original `db/migrate/20260903090001_create_messaging_notifications.rb`, `app/models/messaging/notification.rb`, `app/services/messaging/publish_notification.rb`, `app/jobs/messaging/purge_notification_payloads_job.rb`, `db/structure.sql`, and Messaging model/service tests.

- [x] **Step 1: Add failing tests**

Create a notification, erase its payload through the purge job, then replay the same projection (success) and a different projection under the same `(user_id, dedupe_key)` (localized `notification_idempotency_conflict`). Assert the stored digest remains unchanged after erasure.

- [x] **Step 2: Add the digest column to the original migration**

Add a required lowercase SHA-256 `projection_digest` column and database format check to the original Messaging notification migration. The model callback computes it from canonical JSON only when the row is new or the digest is blank; purge uses `update_columns` and therefore preserves it.

- [x] **Step 3: Compare the digest on every replay**

Compute the canonical digest once in `PublishNotification`, compare it before the erased-row branch, and allow an exact replay even when `data` is `{}`. Conflicting replays must fail closed without restoring erased payload data.

- [x] **Step 4: Run the idempotency and purge tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/models/messaging test/services/messaging/publish_notification_test.rb test/jobs/messaging/purge_notification_payloads_job_test.rb
```

## Task 4: Bound purge transactions and retention lookups

**Files:** `app/jobs/messaging/purge_notification_payloads_job.rb`, `test/jobs/messaging/purge_notification_payloads_job_test.rb`, `test/performance/messaging_notification_fanout_test.rb` if a maintenance benchmark is added.

- [x] **Step 1: Add a failing transaction/hold-scale test**

Create a bounded batch and assert each row is processed in its own transaction boundary, active holds prevent erasure, and multiple source types do not issue three hold queries per notification.

- [x] **Step 2: Select IDs, then lock one row per short transaction**

Replace the outer page transaction with a candidate-ID query. For every ID, open a short transaction, lock and re-read the notification, acquire the same ordered `retention-scope` advisory locks used by hold placement, recheck eligibility/holds, and update only that row.

- [x] **Step 3: Batch scope resolution and hold matching**

Resolve event/registration scope IDs for the page with bounded Active Record queries grouped by `source_type`, eliminating polymorphic source and nested order/payment loads from the row loop. Each locked row performs one combined active-hold existence query after acquiring the shared advisory scope locks; this recheck is required because a hold can be placed after the page query but before the row update.

- [x] **Step 4: Run purge tests with N+1 detection**

```bash
N_PLUS_ONE=1 bundle exec rails test test/jobs/messaging/purge_notification_payloads_job_test.rb
```

## Task 5: Lease scheduler enqueues

**Files:** original `db/migrate/20260903090002_create_messaging_notification_deliveries.rb`, `app/models/messaging/notification_delivery.rb`, `app/jobs/messaging/process_notifications_job.rb`, `app/services/messaging/deliver_notification.rb`, `db/structure.sql`, and scheduler tests.

- [x] **Step 1: Add failing duplicate-sweep test**

Run the scheduler twice before the delivery worker runs. Assert the same pending delivery is enqueued once while its lease is fresh, and that a stale lease becomes eligible again. Assert an enqueue failure does not prevent other rows from being enqueued.

- [x] **Step 2: Add an enqueue lease**

Add nullable `enqueue_claimed_at` to the original delivery migration and claimable index. In `ProcessNotificationsJob`, lock due rows, set the lease in a short transaction, then enqueue only the delivery ID. Fresh leases are excluded; stale leases recover.

- [x] **Step 3: Release the lease when the worker claims the row**

When `DeliverNotification` changes a row to `processing`, clear `enqueue_claimed_at`. A failed/ambiguous enqueue leaves the lease for bounded recovery rather than immediately creating a duplicate storm.

- [x] **Step 4: Run scheduler and delivery tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/jobs/messaging/process_notifications_job_test.rb test/services/messaging/deliver_notification_test.rb
```

## Task 6: Preserve provider registry composition and simplify projection

**Files:** `config/initializers/messaging.rb`, `app/services/messaging/outbox_handlers/publish_transactional_notification.rb`, `test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb`, `test/services/messaging/providers/registry_test.rb`.

- [x] **Step 1: Add failing registry-composition and single-projection tests**

Pre-populate the configured provider registry, run the Messaging initializer callback, and assert the pre-existing adapter remains registered. Stub the publisher and assert the outbox handler passes the same computed projection to both `data` and dedupe-key generation.

- [x] **Step 2: Make initializer registration additive**

Use the existing registry when present, create it only when absent, and register `in_app` only if no adapter is already registered for that channel.

- [x] **Step 3: Compute `data_for` once**

Assign the projection to a local and reuse it for publishing and dedupe identity. The persisted-ID source path is the only supported resolution path; tests use real `Core::OutboxEvent` rows.

- [x] **Step 4: Run outbox/provider tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/messaging/outbox_handlers test/services/messaging/providers test/integration/messaging
```

## Task 7: Extract retention scope resolution

**Files:** `app/services/messaging/retention_scope_resolver.rb`, `app/jobs/messaging/purge_notification_payloads_job.rb`, `test/services/messaging/retention_scope_resolver_test.rb`, and purge tests.

- [x] **Step 1: Add a resolver contract test**

Exercise the resolver with an empty ID page and with notifications whose source types resolve to event and registration scopes. Assert the result is an `{ notification_id => { user_ids:, event_ids:, registration_ids: } }` map and that duplicate scope IDs are unique.

- [x] **Step 2: Extract the resolver**

Move source-type grouped queries out of the purge job into `Messaging::RetentionScopeResolver`. Keep the job responsible only for candidate IDs, per-row advisory locking/hold checks, erasure, and summary aggregation.

- [x] **Step 3: Run resolver and purge tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/messaging/retention_scope_resolver_test.rb test/jobs/messaging/purge_notification_payloads_job_test.rb
```

## Task 8: Co-locate definition-owned projections

**Files:** `app/services/messaging/notification_type_definition.rb`, `app/services/messaging/notification_types.rb`, `app/services/messaging/outbox_handlers/publish_transactional_notification.rb`, and Messaging type/outbox tests.

- [x] **Step 1: Add a failing projection contract test**

Require a fetched definition to expose `project(source:, payload:)` and assert a payment projection uses authoritative source IDs while preserving allowed payload fields.

- [x] **Step 2: Move source-aware projection rules into definitions**

Add the projector to `NotificationTypeDefinition`, provide a projector for every registered type, and have the outbox handler call `definition.project` before `PublishNotification`. Keep `NotificationProjection` as the final forbidden-key/allowlist validator.

- [x] **Step 3: Remove the duplicate handler projection path and run tests**

The handler must not contain a second type switch for projection. Run:

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/messaging/notification_types_test.rb test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb test/services/messaging/notification_projection_test.rb
```

## Task 9: Make the registry single-owner and tests persisted

**Files:** `lib/core/outbox/handler_registry.rb`, `config/application.rb`, `app/services/core/outbox/dispatch.rb`, `test/jobs/core/dispatch_outbox_event_job_test.rb`, `test/services/core/outbox/handler_registry_test.rb`, and `test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb`.

- [x] **Step 1: Add the exact/namespace collision regression**

Register the same string as an exact key and namespace key in one registry and assert each lookup returns only its own handler.

- [x] **Step 2: Split registry stores and remove dispatch fallbacks**

Keep exact and namespace entries in separate internal maps, point both application config entries at the same registry object, and call only `fetch`/`fetch_namespace` from Dispatch. Convert existing Hash-overriding tests to `HandlerRegistry` instances.

- [x] **Step 3: Remove the materialized aggregate test door**

Use real `Core::Outbox::Publish` rows and authoritative aggregate IDs in the transactional notification tests. Remove the `respond_to?(:aggregate)` branch from `source_for` so tests and production resolve sources identically.

- [x] **Step 4: Run registry, dispatch, and outbox integration tests**

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/core/outbox/handler_registry_test.rb test/services/core/outbox/dispatch_test.rb test/jobs/core/dispatch_outbox_event_job_test.rb test/services/messaging/outbox_handlers test/integration/messaging
```

## Task 10: Lock down bounded fan-out cursoring

**Files:** `app/jobs/messaging/fanout_notification_job.rb`, `test/performance/messaging_notification_fanout_test.rb`.

- [x] **Step 1: Add the 110+110 multi-page regression**

Use two UUID-string source lists of 110 recipients each, apply the same `PAGE_SIZE + 1` source bounds and global cursor, and assert every sorted unique recipient is delivered exactly once across pages.

- [x] **Step 2: Keep the production merge bounded and deterministic**

Route the existing audience merge through one helper that deduplicates and sorts string UUIDs. Do not replace the proven per-source bounded merge with an unbounded in-memory audience query.

- [x] **Step 3: Run the fan-out performance test**

```bash
N_PLUS_ONE=1 bundle exec rails test test/performance/messaging_notification_fanout_test.rb test/jobs/messaging/fanout_notification_job_test.rb
```

## Task 11: Acceptance gate

**Files:** this plan and the existing parent plan's verification section.

- [x] **Step 1: Run focused Messaging/outbox tests**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/models/messaging test/services/messaging test/jobs/messaging \
  test/integration/messaging test/performance/messaging_notification_fanout_test.rb \
  test/services/core/outbox/handler_registry_test.rb test/services/core/outbox/dispatch_test.rb
```

- [x] **Step 2: Run affected-domain regressions and quality gates**

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/orders test/services/ticketing test/services/events \
  test/jobs/core test/jobs/ticketing test/integration/orders \
  test/integration/ticketing test/integration/events
RUBOCOP_CACHE_ROOT=/tmp/digis-rubocop-cache bundle exec rubocop --parallel
bin/brakeman --quiet --no-pager
bin/rails zeitwerk:check
git diff --check
```

- [x] **Step 3: Review the final diff**

Confirm no campaign/credit code entered the branch, no provider credentials are persisted, all new messages are localized, the original migrations and `db/structure.sql` agree, and no unrelated user-owned dirty files were staged.

- [ ] **Step 4: User-owned commit checkpoint**

Do not stage or commit automatically. The repository owner reviews and commits the focused hardening changes.

## Verification status

The resolver regression passed: 2 tests, 5 assertions, zero failures/errors.
The focused Messaging/outbox suite passed: 79 tests, 249 assertions, zero
failures/errors. The affected-domain suite passed: 801 tests, 3,950 assertions,
zero failures/errors. The full Rails suite passed: 2,955 tests, 12,314
assertions, zero failures/errors, four skips, all with `N_PLUS_ONE=1`.
RuboCop inspected 1,647 files with no offenses; Brakeman 8.0.6 reports zero
security warnings (five ignored by existing configuration); Zeitwerk, Postman
JSON, recurring YAML, and `git diff --check` pass.
