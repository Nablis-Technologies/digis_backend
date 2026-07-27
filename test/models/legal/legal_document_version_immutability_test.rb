# frozen_string_literal: true

require "test_helper"

module Legal
  # Exercises the DB-level immutability trigger on legal document versions.
  class LegalDocumentVersionImmutabilityTest < ActiveSupport::TestCase
    setup do
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
    end

    def published_version
      @doc.versions.create!(
        version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin)
      )
    end

    test "published legal version rejects column changes at the DB layer" do
      v = published_version
      assert_raises(ActiveRecord::StatementInvalid) do
        Legal::LegalDocumentVersion.where(id: v.id).update_all(body: "tampered")
      end
    end

    test "published legal version cannot be deleted at the DB layer" do
      v = published_version
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.lease_connection.execute(
          "DELETE FROM legal_document_versions WHERE id = '#{v.id}'")
      end
    end

    test "draft legal version may still be edited" do
      v = @doc.versions.create!(
        version: 2, title: "Draft", body: "Draft body",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "Draft", body: "Draft body"),
        status: "draft", created_by: core_users(:super_admin)
      )
      assert_nothing_raised do
        Legal::LegalDocumentVersion.where(id: v.id).update_all(body: "edited")
      end
      assert_equal "edited", v.reload.body
    end

    test "forward status transition (publish -> retire) is permitted" do
      v = published_version
      assert_nothing_raised do
        Legal::LegalDocumentVersion.where(id: v.id).update_all(status: "retired")
      end
      assert_equal "retired", v.reload.status
    end

    test "draft legal version may be deleted at the DB layer" do
      v = @doc.versions.create!(
        version: 3, title: "Draft", body: "Draft body",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "Draft", body: "Draft body"),
        status: "draft", created_by: core_users(:super_admin)
      )
      assert_nothing_raised do
        ActiveRecord::Base.lease_connection.execute(
          "DELETE FROM legal_document_versions WHERE id = '#{v.id}'")
      end
    end
  end
end
