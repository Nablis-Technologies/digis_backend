# Event Foundation, Scheduling, and Media Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the event aggregate from draft creation through authorized publication, collaboration, stable schedules, recurrence, media, consent-document authoring, postponement, and irreversible cancellation.

**Architecture:** Keep `Core::Common` for ordinary nested CRUD only. Publication, category replacement, staff transitions, recurrence materialization, media reorder, schedule changes, and cancellation each use one `Core::BaseService` command invoked by one controller action. PostgreSQL owns structural invariants and counters; Pundit owns authorization; AMS serializers and policy visibility jointly bound every response; Solid Queue handles only after-commit work.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs, Pundit, ActiveModelSerializers, Active Storage, Solid Queue, Minitest fixtures.

---

## Normative sources and delivery rules

- Implement the event portions of `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md` and preserve the package/upstream boundaries in `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`.
- This is a pre-launch clean implementation. Replace incorrect development schema or code directly; do not add dual writes, compatibility columns, data shims, or deprecated endpoints.
- Use existing `core_users`, `organizations_organizations`, `organizations_memberships`, `events_venues`, `events_categories`, `events_artists`, Active Storage, `core_audit_logs`, `Core::BaseService`, `Core::JsonResponse`, and Pundit foundations.
- Add a reusable abstraction only after three concrete consumers need the same behavior. The first three justified shared pieces in this plan are `Events::EventAuthorizer` (publication, schedule change, media), `Events::LockedEventCommand` (category replacement, publication, schedule change), and the existing durable audit/outbox mechanism. Do not put workflow branching into `Core::Common`.
- Every model with a business `type` column sets `self.inheritance_column = nil` and receives a regression test.
- Every command enqueues through durable after-commit/outbox state. No external notification, search update, media purge, or stream-provider call may occur inside the database transaction.
- Run commands with `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test ...`.

## File map

**Create migrations**

- `db/migrate/20260717010100_create_events_events_and_settings.rb`
- `db/migrate/20260717010200_create_event_categories_collaborators_and_staff.rb`
- `db/migrate/20260717010300_create_event_dates_recurrence_and_participants.rb`
- `db/migrate/20260717010400_create_event_media.rb`
- `db/migrate/20260717010500_create_event_date_changes_and_cancellations.rb`
- `db/migrate/20260717010600_create_event_access_zones.rb`
- `db/migrate/20260717010700_create_event_consent_documents.rb`
- `db/migrate/20260717010800_create_event_streams.rb`

**Create application files**

- `app/models/events/event.rb`, `event_setting.rb`, `event_category.rb`, `event_organization.rb`, `event_staff_assignment.rb`, `event_date.rb`, `recurrence_rule.rb`, `event_participant.rb`, `event_media.rb`, `event_date_change.rb`, `event_cancellation.rb`, `access_zone.rb`, `consent_document.rb`, `consent_document_version.rb`, `event_stream.rb`
- `app/policies/events/event_policy.rb`, `event_staff_assignment_policy.rb`, `event_media_policy.rb`, `consent_document_policy.rb`
- `app/serializers/events/event_serializer.rb`, `event_date_serializer.rb`, `event_media_serializer.rb`, `event_staff_assignment_serializer.rb`, `consent_document_serializer.rb`
- `app/serializers/events/public/event_list_serializer.rb`, `event_detail_serializer.rb`
- `app/controllers/events/events_controller.rb`, `event_categories_controller.rb`, `event_organizations_controller.rb`, `event_staff_assignments_controller.rb`, `event_dates_controller.rb`, `recurrence_rules_controller.rb`, `event_media_controller.rb`, `event_participants_controller.rb`, `access_zones_controller.rb`, `consent_documents_controller.rb`, `public_events_controller.rb`
- `app/controllers/events/event_publications_controller.rb`, `event_schedule_changes_controller.rb`, `event_cancellations_controller.rb`, `event_media_orders_controller.rb`
- `app/services/events/create.rb`, `replace_categories.rb`, `publish.rb`, `publication_readiness.rb`, `authorization_resolver.rb`
- `app/services/events/staff_assignments/assign.rb`, `change_role.rb`, `suspend.rb`, `revoke.rb`
- `app/services/events/recurrence/configure.rb`, `materialize.rb`
- `app/services/events/media/attach.rb`, `reorder.rb`, `remove.rb`, `readiness.rb`
- `app/services/events/schedule/change.rb`, `cancellation/initiate.rb`
- `app/services/events/consent_documents/publish_version.rb`
- `app/jobs/events/materialize_recurrence_job.rb`, `refresh_discovery_job.rb`, `schedule_changed_notifications_job.rb`, `sync_stream_schedule_job.rb`, `purge_event_media_job.rb`, `cleanup_unattached_event_media_job.rb`

