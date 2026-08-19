# Launch Hardening and Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the complete event platform is secure, observable, recoverable, and operationally safe before production traffic or organizer funds are accepted.

**Architecture:** Keep liveness cheap, expose authenticated dependency readiness separately, and instrument domain commands through one privacy-safe telemetry seam. Reconciliation is the repair path for uncertain provider outcomes; it never invents financial truth. Domain-specific supervisors remain small and delegate to commands owned by Orders, Payments, Refunds, Finance, Ticketing, and Admission. This phase adds tests and operating controls, not a second business architecture.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL, ActiveSupport::Notifications, Solid Queue, Active Record Encryption, Minitest, Brakeman, Bundler Audit, Prosopite.

---

**Normative specifications:** `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md` and `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`. The launch gate must prove both contracts rather than reinterpret them.

## Entry criteria

- All preceding phase plans in `2026-07-17-event-platform-master-roadmap.md` are green.
- Provider adapters have deterministic fakes and persist raw provider references, not secrets.
- Every externally-triggered mutation has a database uniqueness boundary and idempotency test.
- Ticket credentials use Ed25519 signatures, credential generations, revocations, and slot/access-level usage.

## Task 1: Add privacy-safe domain telemetry

**Files:**
- Create: `app/lib/core/telemetry.rb`
- Create: `test/lib/core/telemetry_test.rb`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Modify: `config/locales/core/errors.en.yml`

- [x] **Step 1: Write the failing telemetry tests**

```ruby
# frozen_string_literal: true

require "test_helper"

class Core::TelemetryTest < ActiveSupport::TestCase
  test "emits only approved operational fields" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("digis.orders.place") do |event|
      events << event.payload
    end

    Core::Telemetry.instrument(
      "orders.place",
      command_id: "cmd-1",
      organization_id: "org-1",
      outcome: "succeeded",
      email: "secret@example.com"
    ) { :completed }

    assert_equal :completed, events.one? && :completed
    assert_equal "cmd-1", events.first.fetch(:command_id)
    assert_not events.first.key?(:email)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "rejects malformed event names" do
    assert_raises(ArgumentError) { Core::Telemetry.instrument("Orders Place") {} }
  end
end
```

- [x] **Step 2: Run the test and verify RED**

```bash
N_PLUS_ONE=1 bin/rails test test/lib/core/telemetry_test.rb
```

RED captured: 3 tests, 5 assertions, 2 failures, and 1 error because
`Core::Telemetry` did not exist and the new sensitive-key contract was not yet
configured.

- [x] **Step 3: Implement the allowlisted telemetry seam**

```ruby
# frozen_string_literal: true

module Core
  module Telemetry
    SAFE_KEYS = %i[
      command_id aggregate_type aggregate_id organization_id event_id
      provider outcome code count currency duration_ms batch_id device_id
    ].freeze
    NAME_PATTERN = /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/

    module_function

    def instrument(name, **payload, &block)
      raise ArgumentError, "invalid telemetry event name" unless NAME_PATTERN.match?(name)

      ActiveSupport::Notifications.instrument(
        "digis.#{name}",
        payload.symbolize_keys.slice(*SAFE_KEYS),
        &block
      )
    end
  end
end
```

Add `:token`, `:qr`, `:credential`, `:lookup_code`, `:pnr`, `:invitation`, `:phone`, `:email`, `:id_number`, `:provider_payload`, and `:webhook_body` to the parameter filter. Do not log request bodies from payment, transfer, registration, or scan endpoints.

- [x] **Step 4: Run the tests and verify GREEN**

```bash
N_PLUS_ONE=1 bin/rails test test/lib/core/telemetry_test.rb test/controllers
```

Verified: 75 tests, 310 assertions, 0 failures, and 0 errors. The complete
CI-equivalent suite passes 2,693 tests and 11,196 assertions with zero failures
and zero errors under `N_PLUS_ONE=1`; RuboCop and Zeitwerk also pass.

- [ ] **Step 5: Commit — user-owned**

