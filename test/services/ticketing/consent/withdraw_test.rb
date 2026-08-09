# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Consent
    class WithdrawTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup { setup_consent_context }

      test "withdraws an optional personal acceptance without creating a replacement" do
        _document, version = create_consent_document(scope: "admission_slot", required: false)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

        result = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @actor,
          idempotency_key: "optional-withdrawal"
        )

        assert_predicate result, :success?
        assert_equal "withdrawn", requirement.reload.status
        assert_equal 1, Ticketing::RegistrationConsentWithdrawal.count
        assert_equal "complete", result.value.status
        assert_empty Ticketing::RegistrationConsentRequirement.where(
          registration_id: @registration.id,
          supersedes_requirement_id: requirement.id
        )
        assert_equal acceptance.id, requirement.registration_consent.id
      end

      test "withdraws a required personal acceptance and appends a fresh pending requirement" do
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

        result = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @actor,
          idempotency_key: "required-withdrawal",
          reason_code: "attendee_request"
        )

        replacement = Ticketing::RegistrationConsentRequirement.find_by!(
          registration_id: @registration.id,
          consent_document_version_id: version.id,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          status: "pending"
        )
        assert_predicate result, :success?
        assert_equal "withdrawn", requirement.reload.status
        assert_equal requirement.id, replacement.supersedes_requirement_id
        assert_equal "reconsent", replacement.required_reason
        assert_equal @actor.id, replacement.subject_user_id
        assert_equal "pending", result.value.status
        assert_equal [ replacement.id ], result.value.pending_requirements.map(&:id)
        assert_equal acceptance.accepted_at, acceptance.reload.accepted_at
      end

      test "only the original verified signer can withdraw an acceptance" do
        _document, version = create_consent_document(scope: "admission_slot", required: false)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

        result = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @replacement_subject,
          idempotency_key: "wrong-subject-withdrawal"
        )

        assert_predicate result, :failure?
        assert_equal "consent_withdrawal_subject_mismatch", result.error.code
        assert_equal 0, Ticketing::RegistrationConsentWithdrawal.count
        assert_equal "accepted", requirement.reload.status
      end

      test "rejects withdrawal of a completed buyer contract" do
        _document, version = create_consent_document(scope: "buyer", required: true)
        requirement = build_consent_requirements(accept_required_buyer: false).value.first
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

        result = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @actor,
          idempotency_key: "buyer-withdrawal"
        )

        assert_predicate result, :failure?
        assert_equal "buyer_consent_withdrawal_forbidden", result.error.code
        assert_equal 0, Ticketing::RegistrationConsentWithdrawal.count
        assert_equal "accepted", requirement.reload.status
      end

      test "replays withdrawal by digest without duplicate history and conflicts on a different key" do
        _document, version = create_consent_document(scope: "admission_slot", required: false)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value
        subject = -> do
          Ticketing::Consent::Withdraw.call(
            consent: acceptance,
            actor: @actor,
            idempotency_key: "replayed-withdrawal"
          )
        end

        assert_idempotent(subject, counter: -> { Ticketing::RegistrationConsentWithdrawal.count })

        conflict = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @actor,
          idempotency_key: "different-withdrawal"
        )
        assert_predicate conflict, :failure?
        assert_equal "consent_withdrawal_conflict", conflict.error.code
      end

      test "publishes one privacy-safe credential requirements handoff for withdrawal" do
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value
        subject = -> do
          Ticketing::Consent::Withdraw.call(
            consent: acceptance,
            actor: @actor,
            idempotency_key: "withdrawal-credential-handoff"
          )
        end

        assert_idempotent(subject, counter: -> { Core::OutboxEvent.where(event_type: "ticketing.consent_credential_requirements_changed").count })

        event = Core::OutboxEvent.find_by!(event_type: "ticketing.consent_credential_requirements_changed")
        assert_equal "ticketing", event.topic
        assert_equal @registration.id, event.payload.fetch("registration_id")
        assert_equal "pending", event.payload.fetch("status")
        assert_equal [ { "package_unit_number" => 1, "admission_position" => 1 } ], event.payload.fetch("affected_coordinates")
        refute_includes event.payload.keys, "consent_content"
        refute_includes event.payload.keys, "evidence_digest"
        refute_includes event.payload.keys, "accepted_by_user_id"
      end

      test "reusing a withdrawal key for another consent returns a typed conflict" do
        _first_document, first_version = create_consent_document(scope: "admission_slot", required: false)
        first_requirement = build_consent_requirements.value.first
        assign_slot!(first_requirement, subject: @actor)
        first_acceptance = accept_consent(
          requirement: first_requirement,
          content_sha256: first_version.content_sha256
        ).value

        _second_document, second_version = create_consent_document(scope: "admission_slot", required: false)
        second_requirement = build_consent_requirements.value.find do |requirement|
          requirement.consent_document_version_id == second_version.id
        end
        assign_slot!(second_requirement, subject: @actor)
        second_acceptance = accept_consent(
          requirement: second_requirement,
          content_sha256: second_version.content_sha256
        ).value

        first = Ticketing::Consent::Withdraw.call(
          consent: first_acceptance,
          actor: @actor,
          idempotency_key: "global-withdrawal-key"
        )
        second = Ticketing::Consent::Withdraw.call(
          consent: second_acceptance,
          actor: @actor,
          idempotency_key: "global-withdrawal-key"
        )

        assert_predicate first, :success?
        assert_predicate second, :failure?
        assert_equal "consent_withdrawal_conflict", second.error.code
        assert_equal 1, Ticketing::RegistrationConsentWithdrawal.count
      end

      test "reusing a withdrawal key with a different reason returns a typed conflict" do
        _document, version = create_consent_document(scope: "admission_slot", required: false)
        requirement = build_consent_requirements.value.first
        assign_slot!(requirement, subject: @actor)
        acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

        first = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @actor,
          idempotency_key: "withdrawal-reason-key",
          reason_code: "attendee_request"
        )
        changed_reason = Ticketing::Consent::Withdraw.call(
          consent: acceptance,
          actor: @actor,
          idempotency_key: "withdrawal-reason-key",
          reason_code: "privacy_request"
        )

        assert_predicate first, :success?
        assert_predicate changed_reason, :failure?
        assert_equal "consent_withdrawal_conflict", changed_reason.error.code
      end
    end
  end
end
