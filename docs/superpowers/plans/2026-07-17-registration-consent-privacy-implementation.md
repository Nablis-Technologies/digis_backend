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
- The registration migrations create nullable indexed UUID columns `ticketing_registration_answers.admission_slot_id`, `ticketing_registration_consent_requirements.admission_slot_id`, and `ticketing_purchase_limit_allocations.ticket_id` without foreign keys because their target tables intentionally arrive in the later ticket-package phase. These columns stay null throughout this phase. The future ticket-package migration, timestamped after this plan's migrations, must add the three foreign keys immediately after it creates `ticketing_admission_slots` and `ticketing_tickets`; this is dependency ordering within one clean pre-launch implementation, not a compatibility path.
- Run commands with `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test ...`.

## File map

**Create migrations**

The migration order follows the repository's one-table-per-migration rule and
places registration tables after the existing ticketing parent tables but
before the existing catalog reservation migrations. The `202607270901xx`
timestamps are intentionally between the existing `20260727090024` ticketing
migration and the `20260728000001` catalog migration.

- `db/migrate/20260727090100_create_core_data_retention_policies.rb`
- `db/migrate/20260727090101_create_ticketing_registrations.rb`
- `db/migrate/20260727090102_create_core_data_retention_holds.rb`
- `db/migrate/20260727090103_create_ticketing_registration_forms.rb`
- `db/migrate/20260727090104_create_ticketing_registration_form_versions.rb`
- `db/migrate/20260727090105_create_ticketing_registration_questions.rb`
- `db/migrate/20260727090106_create_ticketing_registration_form_submissions.rb`
- `db/migrate/20260727090107_create_ticketing_registration_answers.rb`
- `db/migrate/20260727090108_create_ticketing_registration_answer_revisions.rb`
- `db/migrate/20260727090109_create_ticketing_registration_consent_requirements.rb`
- `db/migrate/20260727090110_create_ticketing_registration_consents.rb`
- `db/migrate/20260727090111_create_ticketing_registration_consent_withdrawals.rb`
- `db/migrate/20260727090113_add_registration_immutability_triggers.rb`
- `db/migrate/20260727090114_create_ticketing_purchase_limit_allocations.rb`
- `db/migrate/20260727090115_create_ticketing_purchase_limit_overrides.rb`
- `db/migrate/20260727090116_create_core_reauthentication_proofs.rb`
- `db/migrate/20260727090117_create_ticketing_attendee_exports.rb`

`20260727090112` is intentionally unused. Rails migration versions must be unique
and ordered, not contiguous; do not rename the already implemented `90113`–`90115`
migrations merely to close the harmless gap.

**Create models**

- `app/models/ticketing/registration.rb`, `registration_form.rb`, `registration_form_version.rb`, `registration_question.rb`, `registration_form_submission.rb`, `registration_answer.rb`, `registration_answer_revision.rb`
- `app/models/ticketing/registration_consent_requirement.rb`, `registration_consent.rb`, `registration_consent_withdrawal.rb`
- `app/models/ticketing/purchase_limit_allocation.rb`, `purchase_limit_override.rb`, `attendee_export.rb`
- `app/models/core/data_retention_policy.rb`, `data_retention_hold.rb`, `reauthentication_proof.rb`

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
- `app/services/core/reauthentication/issue.rb`, `consume.rb`, `throttle.rb`
- `app/services/ticketing/exports/field_registry.rb`, `request.rb`, `generate.rb`, `authorize_download.rb`, `invalidate_for_event.rb`, `expire.rb`
- `app/values/ticketing/registration_submission.rb`, `registration_next_action.rb`
- `app/jobs/ticketing/offer_waitlist_job.rb`, `expire_waitlist_offers_job.rb`, `registration_notification_job.rb`, `consent_reminder_job.rb`, `generate_attendee_export_job.rb`, `purge_attendee_export_job.rb`, `expire_attendee_exports_job.rb`
- `app/jobs/core/retention_purge_job.rb`

**Modify**

- `db/migrate/20260728000004_create_catalog_inventory_reservations.rb`
- `db/migrate/20260729000001_create_catalog_venue_capacity_reservations.rb`
- `config/routes.rb`
- `config/recurring.yml`
- `config/initializers/filter_parameter_logging.rb`
- `config/initializers/ticketing_outbox_handlers.rb`
- `config/initializers/private_attendee_exports.rb`
- `config/storage.yml`
- `config/environments/production.rb`
- `postman/Digis API_collection.json`

