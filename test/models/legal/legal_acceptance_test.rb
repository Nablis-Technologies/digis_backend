# frozen_string_literal: true

require "test_helper"

module Legal
  class LegalAcceptanceTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
      @version = @doc.versions.create!(
        version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin)
      )
    end

    test "resolves subject via allowlist, not constantize" do
      acc = Legal::LegalAcceptance.new(
        subject_type: "user", subject_id: core_users(:attendee).id,
        legal_document_version_id: @version.id, accepted_by_user_id: core_users(:super_admin).id,
        acceptance_method: "checkbox", content_sha256: @version.content_sha256,
        evidence_digest: "x", request_uuid: SecureRandom.uuid, accepted_at: Time.current
      )
      assert_equal core_users(:attendee), acc.subject
    end

    test "rejects unknown subject_type" do
      acc = Legal::LegalAcceptance.new(
        subject_type: "Core::User", subject_id: core_users(:attendee).id,
        legal_document_version_id: @version.id, accepted_by_user_id: core_users(:super_admin).id,
        acceptance_method: "checkbox", content_sha256: "x", evidence_digest: "y",
        request_uuid: SecureRandom.uuid, accepted_at: Time.current
      )
      assert acc.invalid?
      assert_includes acc.errors[:subject_type], "is not included in the list"
    end

    test "only published versions may be accepted" do
      draft = @doc.versions.create!(
        version: 2, title: "T2", body: "B2",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T2", body: "B2"),
        status: "draft", created_by: core_users(:super_admin)
      )
      acc = Legal::LegalAcceptance.new(
        subject_type: "user", subject_id: core_users(:attendee).id,
        legal_document_version_id: draft.id, accepted_by_user_id: core_users(:super_admin).id,
        acceptance_method: "checkbox", content_sha256: "x", evidence_digest: "y",
        request_uuid: SecureRandom.uuid, accepted_at: Time.current
      )
      assert acc.invalid?
      assert_includes acc.errors[:legal_document_version_id], "must be a published version"
    end

    test "resolves a commercial assignment subject through the explicit allowlist" do
      schedule = create_schedule(code: "legal_assignment_schedule")
      fee_version = create_version(schedule, legal_document_version: @version)
      assignment = Commercial::Assignment.create!(
        organization: organizations_organizations(:one),
        fee_schedule_version: fee_version,
        assignment_type: "mutual_agreement",
        status: "pending_acceptance",
        reason: "Commercial legal evidence test",
        effective_from: 1.day.from_now,
        risk_level: "high",
        created_by: core_users(:super_admin)
      )
      acc = Legal::LegalAcceptance.new(
        subject_type: "commercial_assignment", subject_id: assignment.id,
        legal_document_version_id: @version.id, accepted_by_user_id: core_users(:super_admin).id,
        acceptance_method: "checkbox", content_sha256: @version.content_sha256,
        evidence_digest: "x", request_uuid: SecureRandom.uuid, accepted_at: Time.current
      )

      assert_equal assignment, acc.subject
      assert_predicate acc, :valid?
    end
  end
end
