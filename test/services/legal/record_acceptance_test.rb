# frozen_string_literal: true

require "test_helper"
require "support/idempotency_assertions"

module Legal
  class RecordAcceptanceTest < ActiveSupport::TestCase
    setup do
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
      @version = @doc.versions.create!(version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin))
    end

    test "records a user acceptance with evidence digest" do
      result = Legal::RecordAcceptance.call(
        subject: core_users(:attendee), legal_document_version: @version,
        accepted_by: core_users(:super_admin)
      )
      assert result.success?
      acc = result.value
      assert_equal "user", acc.subject_type
      assert_equal core_users(:attendee).id, acc.subject_id
      assert_equal @version.content_sha256, acc.content_sha256
      assert_equal 64, acc.evidence_digest.length
    end

    test "idempotent via request_uuid (no duplicate acceptance, no duplicate audit)" do
      uuid = SecureRandom.uuid
      subject = -> do
        Legal::RecordAcceptance.call(
          subject: core_users(:attendee), legal_document_version: @version,
          accepted_by: core_users(:super_admin), request_uuid: uuid
        )
      end

      # Resource side-effect is stable under replay (project IdempotencyAssertions helper).
      # The second replay returns the existing acceptance, so no second audit is written.
      assert_idempotent(subject, counter: -> { Legal::LegalAcceptance.count })
      assert_equal 1, Core::AuditLog.where(audit_key: "legal-accept-#{uuid}").count
      assert_equal 1, Legal::LegalAcceptance.where(request_uuid: uuid).count
    end

    test "rejects unpublished version" do
      draft = @doc.versions.create!(version: 2, title: "T2", body: "B2",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T2", body: "B2"),
        status: "draft", created_by: core_users(:super_admin))
      result = Legal::RecordAcceptance.call(
        subject: core_users(:attendee), legal_document_version: draft,
        accepted_by: core_users(:super_admin)
      )
      assert result.failure?
      assert_equal "version_not_published", result.error.code
    end
  end
end