**Create tests and fixtures**

- Model tests under `test/models/ticketing/`, `test/models/core/data_retention_*_test.rb`, and `test/models/core/reauthentication_proof_test.rb`
- Service tests under `test/services/ticketing/`, `test/services/core/retention/`, and `test/services/core/reauthentication/`
- Integration tests under `test/integration/ticketing/` and `test/integration/admin/data_retention_*_test.rb`
- Job tests under `test/jobs/ticketing/` and `test/jobs/core/retention_purge_job_test.rb`
- Fixtures for every exact table above under `test/fixtures/`

## Task 1: Add retention and registration schema foundations, versioned forms, and encrypted answers

This task owns `ticketing_registration_forms`, `ticketing_registration_form_versions`, `ticketing_registration_questions`, `ticketing_registration_form_submissions`, `ticketing_registration_answers`, and `ticketing_registration_answer_revisions`, plus the platform retention tables named below.

**Files:**
- Create: `db/migrate/20260727090100_create_core_data_retention_policies.rb`
- Create: `db/migrate/20260727090101_create_ticketing_registrations.rb`
- Create: `db/migrate/20260727090102_create_core_data_retention_holds.rb`
- Create: `db/migrate/20260727090103_create_ticketing_registration_forms.rb`
- Create: `db/migrate/20260727090104_create_ticketing_registration_form_versions.rb`
- Create: `db/migrate/20260727090105_create_ticketing_registration_questions.rb`
- Create: `db/migrate/20260727090106_create_ticketing_registration_form_submissions.rb`
- Create: `db/migrate/20260727090107_create_ticketing_registration_answers.rb`
- Create: `db/migrate/20260727090108_create_ticketing_registration_answer_revisions.rb`
- Create: `db/migrate/20260727090113_add_registration_immutability_triggers.rb`
- Create: `app/models/core/data_retention_policy.rb`, `data_retention_hold.rb`
- Create: `app/models/ticketing/registration.rb`
- Create: `app/services/core/retention/select_policy.rb`
- Create: `app/models/ticketing/registration_form.rb`, `registration_form_version.rb`, `registration_question.rb`, `registration_form_submission.rb`, `registration_answer.rb`, `registration_answer_revision.rb`
- Create: `app/controllers/ticketing/registration_forms_controller.rb`, `registration_form_versions_controller.rb`, `registration_answers_controller.rb`
- Create: `app/services/ticketing/forms/publish_version.rb`, `applicable_schema.rb`, `validate_submission.rb`
- Create: `app/services/ticketing/forms/persist_submission.rb`
- Create: `app/services/ticketing/answers/revise.rb`
- Create: `app/policies/ticketing/registration_form_policy.rb`, `registration_form_version_policy.rb`, `registration_answer_policy.rb`, `registration_answer_revision_policy.rb`
- Create: `app/serializers/ticketing/registration_form_serializer.rb`, `registration_form_version_serializer.rb`, `registration_question_serializer.rb`, `registration_schema_serializer.rb`, `registration_answer_serializer.rb`, `registration_answer_revision_serializer.rb`
- Test: `test/services/ticketing/forms/publish_version_test.rb`
- Test: `test/services/ticketing/forms/applicable_schema_test.rb`, `persist_submission_test.rb`
- Test: `test/services/ticketing/forms/validate_submission_test.rb`
- Test: `test/services/ticketing/answers/revise_test.rb`
- Test: `test/services/core/retention/select_policy_test.rb`
- Test: `test/integration/ticketing/registration_forms_test.rb`, `registration_answers_test.rb`

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
- Create: `db/migrate/20260727090109_create_ticketing_registration_consent_requirements.rb`
- Create: `db/migrate/20260727090110_create_ticketing_registration_consents.rb`
- Create: `db/migrate/20260727090111_create_ticketing_registration_consent_withdrawals.rb`
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
- Create: `db/migrate/20260727090114_create_ticketing_purchase_limit_allocations.rb`
- Create: `db/migrate/20260727090115_create_ticketing_purchase_limit_overrides.rb`
- Create: `app/models/ticketing/purchase_limit_allocation.rb`, `purchase_limit_override.rb`
- Create: `app/services/ticketing/purchase_limits/reserve.rb`, `commit.rb`, `release.rb`, `grant_override.rb`, `availability.rb`
- Create: `app/controllers/ticketing/purchase_limit_overrides_controller.rb`
- Create: `app/policies/ticketing/purchase_limit_override_policy.rb`
- Test: `test/services/ticketing/purchase_limits/reserve_test.rb`
- Test: `test/services/ticketing/purchase_limits/lifecycle_test.rb`
- Test: `test/integration/ticketing/purchase_limit_overrides_test.rb`