```bash
git add app/lib/core/telemetry.rb test/lib/core/telemetry_test.rb config/initializers/filter_parameter_logging.rb config/locales/core/errors.en.yml docs/superpowers/plans/2026-07-17-launch-hardening-observability-implementation.md
git commit -m "feat(core): add privacy-safe domain telemetry"
```

## Task 2: Separate liveness from authenticated readiness

**Files:**
- Create: `app/services/admin/system/readiness.rb`
- Create: `app/controllers/admin/system/readiness_controller.rb`
- Create: `app/policies/admin/system/readiness_policy.rb`
- Create: `test/services/admin/system/readiness_test.rb`
- Create: `test/integration/admin/system/readiness_test.rb`
- Modify: `config/routes.rb`
- Modify: `postman/Digis API_collection.json`

- [x] **Step 1: Write failing tests**

Test that `/up` remains an unauthenticated process-only liveness check, while `GET /admin/system/readiness` requires a platform administrator. The readiness result must expose only `ok`/`degraded` plus component names; it must not return hosts, credentials, exception messages, queue contents, or provider secrets.

```ruby
# frozen_string_literal: true

require "test_helper"

class Admin::System::ReadinessTest < ActiveSupport::TestCase
  test "checks local dependencies without calling payment providers" do
    result = Admin::System::Readiness.call

    assert result.success?
    assert_equal %w[database encryption outbox queue storage], result.value.fetch(:components).keys.sort
    assert_includes %w[ok degraded], result.value.fetch(:status)
  end
end
```

- [x] **Step 2: Run focused tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/admin/system/readiness_test.rb test/integration/admin/system/readiness_test.rb
```

RED captured: 5 tests could not load because `Admin::System::Readiness` was
not yet defined.

- [x] **Step 3: Implement readiness checks**

`Admin::System::Readiness` must execute bounded local checks only:

- primary database: `SELECT 1`;
- Solid Queue database/connection: connection checkout and `SELECT 1`;
- outbox: count undispatched rows older than the configured warning threshold; a sustained non-zero count means the Plan 0 enqueuer (`Core::ProcessOutboxJob`, core-foundation Task 5 Step 8) is not scheduled or not draining, not merely a transient backlog;
- storage: verify the configured service and required bucket/container configuration without uploading a probe object;
- encryption: verify primary, deterministic, and salt configuration is present without returning key material.

Return a typed service result. A failed component produces `degraded`, not an exception-shaped API response. Provider network availability belongs to provider reconciliation, never readiness. The implementation checks the primary database, Solid Queue connection, stale undispatched outbox rows, configured storage service, and encryption key presence without returning dependency details.

- [x] **Step 4: Add authorization and route**

Add the controller under the existing admin authentication and Pundit boundary:

```ruby
def show
  authorize [:admin, :system, :readiness], :show?
  render_service_result Admin::System::Readiness.call
end
```

Add `get "system/readiness", to: "system/readiness#show"` inside the existing unversioned `namespace :admin`. The policy permits only a platform administrator role, not an organizer role.

- [x] **Step 5: Run focused and authorization tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/admin/system/readiness_test.rb test/integration/admin/system/readiness_test.rb test/policies
```

