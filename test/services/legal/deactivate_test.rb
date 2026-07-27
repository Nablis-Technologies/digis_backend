# frozen_string_literal: true

require "test_helper"

module Legal
  class DeactivateTest < ActiveSupport::TestCase
    def setup
      @actor = core_users(:super_admin)
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en",
        created_by: @actor, active: true
      )
    end

    test "deactivates an active document and flips the flag" do
      result = Legal::Deactivate.call(legal_document: @doc, actor: @actor)
      assert result.success?, result.error.inspect
      assert_not @doc.reload.active?
    end

    test "is idempotent (no duplicate audit on replay)" do
      subject = -> { Legal::Deactivate.call(legal_document: @doc, actor: @actor) }

      assert_audit_idempotent(
        subject,
        action: "legal.deactivated",
        auditable_type: "Legal::LegalDocument",
        auditable_id: @doc.id
      )
      assert_not @doc.reload.active?
    end
  end
end
