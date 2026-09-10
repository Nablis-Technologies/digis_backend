# Event Completion Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Automatically complete ended event dates/events while providing an authorized manual retry endpoint that preserves the existing payout-maturity boundary.

**Architecture:** `Finance::CompleteEvent` remains the single locked completion command. It will normalize ended scheduled dates, leave postponed/cancelled/future dates untouched, and enqueue the existing maturity fan-out only after all materialized dates are terminal. A bounded recurring job invokes that command with an internal scheduler source; an organization/platform administrator may invoke the same command through `POST /events/:event_id/complete`.

**Tech Stack:** Ruby 3.4, Rails 8.1, PostgreSQL, Solid Queue, recurring.yml, Pundit, ActiveModel Serializers, Minitest.

---

## File map

- Modify `app/services/finance/complete_event.rb` to support scheduler-originated completion, ended-date normalization, schedule-version evidence, and source-aware idempotent audits.
- Create `app/services/finance/complete_due_events.rb` as the bounded candidate selector and command dispatcher.
- Create `app/jobs/finance/complete_due_events_job.rb` as the recurring entry point.
- Modify `config/recurring.yml` to run the due-event job every minute in production.
- Create `app/controllers/finance/event_completions_controller.rb` for the manual retry endpoint.
- Modify `app/policies/events/event_policy.rb`, `config/routes.rb`, and `config/locales/finance.en.yml` for authorization, routing, and localized success/errors.
- Modify `postman/Digis API_collection.json` with the manual completion request.
- Add tests under `test/services/finance`, `test/jobs/finance`, and `test/controllers/finance`.
- Update `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`, `docs/guides/chapa-integration.md`, `docs/superpowers/plans/2026-07-17-refunds-finance-settlement-implementation.md`, and the approved lifecycle spec with the automatic/manual contract.

No migration or seed data is needed. The feature changes lifecycle orchestration, not the schema or fixture baseline.

## Task 1: Extend the authoritative completion command

**Files:**
- Modify `app/services/finance/complete_event.rb`.
- Test `test/services/finance/complete_event_test.rb`.

- [x] **Step 1: Write failing tests for ended-date normalization and maturity evidence.**

Add tests that create a published event with a scheduled date whose `ends_at` is before `@now`, then assert:

```ruby
result = Finance::CompleteEvent.call(
  event: @event,
  actor: core_users(:super_admin),
  idempotency_key: "complete-ended-event",
  at: @now
)

assert_predicate result, :success?
assert_equal "completed", @event.reload.status
assert_equal "completed", @event.event_dates.first.reload.status
assert_equal @now, @event.completed_at
assert_equal 1, Core::AuditLog.where(action: "event.completed", auditable_id: @event.id).count
assert_enqueued_with(job: Finance::MatureEventFundsJob, args: [ @event.id ])
```

Add separate tests proving a future scheduled date keeps the event published, a postponed date remains postponed, a cancelled date remains cancelled, and the command does not enqueue maturity when any future scheduled date remains.

- [x] **Step 2: Write failing tests for scheduler authorization and replay.**

Add tests that call:

```ruby
Finance::CompleteEvent.call(
  event: @event,
  actor: nil,
  source: "scheduler",
  idempotency_key: "scheduled-completion-#{@event.id}",
  at: @now
)
```

The scheduler call must succeed only with the exact internal source value, record `source: "scheduler"` in audit metadata, bump `schedule_version` once when an ended date is normalized, and replay without a second audit or maturity job. A non-scheduler nil actor must remain unauthorized.

- [x] **Step 3: Run the focused tests and verify RED.**

Run:

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/finance/complete_event_test.rb
```

Expected: failures for the missing `source` keyword and missing ended-date completion behavior.

- [x] **Step 4: Implement the minimum command changes.**

Add an internal source constant and keyword:

```ruby
SCHEDULER_SOURCE = "scheduler"