**Modify**

- `config/routes.rb`
- `config/recurring.yml`
- `config/initializers/filter_parameter_logging.rb`
- `config/initializers/events_outbox_handlers.rb`

**Create tests and fixtures**

- Model tests under `test/models/events/`
- Service tests under `test/services/events/`
- Integration tests under `test/integration/events/`
- Job tests under `test/jobs/events/`
- Fixtures `test/fixtures/events_events.yml`, `events_event_settings.yml`, `events_event_categories.yml`, `events_event_organizations.yml`, `events_event_staff_assignments.yml`, `events_event_dates.yml`, `events_recurrence_rules.yml`, `events_event_participants.yml`, `events_event_media.yml`, `events_event_date_changes.yml`, `events_event_cancellations.yml`, `events_access_zones.yml`, `events_consent_documents.yml`, `events_consent_document_versions.yml`, `events_event_streams.yml`

## Task 1: Create the event identity, settings, and category schema

**Files:**
- Create: `db/migrate/20260717010100_create_events_events_and_settings.rb`
- Create: `db/migrate/20260717010200_create_event_categories_collaborators_and_staff.rb`
- Create: `app/models/events/event.rb`
- Create: `app/models/events/event_setting.rb`
- Create: `app/models/events/event_category.rb`
- Test: `test/models/events/event_test.rb`
- Test: `test/services/events/replace_categories_test.rb`
- Create: `test/fixtures/events_events.yml`
- Create: `test/fixtures/events_event_settings.yml`
- Create: `test/fixtures/events_event_categories.yml`

- [ ] **RED: write failing schema and invariant tests.** Assert UUID foreign keys, `lower(slug)` uniqueness, one setting/event, one event/category pair, event status/timestamp coupling, nonnegative versions, valid currencies/timezone, and a transaction test where two category replacements cannot leave more than three rows.

```ruby
# test/services/events/replace_categories_test.rb
require "test_helper"

class Events::ReplaceCategoriesTest < ActiveSupport::TestCase
  test "replaces at most three categories atomically" do
    event = events_events(:draft_concert)
    ids = events_categories(:music, :festival, :nightlife, :education).map(&:id)

    result = Events::ReplaceCategories.call(event:, category_ids: ids, actor: core_users(:organizer_owner))

    assert result.failure?
    assert_equal "too_many_categories", result.error.code
    assert_equal events_event_categories(:draft_music).category_id, event.event_categories.reload.pick(:category_id)
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events/event_test.rb test/services/events/replace_categories_test.rb`; expect missing tables/classes.
- [ ] **GREEN: implement migrations, models, and `Events::ReplaceCategories`.** Use PostgreSQL checks, a functional unique index on `lower(slug)`, and `event.with_lock` around count validation and replacement. Return `Core::BaseService::Result`, write an audit entry without serializing private content, and never rescue `ActiveRecord::RecordNotUnique` as success.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events/event_test.rb test/services/events/replace_categories_test.rb`; expect all assertions to pass.
- [ ] **Refactor:** keep presentation-only values in `events_event_settings.config`; move no queryable policy into JSONB. Confirm every FK is indexed.
- [ ] **Commit:** `git add db/migrate/20260717010100_create_events_events_and_settings.rb db/migrate/20260717010200_create_event_categories_collaborators_and_staff.rb app/models/events test/models/events test/services/events/replace_categories_test.rb test/fixtures/events_event*.yml && git commit -m "feat(events): add event foundation schema"`

## Task 2: Implement draft CRUD, publication, policies, and serializer boundaries

**Files:**
- Create: `app/controllers/events/events_controller.rb`
- Create: `app/controllers/events/event_publications_controller.rb`
- Create: `app/controllers/events/public_events_controller.rb`
- Create: `app/services/events/create.rb`
- Create: `app/services/events/publication_readiness.rb`
- Create: `app/services/events/publish.rb`
- Create: `app/policies/events/event_policy.rb`
- Create: `app/serializers/events/event_serializer.rb`
- Create: `app/serializers/events/public/event_list_serializer.rb`
- Create: `app/serializers/events/public/event_detail_serializer.rb`
- Modify: `config/routes.rb`
- Test: `test/services/events/publish_test.rb`
- Test: `test/integration/events/events_test.rb`
- Test: `test/integration/events/public_events_test.rb`

- [ ] **RED: write publication transaction and response-surface tests.** Cover verified organization recheck under lock, required category/date/ready cover, listing-only publication without products, product-readiness delegation, idempotent repeated publish, private discovery exclusion, direct private lookup, manager vs staff authorization, and absence of inventory/staff/internal cancellation data from public AMS output.

```ruby
# test/services/events/publish_test.rb
require "test_helper"

