# frozen_string_literal: true

require "test_helper"

module Legal
  class LegalDocumentTest < ActiveSupport::TestCase
    test "requires unique document_type per jurisdiction and locale" do
      doc = Legal::LegalDocument.new(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
      doc.save!
      dup = Legal::LegalDocument.new(
        document_type: "platform_terms", internal_name: "ToS 2",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
      assert dup.invalid?
      assert_includes dup.errors[:document_type], "has already been taken"
    end

    test "rejects unknown document_type" do
      doc = Legal::LegalDocument.new(
        document_type: "bogus", internal_name: "X",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
      assert doc.invalid?
      assert_includes doc.errors[:document_type], "is not included in the list"
    end
  end
end