- [x] **RED:** test one allocation/package unit, verified canonical user scope, product-wide vs choose-one date scope, transaction advisory lock, expired reservation cleanup, reserved+committed count, registration-specific override, idempotent lifecycle, checkout replacement reuse, primary refund release, and historical resale seller allocation retention.

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

- [x] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/purchase_limits/reserve_test.rb test/services/ticketing/purchase_limits/lifecycle_test.rb test/integration/ticketing/purchase_limit_overrides_test.rb`; expect missing allocation implementation.
- [x] **GREEN:** call Plan 0 `Core::Database::AdvisoryLock.acquire!("purchase-limit", ticket_type.id, scope_event_date_id || "all-dates", user.id)` inside the transaction; release expired rows; lock/count rows; validate one immutable override; insert every requested unit or none. Use Plan 0 `Core::IdempotencyKey` for command keys and couple status timestamps to states in PostgreSQL. Keep allocation `ticket_id` nullable/indexed and unset until fulfillment; the ticket-package migration adds its FK before issuance can backfill it.
- [x] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/purchase_limits/reserve_test.rb test/services/ticketing/purchase_limits/lifecycle_test.rb test/integration/ticketing/purchase_limit_overrides_test.rb`; expect one concurrent winner using independent database connections.
- [x] **Refactor:** purchase limits never alter inventory, payment, or audience rules. Reuse Plan 0 advisory-lock hashing; keep only the purchase-limit namespace and ordered key parts domain-specific.
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

- [x] **RED:** test state/timestamp coupling, automatic vs manual reviewer, rejection exclusivity, audited reconsideration, queue scope/order, `FOR UPDATE SKIP LOCKED`, complete-party fit, offer expiry/requeue at back, free/paid acceptance differences, manager authorization, complimentary reason/idempotency, normal limits/inventory/consent, zero financial rows, and no cash walk-up path.
- [x] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/registration_decisions/approve_test.rb test/services/ticketing/waitlist/offer_next_test.rb test/services/ticketing/complimentary_issuance/issue_test.rb`; expect missing lifecycle commands.
- [x] **GREEN:** each decision/action is one command and one controller action. Offer workers lock inventory then select eligible registration with `SKIP LOCKED`, reserve the complete party, commit, and notify after commit. Complimentary issuance resolves the recipient, creates a zero-charge confirmed registration, commits normal capacity/limits, and emits the same issuance-ready event as free confirmation.
- [x] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/registration_decisions/approve_test.rb test/services/ticketing/waitlist/offer_next_test.rb test/services/ticketing/complimentary_issuance/issue_test.rb`; expect two simultaneous offer workers to create no duplicate offer.
- [x] **Refactor:** never create a separate waitlist table or complimentary ticket shortcut. Preserve registration as queue and all normal upstream gates.
- [ ] **Commit:** stage listed files and commit `feat(ticketing): add decisions waitlist and complimentary issuance`.

## Task 6: Add platform retention policies, legal holds, and bounded erasure

**Files:**
- Modify: `app/lib/core/database/advisory_lock.rb`
- Modify: `app/models/core/data_retention_policy.rb`, `app/models/core/data_retention_hold.rb`, `app/models/ticketing/registration_answer.rb`
- Modify: `db/migrate/20260727090113_add_registration_immutability_triggers.rb`
- Create: `app/services/core/retention/place_hold.rb`, `release_hold.rb`, `erase_eligible_batch.rb`
- Create: `app/controllers/admin/data_retention_policies_controller.rb`, `data_retention_holds_controller.rb`
- Create: `app/policies/admin/data_retention_policy_policy.rb`, `data_retention_hold_policy.rb`
- Create: `app/jobs/core/retention_purge_job.rb`
- Modify: `config/recurring.yml`, `postman/Digis API_collection.json`
- Test: `test/services/core/retention/erase_eligible_batch_test.rb`
- Test: `test/integration/admin/data_retention_policies_test.rb`
- Test: `test/jobs/core/retention_purge_job_test.rb`