class Events::PublishTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "publishes a ready listing-only event once" do
    event = events_events(:ready_listing)
    actor = core_users(:organizer_owner)

    assert_difference -> { Core::OutboxEvent.where(event_type: "event.published").count }, 1 do
      result = Events::Publish.call(event:, actor:, idempotency_key: SecureRandom.uuid)
      assert result.success?, result.error.inspect
    end

    assert_equal "published", event.reload.status
    assert event.published_at
    assert_equal 1, event.audit_logs.for_action("event.published").count
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/publish_test.rb test/integration/events/events_test.rb test/integration/events/public_events_test.rb`; expect missing command/controllers.
- [ ] **GREEN: implement one service per complex action.** `EventsController` may use `Core::Common` only for draft `index/show/update`; creation and publication invoke commands. `Events::Publish` locks event, loads the organization with lock, authorizes through Pundit before command invocation, calls `PublicationReadiness`, changes state once, records audit/outbox state, and schedules discovery after commit.

```ruby
# app/services/events/publish.rb
module Events
  class Publish < Core::BaseService
    def initialize(event:, actor:, idempotency_key:)
      @event = event
      @actor = actor
      @idempotency_key = idempotency_key
    end

    def call
      Event.transaction do
        event.lock!
        return success(event) if event.published?

        event.organization.lock!
        readiness = PublicationReadiness.call(event:)
        return readiness if readiness.failure?

        event.update!(status: "published", published_at: Time.current)
        Core::Audit::Record.call(
          action: "event.published",
          auditable: event,
          actor:,
          metadata: { idempotency_key: }
        )
        Core::Outbox::Publish.call(
          topic: "events",
          event_type: "event.published",
          aggregate: event,
          payload: { event_id: event.id },
          idempotency_key: "event-published-#{event.id}"
        )
      end
      success(event)
    rescue ActiveRecord::RecordInvalid => error
      failure Core::BusinessError.new(
        "Event is not publishable",
        code: "invalid_event",
        status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      )
    end

    private

    attr_reader :event, :actor, :idempotency_key
  end
end
```

- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/publish_test.rb test/integration/events/events_test.rb test/integration/events/public_events_test.rb`; expect pass.
- [ ] **Refactor:** intersect controller serializer fields/includes with policy visibility. Ensure public serializers expose only title, slug, description, public schedule, safe media variants, participants, and attendee-safe schedule history.
- [ ] **Commit:** `git add app/controllers/events app/services/events app/policies/events/event_policy.rb app/serializers/events config/routes.rb test/services/events/publish_test.rb test/integration/events && git commit -m "feat(events): publish authorized events"`

## Task 3: Add collaborators and explicit event staff assignments

