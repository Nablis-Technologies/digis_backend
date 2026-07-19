# Registration, Consent, Purchase Limits, and Privacy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build free and paid ticket registration, versioned event/product forms, encrypted immutable answers and append-only corrections, exact-version buyer/personal consent, approval/waitlist, cross-checkout purchase limits, platform retention/legal holds, and restricted expiring attendee exports.

**Architecture:** Registration submission is one aggregate command that resolves the canonical phone identity, locks current form/consent versions, validates the complete registration and per-admission matrix, writes immutable evidence, reserves purchase limits and inventory when required, and returns the next commercial action. Plain organizer form drafting may use `Core::Common`; publishing versions, submitting registrations, decisions, waitlist offers, consent actions, answer corrections, purchase-limit transitions, retention erasure, and exports each use one `Core::BaseService` command. Credentials remain downstream and receive only an issuance-ready handoff or `pending_requirements` state; answers and evidence never enter QR/scanner data.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs/advisory locks/partial indexes, Pundit, ActiveModelSerializers, Active Record encryption or the repository encryption convention, Active Storage, Solid Queue, Minitest fixtures.

---

## Normative sources and delivery rules

- Implement decisions 2.7 and 2.37-2.47, sections 8.4-8.4.4, 17-18, and Phase 3 registration/privacy portions of `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`.
- Preserve the upstream contract in `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`: buyer terms precede checkout/confirmation; personal slot consent gates credential activation; answers/evidence are absent from QR, PNR, attendee index, scans, and operator screens; purchase limits finish before a credential ID exists.
- This is pre-launch development. Implement the approved model directly and remove conflicting development code/schema; do not add compatibility read paths, duplicate evidence, or dual writes.
- Reuse `Core::User`, phone normalization/OTP primitives, organization/event authorization, `Core::BaseService`, `Core::AuditLog`, `Core::JsonResponse`, Active Storage, and durable outbox/idempotency behavior. If existing phone resolution cannot serve signup, invitation claim, registration, and complimentary issuance, extract one `Core::PhoneIdentity::ResolveOrCreate` service and migrate all four consumers in the same change; do not add a registration-only duplicate.
- Introduce a shared command concern only after three commands prove the same transaction/idempotency contract. Do not add a generic workflow engine, form expression language, medical-data module, configurable retention engine, or customer identity table.
- Expected domain failures call the Plan 0 `failure Core::BusinessError.new(...)` helper; tests inspect `result.error.code/status/errors`. New exceptions represent programmer/infrastructure errors and use `fail`, while `raise` only re-raises.
- Add log filters for all answer, invitation, token, consent, contact, export-filter, and code parameters before exposing endpoints.
- The registration migrations create nullable indexed UUID columns `ticketing_registration_answers.admission_slot_id`, `ticketing_registration_consent_requirements.admission_slot_id`, and `ticketing_purchase_limit_allocations.ticket_id` without foreign keys because their target tables intentionally arrive in the later ticket-package phase. These columns stay null throughout this phase. `db/migrate/20260717210001_create_ticketing_packages_and_credentials.rb` must add the three foreign keys immediately after it creates `ticketing_admission_slots` and `ticketing_tickets`; this is dependency ordering within one clean pre-launch implementation, not a compatibility path.
- Run commands with `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test ...`.

## File map

**Create migrations**

- `db/migrate/20260717030100_create_core_data_retention.rb`
- `db/migrate/20260717030200_create_ticketing_registrations.rb`
- `db/migrate/20260717030300_create_ticketing_registration_forms_and_answers.rb`
- `db/migrate/20260717030400_create_ticketing_registration_consents.rb`
- `db/migrate/20260717030500_create_ticketing_purchase_limits.rb`
- `db/migrate/20260717030600_create_ticketing_attendee_exports.rb`

**Create models**

- `app/models/ticketing/registration.rb`, `registration_form.rb`, `registration_form_version.rb`, `registration_question.rb`, `registration_form_submission.rb`, `registration_answer.rb`, `registration_answer_revision.rb`
- `app/models/ticketing/registration_consent_requirement.rb`, `registration_consent.rb`, `registration_consent_withdrawal.rb`
- `app/models/ticketing/purchase_limit_allocation.rb`, `purchase_limit_override.rb`, `attendee_export.rb`
- `app/models/core/data_retention_policy.rb`, `data_retention_hold.rb`

