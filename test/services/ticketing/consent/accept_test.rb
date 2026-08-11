# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Consent
    class AcceptTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup { setup_consent_context }

      test "accepts the exact current version and stores private evidence safely" do
        _document, version = create_consent_document(scope: "buyer")
        build_result = build_consent_requirements(accept_required_buyer: false)
        requirement = build_result.value.first

        result = accept_consent(requirement:)

        assert_predicate result, :success?
        acceptance = result.value
        assert_equal requirement.id, acceptance.registration_consent_requirement_id
        assert_equal @registration.id, acceptance.registration_id
        assert_equal @actor.id, acceptance.accepted_by_user_id
        assert_equal "buyer", acceptance.signer_role
        assert_equal version.content_sha256, acceptance.content_sha256
        assert_match(/\A[0-9a-f]{64}\z/, acceptance.evidence_digest)
        assert_equal @retention_policy.id, acceptance.retention_policy_id
        assert_equal acceptance.accepted_at + 30.days, acceptance.retain_until
        assert_equal "accepted", requirement.reload.status
        assert_not_includes acceptance.attributes.keys, "answer"
        assert_not_includes acceptance.attributes.keys, "body"
      end

      test "rejects acceptance from an OTP-unverified subject without creating evidence" do
        _document, version = create_consent_document(scope: "buyer")
        requirement = build_consent_requirements(accept_required_buyer: false).value.first
        @actor.update!(verified_at: nil)

        result = accept_consent(requirement:, content_sha256: version.content_sha256)

        assert_predicate result, :failure?
        assert_equal "consent_subject_unverified", result.error.code
        assert_equal 0, Ticketing::RegistrationConsent.count
        assert_equal "pending", requirement.reload.status
      end

      test "requires a slot subject and records the attendee signer role" do
        _document, version = create_consent_document(scope: "admission_slot")
        requirement = build_consent_requirements.value.first

        unassigned = accept_consent(requirement:)
        assert_predicate unassigned, :failure?
        assert_equal "consent_subject_unassigned", unassigned.error.code

        assign_slot!(requirement, subject: @replacement_subject)
        wrong_subject = accept_consent(requirement:, actor: @actor)
        assert_predicate wrong_subject, :failure?
        assert_equal "consent_subject_mismatch", wrong_subject.error.code

        result = accept_consent(requirement:, actor: @replacement_subject, content_sha256: version.content_sha256)

        assert_predicate result, :success?
        assert_equal "attendee", result.value.signer_role
        assert_equal @replacement_subject.id, result.value.accepted_by_user_id
      end

      test "does not create duplicate requirements or acceptance evidence on replay" do
        _document, = create_consent_document(scope: "buyer")
        first_build = build_consent_requirements(accept_required_buyer: false)
        second_build = build_consent_requirements(accept_required_buyer: false)
        assert_predicate first_build, :success?
        assert_predicate second_build, :success?
        assert_equal 1, Ticketing::RegistrationConsentRequirement.count

        requirement = first_build.value.first
        request_uuid = SecureRandom.uuid
        subject = -> { accept_consent(requirement:, request_uuid:) }
        assert_idempotent(subject, counter: -> { Ticketing::RegistrationConsent.count })

        conflict = accept_consent(requirement:, request_uuid: SecureRandom.uuid)
        assert_predicate conflict, :failure?
        assert_equal "acceptance_conflict", conflict.error.code
      end

      test "requires an idempotency key" do
        _document, version = create_consent_document(scope: "buyer")
        requirement = build_consent_requirements(accept_required_buyer: false).value.first

        result = Ticketing::Consent::Accept.call(
          requirement:,
          actor: @actor,
          request_uuid: SecureRandom.uuid,
          content_sha256: version.content_sha256
        )

        assert_predicate result, :failure?
        assert_equal "missing_idempotency_key", result.error.code
        assert_equal "pending", requirement.reload.status
      end

      test "uses the localized invalid idempotency key message" do
        _document, version = create_consent_document(scope: "buyer")
        requirement = build_consent_requirements(accept_required_buyer: false).value.first

        result = accept_consent(requirement:, content_sha256: version.content_sha256, idempotency_key: "a" * 256)

        assert_predicate result, :failure?
        assert_equal "invalid_idempotency_key", result.error.code
        assert_equal I18n.t("ticketing.consents.errors.invalid_idempotency_key"), result.error.message
      end

      test "a key reused for another requirement returns a typed conflict" do
        _first_document, first_version = create_consent_document(scope: "buyer")
        _second_document, second_version = create_consent_document(scope: "buyer")
        requirements = build_consent_requirements(accept_required_buyer: false).value
        first_requirement = requirements.find do |requirement|
          requirement.consent_document_version_id == first_version.id
        end
        second_requirement = requirements.find do |requirement|
          requirement.consent_document_version_id == second_version.id
        end
        key = "acceptance-shared-key"

        first = accept_consent(
          requirement: first_requirement,
          content_sha256: first_version.content_sha256,
          idempotency_key: key
        )
        second = accept_consent(
          requirement: second_requirement,
          content_sha256: second_version.content_sha256,
          idempotency_key: key
        )

        assert_predicate first, :success?
        assert_predicate second, :failure?
        assert_equal "acceptance_conflict", second.error.code
        assert_equal "pending", second_requirement.reload.status
      end

      test "a different key cannot replay an acceptance request" do
        _document, version = create_consent_document(scope: "buyer")
        requirement = build_consent_requirements(accept_required_buyer: false).value.first
        request_uuid = SecureRandom.uuid

        first = accept_consent(
          requirement:,
          request_uuid:,
          content_sha256: version.content_sha256,
          idempotency_key: "acceptance-first-key"
        )
        replay = accept_consent(
          requirement:,
          request_uuid:,
          content_sha256: version.content_sha256,
          idempotency_key: "acceptance-different-key"
        )

        assert_predicate first, :success?
        assert_predicate replay, :failure?
        assert_equal "acceptance_conflict", replay.error.code
      end

      test "accepts a pending requirement for its exact retired version" do
        document, version = create_consent_document(scope: "buyer")
        requirement = build_consent_requirements(accept_required_buyer: false).value.first
        newer = document.versions.create!(
          version: 2,
          title: "New title",
          body: "New body",
          content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
            type: document.type, title: "New title", body: "New body"
          ),
          required: true,
          acceptance_scope: "buyer",
          status: "draft",
          created_by: core_users(:super_admin)
        )
        Events::ConsentDocuments::PublishVersion.call(
          consent_document: document,
          actor: core_users(:super_admin)
        )

        result = accept_consent(requirement:, content_sha256: version.content_sha256)

        assert_predicate result, :success?
        assert_equal "accepted", requirement.reload.status
        assert_equal version.content_sha256, result.value.content_sha256
        assert_equal "retired", version.reload.status
        assert_equal "published", newer.reload.status
      end

      test "new registrations snapshot only the newer published version" do
        document, = create_consent_document(scope: "buyer")
        original_requirement = build_consent_requirements(accept_required_buyer: false).value.first
        newer = document.versions.create!(
          version: 2,
          title: "New title",
          body: "New body",
          content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
            type: document.type, title: "New title", body: "New body"
          ),
          required: true,
          acceptance_scope: "buyer",
          status: "draft",
          created_by: core_users(:super_admin)
        )
        Events::ConsentDocuments::PublishVersion.call(
          consent_document: document,
          actor: core_users(:super_admin)
        )
        new_registration = Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @replacement_subject,
          created_by: @replacement_subject,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: Time.current
        )

        result = Ticketing::Consent::BuildRequirements.call(
          registration: new_registration,
          acceptances: [
            {
              consent_document_version_id: newer.id,
              request_uuid: SecureRandom.uuid,
              idempotency_key: "new-registration-consent",
              acceptance_method: "otp",
              content_sha256: newer.content_sha256
            }
          ],
          actor: @replacement_subject
        )

        assert_predicate result, :success?
        assert_equal [ newer.id ], result.value.map(&:consent_document_version_id)
        assert_equal "pending", original_requirement.reload.status
        assert_equal 1, Ticketing::RegistrationConsentRequirement.where(
          registration_id: @registration.id,
          consent_document_version_id: document.versions.find_by!(version: 1).id
        ).count
      end

      test "rejects caller-supplied evidence for a different document digest" do
        _document, version = create_consent_document(scope: "buyer")
        requirement = build_consent_requirements(accept_required_buyer: false).value.first

        result = accept_consent(requirement:, content_sha256: "f" * 64)

        assert_predicate result, :failure?
        assert_equal "consent_content_mismatch", result.error.code
        assert_equal version.content_sha256, requirement.consent_document_version.content_sha256
        assert_equal 0, Ticketing::RegistrationConsent.count
      end

      test "rolls back all requirements when one supplied buyer acceptance is invalid" do
        _first_document, first_version = create_consent_document(scope: "buyer")
        _second_document, second_version = create_consent_document(scope: "buyer")

        result = build_consent_requirements(
          accept_required_buyer: false,
          acceptances: [
            {
              consent_document_version_id: first_version.id,
              request_uuid: SecureRandom.uuid,
              idempotency_key: "first-invalid-buyer-consent",
              content_sha256: first_version.content_sha256,
              acceptance_method: "otp"
            },
            {
              consent_document_version_id: second_version.id,
              request_uuid: SecureRandom.uuid,
              idempotency_key: "second-invalid-buyer-consent",
              content_sha256: "0" * 64,
              acceptance_method: "otp"
            }
          ]
        )

        assert_predicate result, :failure?
        assert_equal "consent_content_mismatch", result.error.code
        assert_equal 0, Ticketing::RegistrationConsentRequirement.count
        assert_equal 0, Ticketing::RegistrationConsent.count
      end

      test "projects incomplete required consent without inventing a credential" do
        _document, = create_consent_document(scope: "buyer")
        build_consent_requirements(accept_required_buyer: false)

        result = Ticketing::Consent::CredentialRequirementStatus.call(registration: @registration)

        assert_predicate result, :success?
        assert_equal "pending", result.value.status
        assert_equal 1, result.value.pending_requirements.size
        assert_equal Ticketing::RegistrationConsentRequirement, result.value.pending_requirements.first.class
      end
    end
  end
end
