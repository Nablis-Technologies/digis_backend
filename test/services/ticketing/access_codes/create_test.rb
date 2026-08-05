# frozen_string_literal: true

require "test_helper"

module Ticketing
  module AccessCodes
    class CreateTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @ticket_type = ticket_product.ticket_type
        @actor = core_users(:super_admin)
      end

      test "requires an idempotency key" do
        result = create_access_code(idempotency_key: nil)

        assert result.failure?
        assert_match(/idempotency key/i, result.error.message)
      end

      test "replays the original encrypted code without creating another record" do
        subject = lambda { create_access_code(idempotency_key: "access-code-replay") }

        first = subject.call
        second = subject.call

        assert first.success?, first.error&.message
        assert second.success?, second.error&.message
        assert_equal first.value.record.id, second.value.record.id
        assert_equal first.value.plaintext, second.value.plaintext
        assert_equal 1, Ticketing::AccessCode.where(ticket_type_id: @ticket_type.id).count
        assert_equal 1, Core::AuditLog.where(
          action: "ticketing.access_code.created", auditable_id: first.value.record.id
        ).count

        stored_code = Ticketing::AccessCode.connection.select_value(
          "SELECT code_ciphertext FROM ticketing_access_codes WHERE id = '#{first.value.record.id}'"
        )
        refute_equal first.value.plaintext, stored_code
        refute_includes stored_code, first.value.plaintext
      end

      test "rejects an idempotency key reused for a different request" do
        first = create_access_code(idempotency_key: "access-code-conflict")
        second = create_access_code(
          idempotency_key: "access-code-conflict",
          attributes: { code: "DIFFERENT-CODE", max_uses: 3 }
        )

        assert first.success?, first.error&.message
        assert second.failure?
        assert_match(/different request/i, second.error.message)
        assert_equal 1, Ticketing::AccessCode.where(ticket_type_id: @ticket_type.id).count
      end

      private

      def create_access_code(idempotency_key:, attributes: { code: "REPLAY-CODE", max_uses: 2 })
        Ticketing::AccessCodes::Create.call(
          ticket_type: @ticket_type,
          actor: @actor,
          attributes: attributes,
          idempotency_key:
        )
      end

      def ticket_product
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name: "Access-code ticket", type: "ticket" },
          ticket_type_attributes: {
            audience: "code_or_invitation", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value
      end
    end
  end
end
