# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Consent
    class SupersedeForReassignmentTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup { setup_consent_context(package_quantity: 2, admissions_per_unit: 2) }

      test "builds every package and admission coordinate" do
        _document, = create_consent_document(scope: "admission_slot", required: true)

        result = build_consent_requirements

        assert_predicate result, :success?
        assert_equal 4, result.value.size
        coordinates = result.value.map do |requirement|
          [ requirement.package_unit_number, requirement.admission_position ]
        end.sort
        assert_equal [ [ 1, 1 ], [ 1, 2 ], [ 2, 1 ], [ 2, 2 ] ], coordinates
        assert result.value.all? { |requirement| requirement.subject_user_id.nil? }
      end

      test "supersedes the current requirement while preserving prior acceptance history" do
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.find do |candidate|
          candidate.package_unit_number == 1 && candidate.admission_position == 1
        end
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

        result = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: 1,
          admission_position: 1,
          replacement_subject: @replacement_subject,
          actor: @actor,
          idempotency_key: "reassign-1"
        )

        replacement = result.value
        assert_predicate result, :success?
        assert_equal "superseded", requirement.reload.status
        assert_not_nil requirement.superseded_at
        assert_equal "pending", replacement.status
        assert_equal requirement.id, replacement.supersedes_requirement_id
        assert_equal version.id, replacement.consent_document_version_id
        assert_equal @replacement_subject.id, replacement.subject_user_id
        assert_equal "reconsent", replacement.required_reason
        assert_equal acceptance.id, requirement.registration_consent.id
        assert_equal "pending", Ticketing::Consent::CredentialRequirementStatus.call(
          registration: @registration
        ).value.status
      end

      test "is idempotent and does not authorize the prior subject for the replacement" do
        _document, = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)

        subject = -> do
          Ticketing::Consent::SupersedeForReassignment.call(
            registration: @registration,
            package_unit_number: requirement.package_unit_number,
            admission_position: requirement.admission_position,
            replacement_subject: @replacement_subject,
            actor: @actor,
            idempotency_key: "reassign-replay"
          )
        end
        assert_idempotent(subject, counter: -> {
          Ticketing::RegistrationConsentRequirement.where.not(supersedes_requirement_id: nil).count
        })

        replacement = Ticketing::RegistrationConsentRequirement.find_by!(
          status: "pending",
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position
        )
        old_subject_attempt = accept_consent(requirement: replacement, actor: @actor)
        assert_predicate old_subject_attempt, :failure?
        assert_equal "consent_subject_mismatch", old_subject_attempt.error.code

        different_replacement = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: core_users(:super_admin),
          actor: @actor,
          idempotency_key: "reassign-replay"
        )
        assert_predicate different_replacement, :failure?
        assert_equal "consent_reassignment_conflict", different_replacement.error.code
      end

      test "publishes one privacy-safe credential requirements handoff for reassignment" do
        _document, = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        subject = -> do
          Ticketing::Consent::SupersedeForReassignment.call(
            registration: @registration,
            package_unit_number: requirement.package_unit_number,
            admission_position: requirement.admission_position,
            replacement_subject: @replacement_subject,
            actor: @actor,
            idempotency_key: "reassignment-credential-handoff"
          )
        end

        assert_idempotent(subject, counter: -> { Core::OutboxEvent.where(event_type: "ticketing.consent_credential_requirements_changed").count })

        event = Core::OutboxEvent.find_by!(event_type: "ticketing.consent_credential_requirements_changed")
        assert_equal @registration.id, event.payload.fetch("registration_id")
        assert_equal "pending", event.payload.fetch("status")
        assert_equal [ { "package_unit_number" => 1, "admission_position" => 1 } ], event.payload.fetch("affected_coordinates")
        assert_empty event.payload.keys & %w[consent_content evidence_digest accepted_by_user_id]
      end

      test "rejects a replacement subject who is already current at the coordinate" do
        _document, = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)

        result = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @actor,
          actor: @actor,
          idempotency_key: "reassign-prior-subject"
        )

        assert_predicate result, :failure?
        assert_equal "consent_replacement_subject_conflict", result.error.code
        assert_equal "pending", requirement.reload.status
        assert_empty Ticketing::RegistrationConsentRequirement.where(
          supersedes_requirement_id: requirement.id
        )
      end

      test "requires an explicit idempotency key" do
        _document, = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first

        result = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @replacement_subject,
          actor: @actor
        )

        assert_predicate result, :failure?
        assert_equal "missing_idempotency_key", result.error.code
        assert_equal "pending", requirement.reload.status
      end

      test "a changed key cannot create a second replacement lineage" do
        _document, = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first

        first = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @replacement_subject,
          actor: @actor,
          idempotency_key: "reassign-original-key"
        )
        changed_key = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @replacement_subject,
          actor: @actor,
          idempotency_key: "reassign-changed-key"
        )

        assert_predicate first, :success?
        assert_predicate changed_key, :failure?
        assert_equal "consent_replacement_subject_conflict", changed_key.error.code
        assert_equal 1, Ticketing::RegistrationConsentRequirement.where(
          supersedes_requirement_id: requirement.id
        ).count
      end

      test "retries after replacement acceptance do not create another lineage" do
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first
        key = "reassign-after-acceptance"
        first = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @replacement_subject,
          actor: @actor,
          idempotency_key: key
        )
        replacement = first.value
        accept_consent(
          requirement: replacement,
          actor: @replacement_subject,
          content_sha256: version.content_sha256
        )

        replay = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @replacement_subject,
          actor: @actor,
          idempotency_key: key
        )

        assert_predicate first, :success?
        assert_predicate replay, :success?
        assert_equal replacement.id, replay.value.id
        assert_equal 1, Ticketing::RegistrationConsentRequirement.where(
          supersedes_requirement_id: requirement.id
        ).count
      end

      test "rejects reassignment by an unrelated actor" do
        _document, = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first

        result = Ticketing::Consent::SupersedeForReassignment.call(
          registration: @registration,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          replacement_subject: @replacement_subject,
          actor: @replacement_subject,
          idempotency_key: "reassign-unauthorized"
        )

        assert_predicate result, :failure?
        assert_equal "consent_reassignment_forbidden", result.error.code
        assert_equal "pending", requirement.reload.status
        assert_nil requirement.reload.subject_user_id
      end
    end
  end
end