Verified: 35 tests, 162 assertions, 0 failures, and 0 errors with
`N_PLUS_ONE=1`. The full suite passes 2,698 tests and 11,220 assertions with
zero failures and zero errors. RuboCop, Zeitwerk, route, locale, Postman JSON,
and diff checks pass.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/services/admin/system/readiness.rb app/controllers/admin/system/readiness_controller.rb app/policies/admin/system/readiness_policy.rb test/services/admin/system/readiness_test.rb test/integration/admin/system/readiness_test.rb config/routes.rb postman/'Digis API_collection.json' docs/superpowers/plans/2026-07-17-launch-hardening-observability-implementation.md
git commit -m "feat(admin): add authenticated dependency readiness"
```

## Task 3: Add domain-owned reconciliation supervisors

**Files:**
- Create: `app/jobs/reconciliation/supervisor_job.rb`
- Create: `app/jobs/reconciliation/support.rb`
- Create: `app/jobs/reconciliation/outbox_job.rb`
- Create: `app/jobs/reconciliation/payment_attempts_job.rb`
- Create: `app/jobs/reconciliation/refunds_job.rb`
- Create: `app/jobs/reconciliation/organizer_payouts_job.rb`
- Create: `app/jobs/reconciliation/seller_payouts_job.rb`
- Create: `app/jobs/reconciliation/credential_projection_job.rb`
- Create: `app/jobs/reconciliation/credential_projection.rb`
- Create: `test/jobs/reconciliation/supervisor_job_test.rb`
- Create: `test/jobs/reconciliation/domain_jobs_test.rb`
- Modify: `config/recurring.yml`
- Modify: `test/config/private_attendee_exports_configuration_test.rb`

- [x] **Step 1: Write failing supervisor tests**

Assert the supervisor enqueues each domain job exactly once and does no domain mutation itself. Assert each domain job selects a bounded batch with `FOR UPDATE SKIP LOCKED`, delegates each record to its owning command, and remains safe when two job instances overlap.

Added supervisor and domain-job tests for fast/slow scheduling groups, non-mutating supervision, bounded overdue/uncertain-state selection, stable owner-command delegation, transition audit evidence, and revocation-safe credential projection repair. The credential test also proves admission-use history remains present.

- [x] **Step 2: Run the jobs tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/reconciliation
```

RED captured with 9 errors because the seven reconciliation job classes did not yet exist. Test-only fixture setup errors were corrected before implementation; the next RED run contained only the expected missing-implementation errors.

- [x] **Step 3: Implement the thin supervisor**

```ruby
# frozen_string_literal: true

module Reconciliation
  class SupervisorJob < ApplicationJob
    queue_as :maintenance

    FAST_JOBS = [ OutboxJob, PaymentAttemptsJob, RefundsJob ].freeze
    SLOW_JOBS = [ OrganizerPayoutsJob, SellerPayoutsJob, CredentialProjectionJob ].freeze
    JOBS = (FAST_JOBS + SLOW_JOBS).freeze

    def perform(group = "all")
      { "all" => JOBS, "fast" => FAST_JOBS, "slow" => SLOW_JOBS }
        .fetch(group.to_s, JOBS).each(&:perform_later)
    end
  end
end
```

Each domain job must:

1. select only records in uncertain or overdue states;
2. claim at most the configured batch size with row locking and `SKIP LOCKED`;
3. call the existing domain reconciliation command with a stable reconciliation key;
4. record outcome telemetry and an audit event for operator-visible state changes;
5. reschedule remaining work instead of holding a large transaction;
6. leave provider-reported unknown outcomes pending for the next reconciliation pass.

The credential job compares active generation, active credential rows, revocations, and admission projections. It may repair a derived projection but must never recreate a revoked credential or erase an admission use.

Implemented the supervisor and six domain jobs. `Reconciliation::Support` centralizes only bounded limits, delayed rescheduling, privacy-safe telemetry, and idempotent transition audits; domain jobs continue to select their own rows and call the existing Orders, Finance, Marketplace, Core, and Ticketing commands. `CredentialProjection` owns eager loading and derived-index repair so the job remains an orchestration boundary. Provider-unknown payout/refund results remain processing for the next pass, and payment grace verification continues to use the existing Orders command and stable payment verification identity.

- [x] **Step 4: Schedule recurring supervision**

Configure a short production cadence for payments/outbox and a slower cadence for payouts/projection audits. Keep schedule values environment-configurable. Do not run provider reconciliation in web requests. The primary outbox *delivery* driver, `Core::ProcessOutboxJob` (Plan 0, core-foundation Task 5 Step 8), must also be scheduled here; `Reconciliation::OutboxJob` is only the backstop for rows the enqueuer misses or that exhausted their `DispatchOutboxEventJob` retries, not a substitute for the enqueuer.