def initialize(event:, actor:, idempotency_key:, at: Time.current, source: "manual")
  @event_id = event.id
  @actor = actor
  @idempotency_key = idempotency_key
  @at = at.to_time.utc
  @source = source.to_s
end
```

Inside the existing event transaction, lock dates, update only dates with `status == "scheduled" && ends_at <= at`, record one deterministic `event.date.completed` audit per changed date, increment `schedule_version` once when any date changed, and then require every date to be `completed` or `cancelled` before completing the event. Leave postponed, cancelled, and future scheduled dates untouched. Allow authorization without a user only when `source == SCHEDULER_SOURCE`; manual requests continue to require platform or organization authority. Store `source` in the event audit metadata and include it in replay comparison.

- [x] **Step 5: Run the command tests GREEN.**

Run the same command with `N_PLUS_ONE=1`; expect all completion, replay, authorization, schedule-version, and maturity-job assertions to pass.

## Task 2: Add bounded automatic completion

**Files:**
- Create `app/services/finance/complete_due_events.rb`.
- Create `app/jobs/finance/complete_due_events_job.rb`.
- Modify `config/recurring.yml`.
- Test `test/services/finance/complete_due_events_test.rb` and `test/jobs/finance/complete_due_events_job_test.rb`.

- [x] **Step 1: Write failing candidate-selection and job delegation tests.**

Cover these cases:

- published event with an ended scheduled date is selected;
- draft, cancelled, completed, and future-only events are not selected;
- selection is ordered by event ID and limited to 100 IDs;
- a candidate with a future second date is passed to `Finance::CompleteEvent` and remains published after the command returns `event_dates_incomplete`;
- the recurring job delegates once to `Finance::CompleteDueEvents`.

- [x] **Step 2: Run the new tests and verify RED.**

Run:

```bash
N_PLUS_ONE=1 bundle exec rails test test/services/finance/complete_due_events_test.rb test/jobs/finance/complete_due_events_job_test.rb
```

Expected: missing constant failures for the new service and job.

- [x] **Step 3: Implement the bounded service and job.**

The service will query the bounded candidate IDs, load those events in one
second query to avoid an N+1, and then process each event independently:

```ruby
Events::Event
  .where(status: "published")
  .joins(:event_dates)
  .where(events_event_dates: { status: "scheduled" })
  .where("events_event_dates.ends_at <= ?", at)
  .distinct
  .order(:id)
  .limit(100)
  .pluck(:id)
```

For each loaded event it will call `Finance::CompleteEvent.call(event:, actor: nil, source: "scheduler", idempotency_key: "finance-event-auto-complete-#{event.id}", at:)`. Expected `event_dates_incomplete`, `event_already_completed`, and `event_not_completable` results are safe no-ops. Other failures are collected with only the event ID and error code, logged as a bounded summary, and raised as one `SweepFailure` after every candidate has been attempted; this preserves Solid Queue retry visibility without starving later events. The job simply calls `Finance::CompleteDueEvents.call(at: Time.current)` and lets `SweepFailure` propagate.

Add this production recurring entry:

```yaml
  complete_due_events:
    class: Finance::CompleteDueEventsJob
    queue: default
    schedule: every minute