**Create controllers/policies/serializers**

- `app/controllers/ticketing/registration_forms_controller.rb`, `registration_form_versions_controller.rb`, `registrations_controller.rb`, `registration_decisions_controller.rb`, `waitlist_offers_controller.rb`, `registration_answers_controller.rb`, `registration_consents_controller.rb`, `registration_consent_withdrawals_controller.rb`, `purchase_limit_overrides_controller.rb`, `complimentary_tickets_controller.rb`, `attendee_exports_controller.rb`
- `app/controllers/admin/data_retention_policies_controller.rb`, `data_retention_holds_controller.rb`
- `app/policies/ticketing/registration_form_policy.rb`, `registration_policy.rb`, `registration_answer_policy.rb`, `registration_consent_policy.rb`, `purchase_limit_override_policy.rb`, `attendee_export_policy.rb`
- `app/policies/admin/data_retention_policy_policy.rb`, `data_retention_hold_policy.rb`
- `app/serializers/ticketing/registration_form_serializer.rb`, `registration_schema_serializer.rb`, `registration_serializer.rb`, `registration_answer_serializer.rb`, `registration_consent_requirement_serializer.rb`, `attendee_export_serializer.rb`

**Create services/value objects/jobs**

- `app/services/core/phone_identity/resolve_or_create.rb`
- `app/services/ticketing/forms/publish_version.rb`, `applicable_schema.rb`, `validate_submission.rb`, `persist_submission.rb`
- `app/services/ticketing/registrations/submit.rb`, `confirm_free.rb`, `cancel.rb`
- `app/services/ticketing/registration_decisions/approve.rb`, `reject.rb`, `reconsider.rb`
- `app/services/ticketing/waitlist/enqueue.rb`, `offer_next.rb`, `accept_offer.rb`, `expire_offer.rb`
- `app/services/ticketing/complimentary_issuance/issue.rb`
- `app/services/ticketing/answers/revise.rb`
- `app/services/ticketing/consent/build_requirements.rb`, `accept.rb`, `withdraw.rb`, `supersede_for_reassignment.rb`, `credential_requirement_status.rb`
- `app/services/ticketing/purchase_limits/reserve.rb`, `commit.rb`, `release.rb`, `grant_override.rb`, `availability.rb`
- `app/services/core/retention/select_policy.rb`, `place_hold.rb`, `release_hold.rb`, `erase_eligible_batch.rb`
- `app/services/ticketing/exports/request.rb`, `generate.rb`, `authorize_download.rb`, `expire.rb`
- `app/values/ticketing/registration_submission.rb`, `registration_next_action.rb`
- `app/jobs/ticketing/offer_waitlist_job.rb`, `expire_waitlist_offers_job.rb`, `registration_notification_job.rb`, `consent_reminder_job.rb`, `generate_attendee_export_job.rb`, `expire_attendee_exports_job.rb`
- `app/jobs/core/retention_purge_job.rb`

**Modify**

- `config/routes.rb`
- `config/recurring.yml`
- `config/initializers/filter_parameter_logging.rb`
- `config/initializers/ticketing_outbox_handlers.rb`

**Create tests and fixtures**

- Model tests under `test/models/ticketing/` and `test/models/core/data_retention_*_test.rb`
- Service tests under `test/services/ticketing/` and `test/services/core/retention/`
- Integration tests under `test/integration/ticketing/` and `test/integration/admin/data_retention_*_test.rb`
- Job tests under `test/jobs/ticketing/` and `test/jobs/core/retention_purge_job_test.rb`
- Fixtures for every exact table above under `test/fixtures/`

## Task 1: Add retention and registration schema foundations, versioned forms, and encrypted answers

This task owns `ticketing_registration_forms`, `ticketing_registration_form_versions`, `ticketing_registration_questions`, `ticketing_registration_form_submissions`, `ticketing_registration_answers`, and `ticketing_registration_answer_revisions`, plus the platform retention tables named below.