- [x] **RED:** test null-safe policy version uniqueness, one active policy/category/jurisdiction, organizer prohibition, exact one hold scope, hold windows/releases/idempotency, deadline snapshot not extension, bounded row locking, hold recheck racing purge, payload-only erasure, revision erasure, tombstones, and protection of registration/ticket/financial/security truth.
- [x] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/retention/erase_eligible_batch_test.rb test/integration/admin/data_retention_policies_test.rb test/jobs/core/retention_purge_job_test.rb`; verified expected missing retention workflow failures.
- [x] **GREEN:** implement policy/hold checks and platform-admin policies. Placement, release, and purge share ordered scope advisory locks; purge selects a bounded batch with `FOR UPDATE SKIP LOCKED`, excludes committed holds, rechecks active event/registration/user holds inside the transaction, nulls encrypted payload/evidence identifiers, fills erasure metadata, and records payload-free counts/errors.
- [x] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/retention/erase_eligible_batch_test.rb test/integration/admin/data_retention_policies_test.rb test/jobs/core/retention_purge_job_test.rb`; passed.
- [x] **Refactor:** policy selection is versioned configuration, not a dynamic organizer rule engine. Never silently extend existing `retain_until`.
- [ ] **Commit:** stage listed files and commit `feat(core): add registration data retention controls`.

## Task 7: Add field-authorized, audited, expiring attendee exports

**Normative design:**
`docs/superpowers/specs/2026-08-09-private-attendee-exports-design.md`

**Files:**
- Create: `db/migrate/20260727090116_create_core_reauthentication_proofs.rb`
- Create: `db/migrate/20260727090117_create_ticketing_attendee_exports.rb`
- Create: `app/models/core/reauthentication_proof.rb`
- Create: `app/models/ticketing/attendee_export.rb`
- Modify: `app/controllers/concerns/core/authenticatable.rb`
- Create: `app/services/core/reauthentication/issue.rb`
- Create: `app/services/core/reauthentication/consume.rb`
- Create: `app/services/core/reauthentication/throttle.rb`
- Create: `app/services/ticketing/exports/field_registry.rb`
- Create: `app/services/ticketing/exports/request.rb`
- Create: `app/services/ticketing/exports/generate.rb`
- Create: `app/services/ticketing/exports/authorize_download.rb`
- Create: `app/services/ticketing/exports/invalidate_for_event.rb`
- Create: `app/services/ticketing/exports/expire.rb`
- Modify: `app/controllers/core/auth_controller.rb`
- Create: `app/controllers/ticketing/attendee_exports_controller.rb`
- Create: `app/policies/ticketing/attendee_export_policy.rb`
- Create: `app/serializers/ticketing/attendee_export_serializer.rb`
- Create: `app/jobs/ticketing/generate_attendee_export_job.rb`
- Create: `app/jobs/ticketing/purge_attendee_export_job.rb`
- Create: `app/jobs/ticketing/expire_attendee_exports_job.rb`
- Modify: `app/services/core/retention/erase_eligible_batch.rb`
- Modify: `config/routes.rb`
- Modify: `config/recurring.yml`
- Modify: `config/storage.yml`
- Modify: `config/environments/production.rb`
- Create: `config/initializers/private_attendee_exports.rb`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Modify: `config/initializers/ticketing_outbox_handlers.rb`
- Modify: `db/seeds.rb`
- Modify: `test/fixtures/core_permissions.yml`
- Modify: `test/fixtures/core_role_permissions.yml`
- Create: `config/locales/core/reauthentication.en.yml`
- Create: `config/locales/ticketing/attendee_export.en.yml`
- Modify: `postman/Digis API_collection.json`
- Test: `test/models/core/reauthentication_proof_test.rb`
- Test: `test/models/ticketing/attendee_export_test.rb`
- Test: `test/services/core/reauthentication/issue_test.rb`
- Test: `test/services/core/reauthentication/consume_test.rb`
- Test: `test/services/core/reauthentication/throttle_test.rb`
- Test: `test/services/ticketing/exports/field_registry_test.rb`
- Test: `test/services/ticketing/exports/request_test.rb`
- Test: `test/services/ticketing/exports/generate_test.rb`
- Test: `test/services/ticketing/exports/authorize_download_test.rb`
- Test: `test/services/ticketing/exports/invalidate_for_event_test.rb`
- Test: `test/services/ticketing/exports/expire_test.rb`
- Test: `test/policies/ticketing/attendee_export_policy_test.rb`
- Test: `test/integration/ticketing/attendee_exports_test.rb`
- Test: `test/jobs/ticketing/generate_attendee_export_job_test.rb`
- Test: `test/jobs/ticketing/purge_attendee_export_job_test.rb`
- Test: `test/jobs/ticketing/expire_attendee_exports_job_test.rb`
- Modify: `test/services/core/retention/erase_eligible_batch_test.rb`
- Test: `test/config/private_attendee_exports_configuration_test.rb`

