# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationConsentRequirementTest < ActiveSupport::TestCase
    include Ticketing::ConsentTestHelpers

    setup do
      setup_consent_context
      _document, = create_consent_document(scope: "buyer", required: true)
      @requirement = build_consent_requirements(accept_required_buyer: false).value.first
    end

    test "model rejects an accepted requirement without acceptance evidence" do
      @requirement.status = "accepted"

      assert_not @requirement.valid?
      assert @requirement.errors[:base].present?
    end

    test "database rejects direct accepted status without acceptance evidence" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          Ticketing::RegistrationConsentRequirement.where(id: @requirement.id).update_all(status: "accepted")
          Ticketing::RegistrationConsentRequirement.connection.execute(
            "SET CONSTRAINTS trg_consent_requirement_has_evidence IMMEDIATE"
          )
        end
      end
    end

    test "database rejects a forged accepted requirement insert without evidence" do
      assert_raises(ActiveRecord::StatementInvalid) { insert_requirement!(status: "accepted") }
    end

    test "acceptance evidence constraint trigger defers requirement validation to commit" do
      definition = trigger_definition(
        "trg_consent_requirement_has_evidence"
      )

      assert_match(/AFTER INSERT OR UPDATE OF status/i, definition)
      assert_match(/DEFERRABLE INITIALLY DEFERRED/i, definition)
    end

    test "database rejects direct withdrawn status without withdrawal evidence" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          Ticketing::RegistrationConsentRequirement.where(id: @requirement.id).update_all(status: "withdrawn")
        end
      end
    end

    test "database rejects a forged withdrawn requirement insert without evidence" do
      assert_raises(ActiveRecord::StatementInvalid) { insert_requirement!(status: "withdrawn") }
    end

    test "withdrawal evidence trigger protects inserts and status transitions" do
      definition = trigger_definition(
        "trg_ticketing_registration_consent_requirement_withdrawal_evidence"
      )

      assert_match(/BEFORE INSERT OR UPDATE OF status/i, definition)
    end

    test "database rejects direct mutation of immutable requirement snapshots" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          Ticketing::RegistrationConsentRequirement.where(id: @requirement.id)
            .update_all(required_at: 1.hour.ago)
        end
      end
    end

    test "database rejects deletion of a pending requirement and preserves its credential status" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          ActiveRecord::Base.lease_connection.execute(
            "DELETE FROM ticketing_registration_consent_requirements WHERE id = '#{@requirement.id}'"
          )
        end
      end

      assert_equal "pending", Ticketing::Consent::CredentialRequirementStatus.call(
        registration: @registration
      ).value.status
      assert_equal "pending", @requirement.reload.status
    end

    test "database rejects an admission-slot requirement with a missing coordinate" do
      _document, version = create_consent_document(scope: "admission_slot")
      now = Time.current

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.insert_all!([
          {
            id: SecureRandom.uuid,
            registration_id: @registration.id,
            consent_document_version_id: version.id,
            required: true,
            acceptance_scope: "admission_slot",
            package_unit_number: nil,
            admission_position: 1,
            status: "pending",
            required_reason: "initial_submission",
            required_at: now,
            created_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "admission-slot requirements reject pre-issuance admission slot IDs" do
      _document, version = create_consent_document(scope: "admission_slot")
      now = Time.current
      requirement = Ticketing::RegistrationConsentRequirement.new(
        registration: @registration,
        consent_document_version: version,
        required: true,
        acceptance_scope: "admission_slot",
        package_unit_number: 1,
        admission_position: 1,
        admission_slot_id: SecureRandom.uuid,
        status: "pending",
        required_reason: "initial_submission",
        required_at: now
      )

      assert_not requirement.valid?
      assert requirement.errors[:admission_slot_id].present?
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          Ticketing::RegistrationConsentRequirement.insert_all!([
            {
              id: SecureRandom.uuid,
              registration_id: @registration.id,
              consent_document_version_id: version.id,
              required: true,
              acceptance_scope: "admission_slot",
              package_unit_number: 1,
              admission_position: 1,
              admission_slot_id: SecureRandom.uuid,
              status: "pending",
              required_reason: "initial_submission",
              required_at: now,
              created_at: now,
              updated_at: now
            }
          ])
        end
      end
    end

    test "an existing pending requirement remains valid after a newer version is published" do
      document = @requirement.consent_document_version.consent_document
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

      requirement = @requirement.reload
      assert_predicate requirement, :valid?
      assert_equal "pending", requirement.status
      assert_equal "retired", requirement.consent_document_version.reload.status
      assert_equal "published", newer.reload.status
    end

    test "database rejects every immutable snapshot and lineage field" do
      immutable_changes = {
        registration_id: SecureRandom.uuid,
        consent_document_version_id: SecureRandom.uuid,
        required: false,
        acceptance_scope: "admission_slot",
        package_unit_number: 1,
        admission_position: 1,
        admission_slot_id: SecureRandom.uuid,
        required_reason: "reconsent",
        required_by_id: core_users(:super_admin).id,
        required_at: 1.hour.ago,
        supersedes_requirement_id: SecureRandom.uuid
      }

      immutable_changes.each do |field, value|
        assert_raises(ActiveRecord::StatementInvalid, field.to_s) do
          Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
            Ticketing::RegistrationConsentRequirement.where(id: @requirement.id).update_all(field => value)
          end
        end
      end
    end

    test "database rejects backward status transitions" do
      acceptance = accept_consent(
        requirement: @requirement,
        content_sha256: @requirement.consent_document_version.content_sha256
      ).value
      assert_equal @requirement.id, acceptance.registration_consent_requirement_id

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          Ticketing::RegistrationConsentRequirement.where(id: @requirement.id).update_all(status: "pending")
        end
      end
    end

    test "database rejects subject changes after acceptance" do
      _document, version = create_consent_document(scope: "admission_slot")
      requirement = build_consent_requirements.value.find do |candidate|
        candidate.consent_document_version_id == version.id
      end
      assign_slot!(requirement, subject: @actor)
      accept_consent(requirement:, content_sha256: version.content_sha256)

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.transaction(requires_new: true) do
          Ticketing::RegistrationConsentRequirement.where(id: requirement.id)
            .update_all(subject_user_id: @replacement_subject.id)
        end
      end
    end

    test "superseded_at cannot change after a requirement is superseded" do
      superseded_at = Time.current
      @requirement.update!(status: "superseded", superseded_at:)

      @requirement.superseded_at = superseded_at + 1.minute
      assert_not @requirement.valid?
      assert @requirement.errors[:superseded_at].present?
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsentRequirement.where(id: @requirement.id)
          .update_all(superseded_at: superseded_at + 1.minute)
      end
    end

    private

    def insert_requirement!(status:)
      _document, version = create_consent_document(scope: "buyer")
      now = Time.current
      Ticketing::RegistrationConsentRequirement.insert_all!([
        {
          id: SecureRandom.uuid,
          registration_id: @registration.id,
          consent_document_version_id: version.id,
          required: true,
          acceptance_scope: "buyer",
          subject_user_id: @actor.id,
          status:,
          required_reason: "initial_submission",
          required_at: now,
          created_at: now,
          updated_at: now
        }
      ])
    end

    def trigger_definition(name)
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = #{ActiveRecord::Base.connection.quote(name)}"
      )
    end
  end
end