Added `reconcile_fast` every minute and `reconcile_slow` hourly at minute 30, both environment-configurable through `RECONCILIATION_FAST_SCHEDULE` and `RECONCILIATION_SLOW_SCHEDULE`. The existing `process_outbox` recurring driver remains in place. The recurring configuration test now uses Rails/Solid Queue's ERB-aware configuration loader and verifies every production schedule through Fugit.

- [x] **Step 5: Verify retries, overlap, and unknown outcomes**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/reconciliation test/services/orders test/services/payments test/services/refunds test/services/finance test/services/ticketing
```

Focused Task 3 verification passes 9 tests and 31 assertions with `N_PLUS_ONE=1`. The broader reconciliation/owner-command suites pass 448 tests and 2,731 assertions with zero failures/errors. The final full repository suite passes 2,707 tests and 11,253 assertions with zero failures/errors under `N_PLUS_ONE=1`; RuboCop passes on all changed Ruby files, Zeitwerk passes, recurring YAML/ERB parsing passes, and `git diff --check` passes.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/jobs/reconciliation test/jobs/reconciliation \
  config/recurring.yml test/config/private_attendee_exports_configuration_test.rb \
  docs/superpowers/plans/2026-07-17-launch-hardening-observability-implementation.md
git commit -m "feat(operations): reconcile uncertain domain state"
```

## Task 4: Create one provider contract suite and deterministic fake

**Files:**
- Create: `test/support/contracts/payment_provider_contract.rb`
- Create: `test/support/fakes/fake_payment_provider.rb`
- Modify: `test/services/payments/providers/adapter_contract_test.rb`

- [x] **Step 1: Define the shared contract cases**

Every payment/refund adapter test must include the same contract covering:

- immediate success and rejection;
- timeout before a provider reference is known;
- timeout after the provider accepted the request;
- duplicate callback delivery;
- callback before the initiating request commits;
- callbacks arriving out of order;
- provider fees reported later than settlement;
- insufficient provider/refund liquidity;
- provider success after the local order expired;
- reconciliation returning `unknown` repeatedly and later resolving.

The shared contract follows the existing `Payments::Providers::Result` boundary: normalized status, provider reference, failure code, provider fee evidence, and raw provider status. It also covers required operations, rejection, timeout before/after a provider reference, repeated unknown verification followed by resolution, refund fee evidence, refund capabilities, and liquidity. Order acceptance, webhook deduplication/order races, and refund state transitions remain covered by their existing Orders service and integration tests rather than being duplicated at the adapter boundary.

The fake stores requests by the platform idempotency key and allows tests to enqueue outcomes. It never infers success from an HTTP timeout; an unconfigured operation returns `unknown`.

- [x] **Step 2: Run one adapter without the contract and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/payments/providers/adapter_contract_test.rb
```

RED captured with 2 missing-fake errors after the new contract tests loaded, while the existing Chapa adapter contract remained green.

- [x] **Step 3: Include the contract in every provider adapter test**

Included the shared contract in the repository's payment adapter contract test and added the deterministic fake. The contract deliberately preserves the existing Orders/Refunds result shape; it does not introduce unused `provider_idempotency_key`, `amount_minor`, `currency`, or `raw_code` fields into the result object. Provider-specific payloads remain outside the normalized result and are never copied to API responses.

- [x] **Step 4: Run all adapter and webhook tests**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/payments/providers test/services/orders test/integration/orders
```

Verified: 122 tests, 795 assertions, zero failures, zero errors with `N_PLUS_ONE=1`. This includes the shared contract, deterministic fake, payment attempts, refunds, provider webhooks, settlement grace, and Orders concurrency/integration coverage.

The final repository suite also passes 2,719 tests and 11,335 assertions with zero failures and zero errors under `N_PLUS_ONE=1`; RuboCop, Ruby syntax, Zeitwerk, and `git diff --check` pass.

- [ ] **Step 5: Commit — user-owned**