```

- [x] **Step 4: Run the service/job tests GREEN.**

Run both focused files with `N_PLUS_ONE=1`; expect bounded selection, deterministic keys, safe retries, and job delegation to pass.

## Task 3: Add the optional manual retry endpoint

**Files:**
- Create `app/controllers/finance/event_completions_controller.rb`.
- Modify `app/policies/events/event_policy.rb`, `config/routes.rb`, and `config/locales/finance.en.yml`.
- Test `test/controllers/finance/event_completions_controller_test.rb` and the relevant event-policy test.

- [x] **Step 1: Write failing endpoint and policy tests.**

Cover:

- `POST /events/:event_id/complete` requires `Idempotency-Key` and returns `400 missing_idempotency_key` when absent;
- an organization owner/admin and platform administrator may invoke it;
- an attendee or unrelated organization member receives `403`;
- the controller passes only `event`, `actor`, and `idempotency_key` to `Finance::CompleteEvent`;
- the endpoint returns the localized success message and `Events::EventSerializer` data;
- event-date incompleteness is returned as the command’s localized business error.

- [x] **Step 2: Run the controller tests and verify RED.**

Run:

```bash
N_PLUS_ONE=1 bundle exec rails test test/controllers/finance/event_completions_controller_test.rb
```

Expected: missing route/controller/policy action failures.

- [x] **Step 3: Implement the thin Finance controller and policy action.**

The controller will inherit `Finance::ApplicationController`, include `Core::CommandResponse`, expose a `complete` action, load `Events::Event` by `params[:event_id]`, authorize `:complete?`, and call `Finance::CompleteEvent` exactly once. The policy action will use `Events::AuthorizationResolver.organization_admin_or_owner?` and retain platform-admin access. Add the localized `finance.success.event_complete` message and reuse existing Finance completion errors.

Add this route:

```ruby
post "events/:event_id/complete", to: "finance/event_completions#complete"
```

- [x] **Step 4: Run endpoint/policy tests GREEN.**

Run the focused controller and policy tests with `N_PLUS_ONE=1`; expect authorization, idempotency, serialization, and error responses to pass.

## Task 4: Synchronize API documentation and operational plans

**Files:**
- Modify `postman/Digis API_collection.json`.
- Modify `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`.
- Modify `docs/guides/chapa-integration.md`.
- Modify `docs/superpowers/plans/2026-07-17-refunds-finance-settlement-implementation.md`.
- Modify `docs/superpowers/specs/2026-08-27-event-completion-lifecycle-design.md`.

- [x] Add a Postman request under the event/finance section for `POST /events/{{eventId}}/complete` with a generated `Idempotency-Key` header and no sensitive fields.
- [x] Document the automatic due-event job, scheduler-originated audit metadata, manual retry endpoint, and the fact that completion still requires terminal dates and does not release funds before the seven-day buffer.
- [x] Add the exact implementation handoff to the Finance/settlement plan so the API is not mistaken for a payout bypass.
- [x] Run `jq empty 'postman/Digis API_collection.json'` and `git diff --check`.

## Task 5: Full verification and handoff

- [x] Run the focused suite:

```bash
N_PLUS_ONE=1 bundle exec rails test \
  test/services/finance/complete_event_test.rb \
  test/services/finance/complete_due_events_test.rb \
  test/jobs/finance/complete_due_events_job_test.rb \
  test/controllers/finance/event_completions_controller_test.rb
```

- [x] Run the related Finance regression tests and existing event cancellation/schedule tests with `N_PLUS_ONE=1`.
- [x] Run `RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop`, `bin/rails zeitwerk:check`, `bin/rails routes`, and the Postman JSON check.
- [x] Review the final diff and confirm no migration, seed, payout, refund, or provider behavior changed outside the documented completion boundary.
- [x] Leave all changes unstaged and uncommitted for the user.

No Render database reset or preview-only completion flag is part of this plan. After the code is merged and deployed, the live drill can use the normal manual/automatic completion path; provider timeout behavior remains deterministic in local tests.

Verification: the event-completion focused suite passes 59 tests and 297
assertions with `N_PLUS_ONE=1`; the broader Finance regression suite passes 123
tests and 567 assertions. RuboCop, Zeitwerk, Ruby syntax, recurring/render YAML,
routes, Postman JSON, and `git diff --check` all pass. Render deploy
`dep-da87umjncjis73ffr6ug` is live; the recurring worker runs successfully, the
manual completion drill returned HTTP 200, the event/date reached `completed`,
and the same-key replay produced no duplicate audit or maturity effect.