- [ ] **Scaffold only the two new tables/models through the project generator.**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module \
  Core::ReauthenticationProof purpose:string \
  --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module \
  Ticketing::AttendeeExport status:string \
  --only=migration,model --no-interactive --no-auditable
```

Rename the generated migrations to exactly `20260727090116` and
`20260727090117`. Replace the generated columns with the normative design. Do
not generate public CRUD, generic model auditing, or additional tables.

- [ ] **RED 7.1 — reauthentication proofs.** Write model/service/integration
  tests for authenticated `current_user` password verification, memoized JWT JTI
  binding, HMAC digests, five-minute expiry, purpose binding, no-store response,
  a five-failure/15-minute user-session throttle, 30-attempt/hour IP throttle,
  HMAC counter keys, generic failed-password/throttled responses, inactive or
  revoked sessions, uniform invalid-proof errors, one atomic consume, and two
  independent connections racing to consume the same proof.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/core/reauthentication_proof_test.rb \
  test/services/core/reauthentication/issue_test.rb \
  test/services/core/reauthentication/consume_test.rb \
  test/services/core/reauthentication/throttle_test.rb \
  test/integration/ticketing/attendee_exports_test.rb
```

Expected RED: missing proof table/model/services and reauthenticate route.

- [ ] **GREEN 7.1 — implement the proof boundary.** The original proof migration
  uses UUIDv7; required user FK; 64-character session/token digests; purpose and
  factor checks; unique token digest; ordered issue/expiry/consume checks; and
  indexes on `(user_id, purpose, expires_at)`. `Core::Authenticatable` memoizes
  the decoded access-token payload and exposes the current JTI to authenticated
  controllers. `Issue` authenticates only `current_user`; `Consume` uses one
  locked/conditional state change and never distinguishes invalid reasons.

```ruby
# Required service contracts
Core::Reauthentication::Issue.call(
  user: current_user,
  session_jti: current_authentication_jti,
  purpose: "attendee_export_request",
  password: params.require(:password)
)

Core::Reauthentication::Consume.call(
  user: actor,
  session_jti:,
  purpose: "attendee_export_request",
  raw_proof:
)
```

Run the RED command again; expect pass. Run changed-file RuboCop before moving on.

- [ ] **RED 7.2 — export schema, row modes, registry, and policy.** Prove all
  database state/timestamp/digest/JSON/attempt/expiry constraints; 100-column
  limit; registration versus admission row compatibility; fixed built-ins;
  `question:<registration_form_id>:<question_key>` compatibility across immutable
  submitted versions using a canonical fingerprint of key/type/scope/sensitivity,
  normalized label/help text, requiredness, ordered options, and validation rules;
  changed wording/choice meaning/validation conflicts; proof that position/IDs/
  timestamps do not cause false conflicts; separate standard, contact, dietary,
  and accessibility permissions; `registration_user_email`/`registration_user_phone`
  sourced from the canonical registration user; admission-mode repetition that
  never implies a slot subject; rejection of unimplemented assigned-attendee
  contact selectors; requester-only metadata;
  platform-admin override; owner/admin/manager manageability; staff/scanner and
  unrelated-event denial; exact reason allowlist; bounded ticket-type/date/status
  filters; choose-one and fixed/multi-day access-date matching; OR-within and
  AND-across filter semantics; and proof that a reason never grants a field
  permission.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/ticketing/attendee_export_test.rb \
  test/services/ticketing/exports/field_registry_test.rb \
  test/policies/ticketing/attendee_export_policy_test.rb
