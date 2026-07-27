# frozen_string_literal: true

require "test_helper"

module Legal
  class LegalDocumentVersionTest < ActiveSupport::TestCase
    setup do
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
    end

    test "content_sha256 is canonical for same title/body" do
      a = Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B")
      b = Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B")
      assert_equal a, b
    end

    test "published version is immutable" do
      v = @doc.versions.create!(
        version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin)
      )
      v.body = "changed"
      assert v.invalid?
      assert_includes v.errors[:body], "cannot be changed on a published version"
    end

    test "published requires metadata" do
      v = @doc.versions.new(
        version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "published", created_by: core_users(:super_admin)
      )
      assert v.invalid?
      assert_includes v.errors[:published_by_id], "is required when published"
    end

    test "evidence_digest covers full acceptance event" do
      digest = Legal::LegalDocumentVersion.evidence_digest_for(
        legal_document_version_id: "v1", content_sha256: "c1",
        subject_type: "user", subject_id: "u1", accepted_by_user_id: "a1",
        accepted_by_role: nil, acceptance_method: "checkbox",
        accepted_at: Time.current, request_uuid: "r1"
      )
      assert_kind_of String, digest
      assert_equal 64, digest.length
    end
  end
end