```bash
git add test/support/contracts/payment_provider_contract.rb test/support/fakes/fake_payment_provider.rb \
  test/services/payments/providers/adapter_contract_test.rb \
  docs/superpowers/plans/2026-07-17-launch-hardening-observability-implementation.md
git commit -m "test(payments): enforce provider lifecycle contract"
```

## Task 5: Build reusable database race tests for critical invariants

**Files:**
- Create: `test/support/database_race_helper.rb`
- Create: `test/integration/invariants/concurrency_test.rb`
- Modify: `test/test_helper.rb`

- [ ] **Step 1: Add a separate-connection race helper**

The helper must start workers behind a barrier, check out one Active Record connection per worker, collect exceptions, and join every thread. It must not share model instances or transactional test state between threads. Mark these tests non-transactional and clean only records created by the test.

- [ ] **Step 2: Write race tests that initially fail**

Cover at minimum:

- last inventory unit: one reservation wins;
- identical checkout idempotency key: one order/payment attempt;
- duplicate provider callback: one transition/adjustment;
- simultaneous RSVP approval at capacity: no oversell;
- simultaneous package-to-delegated transition: one generation wins;
- group credential versus individual credential scan after revocation: no online mixed-mode acceptance;
- two scans of the same slot/access/usage number: first scan wins;
- two resale purchases: one listing sale and one seller proceeds record;
- refund versus transfer/resale transition: incompatible commands cannot both commit;
- two payout workers: one disbursement instruction.

- [ ] **Step 3: Run the invariant suite repeatedly**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/invariants/concurrency_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/invariants/concurrency_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/invariants/concurrency_test.rb
```

Expected: every repetition passes with database-enforced uniqueness and locking, not timing sleeps.

- [ ] **Step 4: Commit**

```bash
git add test/support/database_race_helper.rb test/integration/invariants/concurrency_test.rb test/test_helper.rb
git commit -m "test(platform): prove critical concurrency invariants"
```

## Task 6: Complete the security and privacy gate

**Files:**
- Create: `test/integration/security/response_visibility_test.rb`
- Create: `test/integration/security/sensitive_logging_test.rb`
- Create: `test/integration/security/private_media_test.rb`
- Create: `test/services/ticketing/key_rotation_test.rb`
- Create: `docs/runbooks/security-key-rotation.md`

- [ ] **Step 1: Build a response visibility matrix**

For public, attendee, organizer member, event collaborator, scanner device, finance operator, and platform administrator roles, assert both permitted and forbidden fields. Because public controllers bypass policy visibility, test public serializers explicitly. Include registration answers, consent evidence, invitation contact data, tax identities, payment payloads, payout accounts, QR claims, PNR/lookup codes, revocations, buyer/seller identity, and audit metadata.

- [ ] **Step 2: Verify encryption and private media**

Assert encrypted columns do not expose plaintext through raw SQL. Assert private ticket media, ID evidence, exports, and provider artifacts require authorization and short-lived signed delivery; public cover/gallery assets remain the only intentionally public media. Never enable `support_unencrypted_data` or `extend_queries` as a migration shortcut.

- [ ] **Step 3: Verify credential security operations**

Test Ed25519 key activation/retirement, retained verification of still-valid older signatures, device revocation, delta synchronization after a revocation, and rejection after the applicable credential/key cutoff. Document the offline limitation: a disconnected device lacking the latest revocation can temporarily accept stale credentials; gates synchronize before opening, and high-security delegated events may require online validation.

- [ ] **Step 4: Run static and dynamic security checks**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman --no-pager
PATH="$HOME/.asdf/shims:$PATH" bundle exec bundler-audit check --update
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/security test/services/ticketing/key_rotation_test.rb
```

- [ ] **Step 5: Commit**

```bash
git add test/integration/security test/services/ticketing/key_rotation_test.rb docs/runbooks/security-key-rotation.md
git commit -m "test(platform): enforce launch security boundaries"
```

## Task 7: Establish query and throughput budgets