```

Expected RED: missing export schema, registry, and policy.

- [ ] **GREEN 7.2 — implement the aggregate and field contract.** The original
  export migration implements every column and constraint in the approved spec,
  including `expiring`, versioned keyed request/field/filter digests,
  `data_cutoff_at`, processing
  lease/attempts, precise lifecycle timestamps, 24-hour maximum expiry, and
  payload fields required before/null after tombstoning. Add status/due/actor/
  event indexes and `lock_version`. Bind the attachment explicitly:

```ruby
has_one_attached :file, service: :private_exports
```

`FieldRegistry` owns all extractor lambdas and headings. It accepts no SQL,
constant, method, heading, or JSON path supplied by the client. Add the four
permissions to seeds and fixtures. Grant all four to `SUPER_ADMIN`/`ADMIN`,
request/contact to `ORGANIZER`, and none to `CORE_ADMIN`/`SUPPORT`/`USER`.
Dietary/accessibility remain explicit custom/admin-role grants. Event
manageability and permission are both mandatory; neither widens the other.
The registry canonicalizes question semantic fingerprints itself; it never
trusts a client fingerprint or merges a selector after any semantic component
changes.

Run the RED command again; expect pass.

- [ ] **RED 7.3 — request idempotency and durable dispatch.** Prove missing header
  returns `400 missing_idempotency_key`; exact replay returns the original export
  with omitted, expired, consumed, and malformed proof inputs without reading,
  validating, or consuming them and without another outbox/audit row; current
  actor/event/field authorization still runs; a mismatched fingerprint returns
  `409 idempotency_conflict`; a genuinely new request atomically consumes one
  request proof and writes pending export, synchronous audit, and
  `ticketing.attendee_export.requested` outbox event; duplicate outbox delivery
  enqueues safely; event ticket-type/date/status filters cannot escape the event.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/ticketing/exports/request_test.rb \
  test/integration/ticketing/attendee_exports_test.rb \
  test/jobs/ticketing/generate_attendee_export_job_test.rb
```

Expected RED: request/outbox/idempotency behavior is absent.

- [ ] **GREEN 7.3 — implement request and outbox flow.** Require the shared
  `Idempotency-Key` header resolver. Canonicalize actor/event/row mode/ordered
  selectors/filters/reason into a request fingerprint. Scope the idempotency HMAC
  to the operation namespace and requester; use versioned platform HMACs for all
  low-entropy retained request digests and plain SHA-256 only for file integrity.
  Domain-separate each digest purpose and keep referenced historical HMAC keys
  for the full tombstone-retention period.
  After current authorization and canonical request parsing, resolve exact replay
  before proof presence or validity is checked. The controller passes optional
  proof input and must not call `params.require` for it; only a genuinely new
  request requires and consumes the proof. Use `Core::Audit::Record` and
  `Core::Outbox::Publish` inside the export transaction. Register the outbox
  handler by merging one new key in
  `ticketing_outbox_handlers.rb`; do not call `perform_later` from an
  `after_commit` callback.

```ruby
Rails.application.config.x.outbox_handlers["ticketing.attendee_export.requested"] = lambda do |event|
  Ticketing::GenerateAttendeeExportJob.perform_later(event.payload.fetch("attendee_export_id"))
end
```

Use `assert_idempotent` and `assert_audit_idempotent`, then rerun the RED command.

- [ ] **RED 7.4 — generation, recovery, CSV safety, and source erasure.** Prove
  the cutoff-bounded registration cohort; highest eligible revision at/before
  cutoff; generation-time mutable status and registration-user contact semantics;
  no erased,
  expired, consent, or legal-hold-only payload; deterministic registration and
  group-admission rows; 1,000-row batches; 250,000-row/100-column/512-MiB limits;
  CRLF UTF-8 `csv_v1`; canonical arrays/dates/nils; spreadsheet formula
  neutralization; SHA-256 and exact row count; mode-0600 temporary file cleanup;
  authorization recheck; duplicate job; stale 15-minute lease reclaim; partial
  attachment purge; three-attempt limit; earliest-retention expiry cap; and no
  ready transition after invalidation. Prove both finalization/invalidation race
  directions, shared event-lock serialization of a new request versus erasure,
  multi-event/event-row lock ordering, and download authorization racing
  invalidation.