**Files:**
- Create: `app/models/events/event_organization.rb`
- Create: `app/models/events/event_staff_assignment.rb`
- Create: `app/controllers/events/event_organizations_controller.rb`
- Create: `app/controllers/events/event_staff_assignments_controller.rb`
- Create: `app/services/events/authorization_resolver.rb`
- Create: `app/services/events/staff_assignments/assign.rb`
- Create: `app/services/events/staff_assignments/change_role.rb`
- Create: `app/services/events/staff_assignments/suspend.rb`
- Create: `app/services/events/staff_assignments/revoke.rb`
- Create: `app/policies/events/event_staff_assignment_policy.rb`
- Create: `app/serializers/events/event_staff_assignment_serializer.rb`
- Test: `test/models/events/event_staff_assignment_test.rb`
- Test: `test/integration/events/event_staff_assignments_test.rb`

- [ ] **RED: add an authorization matrix.** Prove primary owners/admins need no assignment; primary staff, collaborator members, and contractors require an active assignment; collaborator membership alone grants no access; manager/staff/scanner surfaces differ; expired, suspended, or revoked assignments fail immediately; only owner/admin/manager can assign within allowed authority.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events/event_staff_assignment_test.rb test/integration/events/event_staff_assignments_test.rb`; expect missing models/policies.
- [ ] **GREEN: implement collaborator CRUD with `Core::Common` and staff transitions with services.** Add DB uniqueness, primary-owner exclusion, type/status/time checks, represented-organization membership validation under lock, audit rows, and `self.inheritance_column = nil` tests for both business-type models.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events/event_staff_assignment_test.rb test/integration/events/event_staff_assignments_test.rb`; expect pass.
- [ ] **Refactor:** keep one `Events::AuthorizationResolver`; do not create configurable event permissions or duplicate organization RBAC.
- [ ] **Commit:** stage the listed files and commit `feat(events): add collaborators and event staff assignments`.

## Task 4: Add dates, recurrence, participants, streams, and access zones

**Files:**
- Create: `db/migrate/20260717010300_create_event_dates_recurrence_and_participants.rb`
- Create: `db/migrate/20260717010600_create_event_access_zones.rb`
- Create: `db/migrate/20260717010800_create_event_streams.rb`
- Create: `app/models/events/event_date.rb`, `recurrence_rule.rb`, `event_participant.rb`, `access_zone.rb`, `event_stream.rb`
- Create: `app/controllers/events/event_dates_controller.rb`, `recurrence_rules_controller.rb`, `event_participants_controller.rb`, `access_zones_controller.rb`
- Create: `app/services/events/recurrence/configure.rb`, `materialize.rb`
- Create: `app/jobs/events/materialize_recurrence_job.rb`
- Test: `test/services/events/recurrence/materialize_test.rb`
- Test: `test/integration/events/event_dates_test.rb`
- Test: `test/models/events/access_zone_test.rb`

- [ ] **RED:** cover UTC/local DST generation, unique `source_key`, stable edited/sold dates, valid time intervals, venue capacity counters, same-event participant/date, one stream/date, required `public`/`soft_gated`/`signed` stream protection, no `internal` provider, zone code uniqueness, and date/type matching.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/recurrence/materialize_test.rb test/integration/events/event_dates_test.rb test/models/events/access_zone_test.rb`; expect schema failures.
- [ ] **GREEN:** materialize RFC 5545 occurrences into ordinary date rows by deterministic source key; never destructively recalculate materialized rows. Add required `provider` and `access_protection` to `events_event_streams`, with the exact protection check from the architecture and no self-hosted/internal adapter assumption. Provider capability validation is completed by the streaming plan. Use STI opt-out tests for participant/access-zone types.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/recurrence/materialize_test.rb test/integration/events/event_dates_test.rb test/models/events/access_zone_test.rb`; expect pass.
- [ ] **Refactor:** recurrence service produces dates only; keep pricing, inventory, and access generation in the catalog plan.
- [ ] **Commit:** stage the listed migration/model/controller/service/job/test files and commit `feat(events): add schedules recurrence and zones`.

## Task 5: Add Active Storage event cover and ordered gallery