**Files:**
- Create: `db/migrate/20260717030100_create_core_data_retention.rb`
- Create: `db/migrate/20260717030200_create_ticketing_registrations.rb`
- Create: `db/migrate/20260717030300_create_ticketing_registration_forms_and_answers.rb`
- Create: `app/models/core/data_retention_policy.rb`, `data_retention_hold.rb`
- Create: `app/models/ticketing/registration.rb`
- Create: `app/services/core/retention/select_policy.rb`
- Create: `app/models/ticketing/registration_form.rb`, `registration_form_version.rb`, `registration_question.rb`, `registration_form_submission.rb`, `registration_answer.rb`, `registration_answer_revision.rb`
- Create: `app/controllers/ticketing/registration_forms_controller.rb`, `registration_form_versions_controller.rb`, `registration_answers_controller.rb`
- Create: `app/services/ticketing/forms/publish_version.rb`, `applicable_schema.rb`, `validate_submission.rb`
- Create: `app/services/ticketing/answers/revise.rb`
- Create: `app/policies/ticketing/registration_form_policy.rb`, `registration_answer_policy.rb`
- Test: `test/services/ticketing/forms/publish_version_test.rb`
- Test: `test/services/ticketing/forms/validate_submission_test.rb`
- Test: `test/services/ticketing/answers/revise_test.rb`
- Test: `test/services/core/retention/select_policy_test.rb`

- [ ] **RED:** test retention policy null-safe version uniqueness and one active version/category/jurisdiction; registration event/ticket/date/package checks; one published version/form; immutable published versions/questions; same-event product form; unique keys/positions; exact question/sensitivity/response-scope allowlists; rejection of HTML/executable rules/arbitrary regex/medical fields/uploads; complete registration and package-unit/admission-position matrices; ciphertext-only storage; scoped partial uniqueness; slot coordinate bounds; and append-only ordered revisions inheriting the original deadline.