**Files:**
- Create: `test/performance/public_event_catalog_test.rb`
- Create: `test/performance/order_checkout_test.rb`
- Create: `test/performance/scanner_sync_test.rb`
- Create: `test/performance/webhook_ingestion_test.rb`
- Create: `script/explain_event_platform_indexes`
- Create: `docs/operations/performance-budgets.md`

- [ ] **Step 1: Define measured budgets before optimizing**

Document explicit launch budgets for public event list/detail query counts, organizer attendee pagination, checkout database time, webhook ingestion, scanner full snapshot generation, scanner delta generation, scan-upload batch size, and reconciliation batch size. Record fixture scale, machine profile, warm/cold state, and percentile method. Budgets are release gates only after they have been measured in a production-like environment.

- [ ] **Step 2: Add deterministic query-count tests**

Seed events with occurrences, venue/online access, cover plus ordered gallery, categories, products, price components, inventory pools, and collaborators. Assert bounded query counts as the collection grows. Use Prosopite for N+1 detection; do not assert wall-clock time in normal CI.

- [ ] **Step 3: Add opt-in throughput harnesses**

The scanner harness creates at least 50,000 attendee/package records and measures compressed full/delta payload size and generation time. The webhook harness sends duplicate and out-of-order batches. Tag these as opt-in performance tests so ordinary unit CI remains fast, while the production-candidate pipeline runs them on a fixed machine class.

- [ ] **Step 4: Capture index plans**

`script/explain_event_platform_indexes` must run `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for browse, inventory reservation, idempotency lookup, admission first-scan, credential revocation delta, settlement ledger, and active resale listing queries. Fail the release review—not ordinary unit CI—when a critical query unexpectedly becomes a sequential scan at the documented dataset size.

- [ ] **Step 5: Run query tests and the opt-in harness**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/performance/public_event_catalog_test.rb test/performance/order_checkout_test.rb
EVENT_PLATFORM_PERFORMANCE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/performance/scanner_sync_test.rb test/performance/webhook_ingestion_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner script/explain_event_platform_indexes
```

- [ ] **Step 6: Commit**

```bash
git add test/performance script/explain_event_platform_indexes docs/operations/performance-budgets.md
git commit -m "test(platform): add launch performance budgets"
```

## Task 8: Write operational runbooks and recovery drills

**Files:**
- Create: `docs/runbooks/payment-provider-outage.md`
- Create: `docs/runbooks/delayed-or-duplicate-webhooks.md`
- Create: `docs/runbooks/refund-liquidity-and-pending-refunds.md`
- Create: `docs/runbooks/event-cancellation.md`
- Create: `docs/runbooks/offline-scanner-compromise.md`
- Create: `docs/runbooks/payout-hold-and-reconciliation.md`
- Create: `docs/runbooks/backup-restore-and-disaster-recovery.md`

- [ ] **Step 1: Give every runbook the same executable structure**

Each runbook states detection signal, severity, authority required, safe immediate action, prohibited action, diagnostic queries, reconciliation command, attendee/organizer communication owner, recovery verification, and audit evidence. Commands must be idempotent domain commands or read-only Rails runner queries; no direct financial or ticket-state SQL updates.

- [ ] **Step 2: Exercise failure drills in staging**

Run and record:

- provider accepts payment but callback is delayed;
- duplicate and out-of-order callback storm;
- refund lacks available provider/platform/organizer liquidity and remains pending;
- event cancellation creates refund obligations without double-refunding;
- scanner is revoked while offline and later synchronizes;
- signing key rotates during an active multi-day event;
- organizer or resale seller payout is held and later released;
- database restore followed by outbox and provider reconciliation.

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks
git commit -m "docs(operations): add event platform recovery runbooks"
```

## Task 9: Consolidate the pre-launch schema only after behavior is green

**Files:**
- Modify: event-platform migrations created by earlier phases
- Modify: `db/schema.rb`
- Modify: `db/seeds.rb`
- Create: `docs/operations/prelaunch-schema-consolidation.md`

- [ ] **Step 1: Confirm consolidation is safe**

Require written confirmation that no shared or production-like environment relies on the event-platform migrations. Preserve existing Core/Organizations/Categories/Venues/Artists migration history. Consolidate only the new event-platform migrations where doing so improves dependency order and executable constraints.

- [ ] **Step 2: Recreate the databases from zero**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:drop db:create db:migrate db:seed
RAILS_ENV=test PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:drop db:create db:migrate
```

