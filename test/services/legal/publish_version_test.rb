# frozen_string_literal: true

require "test_helper"
require "support/idempotency_assertions"

module Legal
  class PublishVersionTest < ActiveSupport::TestCase
    setup do
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
    end

    test "promotes draft to published and retires prior published" do
      v1 = @doc.versions.create!(version: 1, title: "T1", body: "B1",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T1", body: "B1"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin))
      v2 = @doc.versions.create!(version: 2, title: "T2", body: "B2",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T2", body: "B2"),
        status: "draft", created_by: core_users(:super_admin))

      result = Legal::PublishVersion.call(legal_document: @doc, actor: core_users(:super_admin))
      assert result.success?
      assert_equal "published", v2.reload.status
      assert_equal "retired", v1.reload.status
      assert_equal 1, @doc.versions.published.count
    end

    test "publish is idempotent (no duplicate audit)" do
      @doc.versions.create!(version: 1, title: "T1", body: "B1",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T1", body: "B1"),
        status: "draft", created_by: core_users(:super_admin))

      assert_audit_idempotent(
        -> { Legal::PublishVersion.call(legal_document: @doc, actor: core_users(:super_admin)) },
        action: "legal.published",
        auditable_type: "Legal::LegalDocument",
        auditable_id: @doc.id
      )
    end

    test "fails with no draft and nothing published" do
      result = Legal::PublishVersion.call(legal_document: @doc, actor: core_users(:super_admin))
      assert result.failure?
      assert_equal "no_draft", result.error.code
    end
  end
end
