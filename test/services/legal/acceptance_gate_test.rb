# frozen_string_literal: true

require "test_helper"

module Legal
  class AcceptanceGateTest < ActiveSupport::TestCase
    setup do
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
      @doc.versions.create!(version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "published", published_by: core_users(:super_admin), published_at: Time.current,
        created_by: core_users(:super_admin))
    end

    test "reports required published docs as unaccepted when no acceptance" do
      out = Legal::AcceptanceGate.required_for(
        context: { subject: core_users(:attendee), jurisdiction_code: "GLOBAL", locale: "en" }
      )
      assert out.any? { |d| d[:document_type] == "platform_terms" && d[:accepted] == false }
    end

    test "marks accepted once RecordAcceptance runs" do
      version = @doc.versions.published.first
      Legal::RecordAcceptance.call(
        subject: core_users(:attendee), legal_document_version: version,
        accepted_by: core_users(:super_admin)
      )
      out = Legal::AcceptanceGate.required_for(
        context: { subject: core_users(:attendee), jurisdiction_code: "GLOBAL", locale: "en" }
      )
      assert out.any? { |d| d[:document_type] == "platform_terms" && d[:accepted] == true }
    end
  end
end