Do not add dual writes, fallback reads, old route aliases, unencrypted-field support, or migration compatibility branches. This is a clean pre-launch cutover.

- [ ] **Step 3: Verify schema constraints directly**

Run tests that introspect partial unique indexes, check constraints, exclusion constraints, foreign keys, and deferred triggers required by the design. Verify every business `type` model declares `self.inheritance_column = nil`.

- [ ] **Step 4: Run the complete suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bin/ci
```

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb db/seeds.rb docs/operations/prelaunch-schema-consolidation.md
git commit -m "refactor(database): consolidate prelaunch event schema"
```

## Task 10: Execute final cross-domain acceptance

**Files:**
- Create: `test/system/event_platform_launch_test.rb`
- Create: `docs/operations/event-platform-launch-checklist.md`

- [ ] **Step 1: Implement the launch journeys**

Cover these end-to-end journeys with provider/scanner fakes and real database constraints:

1. public hybrid event with in-person and cheaper paid `soft_gated` YouTube products in two currencies, including the checkout link-sharing disclosure and rejection of a `signed` product promise;
2. private invite-only event combining guest list, invite code, free ticket, paid ticket, and approval;
3. recurring series with per-occurrence inventory and a multi-day pass;
4. one package ticket switched atomically from group QR to delegated credentials, including an existing user and an unclaimed recipient;
5. offline scan batch retry, first-scan-wins, PNR/manual fallback, revocation delta, and multi-day usage;
6. paid add-on such as parking attached to an eligible admission product;
7. partial cancellation/refund with immutable adjustments, processor fees, pending liquidity, and later reconciliation;
8. organizer-controlled resale with allowed/disallowed policy, one cap mode, resale-count limit, separate platform fee, credential replacement, and seller payout;
9. event with multiple organizer organizations and least-privilege collaborator roles;
10. data export/anonymization that preserves financial, consent, audit, and admission evidence.

- [ ] **Step 2: Complete the release checklist**

The checklist links every architecture invariant to a passing test, migration/index, alert, dashboard signal, and runbook owner. Any missing link blocks launch. Explicitly record the accepted offline-stale-revocation limitation and events that require online validation. Also link the outbox-delivery invariant: the Plan 0 enqueuer (`Core::ProcessOutboxJob`, core-foundation Task 5 Step 8) is scheduled and observed draining in staging, `Reconciliation::OutboxJob` is the backstop, and the Task 2 readiness alarm for undispatched rows is green.

- [ ] **Step 3: Run final verification**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/system/event_platform_launch_test.rb
PATH="$HOME/.asdf/shims:$PATH" bin/ci
git diff --check
```

Expected: all tests and static checks pass, `git diff --check` prints nothing, and the launch checklist contains no unresolved item.

- [ ] **Step 4: Commit**

```bash
git add test/system/event_platform_launch_test.rb docs/operations/event-platform-launch-checklist.md
git commit -m "test(platform): complete launch acceptance gate"
```

## Exit criteria

- Every cross-domain journey is backed by executable tests and database invariants.
- Unknown external outcomes converge through reconciliation without duplicate charges, refunds, admissions, listings, or payouts.
- Public and role-specific responses expose no private or encrypted evidence.
- Observability contains operational identifiers and outcomes but no payment, identity, credential, or registration secrets.
- Backup/restore and incident drills have been exercised in staging.
- Performance budgets are measured and accepted on a production-like environment.
- `PATH="$HOME/.asdf/shims:$PATH" bin/ci` is green from a database created from zero.