```ruby
# test/services/ticketing/forms/validate_submission_test.rb
require "test_helper"

class Ticketing::Forms::ValidateSubmissionTest < ActiveSupport::TestCase
  test "requires every slot-scoped answer for every package admission" do
    schema = Ticketing::Forms::ApplicableSchema.call(
      event: events_events(:festival),
      ticket_type: ticketing_ticket_types(:group_of_three)
    ).value

    submission = Ticketing::RegistrationSubmission.new(
      package_quantity: 1,
      admissions_per_unit: 3,
      form_versions: schema.map(&:id),
      answers: [{ question_key: "accessibility", package_unit_number: 1, admission_position: 1, value: "None" }]
    )

    result = Ticketing::Forms::ValidateSubmission.call(schema:, submission:)
    assert result.failure?
    assert_equal "incomplete_slot_answers", result.error.code
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/retention/select_policy_test.rb test/services/ticketing/forms test/services/ticketing/answers/revise_test.rb`; expect missing tables/classes.
- [ ] **GREEN:** create `core_data_retention_policies` and `core_data_retention_holds` before answer retention-policy foreign keys, then `ticketing_registrations`, then the exact form/submission/answer/revision tables. Keep the downstream `admission_slot_id` nullable/indexed and unset until the ticket-package migration adds its target FK. Add partial unique indexes by response scope, encryption, canonical JSON validation, STI opt-out for question `type`, and status/timestamp checks. Draft CRUD may use `Core::Common`; publish and revision commands lock their aggregate and write audit metadata without values.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/retention/select_policy_test.rb test/services/ticketing/forms test/services/ticketing/answers/revise_test.rb`; expect pass.
- [ ] **Refactor:** expose effective answer through a query choosing the highest non-erased revision, then original. Never overwrite original ciphertext or extend retention.
- [ ] **Commit:** stage listed files and fixtures and commit `feat(ticketing): add versioned registration forms`.

## Task 2: Add the registration aggregate and atomic submission command

**Files:**
- Modify: `app/models/ticketing/registration.rb`
- Create: `app/values/ticketing/registration_submission.rb`, `registration_next_action.rb`
- Create: `app/services/core/phone_identity/resolve_or_create.rb`
- Create: `app/services/ticketing/registrations/submit.rb`, `confirm_free.rb`, `cancel.rb`
- Create: `app/controllers/ticketing/registrations_controller.rb`
- Create: `app/policies/ticketing/registration_policy.rb`
- Create: `app/serializers/ticketing/registration_serializer.rb`, `registration_schema_serializer.rb`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Create: `config/initializers/ticketing_outbox_handlers.rb`
- Test: `test/services/ticketing/registrations/submit_test.rb`
- Test: `test/integration/ticketing/registrations_test.rb`

- [ ] **RED:** test canonical normalized phone identity, OTP requirement, active identity dedupe, selected-date rules, package snapshot equation, source/actor/reason coupling, stale form rollback, audience authorization, exact current forms, buyer consent gate, purchase-limit/inventory atomicity, free automatic/manual, paid automatic/manual next action, and no partial persistence on failure.

```ruby
# app/services/ticketing/registrations/submit.rb
module Ticketing
  module Registrations
    class Submit < Core::BaseService
      def initialize(ticket_type:, actor:, phone:, submission:, audience_proof:)
        @ticket_type = ticket_type
        @actor = actor
        @phone = phone
        @submission = submission
        @audience_proof = audience_proof
      end

      def call
        Registration.transaction do
          identity = unwrap(Core::PhoneIdentity::ResolveOrCreate.call(phone:, actor:))
          audience = Audience::Authorize.call(ticket_type:, user: identity.user, **audience_proof)
          unwrap(audience)

          schema = unwrap(Forms::ApplicableSchema.call(event: ticket_type.event, ticket_type:))
          validation = Forms::ValidateSubmission.call(schema:, submission:)
          unwrap(validation)

          registration = create_registration!(identity)
          unwrap(Forms::PersistSubmission.call(registration:, schema:, submission:, actor:))
          unwrap(Consent::BuildRequirements.call(registration:, acceptances: submission.consents, actor: identity.user))
          reserve_and_confirm_free!(registration, identity.user) if registration.pending_payment? && ticket_type.event_product.free?
        end
        halted_result || success(RegistrationNextAction.for(registration))
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          "Registration is invalid",
          code: "invalid_registration",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :ticket_type, :actor, :phone, :submission, :audience_proof

      def create_registration!(identity)
        Registration.create!(
          event: ticket_type.event,
          ticket_type:,
          user: identity.user,
          created_by: actor,
          source: "self_service",
          package_quantity: submission.package_quantity,
          admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
          party_size: submission.package_quantity * ticket_type.admissions_per_unit,
          selected_event_date_id: submission.selected_event_date_id,
          identity_digest: identity.digest,
          status: ticket_type.approval_mode == "manual" ? "pending_approval" : "pending_payment",
          submitted_at: Time.current
        )
      end

      def inventory_arguments(registration)
        { product: ticket_type.event_product, event_date_ids: ticket_type.covered_date_ids(registration),
          package_quantity: registration.package_quantity,
          admissions_per_unit: registration.admissions_per_unit_snapshot,
          owner: registration, reservation_group_id: registration.id, expires_at: 10.minutes.from_now }
      end

      def reserve_and_confirm_free!(registration, user)
        unwrap(PurchaseLimits::Reserve.call(registration:, user:, quantity: registration.package_quantity))
        unwrap(Catalog::Inventory::Reserve.call(**inventory_arguments(registration)))
        unwrap(ConfirmFree.call(registration:))
      end

      def unwrap(result)
        return result.value if result.success?

        @halted_result = result
        fail ActiveRecord::Rollback
      end

      def halted_result
        @halted_result
      end
    end
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/registrations/submit_test.rb test/integration/ticketing/registrations_test.rb`; expect missing registration workflow.
- [ ] **GREEN:** implement the interface above and all referenced focused collaborators in their named files. `Core::PhoneIdentity::ResolveOrCreate` returns an immutable `Data.define(:user, :digest)` value containing the canonical user and keyed normalized-phone digest. Add the approved active-registration partial uniqueness boundary for `(ticket_type, identity_digest, selected date)`, transaction state checks, event/ticket-type/date same-event constraints, and log filters. A conflicting retry returns the existing active registration after authorization. Zero-price automatic submission reserves limits/inventory through the registration and delegates to `ConfirmFree`; paid submission returns an order-required action without a hold; manual approval and waitlist allocate only when approval/offer creates a real hold. No path creates a credential here.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/registrations/submit_test.rb test/integration/ticketing/registrations_test.rb`; expect pass.
- [ ] **Refactor:** if current auth/signup, invitation claim, registration, and complimentary issue all normalize/resolve phone users, migrate them together to `Core::PhoneIdentity::ResolveOrCreate`; otherwise reuse the existing canonical service and omit the new file.
- [ ] **Commit:** stage listed files and commit `feat(ticketing): add atomic registration submission`.