Also prove `EraseEligibleBatch` changes every pending/processing/ready/failed
export for the event to `expiring` and publishes one idempotent
`ticketing.attendee_export.purge_requested` event per export in the same
transaction before answer/revision ciphertext becomes null.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/ticketing/exports/generate_test.rb \
  test/services/ticketing/exports/invalidate_for_event_test.rb \
  test/jobs/ticketing/generate_attendee_export_job_test.rb \
  test/jobs/ticketing/purge_attendee_export_job_test.rb \
  test/services/core/retention/erase_eligible_batch_test.rb
```

Expected RED: generation/recovery/invalidation contracts are absent.

- [ ] **GREEN 7.4 — implement bounded recoverable generation.** Claim or reclaim
  one attempt under row lock, generate outside the lock, then lock/recheck the
  same attempt before ready. On any non-ready outcome purge partial attachment
  and store only an allowlisted failure code. `InvalidateForEvent` locks exports
  by ID, transitions them to `expiring`, records idempotent audits, and publishes
  one `ticketing.attendee_export.purge_requested` event per export before
  retention erasure commits. Register a merge-safe outbox handler that enqueues
  `PurgeAttendeeExportJob` with only the export ID. Do not add a per-answer
  export manifest table at launch.

  Every export state-changing transaction and every source-answer erasure
  transaction first calls
  `Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event.id)`.
  Retention's existing scope locks continue protecting hold/erasure coordination.
  For multi-event erasure acquire event locks in ascending event-ID order, then
  export rows in ascending export-ID order. Request/replay, claim/reclaim,
  finalization, download authorization, invalidation, and expiry use event lock
  before export row lock. Generate/upload outside all locks; finalization
  reacquires them and succeeds only from its exact `processing` attempt. Document
  and test this global order. ID-driven workers may read immutable `event_id`
  unlocked, then acquire the event lock and lock/reload the export; they must
  never hold an export row lock while waiting for the advisory lock.

Run the RED command again; expect pass.

- [ ] **RED 7.5 — download authorization, expiry, and tombstone.** Prove there is
  no state-changing GET; POST requires a fresh download-purpose proof; only the
  requester/platform administrator can authorize; every field is rechecked;
  URL TTL equals `min(2.minutes, expires_at - Time.current)`; audit action records
  authorization rather than confirmed download; serializer contains no URL,
  selectors, filters, proof/session data, or internal storage metadata; due and
  stuck-expiring jobs are retry-safe; expiry blocks authorization before remote
  purge and clears selectors/filters/failure data before final `expired`.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/ticketing/exports/authorize_download_test.rb \
  test/services/ticketing/exports/expire_test.rb \
  test/integration/ticketing/attendee_exports_test.rb \
  test/jobs/ticketing/expire_attendee_exports_job_test.rb
```

Expected RED: POST authorization/expiring/tombstone behavior is absent.

- [ ] **GREEN 7.5 — implement download and purge.** `AuthorizeDownload` consumes
  proof, updates `last_download_authorized_at`, and writes
  `ticketing.attendee_export.download_authorized` in one transaction; create the
  provider URL only after commit. `Expire` first makes the row non-downloadable,
  purges outside the transaction with retries, then finalizes a digest-only
  tombstone and synchronous expiry audit. The API documentation explicitly calls
  the returned URL a short-lived bearer capability, not a revocable or confirmed
  download.

Run the RED command again; expect pass.

- [ ] **RED/GREEN 7.6 — production storage, logging, routes, scheduling, and
  Postman.** Configure `private_exports`, reject Disk/public storage in production
  when exports are enabled, add the five-minute proof and two-minute URL settings,
  filter password/proof/selectors/filters/contact/URL/idempotency parameters, and
  register only these routes:

```text
POST /auth/reauthenticate
POST /events/:event_id/attendee_exports
GET  /attendee_exports/:id
POST /attendee_exports/:id/download_authorizations
```

Add recurring bounded expiry processing and synchronized Postman examples for
success, new-request missing proof, missing idempotency key, forbidden
sensitivity, exact replay with omitted/expired proof, fingerprint conflict,
not-ready, expired, and payload-free tombstone.