**Files:**
- Create: `db/migrate/20260717010400_create_event_media.rb`
- Create: `app/models/events/event_media.rb`
- Create: `app/controllers/events/event_media_controller.rb`
- Create: `app/controllers/events/event_media_orders_controller.rb`
- Create: `app/services/events/media/attach.rb`, `reorder.rb`, `remove.rb`, `readiness.rb`
- Create: `app/policies/events/event_media_policy.rb`
- Create: `app/serializers/events/event_media_serializer.rb`
- Create: `app/jobs/events/purge_event_media_job.rb`, `cleanup_unattached_event_media_job.rb`
- Modify: `config/recurring.yml`
- Create: `config/initializers/events_outbox_handlers.rb`
- Test: `test/services/events/media/reorder_test.rb`
- Test: `test/integration/events/event_media_test.rb`
- Test: `test/jobs/events/purge_event_media_job_test.rb`

- [ ] **RED:** prove one cover at position zero, at most twenty galleries, deferred collision-free reorder, event locking under concurrent cover attachment, authorization recheck for signed blob IDs, analysis/alt-text publication gate, MIME/size restrictions, private variants only, after-commit purge, and public serializer exclusion of originals/storage keys.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/media/reorder_test.rb test/integration/events/event_media_test.rb test/jobs/events/purge_event_media_job_test.rb`; expect missing implementation.
- [ ] **GREEN:** add `has_one_attached :file`, named cover/gallery/thumbnail variants, deferrable `(event_id,type,position)` uniqueness, event-locked services, analysis-based validation, and STI opt-out. `Core::Common` may handle metadata show/update; attach/reorder/remove use commands.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/media/reorder_test.rb test/integration/events/event_media_test.rb test/jobs/events/purge_event_media_job_test.rb`; expect pass.
- [ ] **Refactor:** reuse Active Storage jobs and storage configuration; do not persist blob IDs or URLs on `events_event_media`.
- [ ] **Commit:** stage listed files and commit `feat(events): add event cover and ordered gallery`.

## Task 6: Add versioned consent-document authoring

**Files:**
- Create: `db/migrate/20260717010700_create_event_consent_documents.rb`
- Create: `app/models/events/consent_document.rb`, `consent_document_version.rb`
- Create: `app/controllers/events/consent_documents_controller.rb`
- Create: `app/services/events/consent_documents/publish_version.rb`
- Create: `app/policies/events/consent_document_policy.rb`
- Create: `app/serializers/events/consent_document_serializer.rb`
- Test: `test/services/events/consent_documents/publish_version_test.rb`
- Test: `test/integration/events/consent_documents_test.rb`

- [ ] **RED:** test monotonic version, exactly one published version, immutable published body/digest semantics, canonical SHA-256, manager authorization, and public exclusion of draft/retired versions.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/consent_documents/publish_version_test.rb test/integration/events/consent_documents_test.rb`; expect missing classes.
- [ ] **GREEN:** implement draft CRUD with `Core::Common` and publish through a locked service. Use a partial unique published-version index and database status/timestamp checks. Never change a version already referenced by registration requirements. Product scoping is added only after `ticketing_ticket_types` exists in the catalog plan.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/consent_documents/publish_version_test.rb test/integration/events/consent_documents_test.rb`; expect pass.
- [ ] **Refactor:** keep consent acceptance out of this module; the registration plan consumes exact immutable version IDs.
- [ ] **Commit:** stage listed files and commit `feat(events): add versioned consent documents`.

## Task 7: Implement append-only schedule change and the irreversible cancellation boundary

**Files:**
- Create: `db/migrate/20260717010500_create_event_date_changes_and_cancellations.rb`
- Create: `app/models/events/event_date_change.rb`, `event_cancellation.rb`
- Create: `app/controllers/events/event_schedule_changes_controller.rb`, `event_cancellations_controller.rb`
- Create: `app/services/events/schedule/change.rb`
- Create: `app/services/events/cancellation/initiate.rb`
- Create: `app/jobs/events/schedule_changed_notifications_job.rb`, `sync_stream_schedule_job.rb`
- Test: `test/services/events/schedule/change_test.rb`
- Test: `test/services/events/cancellation/initiate_test.rb`