## Task 3: Add exact-version consent requirements, acceptance, reassignment, and withdrawal

This task owns `ticketing_registration_consent_requirements`, `ticketing_registration_consents`, and `ticketing_registration_consent_withdrawals`.

**Files:**
- Create: `db/migrate/20260717030400_create_ticketing_registration_consents.rb`
- Create: `app/models/ticketing/registration_consent_requirement.rb`, `registration_consent.rb`, `registration_consent_withdrawal.rb`
- Create: `app/services/ticketing/consent/build_requirements.rb`, `accept.rb`, `withdraw.rb`, `supersede_for_reassignment.rb`, `credential_requirement_status.rb`
- Create: `app/controllers/ticketing/registration_consents_controller.rb`, `registration_consent_withdrawals_controller.rb`
- Create: `app/policies/ticketing/registration_consent_policy.rb`
- Create: `app/serializers/ticketing/registration_consent_requirement_serializer.rb`
- Create: `app/jobs/ticketing/consent_reminder_job.rb`
- Test: `test/services/ticketing/consent/accept_test.rb`
- Test: `test/services/ticketing/consent/withdraw_test.rb`
- Test: `test/services/ticketing/consent/supersede_for_reassignment_test.rb`

- [ ] **RED:** test current requirement partial uniqueness, exact document version/digest, buyer vs admission-slot coordinates/signers, OTP-authenticated subject, one acceptance/requirement, reassignment supersession, pending-requirement credential projection, one withdrawal/acceptance, optional withdrawal, required personal withdrawal/reacceptance, immutable historical evidence, and completed buyer-contract withdrawal rejection.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/consent/accept_test.rb test/services/ticketing/consent/withdraw_test.rb test/services/ticketing/consent/supersede_for_reassignment_test.rb`; expect missing consent schema/services.
- [ ] **GREEN:** create requirement, acceptance, and withdrawal tables with exact scope/coordinate/status/time checks. Keep requirement `admission_slot_id` nullable/indexed and unset until ticket issuance and its later FK. Accept locks current requirement and inserts evidence once. Reassignment supersedes old current requirements and creates new ones. Required personal withdrawal appends a new pending requirement and calls the ticket credential projection/revocation interface; it never edits the acceptance.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/consent/accept_test.rb test/services/ticketing/consent/withdraw_test.rb test/services/ticketing/consent/supersede_for_reassignment_test.rb`; expect pass.
- [ ] **Refactor:** keep only completion state in credential integration. Do not serialize consent content, hashes, signer evidence, answers, or withdrawal reason to scanners/public clients.
- [ ] **Commit:** stage listed files and commit `feat(ticketing): add exact-version consent evidence`.

## Task 4: Add cross-checkout purchase-limit allocation and audited overrides

This task owns `ticketing_purchase_limit_allocations` and `ticketing_purchase_limit_overrides`.

**Files:**
- Create: `db/migrate/20260717030500_create_ticketing_purchase_limits.rb`
- Create: `app/models/ticketing/purchase_limit_allocation.rb`, `purchase_limit_override.rb`
- Create: `app/services/ticketing/purchase_limits/reserve.rb`, `commit.rb`, `release.rb`, `grant_override.rb`, `availability.rb`
- Create: `app/controllers/ticketing/purchase_limit_overrides_controller.rb`
- Create: `app/policies/ticketing/purchase_limit_override_policy.rb`
- Test: `test/services/ticketing/purchase_limits/reserve_test.rb`
- Test: `test/services/ticketing/purchase_limits/lifecycle_test.rb`
- Test: `test/integration/ticketing/purchase_limit_overrides_test.rb`