The configuration test must inspect the attachment's named `private_exports`
service rather than the application's unrelated global Active Storage default.
It proves production boot rejects Disk/public configuration while test and
development may use private Disk storage.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails routes | rg "reauthenticate|attendee_export"
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/config/private_attendee_exports_configuration_test.rb \
  test/models/core/reauthentication_proof_test.rb \
  test/models/ticketing/attendee_export_test.rb \
  test/services/core/reauthentication \
  test/services/ticketing/exports \
  test/policies/ticketing/attendee_export_policy_test.rb \
  test/integration/ticketing/attendee_exports_test.rb \
  test/jobs/ticketing/generate_attendee_export_job_test.rb \
  test/jobs/ticketing/purge_attendee_export_job_test.rb \
  test/jobs/ticketing/expire_attendee_exports_job_test.rb \
  test/services/core/retention/erase_eligible_batch_test.rb
```

- [ ] **Refactor and phase verification.** Run independent-connection races for
  proof consumption, exact request replay, stale generation reclaim, retention
  invalidation versus ready finalization in both lock orders, a late request
  versus source erasure, download authorization versus invalidation, and download
  authorization versus expiry. Confirm every export/erasure path uses the shared
  `registration-privacy-event` transaction lock before export row locks, no file
  generation holds it, and multi-event locks are sorted. Confirm every
  audit/outbox payload is value-free and every query is
  event-bounded/eager-loaded. Then run:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails zeitwerk:check
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman --no-pager
git diff --check
```

- [ ] **Commit:** stage only the Task 7 files above and commit
  `feat(ticketing): add private attendee exports`.

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
- [ ] **GREEN:** complete routes, serializer profiles, Pundit scopes, typed result-to-HTTP error mappings, log filters, recurring jobs, private-export storage validation, and Plan 0 outbox handlers for notifications/export generation/purge. The domain initializer merges its handlers without replacing other domains' entries. Confirm `Core::Common` remains limited to plain form/record CRUD; every workflow endpoint invokes exactly one service. Outbox *delivery* (the enqueuer and recovery sweep that actually dispatch rows) is owned by Plan 0 — core-foundation Task 5, Step 8 (`Core::ProcessOutboxJob` + a `config/recurring.yml` entry); this plan only registers handlers.
- [ ] **Run GREEN:** run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing test/models/core test/services/ticketing test/services/core/retention test/integration/ticketing test/integration/admin test/jobs/ticketing test/jobs/core`; expect pass.
- [ ] **Refactor:** run the full Rails test suite; inspect SQL/query counts and serialized attributes. Confirm answers, evidence, contacts, digests, legal-hold details, and export artifacts never cross public/scanner/staff surfaces.
- [ ] **Commit:** `git add app/models/ticketing app/models/core app/controllers/ticketing app/controllers/admin app/services/ticketing app/services/core app/jobs/ticketing app/jobs/core app/policies/ticketing app/policies/admin app/serializers/ticketing db/migrate/202607270901*.rb config test postman/Digis\ API_collection.json && git commit -m "test(ticketing): complete registration privacy phase gate"`

## Phase acceptance gate

- Current published event-wide and product-specific forms are selected under lock; stale clients receive the current schema and leave no partial registration.
- Every required registration answer and `(package_unit_number, admission_position)` answer is complete, encrypted, immutable, retained by policy, and correctable only through append-only revisions.
- Buyer terms block approval/order/free confirmation; personal slot waivers block only affected credential activation and are safely superseded on reassignment.
- Purchase limits serialize verified identity across checkouts without replacing inventory, audience, or payment rules.
- Free automatic/manual, paid next-action, waitlist, offer, and complimentary issuance states have exact transition, timestamp, idempotency, and authorization tests.
- Legal holds beat purge races; erasure removes payload while preserving structural, commercial, ticket, scan, and financial truth.
- Exports use session-bound single-use reauthentication, exact idempotent replay, explicit registration/admission row modes, registry-owned field/contact/sensitivity authorization, deterministic spreadsheet-safe CSV, private encrypted-at-rest storage, retention-capped expiry, source-erasure invalidation, lease recovery, synchronous audit/outbox evidence, POST download authorization, and digest-only tombstones. Staff/scanner authority alone can never request, view, or download one.
- QR/PNR/scanner integration receives no answer, consent content/evidence, purchase-limit, or export data.
- PostgreSQL concurrency tests use independent connections and prove no duplicate registration, purchase allocation, offer, acceptance, revision, withdrawal, proof consumption, export request, generation finalization, retention invalidation, download authorization, or expiry transition.
- The full Rails test suite passes before tickets, credentials, orders, or payment fulfillment consume the issuance-ready handoff.