- [ ] **RED:** test stable date IDs, immutable old/new snapshots, one schedule-version increment per group, deterministic lock order, same-event history, reschedule retaining ticket references, idempotent outbox, cancellation owner/admin restriction, single cancellation/event, immediate stop transaction, and cancellation initiation never depending on a payment provider.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/schedule/change_test.rb test/services/events/cancellation/initiate_test.rb`; expect missing services.
- [ ] **GREEN:** implement state/timestamp checks, unique cancellation event/idempotency keys, append-only models, and commands. `Initiate` changes event/date state, stops new registration/sales/access, records audit evidence, and publishes `events.cancellation_initiated` through the transactional outbox. It does not calculate refunds or create a premature batch processor; the refunds/finance plan registers the event handler and owns resumable per-payment work after the order/refund schema exists.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/schedule/change_test.rb test/services/events/cancellation/initiate_test.rb`; expect pass.
- [ ] **Refactor:** keep provider calls outside transaction and scrub `last_error`; public APIs expose `attendee_reason`, never internal notes/errors.
- [ ] **Commit:** stage listed files and commit `feat(events): add schedule changes and cancellation coordinator`.

## Task 8: Complete route, serializer, job, and phase acceptance gates

**Files:**
- Modify: `config/routes.rb`
- Modify: `config/recurring.yml`
- Test: `test/integration/events/event_authorization_matrix_test.rb`
- Test: `test/integration/events/event_phase_acceptance_test.rb`
- Test: `test/integration/events/public_events_test.rb`

- [ ] **RED:** add one integration test creating a verified organizer event with categories, collaborator manager, date, recurrence, participant, cover/gallery, access zone, and published consent document; publish it; reschedule without changing IDs; assert public/private serialization and audit/outbox behavior.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/events/event_phase_acceptance_test.rb test/integration/events/event_authorization_matrix_test.rb`; expect any uncovered boundary to fail.
- [ ] **GREEN:** complete routes, policy scopes, serializer visibility, eager loading, recurring jobs, Plan 0 outbox-handler registrations, and typed error mappings. The domain initializer merges event handlers into `Rails.application.config.x.outbox_handlers` without replacing handlers registered by other domains. Add no business workflow to `Core::Common`.
- [ ] **Run GREEN:** run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events test/services/events test/integration/events test/jobs/events`; expect pass.
  - [ ] **Refactor:** run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test`; inspect query counts on public list/detail and remove N+1 queries without broadening serializer visibility.
  - [ ] **Dev sample data:** add a `db/seeds.rb` dev block (or `lib/tasks/dev_seed.rake`) that creates a verified organization plus a few sample events with categories, collaborator manager, a date, recurrence, participant, cover/gallery, access zone, and a published consent document — so local development has clickable data. This is dev-only sample data (NOT production seed data); reference tables such as `events_categories` are already seeded by Plan 0. Verify with `db:seed:replant`.
  - [ ] **Commit:** `git add config app/models/events app/controllers/events app/services/events app/jobs/events app/policies/events app/serializers/events db/migrate/2026071701*.rb test && git commit -m "test(events): complete event foundation phase gate"`

## Phase acceptance gate

- A verified primary organization can create and publish a listing-only event with category, date, analyzed cover, settings, and public/private visibility.
- Ownership is unambiguous; collaborators are metadata, and only explicit active assignments grant non-owner access.
- Recurrence produces stable materialized date IDs, rescheduling appends history and increments one schedule version, and cancellation initiation is irreversible, immediate, and published durably for the later resumable refund processor.
- Media, participant, access-zone, stream, and consent-document records obey same-event and publication constraints.
- Public, organizer, manager, staff, scanner, and platform-admin tests prove distinct serializer and authorization boundaries.
- Concurrency tests prove category, cover, staff, recurrence, schedule, and cancellation uniqueness at PostgreSQL boundaries.
- The full Rails test suite passes before starting the catalog plan.