- [ ] **RED:** test one allocation/package unit, verified canonical user scope, product-wide vs choose-one date scope, transaction advisory lock, expired reservation cleanup, reserved+committed count, registration-specific override, idempotent lifecycle, checkout replacement reuse, primary refund release, and historical resale seller allocation retention.

```ruby
# test/services/ticketing/purchase_limits/reserve_test.rb
require "test_helper"

class Ticketing::PurchaseLimits::ReserveTest < ActiveSupport::TestCase
  test "serializes concurrent reservations for the final allowed package" do
    ticket_type = ticketing_ticket_types(:limited_one_per_user)
    user = core_users(:buyer)
    registrations = [ticketing_registrations(:attempt_one), ticketing_registrations(:attempt_two)]

    results = registrations.map do |registration|
      Thread.new { Ticketing::PurchaseLimits::Reserve.call(registration:, user:, quantity: 1) }
    end.map(&:value)

    assert_equal 1, results.count(&:success?)
    assert_equal 1, results.count(&:failure?)
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/purchase_limits/reserve_test.rb test/services/ticketing/purchase_limits/lifecycle_test.rb test/integration/ticketing/purchase_limit_overrides_test.rb`; expect missing allocation implementation.
- [ ] **GREEN:** call Plan 0 `Core::Database::AdvisoryLock.acquire!("purchase-limit", ticket_type.id, scope_event_date_id || "all-dates", user.id)` inside the transaction; release expired rows; lock/count rows; validate one immutable override; insert every requested unit or none. Use Plan 0 `Core::IdempotencyKey` for command keys and couple status timestamps to states in PostgreSQL. Keep allocation `ticket_id` nullable/indexed and unset until fulfillment; the ticket-package migration adds its FK before issuance can backfill it.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/purchase_limits/reserve_test.rb test/services/ticketing/purchase_limits/lifecycle_test.rb test/integration/ticketing/purchase_limit_overrides_test.rb`; expect one concurrent winner using independent database connections.
- [ ] **Refactor:** purchase limits never alter inventory, payment, or audience rules. Reuse Plan 0 advisory-lock hashing; keep only the purchase-limit namespace and ordered key parts domain-specific.
- [ ] **Commit:** stage listed files and commit `feat(ticketing): enforce cross-checkout purchase limits`.

## Task 5: Implement approval, rejection, reconsideration, waitlist, and complimentary issuance

**Files:**
- Create: `app/services/ticketing/registration_decisions/approve.rb`, `reject.rb`, `reconsider.rb`
- Create: `app/services/ticketing/waitlist/enqueue.rb`, `offer_next.rb`, `accept_offer.rb`, `expire_offer.rb`
- Create: `app/services/ticketing/complimentary_issuance/issue.rb`
- Create: `app/controllers/ticketing/registration_decisions_controller.rb`, `waitlist_offers_controller.rb`, `complimentary_tickets_controller.rb`
- Create: `app/jobs/ticketing/offer_waitlist_job.rb`, `expire_waitlist_offers_job.rb`, `registration_notification_job.rb`
- Test: `test/services/ticketing/registration_decisions/approve_test.rb`
- Test: `test/services/ticketing/waitlist/offer_next_test.rb`
- Test: `test/services/ticketing/complimentary_issuance/issue_test.rb`

- [ ] **RED:** test state/timestamp coupling, automatic vs manual reviewer, rejection exclusivity, audited reconsideration, queue scope/order, `FOR UPDATE SKIP LOCKED`, complete-party fit, offer expiry/requeue at back, free/paid acceptance differences, manager authorization, complimentary reason/idempotency, normal limits/inventory/consent, zero financial rows, and no cash walk-up path.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/registration_decisions/approve_test.rb test/services/ticketing/waitlist/offer_next_test.rb test/services/ticketing/complimentary_issuance/issue_test.rb`; expect missing lifecycle commands.
- [ ] **GREEN:** each decision/action is one command and one controller action. Offer workers lock inventory then select eligible registration with `SKIP LOCKED`, reserve the complete party, commit, and notify after commit. Complimentary issuance resolves the recipient, creates a zero-charge confirmed registration, commits normal capacity/limits, and emits the same issuance-ready event as free confirmation.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/registration_decisions/approve_test.rb test/services/ticketing/waitlist/offer_next_test.rb test/services/ticketing/complimentary_issuance/issue_test.rb`; expect two simultaneous offer workers to create no duplicate offer.
- [ ] **Refactor:** never create a separate waitlist table or complimentary ticket shortcut. Preserve registration as queue and all normal upstream gates.
- [ ] **Commit:** stage listed files and commit `feat(ticketing): add decisions waitlist and complimentary issuance`.

## Task 6: Add platform retention policies, legal holds, and bounded erasure

**Files:**
- Modify: `app/models/core/data_retention_policy.rb`, `data_retention_hold.rb`
- Create: `app/services/core/retention/place_hold.rb`, `release_hold.rb`, `erase_eligible_batch.rb`
- Create: `app/controllers/admin/data_retention_policies_controller.rb`, `data_retention_holds_controller.rb`
- Create: `app/policies/admin/data_retention_policy_policy.rb`, `data_retention_hold_policy.rb`
- Create: `app/jobs/core/retention_purge_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/services/core/retention/erase_eligible_batch_test.rb`
- Test: `test/integration/admin/data_retention_policies_test.rb`
- Test: `test/jobs/core/retention_purge_job_test.rb`

- [ ] **RED:** test null-safe policy version uniqueness, one active policy/category/jurisdiction, organizer prohibition, exact one hold scope, hold windows/releases/idempotency, deadline snapshot not extension, bounded row locking, hold recheck racing purge, payload-only erasure, revision erasure, tombstones, and protection of registration/ticket/financial/security truth.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/retention/erase_eligible_batch_test.rb test/integration/admin/data_retention_policies_test.rb test/jobs/core/retention_purge_job_test.rb`; expect missing retention schema.
- [ ] **GREEN:** implement policy/hold checks and platform-admin policies. Purge selects a bounded batch with `FOR UPDATE SKIP LOCKED`, rechecks active event/registration/user holds inside the transaction, nulls encrypted payload/evidence identifiers, fills erasure metadata, and records payload-free counts/errors.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/retention/erase_eligible_batch_test.rb test/integration/admin/data_retention_policies_test.rb test/jobs/core/retention_purge_job_test.rb`; expect pass.
- [ ] **Refactor:** policy selection is versioned configuration, not a dynamic organizer rule engine. Never silently extend existing `retain_until`.
- [ ] **Commit:** stage listed files and commit `feat(core): add registration data retention controls`.

## Task 7: Add field-authorized, audited, expiring attendee exports

**Files:**
- Create: `db/migrate/20260717030600_create_ticketing_attendee_exports.rb`
- Create: `app/models/ticketing/attendee_export.rb`
- Create: `app/services/ticketing/exports/request.rb`, `generate.rb`, `authorize_download.rb`, `expire.rb`
- Create: `app/controllers/ticketing/attendee_exports_controller.rb`
- Create: `app/policies/ticketing/attendee_export_policy.rb`
- Create: `app/serializers/ticketing/attendee_export_serializer.rb`
- Create: `app/jobs/ticketing/generate_attendee_export_job.rb`, `expire_attendee_exports_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/services/ticketing/exports/generate_test.rb`
- Test: `test/integration/ticketing/attendee_exports_test.rb`
- Test: `test/jobs/ticketing/expire_attendee_exports_job_test.rb`

- [ ] **RED:** test owner/admin/manager request, staff/scanner denial, recent reauthentication, field/question allowlist, sensitivity-specific permissions, event-bounded filters, idempotent request, generation-time reauthorization, erased/expired exclusion, encrypted private attachment, checksum/count, short signed URL, download-time reauthorization/audit, expiry/purge, and payload-free retained row.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/exports/generate_test.rb test/integration/ticketing/attendee_exports_test.rb test/jobs/ticketing/expire_attendee_exports_job_test.rb`; expect missing export workflow.
- [ ] **GREEN:** attach one private generated artifact, write it in bounded streaming batches, calculate SHA-256 and row count, and move pending→processing→ready only after attachment succeeds. After policy recheck the download action redirects to `export.file.blob.url(expires_in: 2.minutes, disposition: :attachment)` and writes an audit entry. Expiry purges asynchronously and marks the row expired.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/exports/generate_test.rb test/integration/ticketing/attendee_exports_test.rb test/jobs/ticketing/expire_attendee_exports_job_test.rb`; expect pass.
- [ ] **Refactor:** do not expose raw Active Storage service URLs, original answer ciphertext, erased values, or export filters beyond authorized organizer/admin serializers.
- [ ] **Commit:** stage listed files and commit `feat(ticketing): add private attendee exports`.

## Task 8: Complete API boundaries, serializer visibility, and the phase acceptance gate

**Files:**
- Modify: `config/routes.rb`
- Modify: `config/recurring.yml`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Test: `test/integration/ticketing/registration_authorization_matrix_test.rb`
- Test: `test/integration/ticketing/registration_privacy_test.rb`
- Test: `test/integration/ticketing/registration_phase_acceptance_test.rb`

- [ ] **RED:** write one full acceptance test for a group-of-three multi-day ticket with event-wide and product forms, three per-slot answers, exact-version buyer terms, personal waivers, OTP user resolution, promotion/audience proof, purchase limit, FX-priced inventory, and zone/date access. Assert either every upstream record commits and produces one issuance-ready handoff, or no registration/submission/answer/consent/allocation/inventory hold remains.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/ticketing/registration_phase_acceptance_test.rb test/integration/ticketing/registration_authorization_matrix_test.rb test/integration/ticketing/registration_privacy_test.rb`; expect any uncovered contract to fail.
- [ ] **GREEN:** complete routes, serializer profiles, Pundit scopes, typed result-to-HTTP error mappings, log filters, recurring jobs, and Plan 0 outbox handlers for notifications/export generation. The domain initializer merges its handlers without replacing other domains' entries. Confirm `Core::Common` remains limited to plain form/record CRUD; every workflow endpoint invokes exactly one service.
- [ ] **Run GREEN:** run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing test/models/core test/services/ticketing test/services/core/retention test/integration/ticketing test/integration/admin test/jobs/ticketing test/jobs/core`; expect pass.
- [ ] **Refactor:** run the full Rails test suite; inspect SQL/query counts and serialized attributes. Confirm answers, evidence, contacts, digests, legal-hold details, and export artifacts never cross public/scanner/staff surfaces.
- [ ] **Commit:** `git add app/models/ticketing app/models/core app/controllers/ticketing app/controllers/admin app/services/ticketing app/services/core app/jobs/ticketing app/jobs/core app/policies/ticketing app/policies/admin app/serializers/ticketing db/migrate/2026071703*.rb config test && git commit -m "test(ticketing): complete registration privacy phase gate"`

## Phase acceptance gate

- Current published event-wide and product-specific forms are selected under lock; stale clients receive the current schema and leave no partial registration.
- Every required registration answer and `(package_unit_number, admission_position)` answer is complete, encrypted, immutable, retained by policy, and correctable only through append-only revisions.
- Buyer terms block approval/order/free confirmation; personal slot waivers block only affected credential activation and are safely superseded on reassignment.
- Purchase limits serialize verified identity across checkouts without replacing inventory, audience, or payment rules.
- Free automatic/manual, paid next-action, waitlist, offer, and complimentary issuance states have exact transition, timestamp, idempotency, and authorization tests.
- Legal holds beat purge races; erasure removes payload while preserving structural, commercial, ticket, scan, and financial truth.
- Exports are field-authorized, reauthenticated, encrypted, audited, short-lived, and unavailable to staff/scanner roles.
- QR/PNR/scanner integration receives no answer, consent content/evidence, purchase-limit, or export data.
- PostgreSQL concurrency tests use independent connections and prove no duplicate registration, purchase allocation, offer, acceptance, revision, withdrawal, or export command.
- The full Rails test suite passes before tickets, credentials, orders, or payment fulfillment consume the issuance-ready handoff.
