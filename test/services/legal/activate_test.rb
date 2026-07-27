# frozen_string_literal: true

require "test_helper"

module Legal
  class ActivateTest < ActiveSupport::TestCase
    def setup
      @actor = core_users(:super_admin)
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en",
        created_by: @actor, active: false
      )
    end

    test "activates an inactive document and flips the flag" do
      result = Legal::Activate.call(legal_document: @doc, actor: @actor)
      assert result.success?, result.error.inspect
      assert @doc.reload.active?
    end

    test "is idempotent (no duplicate audit on replay)" do
      subject = -> { Legal::Activate.call(legal_document: @doc, actor: @actor) }

      assert_audit_idempotent(
        subject,
        action: "legal.activated",
        auditable_type: "Legal::LegalDocument",
        auditable_id: @doc.id
      )
      assert @doc.reload.active?
    end
  end
end
