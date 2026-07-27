# frozen_string_literal: true

require "test_helper"

module Events
  module ConsentDocuments
    class DeactivateTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
      end

      def build_document(active: true)
        Events::ConsentDocument.create!(
          event: @event, created_by: @actor, type: "terms", name: "Terms", active: active
        )
      end

      test "deactivates an active document and flips the flag" do
        doc = build_document(active: true)
        result = Events::ConsentDocuments::Deactivate.call(consent_document: doc, actor: @actor)
        assert result.success?, result.error.inspect
        assert_not doc.reload.active?
      end

      test "is idempotent (no duplicate audit on replay)" do
        doc = build_document(active: true)
        subject = -> { Events::ConsentDocuments::Deactivate.call(consent_document: doc, actor: @actor) }

        assert_audit_idempotent(
          subject,
          action: "event.consent.deactivated",
          auditable_type: "Events::ConsentDocument",
          auditable_id: doc.id
        )
        assert_not doc.reload.active?
      end
    end
  end
end
